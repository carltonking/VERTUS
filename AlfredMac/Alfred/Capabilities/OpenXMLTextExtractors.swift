import Compression
import Foundation

struct DOCXTextExtractor {
    let maxExtractedCharacters: Int
    private let maxDocumentXMLBytes = 5 * 1_024 * 1_024

    enum ExtractionError: Error {
        case encrypted
        case malformed
        case missingDocument
        case tooMuchText
        case unsupportedCompression
        case xmlParseFailed

        func userMessage(filename: String) -> String {
            switch self {
            case .encrypted:
                return "\(filename) is encrypted. Unlock or export an unencrypted DOCX, then choose that file."
            case .malformed:
                return "\(filename) is not a valid DOCX file or could not be opened. Re-export it as .docx, then choose it again."
            case .missingDocument:
                return "\(filename) is malformed or contains no readable document text. Re-export it as .docx with text content, then try again."
            case .tooMuchText:
                return "\(filename) contains too much text to include safely. Select a shorter document or ask about a smaller section."
            case .unsupportedCompression:
                return "I couldn't extract text from \(filename). Re-save it from Word or Pages as a standard .docx, then choose it again."
            case .xmlParseFailed:
                return "I couldn't extract text from \(filename). Re-export it as .docx, then choose it again."
            }
        }
    }

    func extractText(from url: URL) throws -> String {
        let archive = try OpenXMLZipArchive(url: url, maxEntryBytes: maxDocumentXMLBytes)
        guard archive.fileNames.contains("word/document.xml") else {
            throw ExtractionError.missingDocument
        }

        let xml = try archive.entryData(named: "word/document.xml")
        let parser = WordDocumentXMLParser(maxCharacters: maxExtractedCharacters)
        do {
            return try parser.parse(xml)
        } catch let error as ExtractionError {
            throw error
        } catch {
            throw ExtractionError.xmlParseFailed
        }
    }
}

struct PPTXTextExtractor {
    let maxSlides: Int
    let maxExtractedCharacters: Int
    private let maxSlideXMLBytes = 1 * 1_024 * 1_024

    struct Extraction {
        let text: String
        let slideCount: Int
    }

    enum ExtractionError: Error {
        case encrypted
        case malformed
        case noSlides
        case tooManySlides
        case tooMuchText
        case unsupportedCompression
        case xmlParseFailed(slideNumber: Int)

        func userMessage(filename: String) -> String {
            switch self {
            case .encrypted:
                return "\(filename) is encrypted. Unlock or export an unencrypted PPTX, then choose that file."
            case .malformed:
                return "\(filename) is not a valid PPTX file or could not be opened. Re-export it as .pptx, then choose it again."
            case .noSlides:
                return "\(filename) is malformed or contains no readable slides. Re-export it as .pptx with text slides, then try again."
            case .tooManySlides:
                return "\(filename) has too many slides to read safely. Select a PPTX with 100 slides or fewer."
            case .tooMuchText:
                return "\(filename) contains too much text to include safely. Select a shorter presentation or ask about a smaller section."
            case .unsupportedCompression:
                return "I couldn't extract slide text from \(filename). Re-save it from PowerPoint or Keynote as a standard .pptx, then choose it again."
            case .xmlParseFailed(let slideNumber):
                return "I couldn't extract slide text from \(filename). Re-export the deck as .pptx, then choose it again. Slide \(slideNumber) could not be parsed."
            }
        }
    }

    func extractText(from url: URL) throws -> Extraction {
        let archive = try OpenXMLZipArchive(url: url, maxEntryBytes: maxSlideXMLBytes)
        let slideEntries = archive.fileNames
            .compactMap { entry -> (name: String, number: Int)? in
                guard let number = Self.slideNumber(for: entry) else { return nil }
                return (entry, number)
            }
            .sorted { $0.number < $1.number }

        guard !slideEntries.isEmpty else { throw ExtractionError.noSlides }
        guard slideEntries.count <= maxSlides else { throw ExtractionError.tooManySlides }

        var extractedCharacters = 0
        var renderedSlides: [String] = []

        for (index, slideEntry) in slideEntries.enumerated() {
            let xml = try archive.entryData(named: slideEntry.name)
            guard let slideText = TextRunXMLParser.text(from: xml, textElementNames: ["a:t", "t"]) else {
                throw ExtractionError.xmlParseFailed(slideNumber: index + 1)
            }

            let trimmed = slideText.trimmingCharacters(in: .whitespacesAndNewlines)
            extractedCharacters += trimmed.count
            guard extractedCharacters <= maxExtractedCharacters else {
                throw ExtractionError.tooMuchText
            }

            renderedSlides.append("""
                Slide \(index + 1):
                \(trimmed.isEmpty ? "[No extractable text]" : trimmed)
                """)
        }

        return Extraction(
            text: renderedSlides.joined(separator: "\n\n"),
            slideCount: slideEntries.count
        )
    }

    private static func slideNumber(for entry: String) -> Int? {
        guard entry.hasPrefix("ppt/slides/slide"), entry.hasSuffix(".xml") else { return nil }
        let numberText = entry
            .replacingOccurrences(of: "ppt/slides/slide", with: "")
            .replacingOccurrences(of: ".xml", with: "")
        return Int(numberText)
    }
}

private struct OpenXMLZipArchive {
    private struct Entry {
        let name: String
        let flags: UInt16
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private let entries: [Entry]
    private let maxEntryBytes: Int

    var fileNames: [String] {
        entries.map(\.name)
    }

    init(url: URL, maxEntryBytes: Int) throws {
        self.data = try Data(contentsOf: url, options: [.mappedIfSafe])
        self.maxEntryBytes = maxEntryBytes
        self.entries = try Self.readCentralDirectoryEntries(from: data)
    }

    func entryData(named name: String) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }) else {
            throw DOCXTextExtractor.ExtractionError.missingDocument
        }
        guard entry.flags & 0x1 == 0 else {
            throw DOCXTextExtractor.ExtractionError.encrypted
        }
        guard entry.uncompressedSize <= maxEntryBytes else {
            throw DOCXTextExtractor.ExtractionError.tooMuchText
        }
        guard entry.localHeaderOffset + 30 <= data.count,
              data.uint32LE(at: entry.localHeaderOffset) == 0x04034b50
        else {
            throw DOCXTextExtractor.ExtractionError.malformed
        }

        let nameLength = Int(data.uint16LE(at: entry.localHeaderOffset + 26))
        let extraLength = Int(data.uint16LE(at: entry.localHeaderOffset + 28))
        let payloadOffset = entry.localHeaderOffset + 30 + nameLength + extraLength
        guard payloadOffset + entry.compressedSize <= data.count else {
            throw DOCXTextExtractor.ExtractionError.malformed
        }

        let payload = data.subdata(in: payloadOffset..<(payloadOffset + entry.compressedSize))
        switch entry.method {
        case 0:
            return payload
        case 8:
            guard let inflated = Self.inflate(payload, expectedSize: entry.uncompressedSize) else {
                throw DOCXTextExtractor.ExtractionError.malformed
            }
            return inflated
        default:
            throw DOCXTextExtractor.ExtractionError.unsupportedCompression
        }
    }

    private static func readCentralDirectoryEntries(from data: Data) throws -> [Entry] {
        let eocdOffset = try endOfCentralDirectoryOffset(in: data)
        let entryCount = Int(data.uint16LE(at: eocdOffset + 10))
        let centralDirectorySize = Int(data.uint32LE(at: eocdOffset + 12))
        let centralDirectoryOffset = Int(data.uint32LE(at: eocdOffset + 16))

        guard entryCount > 0,
              centralDirectoryOffset + centralDirectorySize <= data.count
        else {
            throw DOCXTextExtractor.ExtractionError.malformed
        }

        var entries: [Entry] = []
        var offset = centralDirectoryOffset

        for _ in 0..<entryCount {
            guard offset + 46 <= data.count,
                  data.uint32LE(at: offset) == 0x02014b50
            else {
                throw DOCXTextExtractor.ExtractionError.malformed
            }

            let flags = data.uint16LE(at: offset + 8)
            let method = data.uint16LE(at: offset + 10)
            let compressedSize = Int(data.uint32LE(at: offset + 20))
            let uncompressedSize = Int(data.uint32LE(at: offset + 24))
            let nameLength = Int(data.uint16LE(at: offset + 28))
            let extraLength = Int(data.uint16LE(at: offset + 30))
            let commentLength = Int(data.uint16LE(at: offset + 32))
            let localHeaderOffset = Int(data.uint32LE(at: offset + 42))
            let nameOffset = offset + 46
            let nextOffset = nameOffset + nameLength + extraLength + commentLength

            guard nameOffset + nameLength <= data.count, nextOffset <= data.count else {
                throw DOCXTextExtractor.ExtractionError.malformed
            }

            guard let name = String(data: data.subdata(in: nameOffset..<(nameOffset + nameLength)), encoding: .utf8) else {
                throw DOCXTextExtractor.ExtractionError.malformed
            }

            entries.append(Entry(
                name: name,
                flags: flags,
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))

            offset = nextOffset
        }

        return entries
    }

    private static func endOfCentralDirectoryOffset(in data: Data) throws -> Int {
        guard data.count >= 22 else {
            throw DOCXTextExtractor.ExtractionError.malformed
        }

        let lowerBound = max(0, data.count - 65_557)
        var offset = data.count - 22
        while offset >= lowerBound {
            if data.uint32LE(at: offset) == 0x06054b50 {
                return offset
            }
            offset -= 1
        }

        throw DOCXTextExtractor.ExtractionError.malformed
    }

    private static func inflate(_ compressed: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }

        var output = Data(count: expectedSize)
        let decodedSize = output.withUnsafeMutableBytes { outputBuffer in
            compressed.withUnsafeBytes { inputBuffer in
                compression_decode_buffer(
                    outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    expectedSize,
                    inputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard decodedSize == expectedSize else { return nil }
        return output
    }
}

private final class WordDocumentXMLParser: NSObject, XMLParserDelegate {
    private let maxCharacters: Int
    private var paragraphs: [String] = []
    private var currentParagraph = ""
    private var isInParagraph = false
    private var isInText = false
    private var characterCount = 0
    private var failed = false
    private var tooLarge = false

    init(maxCharacters: Int) {
        self.maxCharacters = maxCharacters
    }

    func parse(_ data: Data) throws -> String {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false

        guard parser.parse(), !failed else {
            if tooLarge { throw DOCXTextExtractor.ExtractionError.tooMuchText }
            throw DOCXTextExtractor.ExtractionError.xmlParseFailed
        }

        let text = paragraphs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw DOCXTextExtractor.ExtractionError.missingDocument
        }

        return text
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(elementName, qualifiedName: qName) {
        case "p":
            isInParagraph = true
            currentParagraph = ""
        case "t":
            isInText = true
        case "tab" where isInParagraph:
            appendText("\t", parser: parser)
        case "br" where isInParagraph, "cr" where isInParagraph:
            appendText("\n", parser: parser)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard isInParagraph, isInText else { return }
        appendText(string, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(elementName, qualifiedName: qName) {
        case "t":
            isInText = false
        case "p":
            paragraphs.append(currentParagraph)
            currentParagraph = ""
            isInParagraph = false
            isInText = false
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failed = true
    }

    private func appendText(_ text: String, parser: XMLParser) {
        characterCount += text.count
        guard characterCount <= maxCharacters else {
            failed = true
            tooLarge = true
            parser.abortParsing()
            return
        }
        currentParagraph += text
    }

    private func localName(_ elementName: String, qualifiedName qName: String?) -> String {
        let name = qName ?? elementName
        if let colon = name.lastIndex(of: ":") {
            return String(name[name.index(after: colon)...])
        }
        return name
    }
}

private final class TextRunXMLParser: NSObject, XMLParserDelegate {
    private let textElementNames: Set<String>
    private var textRuns: [String] = []
    private var currentText = ""
    private var isInTextElement = false
    private var failed = false

    init(textElementNames: Set<String>) {
        self.textElementNames = textElementNames
    }

    static func text(from data: Data, textElementNames: Set<String>) -> String? {
        let delegate = TextRunXMLParser(textElementNames: textElementNames)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false

        guard parser.parse(), !delegate.failed else { return nil }
        return delegate.textRuns.joined(separator: "\n")
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = qName ?? elementName
        if textElementNames.contains(name) || textElementNames.contains(elementName) {
            isInTextElement = true
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInTextElement {
            currentText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = qName ?? elementName
        if textElementNames.contains(name) || textElementNames.contains(elementName) {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                textRuns.append(trimmed)
            }
            currentText = ""
            isInTextElement = false
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failed = true
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
