import Foundation

struct PPTXExportCapability {
    func write(content: String, title: String?, to url: URL) throws {
        guard url.pathExtension.lowercased() == "pptx" else {
            throw LLMError.networkError("PPTX export requires a .pptx destination.")
        }

        let slides = makeSlides(from: content, fallbackTitle: title)
        var entries: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypesXML(slideCount: slides.count).utf8)),
            ("_rels/.rels", Data(packageRelationshipsXML.utf8)),
            ("ppt/presentation.xml", Data(presentationXML(slideCount: slides.count).utf8)),
            ("ppt/_rels/presentation.xml.rels", Data(presentationRelationshipsXML(slideCount: slides.count).utf8)),
            ("ppt/slideMasters/slideMaster1.xml", Data(slideMasterXML.utf8)),
            ("ppt/slideMasters/_rels/slideMaster1.xml.rels", Data(slideMasterRelationshipsXML.utf8)),
            ("ppt/slideLayouts/slideLayout1.xml", Data(slideLayoutXML.utf8)),
            ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", Data(slideLayoutRelationshipsXML.utf8)),
            ("ppt/theme/theme1.xml", Data(themeXML.utf8)),
        ]

        for (index, slide) in slides.enumerated() {
            let slideNumber = index + 1
            entries.append(("ppt/slides/slide\(slideNumber).xml", Data(slideXML(slide, slideNumber: slideNumber).utf8)))
            entries.append(("ppt/slides/_rels/slide\(slideNumber).xml.rels", Data(slideRelationshipsXML.utf8)))
        }

        let archive = try ZipStoreArchive.make(entries: entries)
        try archive.write(to: url, options: .atomic)
    }

    private struct Slide {
        let title: String
        let bullets: [String]
    }

    private func makeSlides(from content: String, fallbackTitle: String?) -> [Slide] {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var sections: [Slide] = []
        var currentTitle: String?
        var currentBullets: [String] = []

        for line in lines {
            guard !line.isEmpty else { continue }
            if isHeading(line) {
                if let currentTitle {
                    sections.append(Slide(title: currentTitle, bullets: currentBullets))
                }
                currentTitle = cleanHeading(line)
                currentBullets = []
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                currentBullets.append(String(line.dropFirst(2)))
            } else if let re = Self.orderedListPrefix,
                      re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                let bullet = re.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
                currentBullets.append(bullet)
            } else if currentTitle == nil {
                currentTitle = fallbackTitle ?? "Presentation"
                currentBullets.append(line)
            } else {
                currentBullets.append(line)
            }
        }

        if let currentTitle {
            sections.append(Slide(title: currentTitle, bullets: currentBullets))
        }

        if sections.isEmpty {
            sections = [Slide(title: fallbackTitle ?? "Presentation", bullets: ["Overview"])]
        }

        let titleSlide = Slide(
            title: fallbackTitle ?? sections.first?.title ?? "Presentation",
            bullets: sections.first?.title == fallbackTitle ? [] : [sections.first?.title ?? ""].filter { !$0.isEmpty }
        )

        let contentSlides = sections.prefix(5).map { section in
            Slide(
                title: section.title,
                bullets: Array(section.bullets.prefix(6))
            )
        }

        return [titleSlide] + contentSlides
    }

    // Slide-parsing patterns are constant — compile once instead of per line/heading.
    private static let orderedListPrefix = try? NSRegularExpression(pattern: #"^\d+\.\s+"#)
    private static let headingPrefix = try? NSRegularExpression(pattern: #"^#{1,3}\s+"#)

    private func isHeading(_ line: String) -> Bool {
        line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ")
    }

    private func cleanHeading(_ line: String) -> String {
        guard let re = Self.headingPrefix else { return line }
        return re.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
    }

    private func slideXML(_ slide: Slide, slideNumber: Int) -> String {
        let bodyRuns = slide.bullets.isEmpty
            ? paragraphXML("")
            : slide.bullets.map { paragraphXML($0) }.joined(separator: "\n")

        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
              <p:cSld>
                <p:spTree>
                  <p:nvGrpSpPr>
                    <p:cNvPr id="1" name=""/>
                    <p:cNvGrpSpPr/>
                    <p:nvPr/>
                  </p:nvGrpSpPr>
                  <p:grpSpPr>
                    <a:xfrm>
                      <a:off x="0" y="0"/>
                      <a:ext cx="0" cy="0"/>
                      <a:chOff x="0" y="0"/>
                      <a:chExt cx="0" cy="0"/>
                    </a:xfrm>
                  </p:grpSpPr>
                  <p:sp>
                    <p:nvSpPr>
                      <p:cNvPr id="2" name="Title \(slideNumber)"/>
                      <p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>
                      <p:nvPr><p:ph type="title"/></p:nvPr>
                    </p:nvSpPr>
                    <p:spPr>
                      <a:xfrm><a:off x="685800" y="457200"/><a:ext cx="7772400" cy="914400"/></a:xfrm>
                    </p:spPr>
                    <p:txBody>
                      <a:bodyPr/>
                      <a:lstStyle/>
                      <a:p><a:r><a:rPr lang="en-US" sz="3600" b="1"/><a:t>\(xmlEscaped(slide.title))</a:t></a:r></a:p>
                    </p:txBody>
                  </p:sp>
                  <p:sp>
                    <p:nvSpPr>
                      <p:cNvPr id="3" name="Content \(slideNumber)"/>
                      <p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>
                      <p:nvPr><p:ph type="body" idx="1"/></p:nvPr>
                    </p:nvSpPr>
                    <p:spPr>
                      <a:xfrm><a:off x="914400" y="1600200"/><a:ext cx="7315200" cy="4572000"/></a:xfrm>
                    </p:spPr>
                    <p:txBody>
                      <a:bodyPr/>
                      <a:lstStyle/>
            \(bodyRuns)
                    </p:txBody>
                  </p:sp>
                </p:spTree>
              </p:cSld>
              <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
            </p:sld>
            """
    }

    private func paragraphXML(_ text: String) -> String {
        """
                      <a:p>
                        <a:pPr marL="342900" indent="-171450"/>
                        <a:r><a:rPr lang="en-US" sz="2200"/><a:t>\(xmlEscaped(text))</a:t></a:r>
                      </a:p>
            """
    }

    private func contentTypesXML(slideCount: Int) -> String {
        let slideOverrides = (1...slideCount)
            .map { #"  <Override PartName="/ppt/slides/slide\#($0).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"# }
            .joined(separator: "\n")

        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
              <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
              <Default Extension="xml" ContentType="application/xml"/>
              <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
              <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
              <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
              <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
            \(slideOverrides)
            </Types>
            """
    }

    private func presentationXML(slideCount: Int) -> String {
        let slideIDs = (1...slideCount)
            .map { #"    <p:sldId id="\#(255 + $0)" r:id="rId\#($0 + 1)"/>"# }
            .joined(separator: "\n")

        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
              <p:sldMasterIdLst>
                <p:sldMasterId id="2147483648" r:id="rId1"/>
              </p:sldMasterIdLst>
              <p:sldIdLst>
            \(slideIDs)
              </p:sldIdLst>
              <p:sldSz cx="9144000" cy="5143500" type="screen16x9"/>
              <p:notesSz cx="6858000" cy="9144000"/>
            </p:presentation>
            """
    }

    private func presentationRelationshipsXML(slideCount: Int) -> String {
        let slideRelationships = (1...slideCount)
            .map { #"  <Relationship Id="rId\#($0 + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide\#($0).xml"/>"# }
            .joined(separator: "\n")

        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
            \(slideRelationships)
            </Relationships>
            """
    }

    private var packageRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
        </Relationships>
        """
    }

    private var slideRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
        </Relationships>
        """
    }

    private var slideMasterRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
        </Relationships>
        """
    }

    private var slideLayoutRelationshipsXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
        </Relationships>
        """
    }

    private var slideMasterXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld>
          <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
          <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
        </p:sldMaster>
        """
    }

    private var slideLayoutXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="titleAndBody" preserve="1">
          <p:cSld name="Title and Content"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld>
          <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sldLayout>
        """
    }

    private var themeXML: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Alfred">
          <a:themeElements>
            <a:clrScheme name="Alfred">
              <a:dk1><a:srgbClr val="111111"/></a:dk1>
              <a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>
              <a:dk2><a:srgbClr val="333333"/></a:dk2>
              <a:lt2><a:srgbClr val="F7F7F7"/></a:lt2>
              <a:accent1><a:srgbClr val="2563EB"/></a:accent1>
              <a:accent2><a:srgbClr val="16A34A"/></a:accent2>
              <a:accent3><a:srgbClr val="DC2626"/></a:accent3>
              <a:accent4><a:srgbClr val="9333EA"/></a:accent4>
              <a:accent5><a:srgbClr val="EA580C"/></a:accent5>
              <a:accent6><a:srgbClr val="0891B2"/></a:accent6>
              <a:hlink><a:srgbClr val="2563EB"/></a:hlink>
              <a:folHlink><a:srgbClr val="7C3AED"/></a:folHlink>
            </a:clrScheme>
            <a:fontScheme name="Alfred"><a:majorFont><a:latin typeface="Aptos Display"/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/></a:minorFont></a:fontScheme>
            <a:fmtScheme name="Alfred"><a:fillStyleLst/><a:lnStyleLst/><a:effectStyleLst/><a:bgFillStyleLst/></a:fmtScheme>
          </a:themeElements>
        </a:theme>
        """
    }

    private func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
