import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
struct FileWriteCapability {
    private static let supportedExtensions: Set<String> = [
        "txt",
        "md",
        "markdown",
        "json",
        "csv",
        "log",
        "swift",
        "html",
        "css",
        "js",
        "ts",
        "tsx",
        "jsx",
        "py",
        "sh",
        "yaml",
        "yml",
    ]

    struct WriteRequest: Sendable {
        let suggestedFilename: String
        let fileExtension: String
        let format: Format
    }

    enum Format: Sendable {
        case text
        case pdf
        case docx
        case pptx
    }

    enum Detection: Sendable {
        case notRequested
        case unsupported(String)
        case requested(WriteRequest)
    }

    func detectRequest(in query: String) -> Detection {
        let lowered = query.lowercased()
        let verbs = ["create", "write", "save", "export", "make", "generate", "draft"]
        guard verbs.contains(where: { lowered.contains($0) }) else {
            return .notRequested
        }

        let explicitFileSignals = [
            " file",
            " document",
            " note",
            " readme",
            " markdown",
            " text file",
            " code file",
            " slides",
            " deck",
            " slide deck",
            " powerpoint",
            " presentation",
            ".txt",
            ".md",
            ".markdown",
            ".json",
            ".csv",
            ".log",
            ".swift",
            ".html",
            ".css",
            ".js",
            ".ts",
            ".tsx",
            ".jsx",
            ".py",
            ".sh",
            ".yaml",
            ".yml",
            ".pdf",
            ".docx",
            " word document",
            ".pptx",
        ]
        guard explicitFileSignals.contains(where: { lowered.contains($0) }) else {
            return .notRequested
        }

        if lowered.contains(".pdf") || lowered.contains(" pdf") || lowered.contains("pdf ") {
            let suggestedName = sanitizedSuggestedFilename(from: query)
            let filename = ensureExtension(suggestedName ?? suggestedFilenameFromPrompt(query, ext: "pdf"), ext: "pdf")
            return .requested(WriteRequest(suggestedFilename: filename, fileExtension: "pdf", format: .pdf))
        }

        if lowered.contains(".docx") || lowered.contains(" docx") || lowered.contains("word document") {
            let suggestedName = sanitizedSuggestedFilename(from: query)
            let filename = ensureExtension(suggestedName ?? suggestedFilenameFromPrompt(query, ext: "docx"), ext: "docx")
            return .requested(WriteRequest(suggestedFilename: filename, fileExtension: "docx", format: .docx))
        }

        if lowered.contains(".pptx") || lowered.contains(" pptx") || lowered.contains("powerpoint") || lowered.contains("slides") || lowered.contains(" deck") || lowered.contains("slide deck") || lowered.contains("presentation") {
            let suggestedName = sanitizedSuggestedFilename(from: query)
            let filename = ensureExtension(suggestedName ?? suggestedFilenameFromPrompt(query, ext: "pptx"), ext: "pptx")
            return .requested(WriteRequest(suggestedFilename: filename, fileExtension: "pptx", format: .pptx))
        }

        if let unsupported = unsupportedExtensionMentioned(in: lowered) {
            return .unsupported("I can't write .\(unsupported) files yet. Ask for a supported text/code file, PDF, DOCX, or PPTX instead.")
        }

        let suggestedName = sanitizedSuggestedFilename(from: query)
        let ext = inferredExtension(from: lowered, suggestedFilename: suggestedName)

        guard Self.supportedExtensions.contains(ext) else {
            return .unsupported("I can't write .\(ext) files yet. Choose a supported text or code extension, PDF, DOCX, or PPTX.")
        }

        let filename = ensureExtension(suggestedName ?? suggestedFilenameFromPrompt(query, ext: ext), ext: ext)
        return .requested(WriteRequest(suggestedFilename: filename, fileExtension: ext, format: .text))
    }

    /// Resolve where to save WITHOUT prompting. Asking Alfred to create the file IS the
    /// permission, so there is no save panel. Defaults to ~/Downloads and never overwrites —
    /// an existing name gets a numeric suffix (apple.docx → apple-1.docx) so nothing is destroyed.
    func chooseDestination(for request: WriteRequest) async -> URL? {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let url = Self.uniqueURL(in: dir, filename: request.suggestedFilename)
        await CapabilityEventLogger.shared.record("file write", "auto-saved (no prompt)", detail: url.lastPathComponent)
        return url
    }

    /// First non-colliding URL for `filename` in `dir`.
    private static func uniqueURL(in dir: URL, filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = dir.appendingPathComponent(filename)
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            candidate = dir.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }

    func write(content: String, to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else {
            throw LLMError.networkError("Unsupported file extension .\(ext).")
        }

        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func unsupportedExtensionMentioned(in lowered: String) -> String? {
        let unsupportedExtensions = ["doc", "ppt", "rtf", "pages", "key", "numbers", "xlsx", "xls", "png", "jpg", "jpeg", "gif", "mp4", "mov", "zip"]
        return unsupportedExtensions.first { lowered.contains(".\($0)") || lowered.contains(" \($0) file") || lowered.contains(" \($0) document") }
    }

    private func inferredExtension(from lowered: String, suggestedFilename: String?) -> String {
        if let ext = suggestedFilename?.split(separator: ".").last.map(String.init).map({ $0.lowercased() }),
           Self.supportedExtensions.contains(ext) {
            return ext
        }

        let typeHints: [(String, String)] = [
            (".markdown", "markdown"),
            (".md", "md"),
            (".txt", "txt"),
            (".json", "json"),
            (".csv", "csv"),
            (".log", "log"),
            (".swift", "swift"),
            (".html", "html"),
            (".css", "css"),
            (".tsx", "tsx"),
            (".jsx", "jsx"),
            (".ts", "ts"),
            (".js", "js"),
            (".py", "py"),
            (".sh", "sh"),
            (".yaml", "yaml"),
            (".yml", "yml"),
            ("markdown", "md"),
            ("readme", "md"),
            ("json", "json"),
            ("csv", "csv"),
            ("log", "log"),
            ("swift", "swift"),
            ("html", "html"),
            ("css", "css"),
            ("typescript react", "tsx"),
            ("react typescript", "tsx"),
            ("javascript react", "jsx"),
            ("react javascript", "jsx"),
            ("typescript", "ts"),
            ("javascript", "js"),
            ("python", "py"),
            ("shell", "sh"),
            ("bash", "sh"),
            ("yaml", "yaml"),
            ("yml", "yml"),
            ("text", "txt"),
        ]

        return typeHints.first { lowered.contains($0.0) }?.1 ?? "txt"
    }

    // These patterns are constant — compile once instead of per file-write request.
    private static let filenamePattern = try? NSRegularExpression(pattern: #"(?i)(?:^|\s|["'])([^\s"'\n]+?\.(?:txt|md|markdown|json|csv|log|swift|html|css|js|ts|tsx|jsx|py|sh|yaml|yml|pdf|docx|pptx))(?=\s|$|["'])"#)
    private static let topicPatterns: [NSRegularExpression] = [
        #"(?i)\b(?:about|for|on)\s+(.+?)(?:\s+(?:as|to|named|called)\b|$)"#,
        #"(?i)\b(?:note|file|document)\s+(.+?)(?:\s+(?:as|to|named|called)\b|$)"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    private static let topicNoiseRegex = try? NSRegularExpression(pattern: #"(?i)\b(?:markdown|text|file|document|note|readme|txt|md|json|csv|log|swift|html|css|javascript|typescript|python|shell|yaml|yml|pdf|docx|word|pptx|powerpoint|slides|slide|deck|presentation)\b"#)
    private static let filenameCollapseRegex = try? NSRegularExpression(pattern: #"[\s-]+"#)

    private func sanitizedSuggestedFilename(from query: String) -> String? {
        guard let regex = Self.filenamePattern else { return nil }
        let range = NSRange(query.startIndex..<query.endIndex, in: query)
        guard let match = regex.firstMatch(in: query, range: range),
              let nameRange = Range(match.range(at: 1), in: query)
        else { return nil }

        let candidate = String(query[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let lastComponent = URL(fileURLWithPath: candidate).lastPathComponent
        guard !lastComponent.split(separator: ".").dropLast().joined(separator: ".").isEmpty else {
            return nil
        }

        return sanitizeFilename(candidate)
    }

    private func suggestedFilenameFromPrompt(_ query: String, ext: String) -> String {
        let lowered = query.lowercased()
        if lowered.contains("readme") {
            return "README.\(ext)"
        }
        if lowered.contains("note") {
            return "note.\(ext)"
        }

        let topic = topicFromPrompt(query) ?? "alfred-output"
        return "\(sanitizeFilename(topic)).\(ext)"
    }

    private func topicFromPrompt(_ query: String) -> String? {
        for regex in Self.topicPatterns {
            let range = NSRange(query.startIndex..<query.endIndex, in: query)
            guard let match = regex.firstMatch(in: query, range: range),
                  let topicRange = Range(match.range(at: 1), in: query)
            else { continue }

            let topicRaw = String(query[topicRange])
            let stripped = Self.topicNoiseRegex.map {
                $0.stringByReplacingMatches(in: topicRaw, range: NSRange(topicRaw.startIndex..., in: topicRaw), withTemplate: "")
            } ?? topicRaw
            let topic = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            if !topic.isEmpty {
                return topic
            }
        }

        return nil
    }

    private func sanitizeFilename(_ raw: String) -> String {
        let lastComponent = URL(fileURLWithPath: raw).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        let scalars = lastComponent.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let scalarsStr = String(scalars)
        let collapsed = Self.filenameCollapseRegex.map {
            $0.stringByReplacingMatches(in: scalarsStr, range: NSRange(scalarsStr.startIndex..., in: scalarsStr), withTemplate: "-")
        } ?? scalarsStr
        let cleaned = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".-_ "))

        return cleaned.isEmpty ? "alfred-output" : String(cleaned.prefix(80))
    }

    private func ensureExtension(_ filename: String, ext: String) -> String {
        if filename.lowercased().hasSuffix(".\(ext)") {
            return filename
        }

        let base = filename.split(separator: ".").first.map(String.init) ?? filename
        return "\(base).\(ext)"
    }
}
