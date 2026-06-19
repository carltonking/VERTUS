import Foundation

struct WorkflowPlan {
    static let maxSteps = 8

    let originalRequest: String
    let steps: [Step]

    enum Step {
        case readSelectedFiles
        case readSelectedFolder
        case generateContent(String)
        case webSearch(String)
        case writeFile(FileWriteCapability.WriteRequest)
        case appControl(String)
        case shell(String)
        case computerControl(ComputerControlCapability.Plan)

        var summary: String {
            switch self {
            case .readSelectedFiles:
                return "Read explicitly selected file contents"
            case .readSelectedFolder:
                return "Read or list the explicitly selected folder"
            case .generateContent(let purpose):
                return "Generate content: \(purpose)"
            case .webSearch(let query):
                return "Search the web for: \(query)"
            case .writeFile(let request):
                return "Save/export as \(request.suggestedFilename) using NSSavePanel"
            case .appControl(let query):
                return "Run app action: \(query)"
            case .shell(let command):
                return "Run explicit shell command: \(command)"
            case .computerControl(let plan):
                return "Run computer-control actions:\n\(plan.summary)"
            }
        }

        var sideEffectCount: Int {
            switch self {
            case .writeFile, .appControl, .shell, .computerControl:
                return 1
            case .readSelectedFiles, .readSelectedFolder, .generateContent, .webSearch:
                return 0
            }
        }
    }

    var sideEffectCount: Int {
        steps.reduce(0) { $0 + $1.sideEffectCount }
    }

    var summary: String {
        steps.enumerated()
            .map { index, step in "\(index + 1). \(step.summary)" }
            .joined(separator: "\n")
    }
}

@MainActor
struct WorkflowPlanner {
    private let computerControl: ComputerControlCapability

    init(computerControl: ComputerControlCapability) {
        self.computerControl = computerControl
    }

    func makePlan(from query: String, selectedFiles: SelectedFileSnapshot, shellExecutionEnabled: Bool) throws -> WorkflowPlan? {
        let lowered = query.lowercased()
        guard isExplicitWorkflow(lowered) else { return nil }

        var steps: [WorkflowPlan.Step] = []

        if referencesSelectedFolder(lowered), selectedFiles.folderURL != nil {
            steps.append(.readSelectedFolder)
        } else if referencesSelectedFiles(lowered), !selectedFiles.fileURLs.isEmpty {
            steps.append(.readSelectedFiles)
        }

        if let appAction = appActionQuery(from: query, lowered: lowered) {
            steps.append(.appControl(appAction))
        }

        if let searchQuery = webSearchQuery(from: query, lowered: lowered) {
            steps.append(.webSearch(searchQuery))
        }

        if let command = explicitShellCommand(from: query) {
            guard shellExecutionEnabled else {
                throw LLMError.networkError("Shell execution is disabled in Alfred Settings.")
            }
            steps.append(.shell(command))
        }

        if let computerPlan = try computerControl.makePlan(from: query) {
            steps.append(.computerControl(computerPlan))
        }

        if needsGeneratedContent(lowered) {
            steps.append(.generateContent(generationPurpose(from: lowered)))
        }

        switch FileWriteCapability().detectRequest(in: query) {
        case .requested(let request):
            steps.append(.writeFile(request))
        case .unsupported(let message):
            throw LLMError.networkError(message)
        case .notRequested:
            break
        }

        guard steps.count > 1 else { return nil }
        guard steps.count <= WorkflowPlan.maxSteps else {
            throw LLMError.networkError("Workflow requests are capped at \(WorkflowPlan.maxSteps) steps. Please ask for a smaller workflow.")
        }

        return WorkflowPlan(originalRequest: query, steps: steps)
    }

    private func isExplicitWorkflow(_ lowered: String) -> Bool {
        let connectors = [" and ", " then ", " after that ", " workflow", "step "]
        guard connectors.contains(where: { lowered.contains($0) }) else { return false }

        let capabilityTerms = [
            "selected file",
            "selected pdf",
            "selected document",
            "selected folder",
            "save",
            "export",
            "create",
            "make",
            "open ",
            "launch ",
            "search",
            "run:",
            "execute:",
            "bash:",
            "control my mac",
        ]
        let matches = capabilityTerms.filter { lowered.contains($0) }.count
        return matches >= 2
    }

    private func referencesSelectedFiles(_ lowered: String) -> Bool {
        [
            "selected file",
            "selected pdf",
            "selected docx",
            "selected pptx",
            "selected document",
            "these selected files",
            "read these selected files",
        ].contains { lowered.contains($0) }
    }

    private func referencesSelectedFolder(_ lowered: String) -> Bool {
        [
            "selected folder",
            "this folder",
            "chosen folder",
        ].contains { lowered.contains($0) }
    }

    private func needsGeneratedContent(_ lowered: String) -> Bool {
        [
            "summarize",
            "summary",
            "brief",
            "report",
            "deck",
            "slides",
            "markdown",
            "pdf",
            "docx",
            "pptx",
            "answer",
        ].contains { lowered.contains($0) }
    }

    private func generationPurpose(from lowered: String) -> String {
        if lowered.contains("deck") || lowered.contains("slides") || lowered.contains("pptx") {
            return "prepare slide/deck content from available context"
        }
        if lowered.contains("report") || lowered.contains("pdf") {
            return "prepare a concise report from available context"
        }
        if lowered.contains("markdown") || lowered.contains(".md") {
            return "prepare Markdown from available context"
        }
        if lowered.contains("summarize") || lowered.contains("summary") {
            return "summarize the available context"
        }
        return "prepare requested output from available context"
    }

    private func appActionQuery(from query: String, lowered: String) -> String? {
        let prefixes = ["open ", "launch ", "start ", "switch to ", "focus ", "activate "]
        guard let prefix = prefixes.first(where: { lowered.contains($0) }),
              let range = lowered.range(of: prefix)
        else { return nil }

        let suffix = String(query[range.lowerBound...])
        let clause = suffix
            .components(separatedBy: " and ")
            .first?
            .components(separatedBy: " then ")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clause?.isEmpty == false ? clause : nil
    }

    private func webSearchQuery(from query: String, lowered: String) -> String? {
        let markers = ["search for ", "search ", "look up ", "find "]
        guard let marker = markers.first(where: { lowered.contains($0) }),
              let range = lowered.range(of: marker)
        else { return nil }

        let suffix = String(query[range.upperBound...])
        let cleaned = suffix
            .components(separatedBy: " and ")
            .first?
            .components(separatedBy: " then ")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return cleaned?.isEmpty == false ? cleaned : nil
    }

    private func explicitShellCommand(from query: String) -> String? {
        if let start = query.firstIndex(of: "`"),
           let end = query[query.index(after: start)...].firstIndex(of: "`") {
            return String(query[query.index(after: start)..<end])
        }

        for prefix in ["run:", "execute:", "bash:"] {
            if let range = query.lowercased().range(of: prefix) {
                let after = String(query[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !after.isEmpty { return after }
            }
        }
        return nil
    }
}
