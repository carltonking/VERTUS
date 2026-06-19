import Foundation
import PDFKit

struct SelectedFileReader {
    private static let maxTotalTextBytes = 1_048_576
    private static let maxPDFBytes = 10 * 1_024 * 1_024
    private static let maxPDFPages = 50
    private static let maxPDFExtractedCharacters = 100_000
    private static let maxDOCXBytes = 10 * 1_024 * 1_024
    private static let maxDOCXExtractedCharacters = 100_000
    private static let maxPPTXBytes = 20 * 1_024 * 1_024
    private static let maxPPTXSlides = 100
    private static let maxPPTXExtractedCharacters = 100_000

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
    private static let supportedPDFExtensions: Set<String> = ["pdf"]
    private static let supportedDOCXExtensions: Set<String> = ["docx"]
    private static let supportedPPTXExtensions: Set<String> = ["pptx"]

    enum ReadResult {
        case content(String)
        case message(String)
    }

    func readIfRequested(query: String, selectedFiles: SelectedFileSnapshot) throws -> ReadResult? {
        guard shouldReadSelectedFile(query: query) else { return nil }

        guard selectedFiles.folderURL == nil || !selectedFiles.fileURLs.isEmpty else {
            return .message("A folder is selected, but this request needs files. Choose one or more supported files, or ask Alfred to use the selected folder.")
        }

        guard !selectedFiles.fileURLs.isEmpty else {
            return .message("No selected file is available. Choose a plain-text file, PDF, DOCX, or PPTX first, then ask me to use it.")
        }

        let unsupported = selectedFiles.fileURLs.filter { !Self.supports(url: $0) }
        if let first = unsupported.first {
            if first.pathExtension.lowercased() == "doc" {
                return .message("I can't read legacy .doc files. Export or save it as .docx, choose that file, then try again.")
            }
            if first.pathExtension.lowercased() == "ppt" {
                return .message("I can't read legacy .ppt files. Export or save it as .pptx, choose that file, then try again.")
            }
            return .message("I can't read \(first.lastPathComponent) yet. Choose a supported file type such as PDF, DOCX, PPTX, .txt, .md, .json, .csv, .swift, .js, .ts, .py, .sh, .yaml, or .yml.")
        }

        let textURLs = selectedFiles.fileURLs.filter { Self.isSupportedText(url: $0) }
        let pdfURLs = selectedFiles.fileURLs.filter { Self.isSupportedPDF(url: $0) }
        let docxURLs = selectedFiles.fileURLs.filter { Self.isSupportedDOCX(url: $0) }
        let pptxURLs = selectedFiles.fileURLs.filter { Self.isSupportedPPTX(url: $0) }

        let textSizes = try textURLs.map { url in
            (url, try fileSize(for: url))
        }
        let totalTextSize = textSizes.reduce(0) { $0 + $1.1 }
        guard totalTextSize <= Self.maxTotalTextBytes else {
            return .message("The selected text/code files are too large to read safely. Select fewer files or keep the total text/code size under 1 MB, then try again.")
        }

        let oversizedPDF = try pdfURLs.first { url in
            try fileSize(for: url) > Self.maxPDFBytes
        }
        if let oversizedPDF {
            return .message("\(oversizedPDF.lastPathComponent) is too large to read safely. Select a PDF under 10 MB, then try again.")
        }

        let oversizedDOCX = try docxURLs.first { url in
            try fileSize(for: url) > Self.maxDOCXBytes
        }
        if let oversizedDOCX {
            return .message("\(oversizedDOCX.lastPathComponent) is too large to read safely. Select a DOCX under 10 MB, then try again.")
        }

        let oversizedPPTX = try pptxURLs.first { url in
            try fileSize(for: url) > Self.maxPPTXBytes
        }
        if let oversizedPPTX {
            return .message("\(oversizedPPTX.lastPathComponent) is too large to read safely. Select a PPTX under 20 MB, then try again.")
        }

        var renderedParts: [String] = []

        let renderedTextFiles: [String] = try textURLs.map { url -> String in
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard let text = String(data: data, encoding: .utf8) else {
                throw LLMError.networkError("Could not read \(url.lastPathComponent) as UTF-8 text. Save it as UTF-8 text or choose a different supported file.")
            }

            return """
                --- BEGIN SELECTED FILE: \(url.lastPathComponent) ---
                \(text)
                --- END SELECTED FILE: \(url.lastPathComponent) ---
                """
        }
        renderedParts.append(contentsOf: renderedTextFiles)

        let docxExtraction = extractDOCXFiles(docxURLs)
        if let message = docxExtraction.message {
            return .message(message)
        }
        renderedParts.append(contentsOf: docxExtraction.contents)

        let pdfExtraction = extractPDFs(pdfURLs)
        if let message = pdfExtraction.message {
            return .message(message)
        }
        renderedParts.append(contentsOf: pdfExtraction.contents)

        let pptxExtraction = extractPPTXFiles(pptxURLs)
        if let message = pptxExtraction.message {
            return .message(message)
        }
        renderedParts.append(contentsOf: pptxExtraction.contents)

        return ReadResult.content(renderedParts.joined(separator: "\n\n"))
    }

    private func shouldReadSelectedFile(query: String) -> Bool {
        let lowered = query.lowercased()
        let triggers = [
            "selected file",
            "this file",
            "read file",
            "summarize file",
            "summarize selected",
            "explain selected file",
            "use selected file",
            "selected pdf",
            "this pdf",
            "read pdf",
            "summarize pdf",
            "explain pdf",
            "use pdf",
            "selected docx",
            "this docx",
            "read docx",
            "summarize docx",
            "explain docx",
            "use docx",
            "selected document",
            "this document",
            "read document",
            "summarize document",
            "explain document",
            "use document",
            "selected pptx",
            "this pptx",
            "read pptx",
            "summarize pptx",
            "explain pptx",
            "use pptx",
            "selected presentation",
            "this presentation",
            "read presentation",
            "summarize presentation",
            "explain presentation",
            "use presentation",
        ]

        return triggers.contains { lowered.contains($0) }
    }

    private static func supports(url: URL) -> Bool {
        isSupportedText(url: url) || isSupportedPDF(url: url) || isSupportedDOCX(url: url) || isSupportedPPTX(url: url)
    }

    private static func isSupportedText(url: URL) -> Bool {
        supportedTextExtensions.contains(url.pathExtension.lowercased())
    }

    private static func isSupportedPDF(url: URL) -> Bool {
        supportedPDFExtensions.contains(url.pathExtension.lowercased())
    }

    private static func isSupportedDOCX(url: URL) -> Bool {
        supportedDOCXExtensions.contains(url.pathExtension.lowercased())
    }

    private static func isSupportedPPTX(url: URL) -> Bool {
        supportedPPTXExtensions.contains(url.pathExtension.lowercased())
    }

    private func fileSize(for url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw LLMError.networkError("\(url.lastPathComponent) is not a regular file.")
        }
        return values.fileSize ?? 0
    }

    private func extractPDFs(_ urls: [URL]) -> (contents: [String], message: String?) {
        guard !urls.isEmpty else { return ([], nil) }

        var totalPages = 0
        var totalCharacters = 0
        var rendered: [String] = []

        for url in urls {
            guard let document = PDFDocument(url: url) else {
                return ([], "I couldn't extract text from \(url.lastPathComponent). Open it in Preview to confirm it is valid, then choose it again.")
            }

            if document.isEncrypted {
                return ([], "\(url.lastPathComponent) is encrypted. Unlock or export an unencrypted copy, then choose that file.")
            }

            let pageCount = document.pageCount
            totalPages += pageCount
            guard totalPages <= Self.maxPDFPages else {
                return ([], "The selected PDFs are too large to read safely. Select PDFs with 50 pages or fewer in total, then try again.")
            }

            var pageTexts: [String] = []
            for pageIndex in 0..<pageCount {
                guard let page = document.page(at: pageIndex) else {
                    return ([], "I couldn't extract text from \(url.lastPathComponent). Re-export the PDF or choose a text-based PDF, then try again.")
                }
                if let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    pageTexts.append("[Page \(pageIndex + 1)]\n\(text)")
                    totalCharacters += text.count
                    guard totalCharacters <= Self.maxPDFExtractedCharacters else {
                        return ([], "The selected PDFs contain too much extractable text to include safely. Select a shorter PDF or ask about a smaller section.")
                    }
                }
            }

            let text = pageTexts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return ([], "\(url.lastPathComponent) appears image-only or has no extractable text. Use a text-based PDF or OCR it first, then choose it again.")
            }

            rendered.append("""
                --- BEGIN SELECTED PDF: \(url.lastPathComponent) ---
                \(text)
                --- END SELECTED PDF: \(url.lastPathComponent) ---
                """)
        }

        return (rendered, nil)
    }

    private func extractDOCXFiles(_ urls: [URL]) -> (contents: [String], message: String?) {
        guard !urls.isEmpty else { return ([], nil) }

        let extractor = DOCXTextExtractor(maxExtractedCharacters: Self.maxDOCXExtractedCharacters)
        var totalCharacters = 0
        var rendered: [String] = []

        for url in urls {
            do {
                let text = try extractor.extractText(from: url)
                totalCharacters += text.count
                guard totalCharacters <= Self.maxDOCXExtractedCharacters else {
                    return ([], "The selected DOCX files contain too much extractable text to include safely right now. Please select a shorter document or ask about a smaller section.")
                }

                rendered.append("""
                    --- BEGIN SELECTED DOCX: \(url.lastPathComponent) ---
                    \(text)
                    --- END SELECTED DOCX: \(url.lastPathComponent) ---
                    """)
            } catch let error as DOCXTextExtractor.ExtractionError {
                return ([], error.userMessage(filename: url.lastPathComponent))
            } catch {
                return ([], "I couldn't extract text from \(url.lastPathComponent). The DOCX file could not be read.")
            }
        }

        return (rendered, nil)
    }

    private func extractPPTXFiles(_ urls: [URL]) -> (contents: [String], message: String?) {
        guard !urls.isEmpty else { return ([], nil) }

        let extractor = PPTXTextExtractor(
            maxSlides: Self.maxPPTXSlides,
            maxExtractedCharacters: Self.maxPPTXExtractedCharacters
        )
        var totalSlides = 0
        var totalCharacters = 0
        var rendered: [String] = []

        for url in urls {
            do {
                let extraction = try extractor.extractText(from: url)
                totalSlides += extraction.slideCount
                guard totalSlides <= Self.maxPPTXSlides else {
                    return ([], "The selected PPTX files are too large to read safely. Select presentations with 100 slides or fewer in total, then try again.")
                }

                totalCharacters += extraction.text.count
                guard totalCharacters <= Self.maxPPTXExtractedCharacters else {
                    return ([], "The selected PPTX files contain too much text to include safely. Select a shorter presentation or ask about a smaller section.")
                }

                rendered.append("""
                    --- BEGIN SELECTED PPTX: \(url.lastPathComponent) ---
                    \(extraction.text)
                    --- END SELECTED PPTX: \(url.lastPathComponent) ---
                    """)
            } catch let error as PPTXTextExtractor.ExtractionError {
                return ([], error.userMessage(filename: url.lastPathComponent))
            } catch {
                return ([], "I couldn't extract text from \(url.lastPathComponent). The PPTX file could not be read.")
            }
        }

        return (rendered, nil)
    }
}
