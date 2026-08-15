import XCTest
@testable import Alfred

/// Covers the pure, deterministic parts of the multi-agent system. Everything
/// here avoids spawning a subprocess or touching a live Hermes session: query
/// routing (MultiAgentOrchestrator.route), plan decoding (AgentPlan.parse),
/// fallback planning, group ordering, role prompts and config defaults.
@MainActor
final class MultiAgentTests: XCTestCase {

    // MARK: - Routing (MultiAgentOrchestrator.route)

    func testExplicitPrefixesRouteAndStrip() {
        XCTAssertEqual(MultiAgentOrchestrator.route("multi: plan my week"), "plan my week")
        XCTAssertEqual(MultiAgentOrchestrator.route("MULTI: deep research on MCP servers"), "deep research on MCP servers")
        XCTAssertEqual(MultiAgentOrchestrator.route("multi-agent: job search for AI roles"), "job search for AI roles")
        XCTAssertEqual(MultiAgentOrchestrator.route("/agents review the parser"), "review the parser")
        XCTAssertEqual(MultiAgentOrchestrator.route("swarm: compare three web frameworks"), "compare three web frameworks")
    }

    func testExplicitPrefixAloneReturnsNil() {
        XCTAssertNil(MultiAgentOrchestrator.route("multi:"))
        XCTAssertNil(MultiAgentOrchestrator.route("/agents"))
        XCTAssertNil(MultiAgentOrchestrator.route("  multi:   "))
    }

    func testMarkerPhrasesRoute() {
        XCTAssertEqual(MultiAgentOrchestrator.route("run a multi-agent pass on the router"), "run a multi-agent pass on the router")
        XCTAssertEqual(MultiAgentOrchestrator.route("help me with a deep research task on LLM evals"), "help me with a deep research task on LLM evals")
        XCTAssertEqual(MultiAgentOrchestrator.route("plan my week and prioritize my tasks"), "plan my week and prioritize my tasks")
        XCTAssertEqual(MultiAgentOrchestrator.route("set up a job search across three boards"), "set up a job search across three boards")
        XCTAssertEqual(MultiAgentOrchestrator.route("code review the new payment flow"), "code review the new payment flow")
        XCTAssertEqual(MultiAgentOrchestrator.route("can you review this code for me"), "can you review this code for me")
    }

    func testOrdinaryQueriesDoNotRoute() {
        XCTAssertNil(MultiAgentOrchestrator.route("what's the weather today"))
        XCTAssertNil(MultiAgentOrchestrator.route("draft a reply to Sarah"))
        XCTAssertNil(MultiAgentOrchestrator.route("add a unit test for the parser"))
        XCTAssertNil(MultiAgentOrchestrator.route("summarize my emails"))
    }

    // MARK: - Plan parsing (AgentPlan.parse)

    func testParsePlainJSON() {
        let text = #"{"stages":[{"role":"research","task":"Find sources","group":1},{"role":"writing","task":"Write the report","group":2}]}"#
        let plan = AgentPlan.parse(text)
        XCTAssertEqual(plan?.stages.count, 2)
        XCTAssertEqual(plan?.stages[0].role, .research)
        XCTAssertEqual(plan?.stages[0].task, "Find sources")
        XCTAssertEqual(plan?.stages[0].group, 1)
        XCTAssertEqual(plan?.stages[1].role, .writing)
        XCTAssertEqual(plan?.groups, [1, 2])
    }

    func testParseFencedJSON() {
        let text = """
        Here is my plan for the team:

        ```json
        {"stages":[{"role":"code","task":"Implement the retry loop","group":1},{"role":"review","task":"Check edge cases","group":2}]}
        ```

        Hope that helps!
        """
        let plan = AgentPlan.parse(text)
        XCTAssertEqual(plan?.stages.count, 2)
        XCTAssertEqual(plan?.stages[0].role, .code)
        XCTAssertEqual(plan?.stages[1].role, .review)
    }

    func testParseNormalizesGroupNumbers() {
        let text = #"{"stages":[{"role":"research","task":"A","group":0},{"role":"code","task":"B","group":-2},{"role":"writing","task":"C","group":2}]}"#
        let plan = AgentPlan.parse(text)
        XCTAssertEqual(plan?.stages.map(\.group), [1, 1, 2])
        XCTAssertEqual(plan?.groups, [1, 2])
    }

    func testParseRejectsInvalidPlans() {
        // Not JSON at all.
        XCTAssertNil(AgentPlan.parse("I don't know how to plan this."))
        // No stages key.
        XCTAssertNil(AgentPlan.parse(#"{"mode":"sequential"}"#))
        // Unknown role.
        XCTAssertNil(AgentPlan.parse(#"{"stages":[{"role":"astronaut","task":"X","group":1}]}"#))
        // Empty task.
        XCTAssertNil(AgentPlan.parse(#"{"stages":[{"role":"research","task":"  ","group":1}]}"#))
        // Empty stage list.
        XCTAssertNil(AgentPlan.parse(#"{"stages":[]}"#))
        // Over the cost-budget cap — a runaway plan must not spawn 40 agents.
        let many = (1...10).map { #"{"role":"research","task":"T\#($0)","group":1}"# }.joined(separator: ",")
        XCTAssertNil(AgentPlan.parse(#"{"stages":[\#(many)]}"#))
    }

    func testPlanCapMatchesPlannerInstruction() {
        // The planner prompt is told the cap; the parser enforces the same one.
        XCTAssertEqual(AgentPlan.maxStages, 6)
    }

    // MARK: - Fallback plans

    func testFallbackForCodeShapes() {
        let plan = AgentPlan.fallback(for: "implement a retry loop with backoff")
        XCTAssertEqual(plan.stages.map(\.role), [.code, .review, .writing])
        XCTAssertEqual(plan.groups, [1, 2, 3])
        // The review stage is QA-shaped, not a duplicate of the task.
        XCTAssertTrue(plan.stages[1].task.lowercased().contains("review"))
    }

    func testFallbackForGeneralShapes() {
        let plan = AgentPlan.fallback(for: "understand the MCP protocol landscape")
        XCTAssertEqual(plan.stages.map(\.role), [.research, .writing])
        XCTAssertEqual(plan.groups, [1, 2])
    }

    // MARK: - Group ordering

    func testGroupsRunAscendingWithIndependentParallelGroups() {
        // Group 3 may share group number with group 1? No — groups must be
        // processed ascending; equal groups are parallel-eligible. This plan
        // has research+code in group 1 (parallel), then writing in group 2.
        let plan = AgentPlan(stages: [
            AgentStage(role: .writing, task: "Final answer", group: 2),
            AgentStage(role: .research, task: "Gather", group: 1),
            AgentStage(role: .code, task: "Build", group: 1),
        ], rawText: "")
        XCTAssertEqual(plan.groups, [1, 2])
        let groupOne = plan.stages.filter { $0.group == 1 }
        XCTAssertEqual(groupOne.map(\.role), [.research, .code])
    }

    // MARK: - Roles

    func testEveryRoleHasAPromptAndName() {
        for role in AgentRole.allCases {
            XCTAssertFalse(role.displayName.isEmpty)
            XCTAssertFalse(role.systemPrompt.isEmpty, "\(role) must have a system prompt")
            XCTAssertTrue(role.systemPrompt.lowercased().contains(role.rawValue)
                          || role == .planning, // planning prompt names the JSON job
                          "\(role) prompt should mention its own job")
        }
    }

    // MARK: - Config defaults

    func testConfigDefaults() {
        let orchestrator = MultiAgentOrchestrator.shared
        XCTAssertTrue(orchestrator.enabled)
        XCTAssertEqual(orchestrator.parallelization, .sequential)
        XCTAssertEqual(orchestrator.timeout, .fifteenMinutes)
    }

    func testTimeoutEnums() {
        XCTAssertEqual(AgentTimeout.fiveMinutes.seconds, 300)
        XCTAssertEqual(AgentTimeout.fifteenMinutes.seconds, 900)
        XCTAssertEqual(AgentTimeout.oneHour.seconds, 3600)
        for timeout in AgentTimeout.allCases {
            XCTAssertFalse(timeout.displayName.isEmpty)
        }
        for mode in MultiAgentParallelization.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
        }
    }
}
