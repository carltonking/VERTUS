import AppKit
import Foundation

struct AppControlCapability {
    private enum Action: Equatable {
        case open
        case activate
        case hide
        case quit
    }

    private struct Request {
        let action: Action
        let appNames: [String]
        let confirmed: Bool
    }

    func handle(query: String, lowered: String) async throws -> String? {
        guard let request = parse(query: query, lowered: lowered) else { return nil }

        // No confirmation for quit/hide/open/activate — asking is the permission. Only deletes
        // confirm, and these don't delete anything (quit terminates gracefully, app re-opens).
        var results: [String] = []
        for appName in request.appNames {
            let result = await perform(request.action, appName: appName)
            results.append(result)
        }

        return results.joined(separator: "\n")
    }

    private func parse(query: String, lowered: String) -> Request? {
        let confirmed = lowered.hasPrefix("confirm ")
        let parseLowered = confirmed ? String(lowered.dropFirst("confirm ".count)) : lowered
        let parseQuery = confirmed ? String(query.dropFirst("confirm ".count)) : query

        let patterns: [(Action, [String])] = [
            (.quit, ["quit ", "close "]),
            (.hide, ["hide "]),
            (.activate, ["switch to ", "focus ", "activate "]),
            (.open, ["open ", "launch ", "start "]),
        ]

        for (action, prefixes) in patterns {
            for prefix in prefixes {
                guard let range = parseLowered.range(of: prefix) else { continue }
                let suffix = String(parseQuery[range.upperBound...])
                let names = extractAppNames(from: suffix)
                if !names.isEmpty {
                    return Request(action: action, appNames: names, confirmed: confirmed)
                }
            }
        }

        return nil
    }

    private func extractAppNames(from suffix: String) -> [String] {
        let firstClause = suffix
            .split(whereSeparator: { ".?!".contains($0) })
            .first
            .map(String.init) ?? suffix

        let separators = [" and ", " & ", " + ", ","]
        var chunks = [firstClause]
        for separator in separators {
            chunks = chunks.flatMap { $0.components(separatedBy: separator) }
        }

        return chunks
            .map(cleanAppName)
            .filter { !$0.isEmpty }
    }

    private func cleanAppName(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let removable = [
            "please",
            "for me",
            "the app",
            "the application",
            "app",
            "application",
            "apps",
            "applications",
        ]

        for phrase in removable {
            value = value.replacingOccurrences(of: phrase, with: "", options: [.caseInsensitive])
        }

        return value
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    @MainActor
    private func perform(_ action: Action, appName: String) async -> String {
        switch action {
        case .open:
            return await open(appName: appName)
        case .activate:
            return activate(appName: appName)
        case .hide:
            return setHidden(true, appName: appName)
        case .quit:
            return quit(appName: appName)
        }
    }

    @MainActor
    private func open(appName: String) async -> String {
        let display = displayName(appName)

        guard let url = applicationURL(named: appName) else {
            return "I could not find \(display) in Applications."
        }

        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return "Opened \(url.deletingPathExtension().lastPathComponent)."
        } catch {
            return "Could not open \(display): \(error.localizedDescription)"
        }
    }

    @MainActor
    private func activate(appName: String) -> String {
        guard let app = runningApplication(named: appName) else {
            return "I could not find a running app named \(displayName(appName))."
        }

        app.activate(options: [.activateAllWindows])
        return "Activated \(app.localizedName ?? appName)."
    }

    @MainActor
    private func setHidden(_ hidden: Bool, appName: String) -> String {
        guard let app = runningApplication(named: appName) else {
            return "I could not find a running app named \(displayName(appName))."
        }

        app.hide()
        return "Hid \(app.localizedName ?? appName)."
    }

    @MainActor
    private func quit(appName: String) -> String {
        guard let app = runningApplication(named: appName) else {
            return "I could not find a running app named \(displayName(appName))."
        }

        app.terminate()
        return "Quit \(app.localizedName ?? appName)."
    }

    @MainActor
    private func runningApplication(named name: String) -> NSRunningApplication? {
        let normalized = normalize(name)
        return NSWorkspace.shared.runningApplications.first { app in
            guard let localizedName = app.localizedName,
                  let bundleURL = app.bundleURL else { return false }
            guard bundleURL.pathExtension != "appex" else { return false }
            let candidate = normalize(localizedName)
            return candidate == normalized || candidate.contains(normalized)
        }
    }

    private func applicationURL(named name: String) -> URL? {
        let directories = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "\(NSHomeDirectory())/Applications",
        ].map(URL.init(fileURLWithPath:))

        var partialMatch: URL?
        let normalized = normalize(name)

        for directory in directories {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in urls where url.pathExtension == "app" {
                let appName = url.deletingPathExtension().lastPathComponent
                let candidate = normalize(appName)

                if candidate == normalized {
                    return url
                }

                if partialMatch == nil,
                   candidate.contains(normalized) || normalized.contains(candidate) {
                    partialMatch = url
                }
            }
        }

        return partialMatch
    }

    private func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func displayName(_ value: String) -> String {
        value
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - Tool‑calling support

extension AppControlCapability {
    /// Execute an LLM tool call to open an application. Handles JSON argument parsing
    /// and dispatches to the Mac OS workspace API on the MainActor.
    static func executeToolCall(toolName: String, argumentsJSON: String) async -> String {
        guard toolName == "open_application" else {
            return "Unknown tool: \(toolName)."
        }

        struct Args: Decodable {
            let appName: String
        }

        guard let data = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(Args.self, from: data) else {
            return "Failed to parse tool arguments."
        }

        return await Task { @MainActor in
            let apps = AppControlCapability()
            let lowered = "open \(args.appName.lowercased())"
            do {
                return try await apps.handle(query: "open \(args.appName)", lowered: lowered) ?? "Opened \(args.appName)."
            } catch {
                return "Failed to open \(args.appName): \(error.localizedDescription)"
            }
        }.value
    }
}
