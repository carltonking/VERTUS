import Foundation

// MARK: - Multi-agent plan

/// The team's plan for one run: an ordered list of stages, where the group
/// numbers express dependencies. Decoded from the Planning agent's JSON reply;
/// see `parse` for the wire shape.
struct AgentPlan: Sendable, Equatable {
    var stages: [AgentStage]
    /// The planner's raw reply, kept so the team (and the user) can see the
    /// reasoning behind the stage order. Empty for fallback plans.
    var rawText: String

    /// Hard cap on stages per run — the cost budget's teeth. A runaway plan
    /// can't spawn an unbounded team; the planner is told the cap and the
    /// parser enforces it.
    static let maxStages = 6

    /// Ordered group numbers (ascending, normalized to >= 1).
    var groups: [Int] {
        var seen: Set<Int> = []
        return stages.compactMap { stage in
            guard seen.insert(stage.group).inserted else { return nil }
            return stage.group
        }.sorted()
    }

    /// Decode the planning agent's JSON reply into a plan.
    ///
    /// The planner is told to answer with ONLY:
    ///     {"stages":[{"role":"research|planning|code|review|writing","task":"...","group":1}, ...]}
    /// Real models wrap JSON in prose or ```json fences, so the parser grabs the
    /// outermost {...} object and ignores everything around it. Any stage that
    /// fails to decode, an empty stage list, or more than `maxStages` stages
    /// makes the whole plan invalid — the orchestrator falls back.
    static func parse(_ text: String) -> AgentPlan? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        let jsonText = String(text[start...end])
        guard let data = jsonText.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawStages = object["stages"] as? [[String: Any]]
        else { return nil }

        var stages: [AgentStage] = []
        for raw in rawStages {
            guard let roleRaw = raw["role"] as? String,
                  let role = AgentRole(rawValue: roleRaw.lowercased()),
                  let task = raw["task"] as? String
            else { return nil }
            let taskTrimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !taskTrimmed.isEmpty else { return nil }
            let group = max(1, (raw["group"] as? Int) ?? 1)
            stages.append(AgentStage(role: role, task: taskTrimmed, group: group))
        }
        guard !stages.isEmpty, stages.count <= maxStages else { return nil }
        return AgentPlan(stages: stages, rawText: text)
    }

    /// The plan used when the Planning agent itself fails: a conservative
    /// sequential pipeline, shaped by whether the request smells like code.
    /// Better than refusing the run — the team still exists, it just plans
    /// itself.
    static func fallback(for task: String) -> AgentPlan {
        let lower = task.lowercased()
        let codeMarkers = ["code", "function", "bug", "refactor", "script", "api",
                           "class", "implement", "debug", "compile"]
        if codeMarkers.contains(where: { lower.contains($0) }) {
            return AgentPlan(stages: [
                AgentStage(role: .code, task: task, group: 1),
                AgentStage(role: .review, task: "Review the code agent's work for correctness, edge cases and readability. List concrete fixes if any are needed.", group: 2),
                AgentStage(role: .writing, task: "Deliver the final answer for: \(task)", group: 3),
            ], rawText: "")
        }
        return AgentPlan(stages: [
            AgentStage(role: .research, task: "Gather and synthesize what is needed for: \(task)", group: 1),
            AgentStage(role: .writing, task: "Deliver the final answer for: \(task)", group: 2),
        ], rawText: "")
    }
}

// MARK: - Coordinator

/// The agent-to-agent communication layer.
///
/// Agents never talk directly (no RPC, no shared state). They post finished
/// results to the coordinator's mailbox; the orchestrator forwards the mailbox
/// as context to the next agent, which is what makes later agents build on
/// earlier ones. The coordinator also owns the team itself — one live
/// `SpecializedAgent` per role, created lazily and reused across runs so the
/// expensive Hermes spawn happens once per role, not once per run.
actor AgentCoordinator {

    static let shared = AgentCoordinator()

    /// Live agents, keyed by role. A role appears here once its first run
    /// touched it; the sessions stay warm until shutdownAll.
    private var agents: [AgentRole: SpecializedAgent] = [:]

    private init() {}

    /// The team member for a role, creating (and keeping) it on first use.
    /// `timeout` seeds the session's turn deadline; later config changes don't
    /// retroactively apply to a session that already exists.
    func agent(for role: AgentRole, timeout: TimeInterval) -> SpecializedAgent {
        if let existing = agents[role] { return existing }
        let agent = SpecializedAgent(role: role, timeout: timeout)
        agents[role] = agent
        return agent
    }

    /// Execute a plan: groups run in order, stages within a group run
    /// concurrently when `parallel` is true (they are independent by
    /// construction), and every finished stage lands in the mailbox that the
    /// next group sees. Yields progress events through `progress`.
    ///
    /// Cancellation: the caller's task may be cancelled (bar dismissed). The
    /// coordinator checks between stages and cancels the in-flight agent turn
    /// before giving up, so no orphaned Hermes turn keeps burning quota.
    func execute(
        plan: AgentPlan,
        originalRequest: String,
        parallel: Bool,
        timeout: TimeInterval,
        progress: @escaping @Sendable (MultiAgentEvent) -> Void
    ) async -> [AgentStageResult] {
        var results: [AgentStageResult] = []
        // The mailbox: everything the team has produced so far, handed to each
        // next agent as context. Grows across groups; SpecializedAgent bounds
        // what actually reaches the prompt.
        var mailbox: [AgentMessage] = []
        if !plan.rawText.isEmpty {
            mailbox.append(AgentMessage(role: .planning, text: plan.rawText))
        }

        let total = plan.stages.count
        var displayIndex = 1
        var activeAgent: SpecializedAgent?

        for group in plan.groups {
            if Task.isCancelled {
                await activeAgent?.cancelTurn()
                return results
            }
            let stages = plan.stages.filter { $0.group == group }
            let runInParallel = parallel && stages.count > 1

            if runInParallel {
                for stage in stages {
                    progress(.stageStarted(role: stage.role, index: displayIndex, total: total))
                    displayIndex += 1
                }
                let outcomes = await withTaskGroup(of: (Int, AgentStageResult?).self) { group in
                    for (index, stage) in stages.enumerated() {
                        group.addTask {
                            let agent = await self.agent(for: stage.role, timeout: timeout)
                            let stageStart = Date()
                            let (chunkStream, chunkSink) = AsyncStream<String>.makeStream()
                            let forward = Task {
                                for await chunk in chunkStream {
                                    progress(.stageText(role: stage.role, chunk: chunk))
                                }
                            }
                            let transcript = try? await agent.run(
                                task: stage.task,
                                originalRequest: originalRequest,
                                context: mailbox,
                                stream: chunkSink)
                            chunkSink.finish()
                            await forward.value
                            guard let transcript else { return (index, nil) }
                            return (index, AgentStageResult(
                                stage: stage,
                                transcript: transcript,
                                duration: Date().timeIntervalSince(stageStart)))
                        }
                    }
                    var collected: [(Int, AgentStageResult?)] = []
                    for await outcome in group { collected.append(outcome) }
                    return collected
                }
                // Reassemble in stage order so the mailbox reads top-to-bottom.
                for (index, stage) in stages.enumerated() {
                    guard let result = outcomes.first(where: { $0.0 == index })?.1 else {
                        progress(.stageFailed(role: stage.role, message: "agent failed or was cancelled"))
                        continue
                    }
                    results.append(result)
                    mailbox.append(AgentMessage(role: stage.role, text: result.transcript))
                    progress(.stageFinished(role: stage.role, transcript: result.transcript, duration: result.duration))
                }
            } else {
                for stage in stages {
                    if Task.isCancelled {
                        await activeAgent?.cancelTurn()
                        return results
                    }
                    progress(.stageStarted(role: stage.role, index: displayIndex, total: total))
                    displayIndex += 1
                    let agent = await agent(for: stage.role, timeout: timeout)
                    activeAgent = agent
                    let stageStart = Date()
                    let (chunkStream, chunkSink) = AsyncStream<String>.makeStream()
                    let forward = Task {
                        for await chunk in chunkStream {
                            progress(.stageText(role: stage.role, chunk: chunk))
                        }
                    }
                    do {
                        let transcript = try await agent.run(
                            task: stage.task,
                            originalRequest: originalRequest,
                            context: mailbox,
                            stream: chunkSink)
                        chunkSink.finish()
                        await forward.value
                        let result = AgentStageResult(
                            stage: stage,
                            transcript: transcript,
                            duration: Date().timeIntervalSince(stageStart))
                        results.append(result)
                        mailbox.append(AgentMessage(role: stage.role, text: transcript))
                        progress(.stageFinished(role: stage.role, transcript: transcript, duration: result.duration))
                    } catch is CancellationError {
                        chunkSink.finish()
                        await agent.cancelTurn()
                        return results
                    } catch {
                        chunkSink.finish()
                        await forward.value
                        progress(.stageFailed(role: stage.role, message: error.localizedDescription))
                    }
                }
            }
            activeAgent = nil
        }
        return results
    }

    /// Tear down every team member's Hermes process. Called at app quit; the
    /// registry is emptied so a later run (if any) spawns fresh sessions.
    func shutdownAll() async {
        for agent in agents.values {
            await agent.shutdown()
        }
        agents.removeAll()
    }
}
