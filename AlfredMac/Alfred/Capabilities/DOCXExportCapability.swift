import Foundation

struct DOCXExportCapability {
    func write(content: String, title: String?, to url: URL) throws {
        guard url.pathExtension.lowercased() == "docx" else {
            throw LLMError.networkError("DOCX export requires a .docx destination.")
        }

        let documentXML = documentXML(from: content, fallbackTitle: title)
        let entries: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypesXML.utf8)),
            ("_rels/.rels", Data(packageRelationshipsXML.utf8)),
            ("word/document.xml", Data(documentXML.utf8)),
            ("word/_rels/document.xml.rels", Data(documentRelationshipsXML.utf8)),
        ]

        let archive = try ZipStoreArchive.make(entries: entries)
        try archive.write(to: url, options: .atomic)
    }

    private func documentXML(from content: String, fallbackTitle: String?) -> String {
        var paragraphs: [String] = []
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: .newlines)

        if let fallbackTitle, !fallbackTitle.isEmpty, !startsWithHeading(lines) {
            paragraphs.append(paragraph(fallbackTitle, style: .title))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                paragraphs.append(paragraph(String(trimmed.dropFirst(2)), style: .title))
            } else if trimmed.hasPrefix("## ") {
                paragraphs.append(paragraph(String(trimmed.dropFirst(3)), style: .heading))
            } else if trimmed.hasPrefix("### ") {
                paragraphs.append(paragraph(String(trimmed.dropFirst(4)), style: .subheading))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                paragraphs.append(paragraph("• \(trimmed.dropFirst(2))", style: .body))
            } else if trimmed.isEmpty {
                paragraphs.append(paragraph("", style: .body))
            } else {
                paragraphs.append(paragraph(line, style: .body))
            }
        }

        if paragraphs.isEmpty {
            paragraphs.append(paragraph("", style: .body))
        }

        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
              <w:body>
            \(paragraphs.joined(separator: "\n"))
                <w:sectPr>
                  <w:pgSz w:w="12240" w:h="15840"/>
                  <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>
                </w:sectPr>
              </w:body>
            </w:document>
            """
    }

    private func paragraph(_ text: some StringProtocol, style: ParagraphStyle) -> String {
        let runProperties: String
        switch style {
        case .title:
            runProperties = "<w:rPr><w:b/><w:sz w:val=\"36\"/></w:rPr>"
        case .heading:
            runProperties = "<w:rPr><w:b/><w:sz w:val=\"30\"/></w:rPr>"
        case .subheading:
            runProperties = "<w:rPr><w:b/><w:sz w:val=\"26\"/></w:rPr>"
        case .body:
            runProperties = "<w:rPr><w:sz w:val=\"24\"/></w:rPr>"
        }

        return """
                <w:p>
                  <w:r>
                    \(runProperties)
                    <w:t xml:space="preserve">\(xmlEscaped(String(text)))</w:t>
                  </w:r>
                </w:p>
            """
    }

    private enum ParagraphStyle {
        case title
        case heading
        case subheading
        case body
    }

    private func startsWithHeading(_ lines: [String]) -> Bool {
        guard let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return false
        }
        return first.trimmingCharacters(in: .whitespaces).hasPrefix("# ")
    }

    private func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private var contentTypesXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
    }

    private var packageRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
    }

    private var documentRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
        """
    }
}

enum ZipStoreArchive {
    private struct CentralEntry {
        let nameData: Data
        let crc32: UInt32
        let size: UInt32
        let offset: UInt32
    }

    static func make(entries: [(String, Data)]) throws -> Data {
        var archive = Data()
        var centralEntries: [CentralEntry] = []

        for (name, data) in entries {
            guard let nameData = name.data(using: .utf8) else {
                throw LLMError.networkError("Could not encode DOCX entry name.")
            }
            guard data.count <= Int(UInt32.max), archive.count <= Int(UInt32.max) else {
                throw LLMError.networkError("DOCX content is too large.")
            }

            let crc = CRC32.checksum(data)
            let offset = UInt32(archive.count)
            let size = UInt32(data.count)

            archive.appendUInt32LE(0x04034b50)
            archive.appendUInt16LE(20)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt32LE(crc)
            archive.appendUInt32LE(size)
            archive.appendUInt32LE(size)
            archive.appendUInt16LE(UInt16(nameData.count))
            archive.appendUInt16LE(0)
            archive.append(nameData)
            archive.append(data)

            centralEntries.append(CentralEntry(nameData: nameData, crc32: crc, size: size, offset: offset))
        }

        let centralDirectoryOffset = UInt32(archive.count)

        for entry in centralEntries {
            archive.appendUInt32LE(0x02014b50)
            archive.appendUInt16LE(20)
            archive.appendUInt16LE(20)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt32LE(entry.crc32)
            archive.appendUInt32LE(entry.size)
            archive.appendUInt32LE(entry.size)
            archive.appendUInt16LE(UInt16(entry.nameData.count))
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt32LE(0)
            archive.appendUInt32LE(entry.offset)
            archive.append(entry.nameData)
        }

        let centralDirectorySize = UInt32(archive.count) - centralDirectoryOffset
        archive.appendUInt32LE(0x06054b50)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(UInt16(centralEntries.count))
        archive.appendUInt16LE(UInt16(centralEntries.count))
        archive.appendUInt32LE(centralDirectorySize)
        archive.appendUInt32LE(centralDirectoryOffset)
        archive.appendUInt16LE(0)

        return archive
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = 0xedb88320 ^ (crc >> 1)
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
