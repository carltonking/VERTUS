import Foundation
import PDFKit

struct SelectedFolderReader {
    private static let maxEntriesListed = 200
    private static let maxFilesRead = 10
    private static let maxTotalExtractedCharacters = 150_000
    private static let maxTextBytes = 1_048_576
    private static let maxPDFBytes = 10 * 1_024 * 1_024
    private static let maxPDFPages = 50
    private static let maxDOCXBytes = 10 * 1_024 * 1_024
    private static let maxPPTXBytes = 20 * 1_024 * 1_024

    private static let supportedTextExtensions: Set<String> = [
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

    enum FolderResult {
        case content(String)
        case message(String)
    }

    func readIfRequested(query: String, selectedFiles: SelectedFileSnapshot) throws -> FolderResult? {
        guard shouldUseSelectedFolder(query: query) else { return nil }
        guard let folderURL = selectedFiles.folderURL else {
            return .message("No selected folder is available. Choose a folder first, then ask me to use the selected folder.")
        }

        let recursive = shouldRecurse(query: query)
        let entries = try folderEntries(in: folderURL, recursive: recursive)
        guard entries.count <= Self.maxEntriesListed else {
            return .message("The selected folder has too many visible entries to inspect safely. Choose a narrower folder or ask about a smaller scope.")
        }

        let listing = renderListing(entries, folderURL: folderURL, recursive: recursive)
        guard shouldReadContents(query: query) else {
            return .content(listing)
        }

        let readableFiles = entries
            .filter { $0.isRegularFile && Self.supportsReading($0.url) }
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }

        guard !readableFiles.isEmpty else {
            return .message("I found no supported readable files in the selected folder. Choose a folder containing text/code files, text-based PDFs, DOCX, or PPTX files.")
        }

        guard readableFiles.count <= Self.maxFilesRead else {
            return .message("The selected folder has \(readableFiles.count) supported readable files. Ask for a narrower scope; I can read up to \(Self.maxFilesRead) files per request.")
        }

        let extraction = try extractContents(from: readableFiles)
        if let message = extraction.message {
            return .message(message)
        }

        return .content("""
            \(listing)

            [Selected folder file contents]
            \(extraction.content)
            """)
    }

    private func shouldUseSelectedFolder(query: String) -> Bool {
        let lowered = query.lowercased()
        let triggers = [
            "selected folder",
            "this folder",
            "chosen folder",
            "picked folder",
            "use folder",
            "read folder",
            "summarize folder",
            "list folder",
            "folder contents",
        ]
        return triggers.contains { lowered.contains($0) }
    }

    private func shouldReadContents(query: String) -> Bool {
        let lowered = query.lowercased()
        let triggers = [
            "read files",
            "read the files",
            "read file contents",
            "read contents",
            "use files",
            "use the files",
            "open files",
            "extract text",
        ]
        return triggers.contains { lowered.contains($0) }
    }

    private func shouldRecurse(query: String) -> Bool {
        let lowered = query.lowercased()
        return lowered.contains("recursive")
            || lowered.contains("recursively")
            || lowered.contains("subfolders")
            || lowered.contains("nested")
    }

    private struct FolderEntry {
        let url: URL
        let relativePath: String
        let isDirectory: Bool
        let isRegularFile: Bool
        let size: Int?
        let modified: Date?
    }

    private func folderEntries(in folderURL: URL, recursive: Bool) throws -> [FolderEntry] {
        var entries: [FolderEntry] = []
        try collectEntries(in: folderURL, rootURL: folderURL, depth: 0, maxDepth: recursive ? 2 : 0, into: &entries)
        return entries.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private func collectEntries(
        in folderURL: URL,
        rootURL: URL,
        depth: Int,
        maxDepth: Int,
        into entries: inout [FolderEntry]
    ) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isHiddenKey,
        ]
        let children = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        for child in children {
            let values = try child.resourceValues(forKeys: keys)
            if values.isHidden == true { continue }

            let relativePath = child.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            entries.append(FolderEntry(
                url: child,
                relativePath: relativePath,
                isDirectory: values.isDirectory == true,
                isRegularFile: values.isRegularFile == true,
                size: values.fileSize,
                modified: values.contentModificationDate
            ))

            if values.isDirectory == true, depth < maxDepth, entries.count <= Self.maxEntriesListed {
                try collectEntries(in: child, rootURL: rootURL, depth: depth + 1, maxDepth: maxDepth, into: &entries)
            }
        }
    }

    private func renderListing(_ entries: [FolderEntry], folderURL: URL, recursive: Bool) -> String {
        let dateFormatter = ISO8601DateFormatter()
        let rows = entries.map { entry in
            let type = entry.isDirectory ? "folder" : "file"
            let size = entry.isDirectory ? "-" : byteCount(entry.size ?? 0)
            let modified = entry.modified.map { dateFormatter.string(from: $0) } ?? "unknown"
            return "\(entry.relativePath)\t\(type)\t\(size)\t\(modified)"
        }.joined(separator: "\n")

        return """
            [Selected folder listing]
            Folder: \(folderURL.lastPathComponent)
            Scope: \(recursive ? "immediate children plus subfolders to depth 2" : "immediate children only")
            Hidden files: skipped
            Entries: \(entries.count)

            filename	type	size	modified
            \(rows)
            """
    }

    private func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func supportsReading(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return supportedTextExtensions.contains(ext) || ["pdf", "docx", "pptx"].contains(ext)
    }

    private func extractContents(from entries: [FolderEntry]) throws -> (content: String, message: String?) {
        var totalCharacters = 0
        var rendered: [String] = []

        for entry in entries {
            let ext = entry.url.pathExtension.lowercased()
            let size = entry.size ?? 0
            let text: String

            switch ext {
            case let value where Self.supportedTextExtensions.contains(value):
                guard size <= Self.maxTextBytes else {
                    return ("", "\(entry.relativePath) is too large to read safely. Choose files under 1 MB or ask for a narrower folder.")
                }
                let data = try Data(contentsOf: entry.url, options: [.mappedIfSafe])
                guard let decoded = String(data: data, encoding: .utf8) else {
                    return ("", "I couldn't read \(entry.relativePath) as UTF-8 text. Save it as UTF-8 text or choose a different supported file.")
                }
                text = decoded
            case "pdf":
                guard size <= Self.maxPDFBytes else {
                    return ("", "\(entry.relativePath) is too large to read safely. Choose PDFs under 10 MB or ask for a narrower folder.")
                }
                let extracted = extractPDF(entry.url, relativePath: entry.relativePath)
                if let message = extracted.message { return ("", message) }
                text = extracted.text
            case "docx":
                guard size <= Self.maxDOCXBytes else {
                    return ("", "\(entry.relativePath) is too large to read safely. Choose DOCX files under 10 MB or ask for a narrower folder.")
                }
                do {
                    text = try DOCXTextExtractor(maxExtractedCharacters: Self.maxTotalExtractedCharacters).extractText(from: entry.url)
                } catch let error as DOCXTextExtractor.ExtractionError {
                    return ("", error.userMessage(filename: entry.relativePath))
                }
            case "pptx":
                guard size <= Self.maxPPTXBytes else {
                    return ("", "\(entry.relativePath) is too large to read safely. Choose PPTX files under 20 MB or ask for a narrower folder.")
                }
                do {
                    text = try PPTXTextExtractor(maxSlides: 100, maxExtractedCharacters: Self.maxTotalExtractedCharacters)
                        .extractText(from: entry.url)
                        .text
                } catch let error as PPTXTextExtractor.ExtractionError {
                    return ("", error.userMessage(filename: entry.relativePath))
                }
            default:
                continue
            }

            totalCharacters += text.count
            guard totalCharacters <= Self.maxTotalExtractedCharacters else {
                return ("", "The selected folder files contain too much extractable text to include safely. Ask for a narrower scope.")
            }

            rendered.append("""
                --- BEGIN SELECTED FOLDER FILE: \(entry.relativePath) ---
                \(text)
                --- END SELECTED FOLDER FILE: \(entry.relativePath) ---
                """)
        }

        return (rendered.joined(separator: "\n\n"), nil)
    }

    private func extractPDF(_ url: URL, relativePath: String) -> (text: String, message: String?) {
        guard let document = PDFDocument(url: url) else {
            return ("", "I couldn't extract text from \(relativePath). Open it in Preview to confirm it is valid, then choose a narrower folder or different file.")
        }
        if document.isEncrypted {
            return ("", "\(relativePath) is encrypted. Unlock or export an unencrypted copy, then choose that file or folder.")
        }
        guard document.pageCount <= Self.maxPDFPages else {
            return ("", "\(relativePath) has too many pages to read safely. Choose PDFs with 50 pages or fewer.")
        }

        var pageTexts: [String] = []
        var characters = 0
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                return ("", "I couldn't extract text from \(relativePath). Re-export the PDF or choose a text-based PDF.")
            }
            if let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                characters += text.count
                guard characters <= Self.maxTotalExtractedCharacters else {
                    return ("", "\(relativePath) contains too much extractable text to include safely. Ask for a narrower scope.")
                }
                pageTexts.append("[Page \(pageIndex + 1)]\n\(text)")
            }
        }

        let text = pageTexts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return ("", "\(relativePath) appears image-only or has no extractable text. Use a text-based PDF or OCR it first.")
        }
        return (text, nil)
    }
}
