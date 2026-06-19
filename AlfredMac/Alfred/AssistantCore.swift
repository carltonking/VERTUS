import Foundation
import AppKit
import os.log

struct CalendarEventDetails: Decodable {
    let title: String
    let startDate: String
    let durationMinutes: Double
    let location: String?
    let description: String?
}

// MARK: - AssistantCore
//
// Actor that owns the full query pipeline:
// memory retrieval → context building → capability dispatch → LLM stream → post-processing.

actor AssistantCore {
    private let router: LLMRouter
    private let memory: MemoryStore
    private let screen = ScreenCapability()
    private let web = WebSearchCapability()
    private let emailReader = EmailReadService()
    private let shell = ShellCapability()
    private let inserter = TextInserter()
    private let apps = AppControlCapability()
    private let youtube = YouTubeTranscriptCapability()
    private let selectedFileReader = SelectedFileReader()
    private let selectedFolderReader = SelectedFolderReader()
    private let pdfExporter = PDFExportCapability()
    private let docxExporter = DOCXExportCapability()
    private let pptxExporter = PPTXExportCapability()
    private let calendarReminders = CalendarRemindersCapability()
    private let voiceInput = VoiceInputCapability()
    private let mcp = MCPClientCapability()
    private let projectAwareness: ProjectAwarenessService?
    private let personalContextService: PersonalContextService?
    private let relationshipMemoryService: RelationshipMemoryService?
    private let memoryReflectionService: MemoryReflectionService?
    private let writingStyle: WritingStyleStore?
    private let relationshipStore: RelationshipStore?
    private let habitStore: HabitStore?
    private let learningLoopStore: LearningLoopStore?
    private let adaptationEngine: ResponseAdaptationEngine?
    private let rewardEngine: RewardEngine?
    private let contextCompiler: ContextCompiler?
    private let actionSelectionEngine: ActionSelectionEngine?
    private let taskDashboardService: TaskDashboardService?

    init(
        router: LLMRouter,
        memory: MemoryStore,
        projectAwareness: ProjectAwarenessService? = nil,
        personalContextService: PersonalContextService? = nil,
        relationshipMemoryService: RelationshipMemoryService? = nil,
        memoryReflectionService: MemoryReflectionService? = nil,
        writingStyle: WritingStyleStore? = nil,
        relationshipStore: RelationshipStore? = nil,
        habitStore: HabitStore? = nil,
        learningLoopStore: LearningLoopStore? = nil,
        adaptationEngine: ResponseAdaptationEngine? = nil,
        rewardEngine: RewardEngine? = nil,
        contextCompiler: ContextCompiler? = nil,
        actionSelectionEngine: ActionSelectionEngine? = nil,
        taskDashboardService: TaskDashboardService? = nil
    ) {
        self.router = router
        self.memory = memory
        self.projectAwareness = projectAwareness
        self.personalContextService = personalContextService
        self.relationshipMemoryService = relationshipMemoryService
        self.memoryReflectionService = memoryReflectionService
        self.writingStyle = writingStyle
        self.relationshipStore = relationshipStore
        self.habitStore = habitStore
        self.learningLoopStore = learningLoopStore
        self.adaptationEngine = adaptationEngine
        self.rewardEngine = rewardEngine
        self.contextCompiler = contextCompiler
        self.actionSelectionEngine = actionSelectionEngine
        self.taskDashboardService = taskDashboardService
    }

    func processWorkflow(
        plan: WorkflowPlan,
        ownerName: String,
        screenContextEnabled: Bool,
        shellExecutionEnabled: Bool,
        memoryExtractionEnabled: Bool,
        selectedFiles: SelectedFileSnapshot = .empty,
        conversationHistoryEnabled: Bool = true,
        memoryRetentionDays: Int = 90,
        onProgress: @escaping @Sendable (String) -> Void,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let lowered = plan.originalRequest.lowercased()
        let rememberedAccess = SecurityScopedResourceAccess(urls: selectedFiles.securityScopedURLs)
        defer { rememberedAccess.stop() }

        var completed: [String] = []
        var contextBlocks: [String] = []
        var visibleOutputs: [String] = []
        var generatedContent = ""

        do {
            for (index, step) in plan.steps.enumerated() {
                let progress = "Workflow step \(index + 1)/\(plan.steps.count): \(step.summary)"
                onProgress(progress)

                switch step {
                case .readSelectedFiles:
                    let result = try selectedFileReader.readIfRequested(
                        query: "use selected file",
                        selectedFiles: selectedFiles
                    )
                    switch result {
                    case .content(let content):
                        contextBlocks.append("[Selected file contents]\n\(content)")
                    case .message(let message):
                        throw LLMError.networkError(message)
                    case .none:
                        throw LLMError.networkError("No selected files were available for this workflow.")
                    }
                case .readSelectedFolder:
                    let result = try selectedFolderReader.readIfRequested(
                        query: "use selected folder",
                        selectedFiles: selectedFiles
                    )
                    switch result {
                    case .content(let content):
                        contextBlocks.append("[Selected folder context]\n\(content)")
                    case .message(let message):
                        throw LLMError.networkError(message)
                    case .none:
                        throw LLMError.networkError("No selected folder was available for this workflow.")
                    }
                case .generateContent(let purpose):
                    generatedContent = try await generateWorkflowContent(
                        request: plan.originalRequest,
                        purpose: purpose,
                        contextBlocks: contextBlocks,
                        ownerName: ownerName
                    )
                    contextBlocks.append("[Generated workflow content]\n\(generatedContent)")
                case .webSearch(let query):
                    let result = try await web.search(query: query)
                    contextBlocks.append("[Search results]\n\(result)")
                    visibleOutputs.append("Search results:\n\(result)")
                case .writeFile(let request):
                    if generatedContent.isEmpty {
                        generatedContent = try await generateWorkflowContent(
                            request: plan.originalRequest,
                            purpose: "prepare content for \(request.suggestedFilename)",
                            contextBlocks: contextBlocks,
                            ownerName: ownerName
                        )
                    }
                    let message = try await writeGeneratedContent(generatedContent, request: request)
                    guard !message.hasPrefix("File save cancelled.") else {
                        throw LLMError.networkError(message)
                    }
                    contextBlocks.append("[File write]\n\(message)")
                    visibleOutputs.append(message)
                case .appControl(let query):
                    guard let result = try await apps.handle(query: query, lowered: query.lowercased()) else {
                        throw LLMError.networkError("Could not parse the app-control step.")
                    }
                    contextBlocks.append("[App action]\n\(result)")
                    visibleOutputs.append(result)
                case .shell(let command):
                    guard shellExecutionEnabled else {
                        throw LLMError.networkError("Shell execution is disabled in Alfred Settings.")
                    }
                    let output = try await shell.run(command: command)
                    contextBlocks.append("[Shell output]\n\(output)")
                    visibleOutputs.append("Shell output:\n\(output)")
                case .computerControl(let controlPlan):
                    guard FeatureScope.computerControlEnabled else {
                        throw LLMError.networkError("Computer control is disabled in this build (Blueprint v1 scope).")
                    }
                    let result = try await ComputerControlCapability().execute(controlPlan)
                    contextBlocks.append("[Computer control]\n\(result)")
                    visibleOutputs.append(result)
                }

                completed.append(step.summary)
            }

            let outputs = visibleOutputs.isEmpty ? "" : "\n\nResults:\n\(visibleOutputs.joined(separator: "\n\n").prefix(4_000))"
            let final = """
                Workflow complete. Finished \(completed.count) step\(completed.count == 1 ? "" : "s").
                \(completed.map { "- \($0)" }.joined(separator: "\n"))
                \(outputs)
                """
            onToken(final)
            Task {
                await self.postProcess(
                    query: plan.originalRequest,
                    response: final,
                    lowered: lowered,
                    memoryExtractionEnabled: memoryExtractionEnabled,
                    conversationHistoryEnabled: conversationHistoryEnabled,
                    memoryRetentionDays: memoryRetentionDays,
                    allowTextInsertion: false
                )
            }
            return final
        } catch {
            let completedSummary = completed.isEmpty
                ? "No steps completed."
                : "Completed before stopping:\n\(completed.map { "- \($0)" }.joined(separator: "\n"))"
            let message = """
                Workflow stopped: \(error.localizedDescription)
                \(completedSummary)
                """
            onToken(message)
            Task {
                await self.postProcess(
                    query: plan.originalRequest,
                    response: message,
                    lowered: lowered,
                    memoryExtractionEnabled: memoryExtractionEnabled,
                    conversationHistoryEnabled: conversationHistoryEnabled,
                    memoryRetentionDays: memoryRetentionDays,
                    allowTextInsertion: false
                )
            }
            return message
        }
    }

    // MARK: - Main entry point

    func process(
        query: String,
        ownerName: String,
        screenContextEnabled: Bool,
        shellExecutionEnabled: Bool,
        memoryExtractionEnabled: Bool,
        selectedFiles: SelectedFileSnapshot = .empty,
        conversationHistoryEnabled: Bool = true,
        memoryRetentionDays: Int = 90,
        headless: Bool = false,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        if let quickResponse = QuickCommands.handle(query) {
            onToken(quickResponse)
            return quickResponse
        }

        let lowered = query.lowercased()
        let intent = QueryIntent.analyze(query)
        let rememberedAccess = SecurityScopedResourceAccess(urls: selectedFiles.securityScopedURLs)
        defer { rememberedAccess.stop() }

        // Headless routines must never open UI (NSSavePanel) — skip write detection entirely.
        let fileWriteDetection = headless ? FileWriteCapability.Detection.notRequested
                                          : await FileWriteCapability().detectRequest(in: query)
        switch fileWriteDetection {
        case .notRequested:
            break
        case .unsupported(let message):
            await CapabilityEventLogger.shared.record("file write", "refused", detail: message)
            onToken(message)
            Task {
                await self.postProcess(
                    query: query,
                    response: message,
                    lowered: lowered,
                    memoryExtractionEnabled: memoryExtractionEnabled,
                    allowTextInsertion: false
                )
            }
            return message
        case .requested(let request):
            await CapabilityEventLogger.shared.record("file write", "requested", detail: request.suggestedFilename)
            let message = try await handleFileWrite(
                query: query,
                request: request,
                ownerName: ownerName,
                lowered: lowered,
                memoryExtractionEnabled: memoryExtractionEnabled
            )
            onToken(message)
            return message
        }

        // 1. Gather context in parallel where independent
        async let memoriesTask = relevantMemories(for: query)
        async let historyTask = conversationHistoryEnabled ? conversationHistory() : ""
        async let screenshotTask = maybeScreenshot(intent: intent, enabled: screenContextEnabled, supportsVision: router.activeProvider.supportsVision)
        async let webResultTask  = maybeWebSearch(query: query, intent: intent)
        async let emailResultTask = maybeEmailSummary(query: query)
        async let shellResultTask = maybeShell(intent: intent, enabled: shellExecutionEnabled)
        async let appResultTask = maybeAppControl(intent: intent, headless: headless)
        async let youtubeTranscriptTask = maybeYouTubeContext(query: query, lowered: lowered)
        async let calendarTask = maybeCalendarContext(intent: intent)

        let memories      = (try? await memoriesTask) ?? []
        let history       = (try? await historyTask) ?? ""
        let screenshotB64 = try? await screenshotTask
        let webResult     = try? await webResultTask
        let emailResult   = await emailResultTask
        let shellResult   = try? await shellResultTask
        let appResult     = try? await appResultTask
        let youtubeTranscript = try? await youtubeTranscriptTask
        let calendarResult = try? await calendarTask
        let selectedFolderResult = try selectedFolderReader.readIfRequested(query: query, selectedFiles: selectedFiles)
        let selectedFileResult: SelectedFileReader.ReadResult?
        if selectedFolderResult == nil {
            selectedFileResult = try selectedFileReader.readIfRequested(
                query: query,
                selectedFiles: selectedFiles
            )
        } else {
            selectedFileResult = nil
        }

        if case .message(let message) = selectedFolderResult {
            await CapabilityEventLogger.shared.record("folder read", "refused", detail: message)
            onToken(message)
            Task {
                await self.postProcess(
                    query: query,
                    response: message,
                    lowered: lowered,
                    memoryExtractionEnabled: memoryExtractionEnabled,
                    allowTextInsertion: false
                )
            }
            return message
        }

        if case .message(let message) = selectedFileResult {
            await CapabilityEventLogger.shared.record("file read", "refused", detail: message)
            onToken(message)
            Task {
                await self.postProcess(
                    query: query,
                    response: message,
                    lowered: lowered,
                    memoryExtractionEnabled: memoryExtractionEnabled,
                    allowTextInsertion: false
                )
            }
            return message
        }

        if let appResult, webResult == nil, shellResult == nil, screenshotB64 == nil, selectedFileResult == nil, selectedFolderResult == nil {
            onToken(appResult)
            Task {
                await self.postProcess(
                    query: query,
                    response: appResult,
                    lowered: lowered,
                    memoryExtractionEnabled: memoryExtractionEnabled,
                    conversationHistoryEnabled: conversationHistoryEnabled,
                    memoryRetentionDays: memoryRetentionDays
                )
            }
            return appResult
        }

        // Calendar creation intent — extract from screenshot and create event (interactive only)
        if !headless, let calendarResult = try await maybeAddCalendarEvent(
            query: query, lowered: lowered, screenshotB64: screenshotB64
        ) {
            onToken(calendarResult)
            Task {
                await self.postProcess(
                    query: query,
                    response: calendarResult,
                    lowered: lowered,
                    memoryExtractionEnabled: memoryExtractionEnabled,
                    conversationHistoryEnabled: conversationHistoryEnabled,
                    memoryRetentionDays: memoryRetentionDays,
                    allowTextInsertion: false
                )
            }
            return calendarResult
        }

        // 2. Build system prompt
        let personalContext = personalContextService?.personalContext()
        let activeProject = projectAwareness?.currentProject()?.displayName
        let relationshipInjection = relationshipMemoryService?.promptInjection(
            activeProject: activeProject
        ) ?? ""
        let reflectionInjection = memoryReflectionService?.promptInjection(
            activeProject: activeProject
        ) ?? ""
        let unifiedContext = contextCompiler?.generateUnifiedContext(query: query)

        // 2a. Action selection — auto-execute high-confidence actions before LLM (interactive only)
        if !headless, let ctx = unifiedContext, let engine = actionSelectionEngine {
            let selection = engine.selectBestAction(query: query, context: ctx)
            if selection.top.confidenceScore > 0.85 {
                if let autoResult = try await autoExecuteAction(selection.top, query: query, lowered: lowered) {
                    onToken(autoResult)
                    Task {
                        await self.postProcess(
                            query: query,
                            response: autoResult,
                            lowered: lowered,
                            memoryExtractionEnabled: memoryExtractionEnabled,
                            conversationHistoryEnabled: conversationHistoryEnabled,
                            memoryRetentionDays: memoryRetentionDays,
                            allowTextInsertion: false
                        )
                    }
                    return autoResult
                }
            }
        }

        // 2b. Build system prompt with suggested actions
        let actionSuggestionBlock = buildActionSuggestionBlock(query: query, context: unifiedContext)
        let system = buildSystem(
            ownerName: ownerName,
            memories: memories,
            recentHistory: history,
            webResult: webResult,
            shellResult: shellResult,
            selectedFileContentIncluded: selectedFileResult != nil,
            selectedFolderContentIncluded: selectedFolderResult != nil,
            personalContext: personalContext,
            relationshipMemory: relationshipInjection,
            reflectionMemory: reflectionInjection,
            unifiedContext: unifiedContext,
            actionSuggestionBlock: actionSuggestionBlock
        )

        // 3. Build messages
        var userContent = query
        if let web = webResult { userContent += "\n\n[Search results]\n\(web)" }
        if let email = emailResult { userContent += "\n\n[Email inbox — unread, last 24h]\n\(email)" }
        if let sh  = shellResult { userContent += "\n\n[Shell output]\n\(sh)" }
        if let app = appResult { userContent += "\n\n[App actions]\n\(app)" }
        if let transcript = youtubeTranscript {
            userContent += "\n\n[YouTube transcript]\n\(transcript)"
        }
        if let cal = calendarResult {
            userContent += "\n\n[Calendar / Reminders]\n\(cal)"
        }
        if case .content(let content) = selectedFileResult {
            await CapabilityEventLogger.shared.record("file read", "allowed")
            userContent += "\n\n[Selected file contents]\n\(content)"
        }
        if case .content(let content) = selectedFolderResult {
            await CapabilityEventLogger.shared.record("folder read", "allowed")
            userContent += "\n\n[Selected folder context]\n\(content)"
        }

        var messages: [LLMMessage] = [.user(userContent)]

        if let b64 = screenshotB64 {
            messages = [.user(userContent, imageBase64: b64)]
        }

        // 4. Stream LLM response (with tool calling support)
        // Headless routines don't expose tools (no unattended app-opening).
        let fullResponse = try await router.streamWithTools(
            messages: messages,
            system: system,
            tools: headless ? nil : [LLMTool.openApplication.payload],
            executeToolCall: AppControlCapability.executeToolCall,
            onToken: onToken
        )

        // 5. Post-processing (fire-and-forget; don't block the return)
        Task {
            await self.postProcess(
                query: query,
                response: fullResponse,
                lowered: lowered,
                memoryExtractionEnabled: memoryExtractionEnabled,
                conversationHistoryEnabled: conversationHistoryEnabled,
                memoryRetentionDays: memoryRetentionDays,
                allowTextInsertion: !headless
            )
        }

        return fullResponse
    }

    private func generateWorkflowContent(
        request: String,
        purpose: String,
        contextBlocks: [String],
        ownerName: String
    ) async throws -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let context = contextBlocks.isEmpty ? "No additional context was available." : contextBlocks.joined(separator: "\n\n")
        let content = try await router.complete(
            messages: [.user("""
                User workflow request:
                \(request)

                Current workflow purpose:
                \(purpose)

                Workflow context:
                \(context)

                Return only the requested content. Do not include save confirmations or implementation notes.
                """)],
            system: AssistantPersona.systemIntro(ownerName: ownerName, currentDate: now)
        )
        return stripWrappingCodeFence(from: content)
    }

    // MARK: - Context gathering

    private func relevantMemories(for query: String) throws -> [MemoryRecord] {
        try memory.search(query: query, limit: 5)
    }

    private func conversationHistory() throws -> String {
        // Keep ~8 recent exchanges so the bar holds a real back-and-forth conversation.
        let rows = try memory.loadHistory(limit: 16)
        guard !rows.isEmpty else { return "" }
        return rows.map { row in
            "\(row.role): \(row.content.prefix(300))"
        }.joined(separator: "\n")
    }

    private func maybeCalendarContext(intent: QueryIntent) async throws -> String? {
        guard intent.wantsCalendarContext else { return nil }
        let events = try await calendarReminders.readUpcomingEvents(limit: 5)
        let reminders = try await calendarReminders.readReminders(limit: 5)
        var parts: [String] = []
        parts.append("[Calendar events]\n\(events)")
        parts.append("[Reminders]\n\(reminders)")
        return parts.joined(separator: "\n\n")
    }

    private func maybeAddCalendarEvent(query: String, lowered: String, screenshotB64: String?) async throws -> String? {
        let triggers = ["add to calendar", "create event", "create calendar", "save this event", "schedule this", "put this in my calendar", "make an event", "new event"]
        guard triggers.contains(where: { lowered.contains($0) }) else { return nil }

        await CapabilityEventLogger.shared.record("calendar", "create requested")

        guard let b64 = screenshotB64 else {
            return "Show the event details on your screen, then ask again."
        }

        let now = ISO8601DateFormatter().string(from: Date())

        let extractionPrompt = """
            Extract event details from any event information visible in the image.
            Today is \(now).

            Return ONLY valid JSON with these exact fields (use null for unknown):
            {
              "title": "Event name or title",
              "startDate": "ISO8601 datetime like 2026-05-23T14:00:00 or date like 2026-05-23",
              "durationMinutes": 60,
              "location": "Venue, address, or null",
              "description": "Any additional details from the image, or null"
            }

            Infer the date from the image content relative to today if it's not an absolute date.
            If only a date is given (no time), assume a reasonable time like 19:00.
            Do not wrap the JSON in markdown fences.
            """

        let raw = try await router.complete(
            messages: [.user(extractionPrompt, imageBase64: b64)],
            system: "You extract structured event data from images. Return only JSON."
        )

        guard let data = raw.data(using: .utf8),
              let details = try? JSONDecoder().decode(CalendarEventDetails.self, from: data)
        else {
            return "Could not read event details from the image. Make sure event info is clearly visible, then try again."
        }

        let startDate: Date
        if let iso = ISO8601DateFormatter().date(from: details.startDate) {
            startDate = iso
        } else if let dateOnly = ISO8601DateFormatter().date(from: details.startDate + "T19:00:00Z") {
            startDate = dateOnly
        } else {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
            if let parsed = formatter.date(from: String(details.startDate.prefix(10))) {
                startDate = parsed.addingTimeInterval(19 * 3600)
            } else {
                return "Could not parse the event date from the image."
            }
        }

        let result = try await calendarReminders.createEvent(
            title: details.title,
            startDate: startDate,
            durationMinutes: details.durationMinutes
        )

        await CapabilityEventLogger.shared.record("calendar", "created", detail: details.title)
        return result
    }

    private func maybeScreenshot(intent: QueryIntent, enabled: Bool, supportsVision: Bool) async throws -> String? {
        guard enabled else { return nil }
        guard supportsVision else { return nil }
        guard intent.wantsScreenContext else { return nil }
        return try await screen.captureScreenAsBase64()
    }

    private func maybeWebSearch(query: String, intent: QueryIntent) async throws -> String? {
        guard intent.wantsWebSearch else { return nil }
        return try await web.search(query: query)
    }

    /// Fetches unread inbox messages when the user asks about email, so the model can summarize
    /// real mail instead of saying it lacks access. Read-only — runs in interactive + headless
    /// (routine) paths. Needs Automation permission for Mail (prompted on first use).
    private func maybeEmailSummary(query: String) async -> String? {
        let q = query.lowercased()
        let triggers = ["summarize my email", "summarise my email", "summary of my email",
                        "check my email", "check my inbox", "read my email", "read my inbox",
                        "go through my email", "unread email", "new email", "recent email",
                        "my emails", "my inbox", "what emails", "any emails", "email summary"]
        guard triggers.contains(where: { q.contains($0) }) else { return nil }

        guard let results = try? await emailReader.fetchRecentUnread() else {
            return "Couldn't read Mail — Alfred needs Automation permission for Mail (System Settings → Privacy & Security → Automation → Alfred → Mail)."
        }
        guard !results.isEmpty else { return "No unread emails in the last 24 hours." }
        return results.map { r in
            "• \(r.metadata["subject"] ?? r.title) — from \(r.metadata["sender"] ?? r.subtitle)"
        }.joined(separator: "\n")
    }

    private func maybeShell(intent: QueryIntent, enabled: Bool) async throws -> String? {
        guard let command = intent.shellCommand else { return nil }

        guard enabled else {
            return """
                Shell execution is disabled in Alfred Settings.
                Command not run:
                \(command)
                """
        }

        return try await shell.run(command: command)
    }

    private func maybeAppControl(intent: QueryIntent, headless: Bool) async throws -> String? {
        // App control (open/activate/hide/quit apps) is a side effect — never run it headless.
        guard !headless, let query = intent.appControlQuery else { return nil }
        return try await apps.handle(query: query, lowered: query.lowercased())
    }

    private func maybeYouTubeContext(query: String, lowered: String) async throws -> String? {
        guard lowered.contains("youtube")
                || lowered.contains("youtu.be")
                || lowered.contains("youtube.com/watch")
        else { return nil }

        guard youtube.videoID(from: query) != nil else {
            return "No YouTube URL was available, so a transcript could not be fetched. Use visible page context if available."
        }
        guard let transcript = try await youtube.transcript(forVideoURL: query) else {
            return "YouTube captions/transcript were unavailable for this video. Use the page title, URL, and visible context instead."
        }

        // Keep prompt size bounded. Long transcripts still preserve the beginning and enough body
        // for useful summaries without overwhelming small-context models.
        return String(transcript.prefix(18_000))
    }

    private func handleFileWrite(
        query: String,
        request: FileWriteCapability.WriteRequest,
        ownerName: String,
        lowered: String,
        memoryExtractionEnabled: Bool
    ) async throws -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let content = try await router.complete(
            messages: [.user("""
                Create the exact file contents requested by the user.

                User request:
                \(query)

                Suggested filename:
                \(request.suggestedFilename)

                Output only the file contents. Do not include explanations, markdown fences, save confirmations, or surrounding commentary.
                """)],
            system: """
                \(AssistantPersona.systemIntro(ownerName: ownerName, currentDate: now))

                You are generating content for a local .\(request.fileExtension) document that Alfred will save through a user-approved macOS save panel. Return only the document body content.
                """
        )

        let rendered = stripWrappingCodeFence(from: content)

        let message = try await writeGeneratedContent(rendered, request: request)
        Task {
            await self.postProcess(
                query: query,
                response: message,
                lowered: lowered,
                memoryExtractionEnabled: memoryExtractionEnabled,
                allowTextInsertion: false
            )
        }
        return message
    }

    private func writeGeneratedContent(
        _ rendered: String,
        request: FileWriteCapability.WriteRequest
    ) async throws -> String {
        guard let destination = await FileWriteCapability().chooseDestination(for: request) else {
            return "File save cancelled. No file was written; run the request again and choose a destination to save."
        }

        switch request.format {
        case .text:
            try await FileWriteCapability().write(content: rendered, to: destination)
        case .pdf:
            try pdfExporter.write(
                content: rendered,
                title: destination.deletingPathExtension().lastPathComponent,
                to: destination
            )
        case .docx:
            try docxExporter.write(
                content: rendered,
                title: destination.deletingPathExtension().lastPathComponent,
                to: destination
            )
        case .pptx:
            try pptxExporter.write(
                content: rendered,
                title: destination.deletingPathExtension().lastPathComponent,
                to: destination
            )
        }

        await CapabilityEventLogger.shared.record("file write", "succeeded", detail: destination.lastPathComponent)
        return "Saved \(destination.lastPathComponent)."
    }

    private func stripWrappingCodeFence(from content: String) -> String {
        var lines = content.components(separatedBy: .newlines)
        while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeLast()
        }

        guard let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              first.hasPrefix("```"),
              let last = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines),
              last == "```",
              lines.count >= 2
        else {
            return content
        }

        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    // MARK: - System prompt

    private func buildSystem(
        ownerName: String,
        memories: [MemoryRecord],
        recentHistory: String = "",
        webResult: String?,
        shellResult: String?,
        selectedFileContentIncluded: Bool,
        selectedFolderContentIncluded: Bool,
        personalContext: String? = nil,
        relationshipMemory: String = "",
        reflectionMemory: String = "",
        unifiedContext: UnifiedContext? = nil,
        actionSuggestionBlock: String = ""
    ) -> String {
        let now = ISO8601DateFormatter().string(from: Date())

        var parts: [String] = []
        parts.append(AssistantPersona.systemIntro(ownerName: ownerName, currentDate: now))

        // Hermes Tier‑1: inject the bounded local profile (USER.md / MEMORY.md) if present.
        let profileBlock = ProfileDigest.injectedSystemText()
        if !profileBlock.isEmpty { parts.append(profileBlock) }

        if let personalContext, !personalContext.isEmpty {
            parts.append("PERSONAL CONTEXT:\n\(personalContext)")
        }

        if !relationshipMemory.isEmpty {
            parts.append(relationshipMemory)
        }

        if !reflectionMemory.isEmpty {
            parts.append(reflectionMemory)
        }

        if let unifiedBlock = unifiedContext?.systemPromptBlock, !unifiedBlock.isEmpty {
            parts.append(unifiedBlock)
        }

        if !memories.isEmpty {
            let memorySummary = memories.enumerated()
                .map { i, m in "[\(i+1)] \(m.content)" }
                .joined(separator: "\n")
            parts.append("RELEVANT MEMORIES:\n\(memorySummary)")
        }

        if !recentHistory.isEmpty {
            parts.append("RECENT CONVERSATION:\n\(recentHistory)")
        }

        if webResult != nil {
            parts.append("Web search results (each with its source URL) are included in the user message. Synthesize them into your answer using current information, and include the relevant source URLs verbatim as plain text (e.g. https://example.com) so the user can click them. If the user asked for links, list the URLs.")
        }

        if shellResult != nil {
            parts.append("Shell command output is included in the user message. Interpret it for the user.")
        }

        if selectedFileContentIncluded {
            parts.append("Selected file contents are included in the user message. Use only that provided content for file-specific analysis, and do not imply broader filesystem access.")
        }

        if selectedFolderContentIncluded {
            parts.append("Selected folder context is included in the user message. It is bounded, user-approved, non-persistent, and may be only a listing unless file contents are explicitly included. Summarize folders from the listing first unless file contents are present.")
        }

        if let projectAwareness {
            let context = projectAwareness.projectContext()
            if context != "No active projects detected." {
                parts.append("PROJECT CONTEXT:\n\(context)")
            }
        }

        if !actionSuggestionBlock.isEmpty {
            parts.append(actionSuggestionBlock)
        }

        parts.append("""
            You can help control this Mac. App launch, activation, hide, and quit actions are executed before you respond when requested. \
            Text insertion is available for type, insert, paste, write, or put requests. \
            These abilities depend on the user's macOS Accessibility permissions.
            """)

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Action selection

    private func buildActionSuggestionBlock(query: String, context: UnifiedContext?) -> String {
        guard let ctx = context, let engine = actionSelectionEngine else { return "" }
        let result = engine.selectBestAction(query: query, context: ctx)

        var lines: [String] = []
        lines.append("SUGGESTED ACTIONS:")

        let top = result.top
        let label = top.confidenceScore > 0.85 ? "recommended" : "available"
        lines.append("  • \(top.actionType) (\(label), confidence \(String(format: "%.2f", top.confidenceScore)))")

        for fb in result.fallbacks where fb.confidenceScore > 0.2 {
            lines.append("  • \(fb.actionType) (confidence \(String(format: "%.2f", fb.confidenceScore)))")
        }

        if !result.explanation.isEmpty {
            let reasons = result.explanation.joined(separator: "; ")
            lines.append("  • reasoning: \(reasons)")
        }

        return lines.joined(separator: "\n")
    }

    private func autoExecuteAction(_ candidate: ActionCandidate, query: String, lowered: String) async throws -> String? {
        switch candidate.actionType {
        case "open_application":
            return try await apps.handle(query: query, lowered: lowered)

        case "query_memory":
            let results = try memory.search(query: query, limit: 5)
            guard !results.isEmpty else { return "I don't have any memories matching that." }
            let formatted = results.enumerated()
                .map { i, m in "[\(i+1)] \(m.content)" }
                .joined(separator: "\n")
            await CapabilityEventLogger.shared.record("memory", "auto-query", detail: "\(results.count) results")
            return formatted

        case "system_command":
            guard let intent = QueryIntent.analyze(query).shellCommand else { return nil }
            let output = try await shell.run(command: intent)
            return output

        default:
            return nil
        }
    }

    // MARK: - Post-processing

    private func postProcess(
        query: String,
        response: String,
        lowered: String,
        memoryExtractionEnabled: Bool,
        conversationHistoryEnabled: Bool = true,
        memoryRetentionDays: Int = 90,
        allowTextInsertion: Bool = true
    ) async {
        if conversationHistoryEnabled {
            try? memory.pruneConversationHistory(olderThanDays: memoryRetentionDays)
            try? memory.saveMessage(role: "user", content: query)
            try? memory.saveMessage(role: "assistant", content: response)
        }

        // Record learning suggestion (prompt + response + context)
        learningLoopStore?.recordSuggestion(
            userPrompt: query,
            alfredResponse: response,
            writingStyleContext: writingStyle?.generateStyleContext() ?? "",
            relationshipContext: relationshipStore?.generateRelationshipContext() ?? "",
            habitContext: habitStore?.generateHabitContext() ?? ""
        )

        // Record writing sample from user's query
        writingStyle?.recordWritingSample(text: query, source: .chat)

        // Generate reward signals from this interaction
        rewardEngine?.generateRewardSignals()

        // Extract memorable facts via a lightweight Haiku call
        if memoryExtractionEnabled {
            Task {
                await self.extractAndSaveFacts(query: query, response: response)
            }
        }

        // Text insertion if query was "type / insert / paste"
        let insertTriggers = ["type", "insert", "paste", "write", "put"]
        if allowTextInsertion, insertTriggers.contains(where: { lowered.contains($0) }) {
            await inserter.insert(text: response)
        }
    }

    private func extractAndSaveFacts(query: String, response: String) async {
        let extractionPrompt = """
            Given this conversation, extract 0–3 specific facts worth remembering long-term \
            (preferences, names, recurring tasks, decisions). \
            Return one fact per line. If nothing notable, return NONE.

            User: \(query.prefix(400))
            Alfred: \(response.prefix(400))
            """

        guard let raw = try? await router.complete(
            prompt: extractionPrompt,
            system: "Extract memorable facts. Be terse. One fact per line or NONE."
        ) else { return }

        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.uppercased() != "NONE" && $0.count > 10 }

        for fact in lines.prefix(3) {
            try? memory.save(content: fact, tags: ["auto", "extracted"])
        }
    }
}
