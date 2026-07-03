import SwiftUI

/// The "School" tab: manage courses. List the courses currently on your calendar, add a new one by
/// importing a syllabus (review before adding), and delete a course when the semester ends.
struct CoursesTabView: View {
    @ObservedObject var service: SyllabusImportService
    @State private var confirmingDelete: CourseSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch service.phase {
                case .list: courseList
                case .form: addForm
                case .reading: loading("Reading your syllabus…")
                case .creating: loading("Adding to your calendar…")
                case .review: reviewList
                }
                if let banner = service.banner {
                    Text(banner).font(.caption)
                        .foregroundStyle(banner.hasPrefix("⚠️") ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await service.loadCourses() }
    }

    // MARK: - Course list

    private var courseList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Courses").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { service.startAdd() } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }

            if service.courses.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No courses yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Tap Add and choose a syllabus (PDF or photo). Alfred adds every assignment, quiz, exam and final to your calendar with reminders, plus study blocks before each exam.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 4)
            } else {
                ForEach(service.courses) { c in
                    HStack {
                        Image(systemName: "book.closed.fill").foregroundStyle(.tint).font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.display).font(.system(size: 13, weight: .medium))
                            Text("\(c.count) item\(c.count == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { confirmingDelete = c } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Remove \(c.display) from your calendar")
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
                Text("Deleting a course removes its assignments, exams and study blocks from your calendar.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
            }
        }
        .confirmationDialog("Remove \(confirmingDelete?.display ?? "")?",
                            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Remove from calendar", role: .destructive) {
                if let c = confirmingDelete { Task { await service.delete(c) } }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text("This deletes all of \(confirmingDelete?.display ?? "")'s events and study blocks.")
        }
    }

    // MARK: - Add form

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { service.cancel() } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Text("Add a course").font(.system(size: 15, weight: .semibold))
            }
            TextField("Course code (e.g. CS 101)", text: $service.course).textFieldStyle(.roundedBorder)
            Button { Task { await service.chooseAndLoad() } } label: {
                Label("Choose syllabus…", systemImage: "doc.badge.plus")
            }.buttonStyle(.borderedProminent)
            Text("PDF or photo. Leave the code blank to let Alfred read it from the syllabus. A PDF reads more accurately than a photo.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Review

    private var reviewList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(service.course.isEmpty ? "Review" : service.course) — review").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(service.items.filter { $0.include }.count)/\(service.items.count)").font(.caption).foregroundStyle(.secondary)
            }
            TextField("Course code", text: $service.course).textFieldStyle(.roundedBorder).controlSize(.small)
            Text("Uncheck anything wrong, then add. Exams & finals also get study blocks.")
                .font(.caption2).foregroundStyle(.secondary)

            ForEach($service.items) { $item in
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
                Button("Cancel") { service.cancel() }
                Spacer()
                Button { Task { await service.commit() } } label: { Text("Add to calendar") }
                    .buttonStyle(.borderedProminent)
                    .disabled(service.items.allSatisfy { !$0.include })
            }.padding(.top, 4)
        }
    }

    // MARK: - Helpers

    private func loading(_ label: String) -> some View {
        HStack(spacing: 8) { ProgressView(); Text(label).font(.system(size: 12)).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
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
