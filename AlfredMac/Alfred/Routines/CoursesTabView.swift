import SwiftUI
import UniformTypeIdentifiers

/// The "School" tab: upload a syllabus → review the extracted items → add them (with reminders +
/// study blocks) to the iCloud calendar. Mirrors the Telegram /syllabus flow but with a review step.
struct CoursesTabView: View {
    @StateObject private var svc: SyllabusImportService
    @State private var showImporter = false
    @State private var courseHint = ""

    init(router: LLMRouter) {
        _svc = StateObject(wrappedValue: SyllabusImportService(router: router))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch svc.phase {
                case .idle, .error: intro
                case .reading: loading("Reading your syllabus…")
                case .review: reviewList
                case .creating: loading("Adding to your calendar…")
                case .done(let msg): doneView(msg)
                }
                if case let .error(msg) = svc.phase {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .image, .plainText], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task { await svc.load(url: url, courseHint: courseHint) }
            }
        }
    }

    private func loading(_ label: String) -> some View {
        HStack(spacing: 8) { ProgressView(); Text(label).font(.system(size: 12)).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a course").font(.system(size: 15, weight: .semibold))
            Text("Upload a syllabus (PDF or photo). Alfred pulls out every assignment, quiz, exam and final, adds them to your calendar with reminders, and schedules study sessions before each exam.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Course code (e.g. CS 101)", text: $courseHint).textFieldStyle(.roundedBorder)
            Button { showImporter = true } label: {
                Label("Choose syllabus…", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(courseHint.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("Tip: a PDF reads more accurately than a photo. Everything lands on your Personal calendar and syncs to your iPhone.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var reviewList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(svc.course) — review").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(svc.items.filter { $0.include }.count)/\(svc.items.count)").font(.caption).foregroundStyle(.secondary)
            }
            Text("Uncheck anything wrong, then add. Exams & finals also get study blocks.")
                .font(.caption2).foregroundStyle(.secondary)

            ForEach($svc.items) { $item in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: $item.include).labelsHidden().toggleStyle(.checkbox)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(item.type.emoji) \(item.title)").font(.system(size: 12, weight: .medium))
                        Text(subtitle(item)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            HStack {
                Button("Cancel") { svc.reset() }
                Spacer()
                Button { Task { await svc.commit() } } label: { Text("Add to calendar") }
                    .buttonStyle(.borderedProminent)
                    .disabled(svc.items.allSatisfy { !$0.include })
            }
            .padding(.top, 4)
        }
    }

    private func doneView(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
            Text("Reminders are set on your iPhone. Re-upload anytime to update.").font(.caption2).foregroundStyle(.secondary)
            Button("Add another course") { svc.reset() }.buttonStyle(.bordered)
        }
    }

    private func subtitle(_ item: SyllabusItem) -> String {
        var s = prettyDate(item.date)
        if !item.allDay, let t = item.start { s += " · \(t)" }
        if let w = item.weight { s += " · \(w)" }
        return s
    }
    private func prettyDate(_ d: String) -> String {
        let p = d.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return d }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[max(0, min(11, p[1] - 1))]) \(p[2]), \(p[0])"
    }
}
