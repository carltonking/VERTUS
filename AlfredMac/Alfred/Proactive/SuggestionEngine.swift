import Foundation

enum SuggestionEngine {
    static func suggestions(for context: AppContext) -> [ProactiveSuggestion] {
        candidates(for: context)
    }

    static func rankedSuggestions(
        for context: AppContext,
        adaptiveEngine: AdaptiveSuggestionEngine,
        profileCategoryRates: [(category: String, confidence: Double)],
        recentActivity: [String],
        activeProject: String?
    ) -> [SuggestionScore] {
        let candidates = candidates(for: context)

        var allCandidates = candidates
        if let project = activeProject, !project.isEmpty {
            let projectSugs = makeProjectSuggestions(project: project, context: context)
            for sugs in projectSugs where !allCandidates.contains(sugs) {
                allCandidates.append(sugs)
            }
        }

        let scored = adaptiveEngine.rankSuggestions(
            allCandidates,
            context: context,
            activeProject: activeProject,
            profileCategoryRates: profileCategoryRates,
            recentActivity: recentActivity
        )

        for s in scored {
            adaptiveEngine.markShown(s.suggestion)
        }

        return scored
    }

    private static func candidates(for context: AppContext) -> [ProactiveSuggestion] {
        let app = context.appName.lowercased()
        let bundle = context.bundleIdentifier?.lowercased() ?? ""
        let url = context.browserURL?.lowercased() ?? ""
        let title = context.browserTitle ?? context.windowTitle ?? context.appName
        let loweredTitle = title.lowercased()

        if url.contains("youtube.com/watch")
            || url.contains("youtu.be/")
            || loweredTitle.contains("youtube") {
            return [
                suggestion(
                    "Summarize video",
                    icon: "play.rectangle",
                    prompt: "Summarize the YouTube video I am watching. Fetch and use the transcript if available. If there is no transcript, use the current page title and visible screen context.\n\nCurrent page: \(title)\nURL: \(context.browserURL ?? "")"
                ),
                suggestion(
                    "Key takeaways",
                    icon: "list.bullet.rectangle",
                    prompt: "Extract key takeaways and action items from this YouTube video. Fetch and use the transcript if available. If there is no transcript, use visible context and the page title.\n\nCurrent page: \(title)\nURL: \(context.browserURL ?? "")"
                ),
                suggestion(
                    "Explain this",
                    icon: "questionmark.circle",
                    prompt: "Explain the topic of this YouTube video in plain English, based on the current page title and what is visible on screen.\n\nCurrent page: \(title)\nURL: \(context.browserURL ?? "")"
                ),
            ]
        }

        if isCodingApp(app: app, bundle: bundle) {
            return [
                suggestion(
                    "Review code",
                    icon: "curlybraces",
                    prompt: "Review the code or error currently visible in \(context.appName). Point out likely bugs, risky logic, and the next concrete fix. Use screen context and the active window title: \(context.windowTitle ?? "unknown")."
                ),
                suggestion(
                    "Fix visible bug",
                    icon: "wrench.and.screwdriver",
                    prompt: "Help me fix the bug or error currently visible in \(context.appName). Give a concise diagnosis and exact code changes if enough context is visible. Active window: \(context.windowTitle ?? "unknown")."
                ),
                suggestion(
                    "Write tests",
                    icon: "checklist",
                    prompt: "Suggest focused tests for the code currently visible in \(context.appName). Include edge cases and where the tests should live if you can infer it. Active window: \(context.windowTitle ?? "unknown")."
                ),
            ]
        }

        if isWritingApp(app: app, bundle: bundle, url: url) {
            return [
                suggestion(
                    "Improve writing",
                    icon: "text.quote",
                    prompt: "Improve the writing currently visible or selected in \(context.appName). Keep my meaning, tighten the prose, and explain the most important edits briefly."
                ),
                suggestion(
                    "Check grammar",
                    icon: "checkmark.seal",
                    prompt: "Check the visible or selected writing in \(context.appName) for grammar, spelling, clarity, and awkward phrasing. Return a corrected version and a short list of changes."
                ),
                suggestion(
                    "Rewrite tone",
                    icon: "slider.horizontal.3",
                    prompt: "Rewrite the visible or selected text in \(context.appName) to be clearer, more polished, and appropriate for the document context."
                ),
            ]
        }

        if isBrowser(bundle: bundle) {
            return [
                suggestion(
                    "Summarize page",
                    icon: "doc.text.magnifyingglass",
                    prompt: "Summarize the current browser page using the page title, URL, and visible screen context.\n\nCurrent page: \(title)\nURL: \(context.browserURL ?? "")"
                ),
                suggestion(
                    "Find action items",
                    icon: "checklist",
                    prompt: "Find the main action items or decisions from the current browser page.\n\nCurrent page: \(title)\nURL: \(context.browserURL ?? "")"
                ),
            ]
        }

        return [
            suggestion(
                "Summarize screen",
                icon: "rectangle.dashed",
                prompt: "Summarize what I am currently looking at in \(context.appName). Use the active window title and visible screen context. Active window: \(context.windowTitle ?? "unknown")."
            ),
            suggestion(
                "Suggest next steps",
                icon: "sparkles",
                prompt: "Based on what is currently visible in \(context.appName), suggest the most useful next steps. Active window: \(context.windowTitle ?? "unknown")."
            ),
        ]
    }

    private static func suggestion(_ title: String, icon: String, prompt: String) -> ProactiveSuggestion {
        ProactiveSuggestion(
            id: "\(title)-\(prompt.hashValue)",
            title: title,
            prompt: prompt,
            icon: icon
        )
    }

    private static func isBrowser(bundle: String) -> Bool {
        [
            "com.apple.safari",
            "com.google.chrome",
            "com.google.chrome.canary",
            "com.microsoft.edgemac",
            "com.brave.browser",
            "company.thebrowser.browser",
        ].contains(bundle)
    }

    private static func isCodingApp(app: String, bundle: String) -> Bool {
        let codingApps = [
            "xcode",
            "visual studio code",
            "cursor",
            "zed",
            "sublime text",
            "terminal",
            "iterm",
            "warp",
            "pycharm",
            "intellij",
            "webstorm",
            "android studio",
        ]

        return codingApps.contains(where: { app.contains($0) || bundle.contains($0.replacingOccurrences(of: " ", with: "")) })
    }

    private static func isWritingApp(app: String, bundle: String, url: String) -> Bool {
        if url.contains("docs.google.com") || url.contains("notion.so") || url.contains("overleaf.com") {
            return true
        }

        let writingApps = [
            "notes",
            "pages",
            "microsoft word",
            "textedit",
            "ulysses",
            "obsidian",
            "notion",
            "bear",
            "slack",
            "mail",
            "messages",
        ]

        return writingApps.contains(where: { app.contains($0) || bundle.contains($0.replacingOccurrences(of: " ", with: "")) })
    }

    private static func makeProjectSuggestions(project: String, context: AppContext) -> [ProactiveSuggestion] {
        [
            ProactiveSuggestion(
                id: "continue-\(project)",
                title: "Continue \(project)",
                prompt: "I was working on \(project). Based on what is visible in \(context.appName), suggest what to continue with. Active window: \(context.windowTitle ?? "unknown").",
                icon: "arrow.forward.circle"
            ),
            ProactiveSuggestion(
                id: "review-\(project)",
                title: "Review \(project)",
                prompt: "Review the current state of \(project) visible in \(context.appName). Point out issues and suggest next steps. Active window: \(context.windowTitle ?? "unknown").",
                icon: "magnifyingglass.circle"
            ),
        ]
    }
}
