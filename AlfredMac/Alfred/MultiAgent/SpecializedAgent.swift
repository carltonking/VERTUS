import Foundation

// MARK: - Roles
//
// A multi-agent run is a team of specialized reasoning agents. Each role is a
// plain Hermes instance — the same `hermes acp` engine the bar uses — with a
// system prompt that narrows it to one job: planning, research, code, review
// or writing. The orchestrator decides which roles to spawn and in what order;
// agents never call each other, they post results to a mailbox the orchestrator
// forwards as context to the next agent (see AgentCoordinator).

/// A specialized reasoning role in the multi-agent team.
enum AgentRole: String, Codable, CaseIterable, Sendable {
    case planning
    case research
    case code
    case review
    case writing

    var displayName: String {
        switch self {
        case .planning: return "Planning"
        case .research: return "Research"
        case .code: return "Code"
        case .review: return "Review"
        case .writing: return "Writing"
        }
    }

    /// The system prompt that makes this instance a specialist. Every agent
    /// inherits Hermes' own tools (web, terminal, files, the Mac) — the prompt
    /// is what keeps each one on its lane.
    var systemPrompt: String {
        switch self {
        case .planning:
            return """
            You are the Planning agent on a multi-agent team. Your job is to break \
            complex requests into a concrete, ordered plan: what must be researched, \
            built, checked and written, and in what order. You do not do the work — \
            you decide the work. When given a request, produce a tight plan with \
            explicit steps and dependencies. When asked for a team plan, answer ONLY \
            with the JSON plan shape you were told to produce — no prose around it.
            """
        case .research:
            return """
            You are the Research agent on a multi-agent team. Your job is to gather \
            and synthesize information: use web search and your tools to collect \
            current, sourced facts; compress them into what the next agent actually \
            needs. Cite where a claim came from when you can. Never invent facts — \
            if something can't be verified, say so. Deliver findings as concise, \
            structured notes, not a finished essay.
            """
        case .code:
            return """
            You are the Code agent on a multi-agent team. Your job is to write \
            correct, well-structured code: implement the task you were given, prefer \
            the project's existing conventions, keep changes minimal and focused, \
            and flag anything you could not verify. Output the code (and any files \
            you would create or edit) clearly, with the key parts inline. Do not \
            run destructive commands or touch systems outside your task.
            """
        case .review:
            return """
            You are the Review agent on a multi-agent team. Your job is quality \
            assurance: check the work handed to you for correctness, edge cases, \
            security holes, readability and missing tests or sources. Be specific — \
            name the actual problem and the concrete fix. Then give a verdict: \
            APPROVED, or CHANGES NEEDED with the exact list. Do not rewrite the \
            whole thing; review it.
            """
        case .writing:
            return """
            You are the Writing agent on a multi-agent team. Your job is to turn the \
            team's raw material into the final deliverable: a clear, well-organized, \
            publication-ready answer for the user. Match the user's voice and level \
            of detail, use the research and notes you were given, and never invent \
            facts the team did not establish. This is the last stop — your output is \
            what the user sees.
            """
        }
    }
}

/// One agent's finished output, delivered to the team. The mailbox that carries
/// these between agents lives in AgentCoordinator; the orchestrator forwards
/// them as context so a later agent builds on earlier work instead of repeating it.
struct AgentMessage: Sendable, Equatable {
    let role: AgentRole
    let text: String
}

/// One stage in a multi-agent plan: a role, a concrete task, and a group.
///
/// Group semantics drive parallelism: stages in a *higher* group run only after
/// every stage in lower groups finished, and stages that share a group are
/// independent of each other — the orchestrator runs them concurrently when
/// parallel mode is on. A strictly sequential plan is just one stage per group.
struct AgentStage: Sendable, Equatable, Codable {
    var role: AgentRole
    var task: String
    var group: Int

    init(role: AgentRole, task: String, group: Int = 1) {
        self.role = role
        self.task = task
        self.group = group
    }
}

/// The outcome of one stage: what the agent produced, and how long it took.
struct AgentStageResult: Sendable, Equatable {
    let stage: AgentStage
    let transcript: String
    let duration: TimeInterval
}

enum SpecializedAgentError: LocalizedError {
    case turnFailed(String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .turnFailed(let message): return message
        case .emptyOutput: return "The agent returned an empty answer."
        }
    }
}

/// One specialized agent: a long-lived `hermes acp` session pinned to a role.
///
/// The session is created lazily (spawning loads the MCP bridges, so the first
/// turn pays the startup cost) and reused across runs — the "agent spawn <100ms"
/// win is amortized by never tearing the sessions down between runs. Only the
/// orchestrator's shutdown tears them down, at app quit.
actor SpecializedAgent {
    let role: AgentRole

    private let session: HermesSession

    init(role: AgentRole, timeout: TimeInterval, workingDirectory: String = NSHomeDirectory()) {
        self.role = role
        self.session = HermesSession(workingDirectory: workingDirectory, turnDeadline: timeout)
    }

    /// Run one turn: role prompt, the team's earlier work, and the stage task.
    /// Returns the full transcript; incremental chunks are also yielded to
    /// `stream` (a per-call sink the coordinator forwards to the bar).
    func run(task: String,
             originalRequest: String,
             context: [AgentMessage],
             stream: AsyncStream<String>.Continuation? = nil) async throws -> String {
        var prompt = role.systemPrompt + "\n\n"
        prompt += "You are one agent in a coordinated team working on the user's request below. "
        prompt += "Work from earlier agents is given as context — build on it, don't redo it.\n\n"
        prompt += "The user's request: \(originalRequest)\n"

        // Bounded context: the mailbox can grow across a long run, and every
        // extra token costs the provider. Keep the tail of the conversation,
        // truncated per message, so a 6-stage run stays lean.
        let recent = context.suffix(6).map { message -> AgentMessage in
            let text = message.text.count > 4000
                ? String(message.text.prefix(4000)) + "\n…[truncated]"
                : message.text
            return AgentMessage(role: message.role, text: text)
        }
        if !recent.isEmpty {
            let contextBlock = recent
                .map { "— \($0.role.displayName) agent —\n\($0.text)" }
                .joined(separator: "\n\n")
            prompt += "\nWork already done by the team:\n\(contextBlock)\n"
        }

        prompt += "\nYour task: \(task)\n"
        prompt += "\nProduce the deliverable now, concisely and self-contained — the user sees your output, "
        prompt += "not the team's process. Do not ask for clarification."

        var transcript = ""
        for await event in await session.prompt(prompt, capture: false) {
            switch event {
            case .text(let chunk):
                transcript += chunk
                stream?.yield(chunk)
            case .failed(let message):
                throw SpecializedAgentError.turnFailed(message)
            case .thought, .toolStarted, .toolProgress, .usage, .finished:
                break
            }
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpecializedAgentError.emptyOutput }
        return trimmed
    }

    /// Interrupt the in-flight turn (bar dismissal, run cancellation). The
    /// session itself survives for the next run.
    func cancelTurn() async {
        await session.cancel()
    }

    /// Tear down the underlying Hermes process. Called at app quit.
    func shutdown() async {
        await session.shutdown()
    }
}
