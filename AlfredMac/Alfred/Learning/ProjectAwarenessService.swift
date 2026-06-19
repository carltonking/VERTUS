import Foundation
import AppKit

final class ProjectAwarenessService {
    private let memory: MemoryStore
    private let store: ProjectStore
    private var projects: [Project] = []
    private var contextHistory: [AppContext] = []
    private var queryHistory: [String] = []
    private let exclusionWords: Set<String>

    private struct Candidate {
        let name: String
        let keywords: [String]
        let apps: [String]
        let timestamp: Date
        let source: String
        let description: String
    }

    init(memory: MemoryStore) {
        self.memory = memory
        self.store = ProjectStore()
        self.projects = store.load()
        self.exclusionWords = Set(Self.buildExclusionWords())
    }

    // MARK: - Ingestion

    func ingestQuery(_ query: String, context: AppContext? = nil) {
        queryHistory.append(query)
        if queryHistory.count > 200 {
            queryHistory.removeFirst(queryHistory.count - 200)
        }

        let detected = detectCandidatesFromQuery(query, context: context)
        if let context = context {
            contextHistory.append(context)
            if contextHistory.count > 100 {
                contextHistory.removeFirst(contextHistory.count - 100)
            }
        }

        guard !detected.isEmpty else { return }
        for candidate in detected {
            addActivity(for: candidate, activityDescription: query)
        }
    }

    func ingestContext(_ context: AppContext) {
        contextHistory.append(context)
        if contextHistory.count > 100 {
            contextHistory.removeFirst(contextHistory.count - 100)
        }

        let detected = detectCandidatesFromContext(context)
        for candidate in detected {
            addActivity(for: candidate, activityDescription: "Context: \(candidate.name)")
        }
    }

    func refreshProjects() {
        do {
            let detected = try refreshFromAllSources()
            mergeCandidates(detected, into: &projects)
            pruneStaleProjects()
            try store.save(projects)
        } catch {
            NSLog("ProjectAwareness: refresh failed: \(error)")
        }
    }

    // MARK: - Public API

    func forgetProject(named name: String) {
        let normalized = normalizeName(name).lowercased()
        projects.removeAll { $0.normalizedName.lowercased() == normalized }
        try? store.save(projects)
    }

    func activeProjects() -> [Project] {
        projects.filter { $0.status == .active }
            .sorted { $0.confidence > $1.confidence }
    }

    func currentProject() -> Project? {
        activeProjects().max { a, b in
            if abs(a.confidence - b.confidence) > 0.2 {
                return a.confidence < b.confidence
            }
            return a.lastSeen < b.lastSeen
        }
    }

    func projectContext() -> String {
        let active = activeProjects()
        guard !active.isEmpty else { return "No active projects detected." }

        var lines: [String] = ["Current Projects:"]
        for p in active.prefix(5) {
            let timeAgo = formatTimeAgo(p.lastSeen)
            let desc = p.description.isEmpty ? "" : " — \(p.description)"
            lines.append("- \(p.displayName) (confidence: \(Int(p.confidence * 100))%) — last seen \(timeAgo)\(desc)")
        }

        let recent = active.flatMap { $0.recentActivity }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(5)
        if !recent.isEmpty {
            lines.append("")
            lines.append("Recent Activity:")
            for a in recent {
                let timeAgo = formatTimeAgo(a.timestamp)
                lines.append("- \(a.description) (\(a.source), \(timeAgo))")
            }
        }

        if let cur = currentProject() {
            let apps = cur.relatedApps.prefix(3).joined(separator: ", ")
            let appContext = apps.isEmpty ? "" : " — active in \(apps)"
            lines.append("")
            lines.append("Current Project Context: \(cur.displayName)\(appContext)")
        }

        return lines.joined(separator: "\n")
    }

    func recentProjectActivity(projectName: String, days: Int = 7) -> [ProjectActivity] {
        let normalized = normalizeName(projectName)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        guard let project = projects.first(where: { $0.normalizedName == normalized }) else {
            return []
        }
        return project.recentActivity
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Detection from queries

    private func detectCandidatesFromQuery(_ query: String, context: AppContext?) -> [Candidate] {
        var candidates: [Candidate] = []
        let now = Date()

        // Pattern-based extraction
        let patterns: [(regex: String, nameGroup: Int)] = [
            ("(?:work(?:ing)?\\s+(?:on|in)\\s+)([A-Z][A-Za-z0-9]*)", 1),
            ("(?:implement(?:ing)?\\s+)([A-Z][A-Za-z0-9]*)", 1),
            ("(?:build(?:ing)?\\s+)([A-Z][A-Za-z0-9]*)", 1),
            ("(?:debug(?:ging)?\\s+)([A-Z][A-Za-z0-9]*)", 1),
            ("(?:fix(?:ing)?(?:\\s+in)?\\s+)([A-Z][A-Za-z0-9]*)", 1),
            ("(?:feature\\s+(?:for|in)\\s+)([A-Z][A-Za-z0-9]*)", 1),
            ("(?:update(?:ing)?\\s+)([A-Z][A-Za-z0-9]*)", 1),
            ("(?:refactor(?:ing)?\\s+)([A-Z][A-Za-z0-9]*)", 1),
            ("(?:issue\\s+(?:in|with)\\s+)([A-Z][A-Za-z0-9]*)", 1),
            ("(?:bug\\s+(?:in|with)\\s+)([A-Z][A-Za-z0-9]*)", 1),
            ("(?:code\\s+(?:for|in)\\s+)([A-Z][A-Za-z0-9]*)", 1),
        ]

        for pattern in patterns {
            if let match = try? NSRegularExpression(pattern: pattern.regex, options: [])
                .firstMatch(in: query, options: [], range: NSRange(query.startIndex..., in: query)) {
                let nameRange = match.range(at: pattern.nameGroup)
                if let range = Range(nameRange, in: query) {
                    let name = String(query[range])
                    let normalized = normalizeName(name)
                    if !exclusionWords.contains(normalized.lowercased()) && name.count >= 2 {
                        let keywords = extractKeywords(from: query, projectName: normalized)
                        let apps = context.map { [$0.appName] } ?? []
                        candidates.append(Candidate(
                            name: normalized,
                            keywords: keywords,
                            apps: apps,
                            timestamp: now,
                            source: "query",
                            description: query
                        ))
                    }
                }
            }
        }

        // Capitalized proper noun detection (multi-word)
        let properNounPattern = try! NSRegularExpression(pattern: "\\b([A-Z][a-z]+[A-Z][A-Za-z]*)\\b|\\b([A-Z][A-Z]+)\\b", options: [])
        let nounMatches = properNounPattern.matches(in: query, options: [], range: NSRange(query.startIndex..., in: query))
        for match in nounMatches {
            for groupIdx in [1, 2] {
                let r = match.range(at: groupIdx)
                if r.location != NSNotFound, let range = Range(r, in: query) {
                    let name = String(query[range])
                    let normalized = normalizeName(name)
                    if !exclusionWords.contains(normalized.lowercased()) && name.count >= 2 {
                        let keywords = extractKeywords(from: query, projectName: normalized)
                        let apps = context.map { [$0.appName] } ?? []
                        candidates.append(Candidate(
                            name: normalized,
                            keywords: keywords,
                            apps: apps,
                            timestamp: now,
                            source: "query",
                            description: query
                        ))
                    }
                }
            }
        }

        // Deduplicate candidates with same name within this batch
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.name.lowercased()).inserted }
    }

    private func detectCandidatesFromContext(_ context: AppContext) -> [Candidate] {
        var candidates: [Candidate] = []
        let now = Date()
        let windowTitles: [String] = [context.windowTitle].compactMap { $0 }

        for title in windowTitles {
            // Pattern: "ProjectName/Path/File.swift — Xcode"
            let pathPatterns = [
                try! NSRegularExpression(pattern: "^([A-Z][A-Za-z0-9]*)/", options: []),
                try! NSRegularExpression(pattern: " — ([A-Z][A-Za-z0-9]*)", options: []),
            ]
            for pattern in pathPatterns {
                if let match = pattern.firstMatch(in: title, options: [], range: NSRange(title.startIndex..., in: title)) {
                    let r = match.range(at: 1)
                    if r.location != NSNotFound, let range = Range(r, in: title) {
                        let name = String(title[range])
                        let normalized = normalizeName(name)
                        if !exclusionWords.contains(normalized.lowercased()) && name.count >= 2 {
                            let apps = [context.appName]
                            candidates.append(Candidate(
                                name: normalized,
                                keywords: [normalized],
                                apps: apps,
                                timestamp: now,
                                source: "window",
                                description: title
                            ))
                        }
                    }
                }
            }
        }

        return candidates
    }

    private func refreshFromAllSources() throws -> [Candidate] {
        var candidates: [Candidate] = []

        // Scan recent queries from memory
        if let queries = try? memory.recentUserQueries(limit: 100) {
            for query in queries {
                candidates.append(contentsOf: detectCandidatesFromQuery(query, context: nil))
            }
        }

        // Scan context history
        for context in contextHistory {
            candidates.append(contentsOf: detectCandidatesFromContext(context))
        }

        return candidates
    }

    // MARK: - Merging

    private func addActivity(for candidate: Candidate, activityDescription: String) {
        let normalized = normalizeName(candidate.name)
        let activity = ProjectActivity(
            description: String(activityDescription.prefix(200)),
            timestamp: candidate.timestamp,
            source: candidate.source
        )

        if let idx = projects.firstIndex(where: { $0.normalizedName == normalized }) {
            var p = projects[idx]
            p.lastSeen = max(p.lastSeen, candidate.timestamp)
            p.confidence = min(1.0, p.confidence + 0.05)
            for app in candidate.apps where !p.relatedApps.contains(app) {
                p.relatedApps.append(app)
            }
            for kw in candidate.keywords where !p.relatedKeywords.contains(kw) {
                p.relatedKeywords.append(kw)
            }
            if !p.recentActivity.contains(activity) {
                p.recentActivity.append(activity)
                if p.recentActivity.count > 50 {
                    p.recentActivity.removeFirst(p.recentActivity.count - 50)
                }
            }
            p.status = .active
            p.description = generateSummary(for: p, candidate: candidate)
            projects[idx] = p
        } else {
            let description = generateSummary(for: nil, candidate: candidate)
            let project = Project(
                displayName: candidate.name,
                normalizedName: normalized,
                description: description,
                confidence: 0.3,
                lastSeen: candidate.timestamp,
                relatedApps: candidate.apps,
                relatedKeywords: candidate.keywords,
                status: .active,
                recentActivity: [activity]
            )
            projects.append(project)
        }

        // Persist on important updates
        if projects.count <= 20 || projects.first(where: { $0.normalizedName == normalized }) != nil {
            try? store.save(projects)
        }
    }

    private func mergeCandidates(_ candidates: [Candidate], into existing: inout [Project]) {
        var grouped = [String: [Candidate]]()
        for c in candidates {
            let key = normalizeName(c.name).lowercased()
            grouped[key, default: []].append(c)
        }

        for (normalized, group) in grouped {
            let best = group.max { $0.timestamp < $1.timestamp }!
            let activity = group.map { c in
                ProjectActivity(description: String(c.description.prefix(200)), timestamp: c.timestamp, source: c.source)
            }

            if let idx = existing.firstIndex(where: { $0.normalizedName.lowercased() == normalized }) {
                var p = existing[idx]
                p.lastSeen = max(p.lastSeen, best.timestamp)
                p.confidence = min(1.0, Double(group.count) * 0.1 + 0.2)
                for c in group {
                    for app in c.apps where !p.relatedApps.contains(app) {
                        p.relatedApps.append(app)
                    }
                    for kw in c.keywords where !p.relatedKeywords.contains(kw) {
                        p.relatedKeywords.append(kw)
                    }
                }
                for a in activity where !p.recentActivity.contains(a) {
                    p.recentActivity.append(a)
                }
                if p.recentActivity.count > 50 {
                    p.recentActivity = Array(p.recentActivity.suffix(50))
                }
                p.status = .active
                p.description = generateSummary(for: p, candidate: best)
                existing[idx] = p
            } else {
                let project = Project(
                    displayName: best.name,
                    normalizedName: normalized,
                    description: generateSummary(for: nil, candidate: best),
                    confidence: min(1.0, Double(group.count) * 0.1 + 0.2),
                    lastSeen: best.timestamp,
                    relatedApps: group.flatMap(\.apps).unique(),
                    relatedKeywords: group.flatMap(\.keywords).unique(),
                    status: .active,
                    recentActivity: Array(activity.suffix(50))
                )
                existing.append(project)
            }
        }
    }

    private func pruneStaleProjects() {
        let now = Date()
        projects = projects.map { p in
            var mutable = p
            let daysSinceLastSeen = now.timeIntervalSince(p.lastSeen) / 86400
            if daysSinceLastSeen > 30 {
                mutable.status = .archived
            } else if daysSinceLastSeen > 7 {
                mutable.status = .dormant
            }
            return mutable
        }
        // Remove archived projects older than 90 days
        projects.removeAll { p in
            p.status == .archived && now.timeIntervalSince(p.lastSeen) / 86400 > 90
        }
    }

    // MARK: - Summary

    private func generateSummary(for project: Project?, candidate: Candidate) -> String {
        if let project = project, !project.description.isEmpty {
            return project.description
        }
        return "Project: \(candidate.name)"
    }

    // MARK: - Helpers

    private func normalizeName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractKeywords(from query: String, projectName: String) -> [String] {
        query.components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && $0.lowercased() != projectName.lowercased() }
            .map { $0.lowercased() }
            .unique()
    }

    private func formatTimeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        switch interval {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(interval / 60))m ago"
        case ..<86400: return "\(Int(interval / 3600))h ago"
        case ..<604800: return "\(Int(interval / 86400))d ago"
        default: return "\(Int(interval / 604800))w ago"
        }
    }

    private static func buildExclusionWords() -> [String] {
        [
            // IDEs and tools
            "xcode", "vscode", "code", "terminal", "safari", "chrome",
            "firefox", "edge", "slack", "discord", "zoom", "notion",

            // Programming languages (common)
            "swift", "python", "javascript", "typescript", "rust",
            "go", "golang", "java", "kotlin", "ruby", "perl",
            "php", "scala", "clojure", "elixir", "haskell",
            "cpp", "cplusplus", "objc", "objectivec", "dart",
            "sql", "graphql", "bash", "shell", "yaml", "json",

            // Frameworks
            "react", "nextjs", "vue", "angular", "django",
            "flask", "rails", "spring", "express", "laravel",
            "svelte", "tailwind", "bootstrap", "jquery",

            // Generic project-related terms
            "project", "app", "application", "repo", "repository",
            "feature", "bug", "issue", "fix", "update", "build",
            "test", "debug", "release", "version", "commit",
            "branch", "pr", "merge", "deploy", "config",
            "setup", "readme", "license", "gitignore",

            // OS / platform
            "macos", "ios", "ipados", "watchos", "tvos",
            "linux", "ubuntu", "windows", "android",

            // Common tech terms
            "api", "rest", "http", "url", "uri", "cli",
            "gui", "ui", "ux", "sdk", "ide", "db", "orm",
            "s3", "aws", "gcp", "azure", "docker", "k8s",
            "kubernetes", "nginx", "redis", "postgres",
            "mysql", "mongodb", "sqlite", "graphdb",

            // Month names (commonly capitalized in queries)
            "january", "february", "march", "april", "may", "june",
            "july", "august", "september", "october", "november", "december",
            "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "oct", "nov", "dec",

            // Day names
            "monday", "tuesday", "wednesday", "thursday", "friday",
            "saturday", "sunday", "mon", "tue", "wed", "thu", "fri", "sat", "sun",

            // Common English proper nouns that appear frequently
            "apple", "google", "microsoft", "amazon", "meta",
            "github", "gitlab", "bitbucket", "chatgpt", "claude",
            "openai", "anthropic",
        ].map { $0.lowercased() }
    }
}

// MARK: - Array uniqueness helper

private extension Array where Element: Equatable {
    func unique() -> [Element] {
        var seen = [Element]()
        for elem in self where !seen.contains(elem) {
            seen.append(elem)
        }
        return seen
    }
}
