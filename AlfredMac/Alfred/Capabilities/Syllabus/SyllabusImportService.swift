import Foundation
import AppKit
import PDFKit

/// Drives the School tab: manage courses (list from the calendar), add a course by importing a
/// syllabus (file → text → LLM → review → create iCloud events + study blocks), and delete a course
/// at semester's end. Owned by the AppDelegate (not the view) so state survives the popover closing
/// while the file panel is open. Uses the same tagging as the cloud bot, so the two never duplicate.
@MainActor
final class SyllabusImportService: ObservableObject {
    enum Phase: Equatable { case list, form, reading, review, creating }

    @Published var phase: Phase = .list
    @Published var courses: [CourseSummary] = []
    @Published var items: [SyllabusItem] = []
    @Published var course: String = ""      // course-code input; becomes the resolved code after extract
    @Published var termYear: Int?
    @Published var banner: String?          // transient success/error line
    @Published var busy = false

    private let router: LLMRouter
    private let calendar = CalendarRemindersCapability()

    init(router: LLMRouter) { self.router = router }

    // MARK: - Course list

    func loadCourses() async {
        busy = true
        courses = (try? await calendar.listSchoolCourses()) ?? []
        busy = false
    }

    func startAdd() {
        items = []; course = ""; termYear = nil; banner = nil; phase = .form
    }

    func cancel() { banner = nil; phase = .list }

    func delete(_ summary: CourseSummary) async {
        busy = true
        do {
            let n = try await calendar.deleteSchoolCourse(code: summary.code)
            banner = "Removed \(summary.display) — \(n) item\(n == 1 ? "" : "s")."
        } catch {
            banner = "Couldn't remove \(summary.display)."
        }
        await loadCourses()
        busy = false
    }

    // MARK: - Import a syllabus

    /// Opens a native file panel (works from the menu-bar popover, unlike SwiftUI .fileImporter).
    func chooseAndLoad() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Read syllabus"
        panel.message = "Choose a syllabus PDF or photo"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await load(url: url)
    }

    private func load(url: URL) async {
        phase = .reading
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let text = await Self.text(from: url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            banner = "That file had no readable text. Try a PDF or a clear photo."; phase = .form; return
        }
        let hint = course.trimmingCharacters(in: .whitespaces)
        guard let extract = await SyllabusExtractor.extract(text: text, courseHint: hint.isEmpty ? nil : hint, now: Date(), router: router) else {
            banner = "Couldn't reach the AI or read the syllabus. Try again."; phase = .form; return
        }
        guard !extract.items.isEmpty else {
            banner = "No dated items found. Make sure the syllabus lists explicit dates."; phase = .form; return
        }
        items = extract.items.sorted { $0.date < $1.date }
        if hint.isEmpty { course = extract.code ?? extract.course ?? "Course" }
        termYear = extract.termYear
        banner = nil
        phase = .review
    }

    func commit() async {
        let chosen = items.filter { $0.include }
        guard !chosen.isEmpty else { banner = "Nothing selected."; return }
        phase = .creating
        let code = course.trimmingCharacters(in: .whitespaces).isEmpty ? "Course" : course.trimmingCharacters(in: .whitespaces)
        let batch = SyllabusKeys.batchId(code, termYear)

        var specs = chosen.map { SyllabusEvents.deadlineSpec($0, code: code, batch: batch) }
        let study = chosen.filter { $0.type == .exam || $0.type == .final || $0.type == .quiz }
            .flatMap { StudyPlanner.sessions(for: $0, code: code, batch: batch, now: Date()) }
        specs += study

        do {
            let r = try await calendar.createSchoolEvents(specs, calendarName: "Personal")
            let s = study.isEmpty ? "" : " + \(study.count) study blocks"
            let f = r.failed > 0 ? " (\(r.failed) failed)" : ""
            banner = "✅ Added \(code): \(r.ok) items\(s)\(f)."
        } catch {
            if case let LLMError.networkError(m) = error { banner = "⚠️ \(m)" }
            else { banner = "⚠️ Couldn't add to your calendar." }
        }
        await loadCourses()
        phase = .list
    }

    // MARK: - File → text

    nonisolated static func text(from url: URL) async -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            // PDFDocument construction + per-page .string extraction is synchronous and CPU-bound;
            // run it off the main actor so importing a syllabus doesn't freeze the menu-bar popover.
            return await Task.detached {
                guard let doc = PDFDocument(url: url) else { return nil }
                var s = ""
                for i in 0..<min(doc.pageCount, 50) {
                    if let page = doc.page(at: i)?.string { s += page + "\n" }
                }
                return s
            }.value
        }
        if ["png", "jpg", "jpeg", "heic", "heif", "tiff", "gif", "bmp"].contains(ext), let data = try? Data(contentsOf: url) {
            return await ScreenOCRCapability.recognizeText(inImageData: data)
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
