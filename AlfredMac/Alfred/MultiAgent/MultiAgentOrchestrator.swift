import Foundation

// MARK: - Events

/// What a multi-agent run streams to its consumer (the bar, an MCP tool, a
/// routine). Mirrors HermesEvent's shape so the same rendering idioms apply.
enum MultiAgentEvent: Sendable {
    /// A stage began. The planner is reported as index 1/1, then the decoded
    /// stages follow as 2…N+1 / N+1 — the total counts the planner.
    case stageStarted(role: AgentRole, index: Int, total: Int)
    /// Incremental agent text. Append, never replace.
    case stageText(role: AgentRole, chunk: String)
    /// A stage finished cleanly with its full transcript.
    case stageFinished(role: AgentRole, transcript: String, duration: TimeInterval)
    /// A stage failed; the run continues with the remaining stages.
    case stageFailed(role: AgentRole, message: String)
    /// The whole run failed.
    case failed(String)
    /// The run finished; `stages` is how many agents ran (planner excluded).
    case finished(stages: Int, duration: TimeInterval)
}

// MARK: - Config types

/// How the team executes: strictly one agent at a time, or concurrently within
/// a parallel group (the Planning agent decides what belongs in a group).
enum MultiAgentParallelization: String, CaseIterable, Identifiable, Sendable {
    case sequential
    case parallel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sequential: return "Sequential"
        case .parallel: return "Parallel"
        }
    }
}

/// Per-agent turn ceiling. A wedged agent (no response) is restarted by the
/// session watchdog at this bound; actively-streaming turns are unaffected.
enum AgentTimeout: Int, CaseIterable, Identifiable, Sendable {
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case oneHour = 3600

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .fiveMinutes: return "5 min"
        case .fifteenMinutes: return "15 min"
        case .oneHour: return "1 hour"
        }
    }

    var seconds: TimeInterval { TimeInterval(rawValue) }
}

// MARK: - Orchestrator

/// Owns the multi-agent team end to end: config, request routing, the Planning
/// stage that designs each run, and execution through AgentCoordinator.
///
/// One run looks like this:
///   1. A request routes here (bar prefix `multi:`/`/agents`, a marker phrase,
///      the `multi_agent_run` MCP tool, or a routine step).
///   2. The Planning agent turns it into a JSON plan: which roles, what task
///      each, and which groups may run in parallel.
///   3. The coordinator executes the plan — groups in order, stages within a
///      group concurrently when parallel mode is on — with every agent's
///      output posted to a mailbox that the next stage reads as context.
///   4. The last stage's deliverable is the final answer.
///
/// Sessions are long-lived per role (see AgentCoordinator): the expensive
/// Hermes spawn happens once per role, not once per run, so follow-up runs
/// start near-instantly.
@MainActor
final class MultiAgentOrchestrator: ObservableObject {

    static let shared = MultiAgentOrchestrator()

    // MARK: Config (persisted)

    /// Master switch. Off → multi-agent requests fall back to the single
    /// general agent, exactly as before this feature existed.
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
        }
    }

    /// Sequential = one agent at a time; Parallel = concurrent stages within a
    /// parallel group (the planner's group assignment decides what qualifies).
    @Published var parallelization: MultiAgentParallelization {
        didSet {
            guard parallelization != oldValue else { return }
            UserDefaults.standard.set(parallelization.rawValue, forKey: Keys.parallelization)
        }
    }

    /// Per-agent turn ceiling; see AgentTimeout.
    @Published var timeout: AgentTimeout {
        didSet {
            guard timeout != oldValue else { return }
            UserDefaults.standard.set(timeout.rawValue, forKey: Keys.timeout)
        }
    }

    private enum Keys {
        static let enabled = "alfred.multiAgentEnabled"
        static let parallelization = "alfred.multiAgentParallelization"
        static let timeout = "alfred.multiAgentTimeout"
    }

    /// The run currently streaming, so dismissal can stop it (and its agents).
    private var activeRunTask: Task<Void, Never>?
    /// Monotonic run counter, so a finishing (or cancelled) run only clears the
    /// task slot it actually owns — a newer run must never be clobbered.
    private var activeRunID = 0

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        parallelization = defaults.string(forKey: Keys.parallelization)
            .flatMap(MultiAgentParallelization.init(rawValue:)) ?? .sequential
        timeout = AgentTimeout(rawValue: defaults.integer(forKey: Keys.timeout)) ?? .fifteenMinutes
    }

    // MARK: - Routing

    /// Decide whether a request is a multi-agent request, and return the task
    /// to run (prefixes stripped). Nil → the normal single-agent path handles it.
    ///
    /// Pure and nonisolated so tests and background callers (routines, the MCP
    /// tool) use exactly the same detection as the bar. Explicit escape hatches
    /// first (`multi:` / `/agents`), then conservative marker phrases — a wrong
    /// guess is an inconvenience, not a loss, because a multi-agent run still
    /// answers any question.
    nonisolated static func route(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        // Explicit escape hatches — always route, prefix stripped.
        let prefixes = ["multi:", "multi-agent:", "/agents", "swarm:"]
        for prefix in prefixes where lower.hasPrefix(prefix) {
            let task = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return task.isEmpty ? nil : task
        }

        // Marker phrases: the natural ways people ask for a coordinated team.
        let markers = [
            "multi-agent", "multi agent", "agent team", "agent swarm",
            "deep research", "research project", "research report",
            "plan my week", "weekly planning", "weekly plan",
            "job search", "job hunt",
            "code review", "review this code", "review this implementation",
        ]
        guard markers.contains(where: { lower.contains($0) }) else { return nil }
        return trimmed
    }

    // MARK: - Running

    /// Run the team on `task`, streaming progress. The returned stream
    /// terminates on `.finished` / `.failed` / cancellation.
    ///
    /// Cancellation is wired two ways: stopping the iteration terminates the
    /// stream (onTermination cancels the pipeline, which cancels in-flight
    /// agent turns), and cancelActiveRun() does the same from outside (bar
    /// dismissal).
    func run(task: String) -> AsyncStream<MultiAgentEvent> {
        AsyncStream { continuation in
            activeRunID += 1
            let runID = activeRunID
            var pipeline: Task<Void, Never>?
            pipeline = Task { @MainActor [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.performRun(task: task, runID: runID, into: continuation)
            }
            activeRunTask = pipeline
            continuation.onTermination = { _ in
                // The consumer stopped iterating (bar dismissed / superseded):
                // cancel the pipeline, which cancels the in-flight agent turns.
                pipeline?.cancel()
            }
        }
    }

    /// Stop the current run (and its in-flight agent turns). The team sessions
    /// survive for the next run.
    func cancelActiveRun() {
        activeRunTask?.cancel()
        activeRunTask = nil
    }

    /// Run the team and collect the result as plain text — the MCP tool and
    /// routine-step surface. Headers and per-stage deliverables, no chatter.
    func runCollectingText(task: String) async -> String {
        var parts: [String] = []
        var failure: String?
        for await event in run(task: task) {
            switch event {
            case .stageStarted(let role, let index, let total):
                parts.append("— \(role.displayName) agent (\(index)/\(total)) —")
            case .stageFinished(let role, let transcript, _):
                parts.append(transcript.isEmpty
                    ? "[\(role.displayName) agent produced no text]"
                    : transcript)
            case .stageText:
                break   // the finished transcript already carries the full text
            case .stageFailed(let role, let message):
                parts.append("[\(role.displayName) agent failed: \(message)]")
            case .failed(let message):
                failure = message
            case .finished:
                break
            }
        }
        if let failure { return "Multi-agent run failed: \(failure)" }
        return parts.joined(separator: "\n\n")
    }

    /// Tear down every team session. Called at app quit.
    func shutdownAll() async {
        cancelActiveRun()
        await AgentCoordinator.shared.shutdownAll()
    }

    // MARK: - Pipeline

    private func performRun(task: String, runID: Int, into continuation: AsyncStream<MultiAgentEvent>.Continuation) async {
        let started = Date()
        defer {
            continuation.finish()
            if activeRunID == runID { activeRunTask = nil }
        }

        guard enabled else {
            continuation.yield(.failed(
                "Multi-agent is off — enable it in Alfred Settings (menu-bar icon → Alfred Settings → MULTI-AGENT), or ask me directly."))
            return
        }
        // The run spends quota on whichever provider is active, like a bar turn.
        if let provider = ProviderKeyRing.shared.activeKey?.provider {
            UsageTracker.shared.record(provider: provider)
        }

        // 1. The Planning agent designs the team.
        let plan: AgentPlan
        let plannerStarted = Date()
        continuation.yield(.stageStarted(role: .planning, index: 1, total: 1))
        do {
            let planner = await AgentCoordinator.shared.agent(for: .planning, timeout: timeout.seconds)
            let (planStream, planSink) = AsyncStream<String>.makeStream()
            let forward = Task {
                for await chunk in planStream {
                    continuation.yield(.stageText(role: .planning, chunk: chunk))
                }
            }
            let planText: String
            do {
                planText = try await planner.run(
                    task: Self.plannerTask(for: task),
                    originalRequest: task,
                    context: [],
                    stream: planSink)
            } catch {
                // Finish the sink so the forwarding task terminates — never
                // leave a task parked on an unfinished stream.
                planSink.finish()
                await forward.value
                throw error
            }
            planSink.finish()
            await forward.value
            continuation.yield(.stageFinished(
                role: .planning,
                transcript: planText,
                duration: Date().timeIntervalSince(plannerStarted)))

            if let parsed = AgentPlan.parse(planText) {
                plan = parsed
            } else {
                NSLog("[multi-agent] planner returned an unusable plan — falling back to a default pipeline")
                continuation.yield(.stageFailed(
                    role: .planning,
                    message: "The planner returned a plan I couldn't read — using a default pipeline."))
                plan = AgentPlan.fallback(for: task)
            }
        } catch {
            // The planner itself failed — that is infrastructure (no provider,
            // no binary), and the same failure will hit every worker. Report
            // honestly rather than letting a team of doomed agents run.
            NSLog("[multi-agent] planning agent failed: %@", error.localizedDescription)
            continuation.yield(.stageFailed(role: .planning, message: error.localizedDescription))
            continuation.yield(.failed(
                "The planning agent couldn't start (\(error.localizedDescription)). Multi-agent needs a working Hermes — the normal agent path may still work."))
            return
        }

        // 2. Execute the plan. Stage totals count the planner: 1 planner +
        //    N stages → the bar shows (2…N+1 / N+1).
        let total = plan.stages.count + 1
        let results = await AgentCoordinator.shared.execute(
            plan: plan,
            originalRequest: task,
            parallel: parallelization == .parallel,
            timeout: timeout.seconds) { event in
                // Re-number decoded stages to follow the planner (2…N+1 / N+1).
                switch event {
                case .stageStarted(let role, let index, _):
                    continuation.yield(.stageStarted(role: role, index: index + 1, total: total))
                case .stageFinished(let role, let transcript, let duration):
                    continuation.yield(.stageFinished(role: role, transcript: transcript, duration: duration))
                case .stageFailed(let role, let message):
                    continuation.yield(.stageFailed(role: role, message: message))
                case .stageText(let role, let chunk):
                    continuation.yield(.stageText(role: role, chunk: chunk))
                case .failed, .finished:
                    break
                }
            }

        if results.isEmpty {
            continuation.yield(.failed("The agent team couldn't complete the run."))
            return
        }
        continuation.yield(.finished(stages: results.count, duration: Date().timeIntervalSince(started)))
    }

    /// What the Planning agent is asked to produce: a JSON plan of the team.
    /// The shape is deliberately small so even a weak model can hit it.
    private static func plannerTask(for task: String) -> String {
        """
        Design a multi-agent run for the user's request below. Decide which \
        specialized agents are needed (planning, research, code, review, writing), \
        what each should deliver, and in what order.

        Groups express dependencies: stages in a higher group run only after every \
        stage in lower groups finishes; stages that share a group are independent \
        and may run in parallel.

        Answer ONLY with a JSON object in exactly this shape — no prose, no fences:
        {"stages":[{"role":"research","task":"<concrete deliverable>","group":1},{"role":"writing","task":"<concrete deliverable>","group":2}]}

        Rules:
        - Use 2 to \(AgentPlan.maxStages) stages. Every task must be concrete and self-contained.
        - Put independent work (research, code, planning) in the same group so it \
        can run in parallel; chain dependent stages across groups.
        - End with a writing or review stage that produces the final answer for the user.
        - "role" must be one of: planning, research, code, review, writing.

        The user's request: \(task)
        """
    }
}
