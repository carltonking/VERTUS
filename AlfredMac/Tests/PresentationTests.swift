import XCTest
@testable import Alfred

/// Covers the pure, deterministic parts of the presentation generator. No live
/// Hermes session, no network: content parsing, style resolution, the HTML deck
/// builder, a real PPTX export (validated by unzipping + parsing the XML), the
/// Wikipedia image-URL helpers, speaker-notes parsing/markdown, and style
/// matching precedence.
final class PresentationTests: XCTestCase {

    // MARK: - Fixture

    /// A small, realistic deck for exporter tests.
    private func sampleContent() -> SlideContent {
        SlideContent(
            title: "Quantum Computing Basics",
            subtitle: "CS 451 · Spring 2026",
            slides: [
                Slide(title: "Quantum Computing Basics",
                      bullets: [],
                      notes: "Open with why quantum matters and what the talk covers.",
                      imageQuery: ""),
                Slide(title: "Qubits vs Bits",
                      bullets: ["A bit is 0 or 1", "A qubit is a superposition", "Measurement collapses the state"],
                      notes: "Spend ~90s on superposition: the double-slit intuition, then the bra-ket shorthand.",
                      imageQuery: "quantum computer chip"),
                Slide(title: "Entanglement",
                      bullets: ["Correlated states", "Bell pairs", "No faster-than-light signaling"],
                      notes: "Entanglement is correlation, not communication — underline that.",
                      imageQuery: ""),
                Slide(title: "Takeaways",
                      bullets: ["Qubits superpose", "Gates entangle", "Error correction is the bottleneck"],
                      notes: "Close with the three takeaways; field questions.",
                      imageQuery: ""),
            ])
    }

    // MARK: - Content parsing (SlideContent.parse)

    func testParsePlainJSON() {
        let text = """
        {"title":"Deck","subtitle":"Sub","slides":[{"title":"S1","bullets":["a","b"],"notes":"n","imageQuery":""}]}
        """
        let content = SlideContent.parse(text)
        XCTAssertEqual(content?.title, "Deck")
        XCTAssertEqual(content?.subtitle, "Sub")
        XCTAssertEqual(content?.slides.count, 1)
        XCTAssertEqual(content?.slides[0].bullets, ["a", "b"])
    }

    func testParseFencedAndProseWrapped() {
        let text = """
        Here is your deck!

        ```json
        {"title":"Fenced Deck","subtitle":"","slides":[{"title":"S1","bullets":["x"],"notes":"","imageQuery":"chart"}]}
        ```
        """
        let content = SlideContent.parse(text)
        XCTAssertEqual(content?.title, "Fenced Deck")
        XCTAssertEqual(content?.slides[0].imageQuery, "chart")
    }

    func testParseTrimsBulletsAndDropsEmptyOnes() {
        let text = """
        {"title":"T","subtitle":"","slides":[{"title":"S","bullets":["  keep  ","","  ","also"],"notes":"","imageQuery":""}]}
        """
        let content = SlideContent.parse(text)
        XCTAssertEqual(content?.slides[0].bullets, ["keep", "also"])
    }

    func testParseRejectsInvalidContent() {
        XCTAssertNil(SlideContent.parse("I can't make slides for that."))
        XCTAssertNil(SlideContent.parse(#"{"title":"","subtitle":"","slides":[]}"#))
        XCTAssertNil(SlideContent.parse(#"{"title":"No slides","subtitle":"","slides":[]}"#))
        XCTAssertNil(SlideContent.parse(#"{"slides":[{"title":"","bullets":[],"notes":""}]}"#))
    }

    func testSlideCountFromMinutes() {
        XCTAssertEqual(SlideContent.slideCount(forMinutes: 10), 7)
        XCTAssertEqual(SlideContent.slideCount(forMinutes: 15), 10)
        XCTAssertEqual(SlideContent.slideCount(forMinutes: 3), 5)   // floor
        XCTAssertEqual(SlideContent.slideCount(forMinutes: 60), 20) // ceiling
    }

    func testToneGuidance() {
        for tone in PresentationTone.allCases {
            XCTAssertFalse(tone.displayName.isEmpty)
            XCTAssertFalse(tone.contentGuidance.isEmpty)
        }
        XCTAssertTrue(PresentationTone.academic.contentGuidance.lowercased().contains("evidence"))
    }

    // MARK: - Styles (PresentationStyle)

    func testStyleResolution() {
        XCTAssertEqual(PresentationStyle.style(named: "academic").id, "academic")
        XCTAssertEqual(PresentationStyle.style(named: "Modern").id, "modern")
        XCTAssertEqual(PresentationStyle.style(named: "  MINIMAL  ").id, "minimal")
        // Unknown → modern fallback.
        XCTAssertEqual(PresentationStyle.style(named: "neon").id, "modern")
        XCTAssertEqual(PresentationStyle.style(named: nil).id, "modern")
    }

    func testAllStylesAreUniqueAndComplete() {
        let ids = PresentationStyle.all.map(\.id)
        XCTAssertEqual(Set(ids).count, PresentationStyle.all.count)
        XCTAssertEqual(Set(ids), Set(["modern", "minimal", "colorful", "academic"]))
        for style in PresentationStyle.all {
            XCTAssertFalse(style.displayName.isEmpty)
            XCTAssertEqual(style.background.count, 6)   // hex, no '#'
            XCTAssertEqual(style.text.count, 6)
            XCTAssertFalse(style.pptxTitleFont.isEmpty)
        }
    }

    // MARK: - HTML deck builder

    func testDeckHTMLBuildsSectionsAndEscapes() {
        let content = sampleContent()
        let html = DeckHTML.build(content: content, style: .modern,
                                  images: [1: "data:image/png;base64,AAAA"],
                                  logoDataURI: nil)
        XCTAssertTrue(html.contains("<section class=\"slide title-slide\">"))
        XCTAssertTrue(html.contains("<section class=\"slide \">") || html.contains("<section class=\"slide\">"))
        XCTAssertEqual(html.components(separatedBy: "<section").count - 1, 4)
        XCTAssertTrue(html.contains("data:image/png;base64,AAAA"))
        // Escaping: bullets with < & " come out safe. Slide 1 is the title
        // slide (bullets dropped by design), so the risky bullet must live on
        // a content slide.
        let risky = SlideContent(title: "T", subtitle: "", slides: [
            Slide(title: "T", bullets: [], notes: "", imageQuery: ""),
            Slide(title: "S", bullets: ["a < b & \"c\""], notes: "", imageQuery: ""),
        ])
        let riskyHTML = DeckHTML.build(content: risky, style: .minimal, images: [:], logoDataURI: nil)
        XCTAssertTrue(riskyHTML.contains("a &lt; b &amp; &quot;c&quot;"))
        XCTAssertFalse(riskyHTML.contains("a < b & \"c\""))
    }

    func testDeckHTMLStampsLogoOnlyOnTitleSlide() {
        let html = DeckHTML.build(content: sampleContent(), style: .modern,
                                  images: [:], logoDataURI: "data:image/png;base64,LOGO")
        XCTAssertTrue(html.contains("class=\"logo\""))
        // One logo image total.
        XCTAssertEqual(html.components(separatedBy: "class=\"logo\"").count - 1, 1)
    }

    // MARK: - PPTX exporter

    func testPPTXExportProducesValidOpenableArchive() throws {
        let content = sampleContent()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try PPTXExporter.export(
            content: content, style: .academic,
            images: [1: PPTXExporter.ImagePart(data: Data([0x89, 0x50, 0x4E, 0x47]), ext: "png", mime: "image/png")],
            logo: nil, to: dir)

        XCTAssertEqual(url.lastPathComponent, "deck.pptx")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // The archive must be a valid zip.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-t", url.path]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        unzip.standardError = pipe
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0, "deck.pptx is not a valid zip archive")

        // Required parts present, and a slide + its notes parse as XML.
        let requiredParts = [
            "[Content_Types].xml", "ppt/presentation.xml",
            "ppt/slideMasters/slideMaster1.xml", "ppt/slideLayouts/slideLayout1.xml",
            "ppt/theme/theme1.xml", "ppt/notesMasters/notesMaster1.xml",
            "ppt/slides/slide1.xml", "ppt/slides/slide2.xml",
            "ppt/notesSlides/notesSlide1.xml", "ppt/notesSlides/notesSlide2.xml",
            "docProps/core.xml", "docProps/app.xml",
        ]
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        listing.arguments = ["-Z1", url.path]
        let listPipe = Pipe()
        listing.standardOutput = listPipe
        listing.standardError = listPipe
        try listing.run()
        listing.waitUntilExit()
        let names = String(data: listPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for part in requiredParts {
            XCTAssertTrue(names.contains(part), "missing required part: \\(part)")
        }
        XCTAssertTrue(names.contains("ppt/media/image1.png"), "slide image should be embedded")

        // The image relationship is wired: slide2.xml.rels references it.
        let rels = try unzipPart(url: url, name: "ppt/slides/_rels/slide2.xml.rels")
        XCTAssertTrue(rels.contains("../media/image1.png"))
        // Notes land in the notes slide, escaped.
        let notes = try unzipPart(url: url, name: "ppt/notesSlides/notesSlide2.xml")
        XCTAssertTrue(notes.contains("superposition"))
    }

    func testPPTXExportEscapesText() throws {
        let content = SlideContent(title: "T & <Title>", subtitle: "", slides: [
            Slide(title: "T & <Title>", bullets: [], notes: "", imageQuery: ""),
            Slide(title: "S", bullets: ["use 5 > 3 & \"quoted\""], notes: "", imageQuery: ""),
        ])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try PPTXExporter.export(
            content: content, style: .minimal, images: [:], logo: nil, to: dir)
        let slide = try unzipPart(url: url, name: "ppt/slides/slide2.xml")
        XCTAssertTrue(slide.contains("5 &gt; 3 &amp; &quot;quoted&quot;"))
        XCTAssertFalse(slide.contains("5 > 3 &"))
        // Titles in docProps too.
        let core = try unzipPart(url: url, name: "docProps/core.xml")
        XCTAssertTrue(core.contains("T &amp; &lt;Title&gt;"))
    }

    private func unzipPart(url: URL, name: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: - PDF renderer

    @MainActor
    func testPDFRendererProducesData() async throws {
        let html = DeckHTML.build(content: sampleContent(), style: .modern,
                                  images: [:], logoDataURI: nil)
        let data = try await PDFRenderer.render(html: html)
        XCTAssertFalse(data.isEmpty)
        // PDF magic bytes.
        let head = data.prefix(5)
        XCTAssertEqual(String(data: head, encoding: .ascii), "%PDF-")
    }

    // MARK: - Image finder helpers

    func testSearchURLBuilding() {
        let url = ImageFinder.searchURL(for: "double slit experiment")
        XCTAssertNotNil(url)
        let query = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        XCTAssertTrue(query.queryItems?.contains(URLQueryItem(name: "action", value: "query")) == true)
        XCTAssertTrue(query.queryItems?.contains { $0.name == "srsearch" && $0.value == "double slit experiment" } == true)
    }

    func testThumbnailURLBuilding() {
        let url = ImageFinder.thumbnailURL(for: "Quantum computing", size: 800)
        XCTAssertNotNil(url)
        let query = URLComponents(url: url!, resolvingAgainstBaseURL: false)!
        XCTAssertTrue(query.queryItems?.contains(URLQueryItem(name: "pithumbsize", value: "800")) == true)
    }

    func testSearchResultParsing() {
        let json: [String: Any] = [
            "query": ["search": [["title": "Quantum computing"], ["title": "Qubit"]]],
        ]
        XCTAssertEqual(ImageFinder.topSearchResult(from: json), "Quantum computing")
        XCTAssertNil(ImageFinder.topSearchResult(from: ["query": ["search": []]]))
        XCTAssertNil(ImageFinder.topSearchResult(from: ["other": 1]))
    }

    func testThumbnailSourceParsing() {
        let json: [String: Any] = [
            "query": ["pages": ["123": ["title": "Q", "thumbnail": ["source": "https://upload.wikimedia.org/x.jpg"]]]],
        ]
        XCTAssertEqual(ImageFinder.thumbnailSource(from: json), "https://upload.wikimedia.org/x.jpg")
        XCTAssertNil(ImageFinder.thumbnailSource(from: ["query": ["pages": ["1": ["title": "no thumb"]]]]))
        // First usable page wins even when an earlier page lacks a thumbnail.
        let mixed: [String: Any] = [
            "query": ["pages": [
                "1": ["title": "no thumb"],
                "2": ["thumbnail": ["source": "https://example.com/a.png"]],
            ]],
        ]
        XCTAssertEqual(ImageFinder.thumbnailSource(from: mixed), "https://example.com/a.png")
    }

    func testImageKindClassification() {
        XCTAssertEqual(ImageFinder.imageKind(for: "https://x/y.jpg")?.ext, "jpg")
        XCTAssertEqual(ImageFinder.imageKind(for: "https://x/y.JPEG")?.mime, "image/jpeg")
        XCTAssertEqual(ImageFinder.imageKind(for: "https://x/y.png")?.mime, "image/png")
        XCTAssertNil(ImageFinder.imageKind(for: "https://x/y.svg"))
        XCTAssertNil(ImageFinder.imageKind(for: "https://x/y.webp"))
    }

    // MARK: - Speaker notes

    func testSpeakerNotesPlanParsing() {
        let text = """
        ```json
        {"intro":"Hook.","totalMinutes":8,"slides":[{"index":1,"points":"Say the thing","minutes":1.5},{"index":2,"points":"More things","minutes":2}],"qa":"Q: why? A: because"}
        ```
        """
        let plan = SpeakerNotesPlan.parse(text)
        XCTAssertEqual(plan?.intro, "Hook.")
        XCTAssertEqual(plan?.totalMinutes, 8)
        XCTAssertEqual(plan?.slides.count, 2)
        XCTAssertEqual(plan?.slides[1].minutes, 2)
        XCTAssertNil(SpeakerNotesPlan.parse("nope"))
    }

    func testSpeakerNotesMarkdown() {
        let content = sampleContent()
        let plan = SpeakerNotesPlan(
            intro: "Hook: quantum isn't magic.",
            totalMinutes: 7,
            slides: [
                SpeakerNotesPlan.SlideNotes(index: 1, points: "Open with the why.", minutes: 1),
                SpeakerNotesPlan.SlideNotes(index: 2, points: "Superposition via double slit.", minutes: 2),
                SpeakerNotesPlan.SlideNotes(index: 3, points: "Correlation not communication.", minutes: 2),
                SpeakerNotesPlan.SlideNotes(index: 4, points: "Three takeaways.", minutes: 2),
            ],
            qa: "Q: can we communicate with entanglement? A: no.")
        let md = SpeakerNotesGenerator.markdown(topic: "Quantum Computing Basics", content: content, plan: plan)
        XCTAssertTrue(md.contains("# Quantum Computing Basics"))
        XCTAssertTrue(md.contains("~7 minutes"))
        XCTAssertTrue(md.contains("## Slide 2: Qubits vs Bits"))
        XCTAssertTrue(md.contains("Superposition via double slit."))
        XCTAssertTrue(md.contains("## Conclusion & Q&amp;A") || md.contains("## Conclusion & Q&A"))
        XCTAssertTrue(md.contains("Field questions") == false) // the real Q&A is used
    }

    // MARK: - Style matching (StyleMatcher.suggestedStyle)

    func testStylePrecedenceExplicitWins() {
        let history = [PresentationHistoryEntry(topic: "t", tone: "academic", style: "minimal", createdAt: 1)]
        let style = StyleMatcher.suggestedStyle(
            explicit: "colorful", settingsDefault: "academic", history: history, tone: .academic)
        XCTAssertEqual(style.id, "colorful")
    }

    func testStylePrecedenceSettingsDefaultOverHistory() {
        let history = [PresentationHistoryEntry(topic: "t", tone: "academic", style: "minimal", createdAt: 1)]
        let style = StyleMatcher.suggestedStyle(
            explicit: nil, settingsDefault: "modern", history: history, tone: .academic)
        XCTAssertEqual(style.id, "modern")
    }

    func testStylePrecedenceToneMatchedHistory() {
        let history = [
            PresentationHistoryEntry(topic: "a", tone: "business", style: "colorful", createdAt: 2),
            PresentationHistoryEntry(topic: "b", tone: "academic", style: "minimal", createdAt: 1),
        ]
        // Empty settings default → history decides; same-tone entry wins.
        let style = StyleMatcher.suggestedStyle(
            explicit: nil, settingsDefault: "", history: history, tone: .academic)
        XCTAssertEqual(style.id, "minimal")
    }

    func testStylePrecedenceNewestHistoryWithoutToneMatch() {
        let history = [
            PresentationHistoryEntry(topic: "a", tone: "business", style: "colorful", createdAt: 2),
            PresentationHistoryEntry(topic: "b", tone: "business", style: "minimal", createdAt: 1),
        ]
        let style = StyleMatcher.suggestedStyle(
            explicit: nil, settingsDefault: "", history: history, tone: .academic)
        XCTAssertEqual(style.id, "colorful") // most recent overall
    }

    func testStylePrecedenceToneDefaults() {
        XCTAssertEqual(
            StyleMatcher.suggestedStyle(explicit: nil, settingsDefault: "", history: [], tone: .academic).id,
            "academic")
        XCTAssertEqual(
            StyleMatcher.suggestedStyle(explicit: nil, settingsDefault: "", history: [], tone: .business).id,
            "modern")
    }

    // MARK: - Formats

    func testExportFormats() {
        XCTAssertEqual(PresentationExportFormat.both.displayName, "PPTX + PDF")
        XCTAssertEqual(PresentationExportFormat.allCases.count, 3)
        for format in PresentationExportFormat.allCases {
            XCTAssertFalse(format.displayName.isEmpty)
        }
        XCTAssertEqual(PresentationExportFormat(rawValue: "pptx"), .pptx)
        XCTAssertNil(PresentationExportFormat(rawValue: "bogus"))
    }
}
