import Foundation

// MARK: - PPTX exporter
//
// Writes a valid Office Open XML presentation (PPTX) from deck content — no
// third-party dependency, just XML + the system `zip` binary. The package is
// deliberately minimal but complete: one slide master, one layout, one theme,
// one notes master, one slide + notes slide per deck slide, and embedded
// images when the deck has them. PowerPoint (and Keynote, and python-pptx)
// open it; the speaker notes land in the notes pane.
//
// Geometry is absolute per shape (EMU; 914,400 EMU = 1 inch; slide is
// 13.333" × 7.5", 16:9), so slides are layout-independent and every style
// renders identically.

enum PPTXExporter {

    private static let emuPerInch = 91_440.0
    private static let slideWidth = 12_192_000     // 13.333"
    private static let slideHeight = 6_858_000     // 7.5"

    private static func emu(_ inches: Double) -> Int {
        Int((inches * emuPerInch).rounded())
    }

    struct ImagePart {
        let data: Data
        let ext: String          // "png" | "jpg"
        let mime: String
    }

    // MARK: - Entry

    /// Export the deck into `directory` as `deck.pptx`. Returns the file URL.
    static func export(content: SlideContent, style: PresentationStyle,
                       images: [Int: ImagePart], logo: ImagePart?,
                       to directoryURL: URL) throws -> URL {
        let workspace = directoryURL.appendingPathComponent(".pptx_workspace")
        try? FileManager.default.removeItem(at: workspace)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let parts = try buildParts(
            content: content, style: style,
            images: images, logo: logo)

        // Write every part, then zip. Media first so slide rels can reference
        // them regardless of write order.
        for (relativePath, data) in parts {
            let url = workspace.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        // /usr/bin/zip is guaranteed on macOS. Argument array (not a shell
        // string) so `[Content_Types].xml` needs no quoting.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = workspace
        let archive = workspace.appendingPathComponent("deck.pptx")
        process.arguments = ["-r", "-X", archive.path] + parts.keys.map { $0 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PresentationError.exportFailed("zip failed with code \(process.terminationStatus)")
        }

        let destination = directoryURL.appendingPathComponent("deck.pptx")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: archive, to: destination)
        try? FileManager.default.removeItem(at: workspace)
        return destination
    }

    // MARK: - Parts

    private static func buildParts(content: SlideContent, style: PresentationStyle,
                                   images: [Int: ImagePart], logo: ImagePart?) throws -> [String: Data] {
        let slideCount = content.slides.count
        var parts: [String: Data] = [:]

        func put(_ path: String, _ xml: String) {
            parts[path] = Data(xml.utf8)
        }

        // Media — one part per unique image (slide index → media file name).
        var mediaNames: [Int: String] = [:]
        var mediaParts: [String: ImagePart] = [:]
        var mediaCounter = 0
        func addMedia(_ image: ImagePart) -> String {
            mediaCounter += 1
            let name = "image\(mediaCounter).\(image.ext)"
            mediaParts["ppt/media/\(name)"] = image
            return name
        }
        for (index, image) in images.sorted(by: { $0.key < $1.key }) {
            mediaNames[index] = addMedia(image)
        }
        var logoName: String?
        if let logo {
            logoName = addMedia(logo)
        }

        // 1. [Content_Types].xml
        var overrides = [
            "/ppt/presentation.xml", "/ppt/slideMasters/slideMaster1.xml",
            "/ppt/slideLayouts/slideLayout1.xml", "/ppt/theme/theme1.xml",
            "/ppt/notesMasters/notesMaster1.xml", "/docProps/core.xml", "/docProps/app.xml",
        ]
        for i in 1...slideCount {
            overrides.append("/ppt/slides/slide\(i).xml")
            overrides.append("/ppt/notesSlides/notesSlide\(i).xml")
        }
        var defaultExtensions = [
            "rels": "application/vnd.openxmlformats-package.relationships+xml",
            "xml": "application/xml",
            "png": "image/png",
            "jpeg": "image/jpeg",
        ]
        let defaultsXML = defaultExtensions
            .map { "<Default Extension=\"\($0.key)\" ContentType=\"\($0.value)\"/>" }
            .joined(separator: "")
        let overridesXML = overrides
            .map { "<Override PartName=\"\($0)\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.\(partContentTypeName($0)).main+xml\"/>" }
            .joined(separator: "")
        put("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        \(defaultsXML)\(overridesXML)</Types>
        """)

        // 2. Root rels
        put("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """)

        // 3. presentation.xml + rels
        var sldIdXML = ""
        var presentationRels = [
            ("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster", "slideMasters/slideMaster1.xml"),
            ("rId2", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster", "notesMasters/notesMaster1.xml"),
        ]
        for i in 1...slideCount {
            sldIdXML += "<p:sldId id=\"\(255 + i)\" r:id=\"rId\(2 + i)\"/>"
            presentationRels.append(("rId\(2 + i)",
                                     "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide",
                                     "slides/slide\(i).xml"))
        }
        put("ppt/presentation.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
        <p:notesMasterIdLst><p:notesMasterId r:id="rId2"/></p:notesMasterIdLst>
        <p:sldIdLst>\(sldIdXML)</p:sldIdLst>
        <p:sldSz cx="\(slideWidth)" cy="\(slideHeight)" type="screen16x9"/>
        <p:notesSz cx="6858000" cy="9144000"/>
        <p:defaultTextStyle>
        \(textStyleLevels())
        </p:defaultTextStyle>
        </p:presentation>
        """)
        put("ppt/_rels/presentation.xml.rels", relsXML(presentationRels))

        // 4. Slide master + rels
        put("ppt/slideMasters/slideMaster1.xml", slideMasterXML(style: style))
        put("ppt/slideMasters/_rels/slideMaster1.xml.rels", relsXML([
            ("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout", "../slideLayouts/slideLayout1.xml"),
            ("rId2", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme", "../theme/theme1.xml"),
        ]))

        // 5. Slide layout + rels
        put("ppt/slideLayouts/slideLayout1.xml", slideLayoutXML())
        put("ppt/slideLayouts/_rels/slideLayout1.xml.rels", relsXML([
            ("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster", "../slideMasters/slideMaster1.xml"),
        ]))

        // 6. Theme
        put("ppt/theme/theme1.xml", themeXML(style: style))

        // 7. Notes master + rels
        put("ppt/notesMasters/notesMaster1.xml", notesMasterXML())
        put("ppt/notesMasters/_rels/notesMaster1.xml.rels", relsXML([
            ("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme", "../theme/theme1.xml"),
        ]))

        // 8. Slides + notes slides
        for (index, slide) in content.slides.enumerated() {
            let number = index + 1
            put("ppt/slides/slide\(number).xml",
                slideXML(slide, index: index, total: slideCount, style: style,
                         deckTitle: content.title, subtitle: content.subtitle,
                         hasImage: mediaNames[index] != nil,
                         hasLogo: index == 0 && logoName != nil))
            var slideRels = [
                ("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout", "../slideLayouts/slideLayout1.xml"),
            ]
            if let name = mediaNames[index] {
                slideRels.append(("rId2", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/\(name)"))
            }
            if index == 0, let name = logoName {
                slideRels.append(("rId3", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "../media/\(name)"))
            }
            put("ppt/slides/_rels/slide\(number).xml.rels", relsXML(slideRels))

            put("ppt/notesSlides/notesSlide\(number).xml", notesSlideXML(notes: slide.notes))
            put("ppt/notesSlides/_rels/notesSlide\(number).xml.rels", relsXML([
                ("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster", "../notesMasters/notesMaster1.xml"),
            ]))
        }

        // 9. Media
        for (path, image) in mediaParts {
            parts[path] = image.data
        }

        // 10. Doc props
        let now = ISO8601DateFormatter().string(from: Date())
        put("docProps/core.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:title>\(escape(content.title))</dc:title>
        <dc:creator>Alfred</dc:creator>
        <cp:lastModifiedBy>Alfred</cp:lastModifiedBy>
        <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified>
        </cp:coreProperties>
        """)
        put("docProps/app.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
        <Application>Alfred Presentation Generator</Application>
        <Slides>\(slideCount)</Slides>
        <Notes>\(slideCount)</Notes>
        <TitlesOfParts><vt:vector size="\(slideCount)" baseType="lpstr"><vt:lpstr>\(escape(content.title))</vt:lpstr>\(String(repeating: "<vt:lpstr>Slide</vt:lpstr>", count: slideCount - 1))</vt:vector></TitlesOfParts>
        </Properties>
        """)

        return parts
    }

    // MARK: - XML builders

    private static func partContentTypeName(_ part: String) -> String {
        switch part {
        case "/ppt/presentation.xml": return "presentation"
        case "/ppt/slideMasters/slideMaster1.xml": return "slideMaster"
        case "/ppt/slideLayouts/slideLayout1.xml": return "slideLayout"
        case "/ppt/theme/theme1.xml": return "theme"
        case "/ppt/notesMasters/notesMaster1.xml": return "notesMaster"
        case "/docProps/core.xml": return "core-properties"
        case "/docProps/app.xml": return "extended-properties"
        default:
            if part.hasPrefix("/ppt/slides/slide") { return "slide" }
            if part.hasPrefix("/ppt/notesSlides/") { return "notesSlide" }
            return "slide"
        }
    }

    private static func relsXML(_ rels: [(String, String, String)]) -> String {
        let items = rels.map { id, type, target in
            "<Relationship Id=\"\(id)\" Type=\"\(type)\" Target=\"\(target)\"/>"
        }.joined(separator: "")
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(items)</Relationships>
        """
    }

    /// Default text style for presentation.xml: one entry per outline level.
    private static func textStyleLevels() -> String {
        var out = "<a:defPPr><a:defRPr lang=\"en-US\"/></a:defPPr>"
        for level in 1...9 {
            let sz = level == 1 ? 1800 : max(1200, 1800 - level * 100)
            out += "<a:lvl\(level)pPr><a:defRPr lang=\"en-US\" sz=\"\(sz)\"/></a:lvl\(level)pPr>"
        }
        return out
    }

    private static func slideMasterXML(style: PresentationStyle) -> String {
        // Title + body placeholder shapes so the layout (and any tool that
        // reads placeholders) has something to attach to.
        let titlePlaceholder = placeholderShape(
            id: 2, name: "Title Placeholder 1", type: "title",
            x: emu(0.75), y: emu(0.5), w: emu(11.833), h: emu(1.0))
        let bodyPlaceholder = placeholderShape(
            id: 3, name: "Content Placeholder 2", type: "body", idx: 1,
            x: emu(0.75), y: emu(1.75), w: emu(11.833), h: emu(5.25))
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld>
        <p:bg><p:bgPr><a:solidFill><a:srgbClr val="\(style.background)"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>
        <p:spTree>
        \(groupShape())
        \(titlePlaceholder)
        \(bodyPlaceholder)
        </p:spTree>
        </p:cSld>
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
        <p:sldLayoutIdLst><p:sldLayoutId id="1" r:id="rId1"/></p:sldLayoutIdLst>
        <p:txStyles>
        <p:titleStyle>
        \(textStyleLevels())
        </p:titleStyle>
        <p:bodyStyle>
        \(textStyleLevels())
        </p:bodyStyle>
        <p:otherStyle>
        \(textStyleLevels())
        </p:otherStyle>
        </p:txStyles>
        </p:sldMaster>
        """
    }

    private static func slideLayoutXML() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1">
        <p:cSld name="Blank">
        <p:spTree>
        \(groupShape())
        \(placeholderShape(id: 2, name: "Title Placeholder 1", type: "title", x: emu(0.75), y: emu(0.5), w: emu(11.833), h: emu(1.0)))
        \(placeholderShape(id: 3, name: "Content Placeholder 2", type: "body", idx: 1, x: emu(0.75), y: emu(1.75), w: emu(11.833), h: emu(5.25)))
        </p:spTree>
        </p:cSld>
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:sldLayout>
        """
    }

    private static func notesMasterXML() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:notesMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld>
        <p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>
        <p:spTree>
        \(groupShape())
        \(placeholderShape(id: 2, name: "Notes Placeholder 1", type: "body", idx: 1, x: emu(0.5), y: emu(0.5), w: emu(9.0), h: emu(10.5)))
        \(placeholderShape(id: 3, name: "Slide Image Placeholder 1", type: "sldImg", idx: 0, x: emu(0.5), y: emu(0.5), w: emu(3.0), h: emu(2.0)))
        </p:spTree>
        </p:cSld>
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:notesMaster>
        """
    }

    private static func groupShape() -> String {
        """
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        """
    }

    private static func placeholderShape(id: Int, name: String, type: String,
                                         idx: Int? = nil, x: Int, y: Int, w: Int, h: Int) -> String {
        let ph: String
        if let idx {
            ph = "<p:ph type=\"\(type)\" idx=\"\(idx)\"/>"
        } else {
            ph = "<p:ph type=\"\(type)\"/>"
        }
        return """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="\(name)"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr>\(ph)</p:nvPr></p:nvSpPr>
        <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(w)" cy="\(h)"/></a:xfrm></p:spPr>
        <p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp>
        """
    }

    private static func themeXML(style: PresentationStyle) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="AlfredDeck">
        <a:themeElements>
        <a:clrScheme name="Alfred">
        <a:dk1><a:srgbClr val="000000"/></a:dk1>
        <a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>
        <a:dk2><a:srgbClr val="\(style.text)"/></a:dk2>
        <a:lt2><a:srgbClr val="\(style.background)"/></a:lt2>
        <a:accent1><a:srgbClr val="\(style.accent)"/></a:accent1>
        <a:accent2><a:srgbClr val="\(style.accent2)"/></a:accent2>
        <a:accent3><a:srgbClr val="4472C4"/></a:accent3>
        <a:accent4><a:srgbClr val="ED7D31"/></a:accent4>
        <a:accent5><a:srgbClr val="A5A5A5"/></a:accent5>
        <a:accent6><a:srgbClr val="FFC000"/></a:accent6>
        <a:hlink><a:srgbClr val="0563C1"/></a:hlink>
        <a:folHlink><a:srgbClr val="954F72"/></a:folHlink>
        </a:clrScheme>
        <a:fontScheme name="Alfred">
        <a:majorFont><a:latin typeface="\(style.pptxTitleFont)"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>
        <a:minorFont><a:latin typeface="\(style.pptxBodyFont)"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>
        </a:fontScheme>
        <a:fmtScheme name="Alfred">
        <a:fillStyleLst>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        </a:fillStyleLst>
        <a:lnStyleLst>
        <a:ln w="9525" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/><a:miter lim="800000"/></a:ln>
        <a:ln w="25400" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/><a:miter lim="800000"/></a:ln>
        <a:ln w="38100" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/><a:miter lim="800000"/></a:ln>
        </a:lnStyleLst>
        <a:effectStyleLst>
        <a:effectStyle><a:effectLst/></a:effectStyle>
        <a:effectStyle><a:effectLst/></a:effectStyle>
        <a:effectStyle><a:effectLst/></a:effectStyle>
        </a:effectStyleLst>
        <a:bgFillStyleLst>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        </a:bgFillStyleLst>
        </a:fmtScheme>
        </a:themeElements>
        </a:theme>
        """
    }

    // MARK: - Slide XML

    private static func slideXML(_ slide: Slide, index: Int, total: Int,
                                 style: PresentationStyle, deckTitle: String,
                                 subtitle: String, hasImage: Bool, hasLogo: Bool) -> String {
        let isTitle = index == 0

        let background = """
        <p:bg><p:bgPr><a:solidFill><a:srgbClr val="\(style.background)"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>
        """

        var shapes = groupShape()

        if isTitle {
            shapes += titleSlideShapes(contentTitle: slide.title, subtitle: subtitle,
                                       style: style, hasLogo: hasLogo)
        } else {
            // Thin accent bar at the top.
            shapes += rectShape(id: 10, x: 0, y: 0, w: slideWidth, h: emu(0.14), fill: style.accent)
            shapes += contentSlideShapes(slide: slide, style: style, deckTitle: deckTitle,
                                         page: index + 1, hasImage: hasImage)
        }

        let clrMap = "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>"

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld>
        \(background)
        <p:spTree>
        \(shapes)
        </p:spTree>
        </p:cSld>
        \(clrMap)
        </p:sld>
        """
    }

    /// Title slide: centered deck title, subtitle and an optional logo at
    /// top-right.
    private static func titleSlideShapes(contentTitle: String, subtitle: String,
                                         style: PresentationStyle,
                                         hasLogo: Bool) -> String {
        var shapes = ""
        if hasLogo {
            shapes += picShape(id: 4, name: "Logo",
                               x: emu(11.4), y: emu(0.3), w: emu(1.2), h: emu(1.2),
                               rEmbed: "rId3", altText: "logo")
        }
        shapes += textShape(
            id: 2, name: "Title", x: emu(0.9), y: emu(2.4), w: emu(11.533), h: emu(1.5),
            paragraphs: [runParagraph(text: contentTitle, font: style.pptxTitleFont,
                                      size: 4800, color: style.text, bold: true,
                                      align: "ctr")])
        shapes += textShape(
            id: 3, name: "Subtitle", x: emu(0.9), y: emu(4.05), w: emu(11.533), h: emu(0.9),
            paragraphs: [runParagraph(text: subtitle, font: style.pptxBodyFont,
                                      size: 2400, color: style.mutedText, bold: false,
                                      align: "ctr")])
        return shapes
    }

    private static func contentSlideShapes(slide: Slide, style: PresentationStyle,
                                           deckTitle: String, page: Int,
                                           hasImage: Bool) -> String {
        var shapes = ""

        shapes += textShape(
            id: 2, name: "Title", x: emu(0.75), y: emu(0.45), w: emu(11.833), h: emu(1.0),
            paragraphs: [runParagraph(text: slide.title, font: style.pptxTitleFont,
                                      size: 4000, color: style.text, bold: true,
                                      align: "l")])

        // Body — narrower when a slide image shares the row.
        let bodyWidth = hasImage ? emu(7.6) : emu(11.833)
        let bodyParagraphs = slide.bullets.map { bullet in
            bulletParagraph(text: bullet, font: style.pptxBodyFont, color: style.text,
                            accent: style.accent)
        }
        shapes += textShape(
            id: 3, name: "Body", x: emu(0.75), y: emu(1.75), w: bodyWidth, h: emu(5.0),
            paragraphs: bodyParagraphs, autofit: true)

        if hasImage {
            shapes += picShape(id: 4, name: "Image",
                               x: emu(8.6), y: emu(1.75), w: emu(3.95), h: emu(3.95),
                               rEmbed: "rId2", altText: "illustration")
        }

        // Footer: deck title left, page number right.
        shapes += textShape(
            id: 5, name: "FooterLeft", x: emu(0.75), y: emu(6.95), w: emu(6.0), h: emu(0.3),
            paragraphs: [runParagraph(text: deckTitle, font: style.pptxBodyFont,
                                      size: 1200, color: style.mutedText, bold: false,
                                      align: "l")])
        shapes += textShape(
            id: 6, name: "FooterRight", x: emu(6.9), y: emu(6.95), w: emu(5.683), h: emu(0.3),
            paragraphs: [runParagraph(text: "\(page)", font: style.pptxBodyFont,
                                      size: 1200, color: style.mutedText, bold: false,
                                      align: "r")])
        return shapes
    }

    // MARK: - Shape builders

    private static func rectShape(id: Int, x: Int, y: Int, w: Int, h: Int, fill: String) -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="Bar"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr/></p:nvSpPr>
        <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(w)" cy="\(h)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="\(fill)"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr>
        <p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp>
        """
    }

    private static func picShape(id: Int, name: String, x: Int, y: Int, w: Int, h: Int,
                                 rEmbed: String, altText: String) -> String {
        """
        <p:pic><p:nvPicPr><p:cNvPr id="\(id)" name="\(name)" descr="\(altText)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>
        <p:blipFill><a:blip r:embed="\(rEmbed)"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>
        <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(w)" cy="\(h)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:ln><a:noFill/></a:ln></p:spPr>
        </p:pic>
        """
    }

    private static func textShape(id: Int, name: String, x: Int, y: Int, w: Int, h: Int,
                                  paragraphs: [String], autofit: Bool = false) -> String {
        let autofitXML = autofit ? "<a:normAutofit/>" : ""
        return """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="\(name)"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr/></p:nvSpPr>
        <p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(w)" cy="\(h)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:ln><a:noFill/></a:ln></p:spPr>
        <p:txBody><a:bodyPr wrap="square">\(autofitXML)</a:bodyPr><a:lstStyle/>
        \(paragraphs.joined(separator: ""))
        </p:txBody></p:sp>
        """
    }

    private static func runParagraph(text: String, font: String, size: Int, color: String,
                                     bold: Bool, align: String) -> String {
        let b = bold ? " b=\"1\"" : ""
        return """
        <a:p><a:pPr algn="\(align)"/><a:r><a:rPr lang="en-US" sz="\(size)"\(b)><a:solidFill><a:srgbClr val="\(color)"/></a:solidFill><a:latin typeface="\(font)"/></a:rPr><a:t>\(escape(text))</a:t></a:r></a:p>
        """
    }

    private static func bulletParagraph(text: String, font: String, color: String,
                                        accent: String) -> String {
        return """
        <a:p><a:pPr marL="342900" indent="-342900"><a:spcBef><a:spcPts val="800"/></a:spcBef><a:buClr><a:srgbClr val="\(accent)"/></a:buClr><a:buFont typeface="Arial"/><a:buChar char="&#8226;"/></a:pPr><a:r><a:rPr lang="en-US" sz="2000"><a:solidFill><a:srgbClr val="\(color)"/></a:solidFill><a:latin typeface="\(font)"/></a:rPr><a:t>\(escape(text))</a:t></a:r></a:p>
        """
    }

    private static func notesSlideXML(notes: String) -> String {
        let paragraphs: String
        let lines = notes.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.isEmpty || lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            paragraphs = "<a:p/>"
        } else {
            paragraphs = lines.map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return "<a:p/>" }
                return "<a:p><a:r><a:rPr lang=\"en-US\" sz=\"1400\"/><a:t>\(escape(trimmed))</a:t></a:r></a:p>"
            }.joined(separator: "")
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
        <p:cSld>
        <p:spTree>
        \(groupShape())
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Notes"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>
        <p:spPr><a:xfrm><a:off x="\(emu(0.5))" y="\(emu(0.5))"/><a:ext cx="\(emu(9.0))" cy="\(emu(10.5))"/></a:xfrm></p:spPr>
        <p:txBody><a:bodyPr/><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>
        </p:spTree>
        </p:cSld>
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
        </p:notes>
        """
    }

    // MARK: - Escaping

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
