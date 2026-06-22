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
    // Shared ISO8601 formatter. Allocating one was happening on every query (buildSystem)
    // and several capability paths; the allocation is costly. Formatting/parsing with the
    // default options is thread-safe, and we never mutate its formatOptions here.
    nonisolated(unsafe) private static let iso8601 = ISO8601DateFormatter()

    private let router: LLMRouter
    private let memory: MemoryStore
    private let screen = ScreenCapability()
    private let screenText = ScreenTextCapability()
    private let web = WebSearchCapability()
    private let github = GitHubCapability()
    private let notion = NotionCapability()
    private let obsidian = ObsidianCapability()
    private let stylePrefs = ResponseStylePreferenceStore()
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
        computerControlEnabled: Bool = false,
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
                    guard computerControlEnabled else {
                        throw LLMError.networkError("Computer control is off. Turn it on in Alfred's Settings tab.")
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
        // GitHub write confirmation gate — MUST be the first thing checked. If a write is armed from
        // the previous turn, this turn can only be its yes/no answer: "yes" runs it, anything else
        // drops it (default-deny) and falls through to normal handling. Running this before every
        // other interceptor stops an armed write from surviving into an unrelated later message (e.g.
        // "open safari") and then being fired by a stray "yes". Interactive only — a headless routine
        // must never touch or consume the interactive user's pending confirmation.
        if !headless, await GitHubWriteGate.shared.hasPending {
            let answer = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if GitHubWriteCapability.isAffirmative(answer), let action = await GitHubWriteGate.shared.take() {
                await CapabilityEventLogger.shared.record("github write", "confirmed")
                let result = await GitHubWriteCapability.execute(action)
                onToken(result)
                return result
            }
            await GitHubWriteGate.shared.clear()
            if GitHubWriteCapability.isNegative(answer) {
                let m = "Cancelled — nothing was changed on GitHub."
                onToken(m)
                return m
            }
            // Neither yes nor no → write dropped; fall through and handle this as a fresh request.
        }

        if let quickResponse = QuickCommands.handle(query) {
            onToken(quickResponse)
            return quickResponse
        }

        // Messages read — needs async to request Contacts access (for name resolution) before the
        // synchronous chat.db read. Handled before the LLM.
        if MessagesReadCapability.detect(query.lowercased()) {
            await MessagesReadCapability.ensureContactsAccess()
            let result = MessagesReadCapability.recent()
            onToken(result)
            return result
        }

        // Spotify "play <song>" — needs an async search (Web API) then local AppleScript playback.
        // Handled before the LLM so the model can't invent a fake result. Only fires when the user
        // has set Spotify credentials; otherwise QuickCommands already returned the setup message.
        if SpotifyCapability.hasCredentials,
           SpotifyCapability.detect(query.lowercased()) == .searchUnsupported {
            let result = await SpotifyCapability.searchAndPlay(query: query)
            onToken(result)
            return result
        }

        // New GitHub write request → parse, stash, and ask for confirmation before doing anything.
        // The confirmation answer is handled by the gate at the very top of process(). Interactive
        // only — a headless routine must never arm a write it can't confirm.
        if !headless, let prepared = await GitHubWriteCapability.prepare(query) {
            switch prepared {
            case .ready(let action):
                await GitHubWriteGate.shared.set(action)
                await CapabilityEventLogger.shared.record("github write", "awaiting-confirm")
                let prompt = action.confirmationPrompt
                onToken(prompt)
                return prompt
            case .message(let msg):
                onToken(msg)
                return msg
            }
        }

        // Outlook / Microsoft — device-code login ("connect outlook") and reading mail. Handled
        // before the LLM so the auth flow and Graph call are deterministic.
        if let outlook = await OutlookCapability.handle(query) {
            await CapabilityEventLogger.shared.record("outlook", "requested")
            onToken(outlook)
            return outlook
        }

        // Gmail / Google — loopback-OAuth login ("connect gmail") and reading mail, before the LLM.
        if let gmail = await GmailCapability.handle(query) {
            await CapabilityEventLogger.shared.record("gmail", "requested")
            onToken(gmail)
            return gmail
        }

        // Contacts lookup ("what's Mom's number") — exact phone/email, before the LLM can guess.
        if let contact = await ContactsCapability.handle(query) {
            await CapabilityEventLogger.shared.record("contacts", "requested")
            onToken(contact)
            return contact
        }

        // Spotlight file search ("find my file about X") — real paths, never invented.
        if let files = SpotlightCapability.handle(query) {
            await CapabilityEventLogger.shared.record("spotlight", "requested")
            onToken(files)
            return files
        }

        // Clipboard read ("what's in my clipboard") — verbatim, before the LLM.
        if let clip = ClipboardCapability.handle(query) {
            await CapabilityEventLogger.shared.record("clipboard", "requested")
            onToken(clip)
            return clip
        }

        // Browser tabs ("what am I reading", "what tabs are open") — exact URL/title from Safari/Chrome.
        if let browser = BrowserCapability.handle(query) {
            await CapabilityEventLogger.shared.record("browser", "requested")
            onToken(browser)
            return browser
        }

        // Reminder create ("remind me to call mom tomorrow at 5") — safe local write, no confirm.
        if let r = ReminderCreateCapability.detect(query) {
            let result = (try? await calendarReminders.createReminder(title: r.title, notes: nil, dueDate: r.dueDate))
                ?? "Couldn't create the reminder — Alfred may need Reminders access (System Settings → Privacy & Security → Reminders → Alfred)."
            await CapabilityEventLogger.shared.record("reminder", "created", detail: r.title)
            onToken(result)
            return result
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
        async let screenContextTask = maybeScreenContext(intent: intent, enabled: screenContextEnabled, supportsVision: router.activeProvider.supportsVision)
        async let webResultTask  = maybeWebSearch(query: query, intent: intent)
        async let githubResultTask = maybeGitHub(query: query)
        async let notionResultTask = maybeNotion(query: query)
        async let obsidianResultTask = maybeObsidian(query: query)
        async let emailResultTask = maybeEmailSummary(query: query)
        async let shellResultTask = maybeShell(intent: intent, enabled: shellExecutionEnabled)
        async let appResultTask = maybeAppControl(intent: intent, headless: headless)
        async let youtubeTranscriptTask = maybeYouTubeContext(query: query, lowered: lowered)
        async let calendarTask = maybeCalendarContext(intent: intent)

        let memories      = (try? await memoriesTask) ?? []
        let history       = (try? await historyTask) ?? ""
        let screenContext = await screenContextTask
        // Only vision-capable providers get the image; text/failure are injected as prompt context below.
        let screenshotB64: String? = switch screenContext {
            case .image(let b64): b64
            default: nil
        }
        let webResult     = try? await webResultTask
        // If the user asked for current info but the (bounded) search returned nothing in time,
        // tell the model so it answers from general knowledge with a caveat instead of confidently
        // presenting stale training data as live.
        let webSearchFailed = intent.wantsWebSearch && webResult == nil
        let githubResult  = await githubResultTask
        let notionResult  = await notionResultTask
        let obsidianResult = await obsidianResultTask
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
            webSearchFailed: webSearchFailed,
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
        if let gh = githubResult { userContent += "\n\n[GitHub]\n\(gh)" }
        if let nt = notionResult { userContent += "\n\n[Notion]\n\(nt)" }
        if let ob = obsidianResult { userContent += "\n\n[Obsidian]\n\(ob)" }
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
        // Non-vision models can't take the screenshot, so feed Accessibility-extracted screen text
        // instead. A capture failure (e.g. missing permission) is surfaced so the model can relay it.
        if case .text(let onScreen)? = screenContext {
            await CapabilityEventLogger.shared.record("screen text", "allowed")
            userContent += "\n\n\(onScreen)"
        } else if case .failed(let reason)? = screenContext {
            userContent += "\n\n[Screen access note — tell the user: \(reason)]"
        }

        var messages: [LLMMessage] = [.user(userContent)]

        if let b64 = screenshotB64 {
            messages = [.user(userContent, imageBase64: b64)]
        }

        // 4. Stream LLM response (with tool calling support)
        // Headless routines don't expose tools (no unattended app-opening). Also withhold the
        // open-app tool when a read-data capability already supplied an answer (e.g. GitHub):
        // otherwise smaller models hijack the turn into a bogus open_application call (treating a
        // PR URL as an app name) and return no text. With the data present and no tool, they answer.
        // Withhold the open-app tool whenever ANY read-data capability supplied content. Otherwise
        // smaller models hijack the turn into a bogus open_application call and return no text
        // (the empty-response bug). With data present, they should just answer.
        let suppressTools = githubResult != nil || notionResult != nil || obsidianResult != nil
            || emailResult != nil || webResult != nil || shellResult != nil
            || youtubeTranscript != nil || calendarResult != nil
        var fullResponse = try await router.streamWithTools(
            messages: messages,
            system: system,
            tools: (headless || suppressTools) ? nil : [LLMTool.openApplication.payload],
            executeToolCall: { @Sendable name, args in
                await AppControlCapability.executeToolCall(toolName: name, argumentsJSON: args)
            },
            onToken: onToken
        )

        // Safety net: small models occasionally return a completely empty completion (notably on
        // terse inputs like "yes"). Rather than surface a blank turn ("I'm sorry, I don't have an
        // answer"), retry once as a plain text completion (no tools) so the user always gets a real
        // reply. The recent conversation is in `system`, so the model can still resolve the "yes".
        if fullResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fullResponse = try await router.stream(messages: messages, system: system, onToken: onToken)
        }

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
        let now = Self.iso8601.string(from: Date())
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
        // Keep only the last few exchanges. A long window let stale, unrelated topics bleed into
        // short follow-ups ("yes" resolving against an old "open Safari" turn). Also drop blank
        // assistant turns (past empty replies) — they add noise and confuse reference resolution.
        let rows = try memory.loadHistory(limit: 8)
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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

        let now = Self.iso8601.string(from: Date())

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
        if let iso = Self.iso8601.date(from: details.startDate) {
            startDate = iso
        } else if let dateOnly = Self.iso8601.date(from: details.startDate + "T19:00:00Z") {
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

    /// Result of trying to read the screen for an explicit "look at my screen" request.
    private enum ScreenContextResult {
        case image(String)   // base64 JPEG — only for vision-capable providers
        case text(String)    // Accessibility-extracted on-screen text — works with any model
        case failed(String)  // human-readable reason (e.g. missing permission) to relay to the user
    }

    /// Gathers screen context for an explicit screen request. Vision-capable providers get the
    /// actual pixels; every other model falls back to Accessibility-extracted text so local/free
    /// models can still "see" what's on screen. Never throws — a capture failure becomes `.failed`
    /// so the user learns about a missing permission instead of getting a blind answer.
    private func maybeScreenContext(intent: QueryIntent, enabled: Bool, supportsVision: Bool) async -> ScreenContextResult? {
        guard enabled, intent.wantsScreenContext else { return nil }

        if supportsVision {
            do {
                return .image(try await screen.captureScreenAsBase64())
            } catch {
                // Image capture failed (usually Screen Recording permission). Try text before giving up.
                if let cap = screenText.captureFrontmost() {
                    return .text(formatScreenText(cap))
                }
                let reason: String
                switch error {
                case let LLMError.networkError(msg): reason = msg
                default: reason = error.localizedDescription
                }
                return .failed(reason)
            }
        }

        // Non-vision model: read on-screen text via Accessibility instead of pixels.
        if let cap = screenText.captureFrontmost() {
            return .text(formatScreenText(cap))
        }
        return .failed("I couldn't read your screen. Grant Accessibility access in System Settings → Privacy & Security → Accessibility (and Screen Recording for image capture), then ask again.")
    }

    private func formatScreenText(_ capture: ScreenTextCapability.Capture) -> String {
        var header = "[On-screen text — \(capture.appName)"
        if !capture.windowTitle.isEmpty { header += ": \(capture.windowTitle)" }
        header += "]"
        return "\(header)\n\(capture.text)"
    }

    private func maybeWebSearch(query: String, intent: QueryIntent) async throws -> String? {
        guard intent.wantsWebSearch else { return nil }
        return try await web.search(query: query)
    }

    /// Pulls GitHub context (PRs, issues, notifications, profile) when the user mentions GitHub.
    /// Read-only and self-contained — `summary` never throws (returns a helpful note when the
    /// token is missing or a call fails), so it can't break the rest of the pipeline.
    private func maybeGitHub(query: String) async -> String? {
        guard query.lowercased().contains("github") else { return nil }
        await CapabilityEventLogger.shared.record("github", "requested")
        return await github.summary(query: query)
    }

    /// Searches Notion when the user mentions it. Same read-only, never-throws contract as GitHub.
    private func maybeNotion(query: String) async -> String? {
        guard query.lowercased().contains("notion") else { return nil }
        await CapabilityEventLogger.shared.record("notion", "requested")
        return await notion.summary(query: query)
    }

    /// Searches the local Obsidian vault(s) when the user mentions it. Pure local file reads — no
    /// API, no token. PRIVACY: the Redactor does not scrub free-form note bodies, so when a cloud
    /// model is active we send titles + paths only (`includeBodies: false`); full snippets go out
    /// only to a local model. Same read-only, never-throws contract as GitHub/Notion.
    private func maybeObsidian(query: String) async -> String? {
        guard query.lowercased().contains("obsidian") else { return nil }
        await CapabilityEventLogger.shared.record("obsidian", "requested")
        return await obsidian.summary(query: query, includeBodies: !router.isActiveProviderCloud)
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

        let results: [IntegrationSearchResult]
        do {
            results = try await emailReader.fetchRecentUnread()
        } catch {
            // Don't blame permission blindly — surface the real AppleScript error. Only -1743 is the
            // actual "not authorized" code; anything else (Mail not running, script error) is reported
            // as-is so the user isn't sent to toggle a permission that's already granted.
            var inner = error as NSError
            if case IntegrationError.underlying(let e) = error { inner = e as NSError }
            let asCode = inner.userInfo["NSAppleScriptErrorNumber"] as? Int
            if asCode == -1743 {
                return "Couldn't read Mail — Alfred needs Automation permission for Mail (System Settings → Privacy & Security → Automation → Alfred → Mail)."
            }
            let brief = inner.userInfo["NSAppleScriptErrorBriefMessage"] as? String
                ?? inner.userInfo[NSLocalizedDescriptionKey] as? String
                ?? error.localizedDescription
            return "Couldn't read Mail: \(brief). (Make sure Mail is open and has your account configured.)"
        }
        guard !results.isEmpty else { return "No unread emails right now." }
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
        let now = Self.iso8601.string(from: Date())
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
        webSearchFailed: Bool = false,
        shellResult: String?,
        selectedFileContentIncluded: Bool,
        selectedFolderContentIncluded: Bool,
        personalContext: String? = nil,
        relationshipMemory: String = "",
        reflectionMemory: String = "",
        unifiedContext: UnifiedContext? = nil,
        actionSuggestionBlock: String = ""
    ) -> String {
        let now = Self.iso8601.string(from: Date())

        var parts: [String] = []
        parts.append(AssistantPersona.systemIntro(ownerName: ownerName, currentDate: now))

        // Hermes Tier‑1: inject the bounded local profile (USER.md / MEMORY.md) if present.
        let profileBlock = ProfileDigest.injectedSystemText()
        if !profileBlock.isEmpty { parts.append(profileBlock) }

        // Explicit response-style preferences the user has taught Alfred ("just give me a list").
        // High in the prompt so they're followed by default.
        let styleBlock = stylePrefs.systemPromptBlock(ownerName: ownerName)
        if !styleBlock.isEmpty { parts.append(styleBlock) }

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
                // Cap each memory: an unbounded auto-extracted fact could otherwise dominate the
                // prompt and inflate prefill (and thus TTFT) on every query.
                .map { i, m in "[\(i+1)] \(String(m.content.prefix(280)))" }
                .joined(separator: "\n")
            parts.append("RELEVANT MEMORIES:\n\(memorySummary)")
        }

        if !recentHistory.isEmpty {
            parts.append("RECENT CONVERSATION:\n\(recentHistory)")
        }

        if webResult != nil {
            parts.append("Web search results (each with its source URL) are included in the user message. Synthesize them into your answer using current information, and include the relevant source URLs verbatim as plain text (e.g. https://example.com) so the user can click them. If the user asked for links, list the URLs.")
        } else if webSearchFailed {
            parts.append("A live web search was attempted for this query but returned no results in time. Answer from general knowledge and briefly note that the information may be out of date.")
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

        // Learn explicit response-style feedback ("just give me a list", "that was too long").
        Task { await self.maybeLearnStylePreference(query: query) }

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

    /// Detects when the user is telling Alfred HOW to respond (format/length/detail/tone) and saves
    /// it as a persistent style rule applied to future answers. A cheap keyword pre-filter avoids an
    /// LLM call on ordinary queries; the LLM then disambiguates ("make a list of groceries" is a
    /// content request, not a style rule → NONE) and normalizes the feedback into one imperative rule.
    private func maybeLearnStylePreference(query: String) async {
        let lowered = query.lowercased()
        let cues = ["list", "bullet", "short", "long", "concise", "brief", "detail", "summar",
                    "format", "prefer", "tone", "casual", "formal", "tldr", "shorter", "longer",
                    "verbose", "wordy", "paragraph", "next time", "respond", "answer", "reply"]
        guard cues.contains(where: { lowered.contains($0) }) else { return }
        // Style feedback is short; skip long task-style requests that merely mention a cue word.
        guard query.split(separator: " ").count <= 20 else { return }

        let prompt = """
            The user said: "\(query)"

            Is this an instruction about HOW they want Alfred to FORMAT or STYLE its answers — length,
            list vs prose, level of detail, or tone? If YES, rewrite it as ONE short imperative rule
            Alfred should follow from now on, e.g. "Respond with a short bulleted list.", "Keep answers
            to 1–2 sentences.", "Use a casual, friendly tone." If it is NOT about response style (it's a
            normal task or question), output exactly NONE. Output only the rule or NONE.
            """
        guard let raw = try? await router.complete(
            prompt: prompt,
            system: "You extract response-style preferences. Output one imperative rule, or NONE."
        ) else { return }

        let rule = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty, rule.uppercased() != "NONE", rule.count > 5, rule.count < 160 else { return }
        stylePrefs.add(rule)
        await CapabilityEventLogger.shared.record("style", "learned", detail: rule)
    }
}
