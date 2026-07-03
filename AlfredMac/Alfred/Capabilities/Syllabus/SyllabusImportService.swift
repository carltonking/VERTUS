import Foundation
import PDFKit

/// Drives the Courses tab: pick a syllabus file → extract text → LLM → review list → create iCloud
/// events (+ study blocks). Uses the same tagging as the cloud bot so the two never duplicate.
@MainActor
final class SyllabusImportService: ObservableObject {
    enum Phase: Equatable {
        case idle, reading, review, creating
        case done(String)
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var items: [SyllabusItem] = []
    @Published var course: String = ""
    @Published var termYear: Int?

    private let router: LLMRouter
    private let calendar = CalendarRemindersCapability()

    init(router: LLMRouter) { self.router = router }

    /// Step 1 — read a picked file, extract, and populate the review list.
    func load(url: URL, courseHint: String) async {
        phase = .reading
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let text = await Self.text(from: url), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .error("That file had no readable text. If it's a scanned PDF, try a clear photo instead.")
            return
        }
        let hint = courseHint.trimmingCharacters(in: .whitespaces)
        guard let extract = await SyllabusExtractor.extract(text: text, courseHint: hint.isEmpty ? nil : hint, now: Date(), router: router) else {
            phase = .error("Couldn't reach the AI or parse the syllabus. Try again in a moment.")
            return
        }
        guard !extract.items.isEmpty else {
            phase = .error("No dated items found. Make sure the syllabus lists explicit assignment/exam dates.")
            return
        }
        items = extract.items.sorted { $0.date < $1.date }
        course = hint.isEmpty ? (extract.code ?? extract.course ?? "Course") : hint
        termYear = extract.termYear
        phase = .review
    }

    /// Step 2 — create the checked items (+ study blocks) on the iCloud calendar.
    func commit() async {
        let chosen = items.filter { $0.include }
        guard !chosen.isEmpty else { phase = .error("Nothing selected."); return }
        phase = .creating
        let code = course.trimmingCharacters(in: .whitespaces).isEmpty ? "Course" : course.trimmingCharacters(in: .whitespaces)
        let batch = SyllabusKeys.batchId(code, termYear)

        var specs = chosen.map { SyllabusEvents.deadlineSpec($0, code: code, batch: batch) }
        let studySpecs = chosen
            .filter { $0.type == .exam || $0.type == .final || $0.type == .quiz }
            .flatMap { StudyPlanner.sessions(for: $0, code: code, batch: batch, now: Date()) }
        specs += studySpecs

        do {
            let r = try await calendar.createSchoolEvents(specs, calendarName: "Personal")
            let study = studySpecs.isEmpty ? "" : ", incl. \(studySpecs.count) study blocks"
            let failed = r.failed > 0 ? " (\(r.failed) failed)" : ""
            phase = .done("Added \(r.ok) items to your Personal calendar\(study)\(failed).")
        } catch {
            if case let LLMError.networkError(m) = error { phase = .error(m) }
            else { phase = .error("Couldn't add to your calendar. \(error.localizedDescription)") }
        }
    }

    func reset() {
        items = []; course = ""; termYear = nil; phase = .idle
    }

    /// Delete everything for a course code (mirrors the cloud's /school delete).
    func deleteCourse(_ code: String) async {
        do {
            let n = try await calendar.deleteSchoolCourse(code: code)
            phase = .done(n > 0 ? "Removed \(n) \(code) items." : "No \(code) items found.")
        } catch {
            phase = .error("Couldn't remove those items.")
        }
    }

    // MARK: - File → text

    static func text(from url: URL) async -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else { return nil }
            var s = ""
            for i in 0..<min(doc.pageCount, 50) where doc.page(at: i)?.string != nil {
                s += (doc.page(at: i)?.string ?? "") + "\n"
            }
            return s
        }
        if ["png", "jpg", "jpeg", "heic", "heif", "tiff", "gif", "bmp"].contains(ext), let data = try? Data(contentsOf: url) {
            return await ScreenOCRCapability.recognizeText(inImageData: data)
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
