import AppKit
import Foundation

// MARK: - Presentation generator skill
//
// The complete presentation pipeline, owned by one manager:
//
//   1. A Hermes turn (the skill's own session, never the bar's) researches the
//      topic and produces the deck as JSON — outline, per-slide concise
//      bullets, per-slide speaker notes, and image queries.
//   2. ImageFinder pulls a relevant lead image for up to a few slides.
//   3. PresentationDesigner lays the deck out in the resolved style and
//      renders the PDF (HTML → WKWebView). PPTXExporter writes the .pptx.
//   4. StyleMatcher records the deck so the next one matches the user's style.
//
// Every deck is persisted under ~/.alfred/presentations/<id>/ (content,
// media, both exports, notes), which is what lets the follow-on tools
// (add_speaker_notes, design_presentation, export_presentation) operate on an
// existing deck without regenerating content.

/// What a deck request exports by default.
enum PresentationExportFormat: String, CaseIterable, Identifiable, Sendable {
    case both
    case pptx
    case pdf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .both: return "PPTX + PDF"
        case .pptx: return "PPTX"
        case .pdf: return "PDF"
        }
    }
}

/// One generated deck, as the skill knows it. Persisted as record.json in the
/// deck's directory.
struct PresentationRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var topic: String
    var tone: String
    var style: String
    var slideCount: Int
    var createdAt: TimeInterval
    /// Absolute path to the deck's directory.
    var directory: String
    var hasPptx: Bool
    var hasPdf: Bool
    var hasNotes: Bool

    var resultText: String {
        var lines = ["Deck ready: \(topic) — \(slideCount) slides, \(tone) tone, \(style) style."]
        lines.append("Files: \(directory)")
        if hasPptx { lines.append("• deck.pptx — open in PowerPoint or Keynote") }
        if hasPdf { lines.append("• deck.pdf — ready to present or submit") }
        if hasNotes { lines.append("• speaker_notes.md — your presenting script") }
        lines.append("• slides.html — the deck as a web page")
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class PresentationGeneratorSkill: ObservableObject {

    static let shared = PresentationGeneratorSkill()

    // MARK: Persisted config

    /// Default slide count when the request gives neither a count nor minutes.
    @Published var defaultSlides: Int {
        didSet {
            guard defaultSlides != oldValue else { return }
            UserDefaults.standard.set(defaultSlides, forKey: Keys.defaultSlides)
        }
    }

    /// Default design style (a PresentationStyle id).
    @Published var styleID: String {
        didSet {
            guard styleID != oldValue else { return }
            UserDefaults.standard.set(styleID, forKey: Keys.style)
        }
    }

    /// Whether new decks include speaker notes by default.
    @Published var includeNotes: Bool {
        didSet {
            guard includeNotes != oldValue else { return }
            UserDefaults.standard.set(includeNotes, forKey: Keys.includeNotes)
        }
    }

    /// What create_presentation exports by default.
    @Published var exportFormat: PresentationExportFormat {
        didSet {
            guard exportFormat != oldValue else { return }
            UserDefaults.standard.set(exportFormat.rawValue, forKey: Keys.exportFormat)
        }
    }

    private enum Keys {
        static let defaultSlides = "alfred.presentationDefaultSlides"
        static let style = "alfred.presentationStyle"
        static let includeNotes = "alfred.presentationIncludeNotes"
        static let exportFormat = "alfred.presentationExportFormat"
    }

    /// The skill's own Hermes session — long-lived, spawned on first use, and
    /// separate from the bar's, so a deck build never blocks a conversation.
    /// A generous deadline: a content turn for 15+ slides can run a while.
    private lazy var session = HermesSession(turnDeadline: 600)

    /// Progress hook (future UI); always mirrored to NSLog.
    var onProgress: ((String) -> Void)?

    /// Idempotency: an identical request within 10 minutes returns the same
    /// deck instead of burning another model turn (a Hermes retry after a
    /// watchdog restart would otherwise double-generate).
    private var lastCreated: (key: String, record: PresentationRecord, at: Date)?

    private init() {
        let defaults = UserDefaults.standard
        defaultSlides = defaults.object(forKey: Keys.defaultSlides) as? Int ?? 10
        styleID = defaults.string(forKey: Keys.style) ?? PresentationStyle.modern.id
        includeNotes = defaults.object(forKey: Keys.includeNotes) as? Bool ?? true
        exportFormat = PresentationExportFormat(rawValue: defaults.string(forKey: Keys.exportFormat) ?? "")
            ?? .both
    }

    private func progress(_ message: String) {
        NSLog("[presentation] %@", message)
        onProgress?(message)
    }

    // MARK: - Branding

    private static var brandingDirectory: String {
        let home = NSHomeDirectory() as NSString
        return home.appendingPathComponent(".alfred/branding")
    }

    /// A custom logo stamped on the title slide when one is set.
    var hasLogo: Bool {
        FileManager.default.fileExists(atPath: Self.brandingDirectory + "/logo.png")
    }

    /// Set the branding logo from an image file. Normalizes to PNG so the
    /// designers can rely on one format. Never throws — a bad file simply
    /// leaves branding unchanged.
    func setLogo(from sourceURL: URL) {
        guard let data = try? Data(contentsOf: sourceURL),
              let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            progress("Branding logo rejected — couldn't read that image.")
            return
        }
        try? FileManager.default.createDirectory(
            atPath: Self.brandingDirectory, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: Self.brandingDirectory + "/logo.png"))
        progress("Branding logo set — future decks will carry it.")
    }

    func clearLogo() {
        try? FileManager.default.removeItem(atPath: Self.brandingDirectory + "/logo.png")
        progress("Branding logo removed.")
    }

    private func logoImagePart() -> PPTXExporter.ImagePart? {
        guard hasLogo, let data = try? Data(contentsOf: URL(fileURLWithPath: Self.brandingDirectory + "/logo.png")) else {
            return nil
        }
        return PPTXExporter.ImagePart(data: data, ext: "png", mime: "image/png")
    }

    private func logoDataURI() -> String? {
        guard let logo = logoImagePart() else { return nil }
        return "data:image/png;base64,\(logo.data.base64EncodedString())"
    }

    // MARK: - Storage

    private static func decksDirectory() -> String {
        let home = NSHomeDirectory() as NSString
        let dir = home.appendingPathComponent(".alfred/presentations")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir as String
    }

    private func deckDirectory(id: UUID) -> String {
        (Self.decksDirectory() as NSString).appendingPathComponent(id.uuidString)
    }

    /// Every deck on disk, newest first.
    func records() -> [PresentationRecord] {
        let dir = Self.decksDirectory()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var found: [PresentationRecord] = []
        for name in names {
            let recordPath = (dir as NSString).appendingPathComponent(name + "/record.json")
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: recordPath)),
                  let record = try? JSONDecoder().decode(PresentationRecord.self, from: data)
            else { continue }
            found.append(record)
        }
        return found.sorted { $0.createdAt > $1.createdAt }
    }

    private func record(id: UUID) -> PresentationRecord? {
        records().first { $0.id == id }
    }

    private func saveRecord(_ record: PresentationRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: URL(fileURLWithPath: record.directory + "/record.json"), options: .atomic)
    }

    private func loadContent(record: PresentationRecord) -> SlideContent? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: record.directory + "/content.json")),
              let content = try? JSONDecoder().decode(SlideContent.self, from: data)
        else { return nil }
        return content
    }

    // MARK: - Create

    /// The full pipeline. `tone` defaults to academic (the skill's home turf);
    /// `style` is a PresentationStyle id or nil (learn it). `includeNotes`
    /// overrides the settings default when set.
    func create(topic: String,
                numSlides: Int? = nil,
                minutes: Int? = nil,
                tone: PresentationTone = .academic,
                style: String? = nil,
                includeNotes: Bool? = nil) async throws -> PresentationRecord {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PresentationError.invalidRequest("Give the deck a topic.")
        }

        var count = numSlides ?? defaultSlides
        if let minutes { count = SlideContent.slideCount(forMinutes: minutes) }
        count = max(3, min(30, count))
        let wantsNotes = includeNotes ?? self.includeNotes
        let format = exportFormat

        // Idempotency: the same request made twice within 10 minutes reuses
        // the deck (a Hermes watchdog retry must not regenerate).
        let key = "\(trimmed)|\(style ?? "")|\(tone.rawValue)|\(count)"
        if let cached = lastCreated, cached.key == key,
           Date().timeIntervalSince(cached.at) < 600 {
            progress("Reusing the deck made \(Int(Date().timeIntervalSince(cached.at)))s ago for the same request.")
            return cached.record
        }

        let resolvedStyle = StyleMatcher.suggestedStyle(
            explicit: style,
            settingsDefault: styleID,
            history: StyleMatcher.shared.history,
            tone: tone)

        progress("Building a \(count)-slide \(tone.displayName) deck on “\(trimmed)” (\(resolvedStyle.displayName)).")

        // 1. Content (research + outline + bullets + notes) — one model turn.
        let content = try await SlideContentGenerator.generate(
            session: session, topic: trimmed, slideCount: count,
            tone: tone, styleName: resolvedStyle.displayName,
            includeNotes: wantsNotes)
        progress("Content ready — \(content.slides.count) slides.")

        // 2. Images for the slides that asked for them (bounded: 4 lookups).
        var htmlImages: [Int: String] = [:]
        var pptxImages: [Int: PPTXExporter.ImagePart] = [:]
        let imageSlides = content.slides.enumerated().compactMap { index, slide -> (Int, String)? in
            guard index > 0, !slide.imageQuery.isEmpty else { return nil }
            return (index, slide.imageQuery)
        }
        let wanted = imageSlides.prefix(4)
        await withTaskGroup(of: (Int, FoundImage?)?.self) { group in
            for (index, query) in wanted {
                group.addTask {
                    let image = await ImageFinder.find(query: query)
                    return image.map { (index, $0) }
                }
            }
            for await outcome in group {
                guard let (index, image) = outcome, let image else { continue }
                pptxImages[index] = PPTXExporter.ImagePart(data: image.data, ext: image.ext, mime: image.mime)
                htmlImages[index] = "data:\(image.mime);base64,\(image.data.base64EncodedString())"
                progress("Image for slide \(index + 1): \(content.slides[index].imageQuery)")
            }
        }

        // 3. Persist the deck (content + media) so follow-on tools can reuse it.
        let id = UUID()
        let dir = deckDirectory(id: id)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var record = PresentationRecord(
            id: id, topic: trimmed, tone: tone.rawValue, style: resolvedStyle.id,
            slideCount: content.slides.count, createdAt: Date().timeIntervalSince1970,
            directory: dir, hasPptx: false, hasPdf: false, hasNotes: false)
        if let data = try? JSONEncoder().encode(content) {
            try? data.write(to: URL(fileURLWithPath: dir + "/content.json"), options: .atomic)
        }
        persistImages(pptxImages, in: dir)
        saveRecord(record)

        // 4. Notes: the content turn already wrote per-slide notes — surface
        //    them as a markdown script the user can present from.
        if wantsNotes {
            writeNotesMarkdown(content: content, dir: dir)
            record.hasNotes = true
        }

        // 5. Export (PDF via HTML+WebKit, PPTX via the OOXML writer).
        let logo = logoImagePart()
        switch format {
        case .both, .pdf:
            let html = DeckHTML.build(content: content, style: resolvedStyle,
                                      images: htmlImages, logoDataURI: logoDataURI())
            try? html.data(using: .utf8)?.write(to: URL(fileURLWithPath: dir + "/slides.html"), options: .atomic)
            do {
                let pdf = try await PDFRenderer.render(html: html)
                try pdf.write(to: URL(fileURLWithPath: dir + "/deck.pdf"), options: .atomic)
                record.hasPdf = true
                progress("PDF rendered.")
            } catch {
                progress("PDF render failed: \(error.localizedDescription)")
            }
        case .pptx:
            break
        }

        switch format {
        case .both, .pptx:
            do {
                let pptx = try PPTXExporter.export(
                    content: content, style: resolvedStyle,
                    images: pptxImages, logo: logo,
                    to: URL(fileURLWithPath: dir))
                record.hasPptx = pptx.lastPathComponent == "deck.pptx"
                progress("PPTX exported.")
            } catch {
                progress("PPTX export failed: \(error.localizedDescription)")
            }
        case .pdf:
            break
        }

        saveRecord(record)
        StyleMatcher.shared.record(topic: trimmed, tone: tone, style: resolvedStyle)
        lastCreated = (key: key, record: record, at: Date())
        progress("Done — \(record.resultText)")
        return record
    }

    // MARK: - Follow-on tools

    /// Refine a deck's speaker notes into a full presenting script (the
    /// add_speaker_notes tool). One extra model turn on the skill's session.
    func addSpeakerNotes(id: UUID) async throws -> String {
        guard let record = record(id: id), let content = loadContent(record: record) else {
            throw PresentationError.notFound("No presentation with that id. Ask Alfred to create one first.")
        }
        let tone = PresentationTone(rawValue: record.tone) ?? .academic
        progress("Writing the presenting script for “\(record.topic)”…")
        let plan = try await SpeakerNotesGenerator.generate(
            session: session, topic: record.topic, tone: tone, content: content)
        let markdown = SpeakerNotesGenerator.markdown(topic: record.topic, content: content, plan: plan)
        try? markdown.data(using: .utf8)?
            .write(to: URL(fileURLWithPath: record.directory + "/speaker_notes.md"), options: .atomic)
        if let data = try? JSONEncoder().encode(plan) {
            try? data.write(to: URL(fileURLWithPath: record.directory + "/notes.json"), options: .atomic)
        }
        var updated = record
        updated.hasNotes = true
        saveRecord(updated)
        progress("Speaker notes written (~\(Int(plan.totalMinutes.rounded())) min script).")
        return record.directory + "/speaker_notes.md"
    }

    /// Re-render an existing deck in a different design style — no new model
    /// turn, the content is reused (the design_presentation tool).
    func redesign(id: UUID, style: String) async throws -> PresentationRecord {
        guard let record = record(id: id), let content = loadContent(record: record) else {
            throw PresentationError.notFound("No presentation with that id. Ask Alfred to create one first.")
        }
        let resolved = PresentationStyle.style(named: style)
        guard resolved.id != record.style else { return record }

        let images = loadImages(in: record.directory)
        let htmlImages = images.mapValues { image in
            "data:\(image.mime);base64,\(image.data.base64EncodedString())"
        }
        let pptxImages = images
        var updated = record
        updated.style = resolved.id

        // Re-render what already exists.
        if record.hasPdf {
            let html = DeckHTML.build(content: content, style: resolved,
                                      images: htmlImages, logoDataURI: logoDataURI())
            try? html.data(using: .utf8)?
                .write(to: URL(fileURLWithPath: record.directory + "/slides.html"), options: .atomic)
            if let pdf = try? await PDFRenderer.render(html: html) {
                try? pdf.write(to: URL(fileURLWithPath: record.directory + "/deck.pdf"), options: .atomic)
                progress("PDF re-rendered in \(resolved.displayName).")
            }
        }
        if record.hasPptx {
            try? PPTXExporter.export(content: content, style: resolved,
                                     images: pptxImages, logo: logoImagePart(),
                                     to: URL(fileURLWithPath: record.directory))
            progress("PPTX re-exported in \(resolved.displayName).")
        }
        saveRecord(updated)
        return updated
    }

    /// Re-export an existing deck in a given format (the export_presentation
    /// tool).
    func export(id: UUID, format: PresentationExportFormat) async throws -> PresentationRecord {
        guard let record = record(id: id), let content = loadContent(record: record) else {
            throw PresentationError.notFound("No presentation with that id. Ask Alfred to create one first.")
        }
        let resolved = PresentationStyle.style(named: record.style)
        let images = loadImages(in: record.directory)
        let htmlImages = images.mapValues { image in
            "data:\(image.mime);base64,\(image.data.base64EncodedString())"
        }
        var updated = record

        switch format {
        case .both, .pdf:
            let html = DeckHTML.build(content: content, style: resolved,
                                      images: htmlImages, logoDataURI: logoDataURI())
            try? html.data(using: .utf8)?
                .write(to: URL(fileURLWithPath: record.directory + "/slides.html"), options: .atomic)
            if let pdf = try? await PDFRenderer.render(html: html) {
                try? pdf.write(to: URL(fileURLWithPath: record.directory + "/deck.pdf"), options: .atomic)
                updated.hasPdf = true
            }
        case .pptx:
            break
        }

        switch format {
        case .both, .pptx:
            if let pptx = try? PPTXExporter.export(content: content, style: resolved,
                                                   images: images, logo: logoImagePart(),
                                                   to: URL(fileURLWithPath: record.directory)) {
                updated.hasPptx = pptx.lastPathComponent == "deck.pptx"
            }
        case .pdf:
            break
        }

        saveRecord(updated)
        progress("Re-exported \(format.displayName).")
        return updated
    }

    /// Tear down the skill's Hermes session. Called at app quit.
    func shutdown() async {
        await session.shutdown()
    }

    // MARK: - Image persistence

    /// Store embedded slide images under the deck's media/ dir so re-exports
    /// (design/export tools) don't need the network again.
    private func persistImages(_ images: [Int: PPTXExporter.ImagePart], in dir: String) {
        guard !images.isEmpty else { return }
        let mediaDir = dir + "/media"
        try? FileManager.default.createDirectory(atPath: mediaDir, withIntermediateDirectories: true)
        var index: [String: String] = [:]
        for (slideIndex, image) in images.sorted(by: { $0.key < $1.key }) {
            let name = "slide\(slideIndex).\(image.ext)"
            try? image.data.write(to: URL(fileURLWithPath: mediaDir + "/" + name))
            index[String(slideIndex)] = name
        }
        if let data = try? JSONSerialization.data(withJSONObject: index) {
            try? data.write(to: URL(fileURLWithPath: dir + "/images.json"), options: .atomic)
        }
    }

    private func loadImages(in dir: String) -> [Int: PPTXExporter.ImagePart] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/images.json")),
              let index = (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
        else { return [:] }
        var images: [Int: PPTXExporter.ImagePart] = [:]
        for (slideKey, name) in index {
            guard let slide = Int(slideKey),
                  let imageData = try? Data(contentsOf: URL(fileURLWithPath: dir + "/media/" + name))
            else { continue }
            let ext = name.hasSuffix(".jpg") ? "jpg" : "png"
            let mime = ext == "jpg" ? "image/jpeg" : "image/png"
            images[slide] = PPTXExporter.ImagePart(data: imageData, ext: ext, mime: mime)
        }
        return images
    }

    private func writeNotesMarkdown(content: SlideContent, dir: String) {
        var lines: [String] = []
        lines.append("# \(content.title)")
        lines.append("")
        lines.append("Speaker notes (from the content pass)")
        lines.append("")
        for (index, slide) in content.slides.enumerated() {
            lines.append("## Slide \(index + 1): \(slide.title)")
            lines.append("")
            lines.append(slide.notes.isEmpty ? "(no notes)" : slide.notes)
            lines.append("")
        }
        let markdown = lines.joined(separator: "\n")
        try? markdown.data(using: .utf8)?
            .write(to: URL(fileURLWithPath: dir + "/speaker_notes.md"), options: .atomic)
    }
}
