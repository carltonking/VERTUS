import AppKit
import Foundation

/// File operations (Blueprint v1 §9 Files automation): organize / gather / move / rename / delete.
///
/// Understands named locations ("desktop", "downloads", "documents") so common requests don't
/// need a manual picker; falls back to NSOpenPanel when the location/file isn't named. Never
/// trusts arbitrary paths from the prompt — only home subfolders or user-picked URLs. Destructive
/// ops confirm first; "delete" moves to Trash (recoverable). Partial failures are reported.
@MainActor
struct FileOperationCapability {

    enum Operation: Equatable {
        case organize
        case gather          // move filtered files into a named folder
        case move
        case delete
        case rename(String)
    }

    enum FileFilter: Equatable {
        case images, documents, videos, audio, pdfs, archives, all
        func matches(_ ext: String) -> Bool {
            let e = ext.lowercased()
            switch self {
            case .images:    return ["jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "tiff", "svg"].contains(e)
            case .documents: return ["pdf", "doc", "docx", "txt", "rtf", "pages", "md", "odt"].contains(e)
            case .videos:    return ["mp4", "mov", "avi", "mkv", "m4v", "webm"].contains(e)
            case .audio:     return ["mp3", "wav", "aac", "flac", "m4a", "aiff"].contains(e)
            case .pdfs:      return e == "pdf"
            case .archives:  return ["zip", "tar", "gz", "rar", "7z", "dmg", "pkg"].contains(e)
            case .all:       return true
            }
        }
    }

    private let access = FileAccessCapability()
    private let fm = FileManager.default

    // MARK: - Detection

    static func detect(in query: String) -> Operation? {
        let q = query.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { q.contains($0) } }
        let fileCtx = has([" file", "files", "folder", "photo", "image", "picture", "screenshot",
                           "video", "pdf", "document", "downloads", "desktop", "directory"])

        // Rename: "rename <file> to <new name>"
        if q.contains("rename"), let toRange = query.range(of: " to ", options: .caseInsensitive) {
            let n = String(query[toRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { return .rename(n) }
        }
        // Gather: "put/move/take <filter> into a folder named X"
        if destinationName(in: query) != nil, has(["put", "move", "take", "gather", "collect", " into "]) {
            return .gather
        }
        if has(["organize", "sort", "tidy", "clean up", "group by"]) && fileCtx { return .organize }
        if has(["move "]) && fileCtx { return .move }
        if has(["delete", "trash"]) && fileCtx { return .delete }
        return nil
    }

    // MARK: - NL parsing

    static func location(in query: String) -> URL? {
        let q = query.lowercased()
        let home = FileManager.default.homeDirectoryForCurrentUser
        if q.contains("desktop") { return home.appendingPathComponent("Desktop") }
        if q.contains("download") { return home.appendingPathComponent("Downloads") }
        if q.contains("document") { return home.appendingPathComponent("Documents") }
        if q.contains("picture") || q.contains("photos folder") { return home.appendingPathComponent("Pictures") }
        if q.contains("movie") || q.contains("videos folder") { return home.appendingPathComponent("Movies") }
        if q.contains("music") { return home.appendingPathComponent("Music") }
        if q.contains("home folder") || q.contains("my home") { return home }
        return nil
    }

    static func filter(in query: String) -> FileFilter {
        let q = query.lowercased()
        if has(q, ["photo", "image", "picture", "screenshot"]) { return .images }
        if has(q, ["video", "movie"]) { return .videos }
        if q.contains("pdf") { return .pdfs }
        if has(q, ["audio", "music", "song"]) { return .audio }
        if has(q, ["archive", "zip"]) { return .archives }
        if q.contains("document") { return .documents }
        return .all
    }

    /// Extracts the destination folder name from "… named/called/titled X [folder]".
    static func destinationName(in query: String) -> String? {
        let lower = query.lowercased()
        for kw in [" named ", " called ", " titled "] {
            guard let r = lower.range(of: kw) else { continue }
            let startOffset = lower.distance(from: lower.startIndex, to: r.upperBound)
            var name = String(query.dropFirst(startOffset)).trimmingCharacters(in: .whitespaces)
            // Stop at sentence punctuation.
            if let cut = name.rangeOf(anyOf: [".", ",", ";", "\n"]) { name = String(name[..<cut]) }
            name = name.trimmingCharacters(in: .whitespaces)
            // Drop a trailing " folder".
            if name.lowercased().hasSuffix(" folder") { name = String(name.dropLast(7)).trimmingCharacters(in: .whitespaces) }
            if !name.isEmpty, isSafeRenameName(name) { return name }
        }
        return nil
    }

    /// A specific filename mentioned in the prompt (e.g. "report.pdf").
    static func namedFile(in query: String) -> String? {
        for raw in query.split(whereSeparator: { " \"'".contains($0) }) {
            let s = String(raw)
            let ext = (s as NSString).pathExtension
            if !s.hasPrefix("."), (1...5).contains(ext.count), isSafeRenameName(s) { return s }
        }
        return nil
    }

    private static func has(_ q: String, _ words: [String]) -> Bool { words.contains { q.contains($0) } }

    // MARK: - Dispatch

    func handle(_ op: Operation, query: String) async -> String {
        switch op {
        case .organize:        return await organize(query: query)
        case .gather:          return await gather(query: query)
        case .move:            return await move()
        case .delete:          return await delete(query: query)
        case .rename(let name): return await rename(to: name)
        }
    }

    // MARK: - Operations

    private func organize(query: String) async -> String {
        let target: URL?
        if let loc = Self.location(in: query) { target = loc } else { target = await access.chooseFolder() }
        guard let folder = target else { return "Organize cancelled." }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let files = childFiles(of: folder)
        guard !files.isEmpty else { return "No files to organize in \(folder.lastPathComponent)." }

        var plan: [String: [URL]] = [:]
        for f in files { plan[Self.category(for: f.pathExtension), default: []].append(f) }
        let summary = plan.map { "\($0.key) (\($0.value.count))" }.sorted().joined(separator: ", ")
        guard Self.confirm(
            title: "Organize \(files.count) files in \(folder.lastPathComponent)?",
            message: "Into subfolders by type — \(summary).") else { return "Organize cancelled." }

        var moved = 0
        var failures: [String] = []
        for (cat, urls) in plan {
            guard let dir = ensureSubfolder(cat, in: folder, failures: &failures) else { continue }
            moved += moveFiles(urls, into: dir, failures: &failures)
        }
        return Self.report("Organized \(moved) file\(moved == 1 ? "" : "s") in \(folder.lastPathComponent): \(summary).", failures: failures)
    }

    private func gather(query: String) async -> String {
        guard let destName = Self.destinationName(in: query) else {
            return "Tell me what to name the folder, e.g. \"…into a folder named Screenshots\"."
        }
        let target: URL?
        if let loc = Self.location(in: query) { target = loc } else { target = await access.chooseFolder() }
        guard let folder = target else { return "Cancelled." }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        let filter = Self.filter(in: query)
        let files = childFiles(of: folder).filter { filter.matches($0.pathExtension) }
        guard !files.isEmpty else {
            return "No matching files found in \(folder.lastPathComponent)."
        }
        guard Self.confirm(
            title: "Move \(files.count) file\(files.count == 1 ? "" : "s") into “\(destName)”?",
            message: "From \(folder.lastPathComponent) into a new folder “\(destName)”.") else { return "Cancelled." }

        var failures: [String] = []
        guard let destDir = ensureSubfolder(destName, in: folder, failures: &failures) else {
            return failures.first ?? "Couldn't create \(destName)."
        }
        let moved = moveFiles(files, into: destDir, failures: &failures)
        return Self.report("Moved \(moved) file\(moved == 1 ? "" : "s") into “\(destName)” in \(folder.lastPathComponent).", failures: failures)
    }

    private func move() async -> String {
        let files = await access.chooseFiles()
        guard !files.isEmpty else { return "Move cancelled." }
        guard let dest = await access.chooseFolder() else { return "Move cancelled." }
        let scoped = dest.startAccessingSecurityScopedResource()
        defer { if scoped { dest.stopAccessingSecurityScopedResource() } }
        guard Self.confirm(
            title: "Move \(files.count) file\(files.count == 1 ? "" : "s")?",
            message: "To \(dest.lastPathComponent).") else { return "Move cancelled." }
        var failures: [String] = []
        let moved = moveFiles(files, into: dest, failures: &failures)
        return Self.report("Moved \(moved) of \(files.count) file\(files.count == 1 ? "" : "s") to \(dest.lastPathComponent).", failures: failures)
    }

    private func delete(query: String) async -> String {
        // If a specific file + location are named, resolve it directly (no picker).
        if let name = Self.namedFile(in: query), let loc = Self.location(in: query) {
            let scoped = loc.startAccessingSecurityScopedResource()
            defer { if scoped { loc.stopAccessingSecurityScopedResource() } }
            let url = loc.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else {
                return "Couldn't find \(name) in \(loc.lastPathComponent)."
            }
            guard Self.confirm(title: "Move \(name) to Trash?", message: name, destructive: true)
            else { return "Delete cancelled." }
            do { try fm.trashItem(at: url, resultingItemURL: nil); return "Moved \(name) to Trash." }
            catch { return "Couldn't trash \(name): \(error.localizedDescription)" }
        }

        let files = await access.chooseFiles()
        guard !files.isEmpty else { return "Delete cancelled." }
        guard Self.confirm(
            title: "Move \(files.count) file\(files.count == 1 ? "" : "s") to Trash?",
            message: files.map { $0.lastPathComponent }.joined(separator: ", "),
            destructive: true) else { return "Delete cancelled." }
        var trashed = 0
        var failures: [String] = []
        for f in files {
            do { try fm.trashItem(at: f, resultingItemURL: nil); trashed += 1 }
            catch { failures.append("\(f.lastPathComponent): \(error.localizedDescription)") }
        }
        return Self.report("Moved \(trashed) of \(files.count) file\(files.count == 1 ? "" : "s") to Trash.", failures: failures)
    }

    private func rename(to newName: String) async -> String {
        guard Self.isSafeRenameName(newName) else { return "Invalid name — no path separators allowed." }
        let files = await access.chooseFiles()
        guard let f = files.first else { return "Rename cancelled." }
        var finalName = newName
        if (newName as NSString).pathExtension.isEmpty, !f.pathExtension.isEmpty {
            finalName += "." + f.pathExtension
        }
        let dest = f.deletingLastPathComponent().appendingPathComponent(finalName)
        guard !fm.fileExists(atPath: dest.path) else {
            return "A file named \(finalName) already exists — rename cancelled."
        }
        guard Self.confirm(title: "Rename file?", message: "\(f.lastPathComponent) → \(finalName)")
        else { return "Rename cancelled." }
        do { try fm.moveItem(at: f, to: dest); return "Renamed to \(finalName)." }
        catch { return "Rename failed: \(error.localizedDescription)" }
    }

    // MARK: - Shared helpers

    private func childFiles(of folder: URL) -> [URL] {
        let contents = (try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return contents.filter {
            ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) == false
        }
    }

    /// Creates `name` under `folder`, returning nil (and appending a failure) if a file already
    /// occupies that name or creation fails.
    private func ensureSubfolder(_ name: String, in folder: URL, failures: inout [String]) -> URL? {
        let dir = folder.appendingPathComponent(name, isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir.path, isDirectory: &isDir), !isDir.boolValue {
            failures.append("\(name): a file with that name already exists")
            return nil
        }
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true); return dir }
        catch { failures.append("\(name): \(error.localizedDescription)"); return nil }
    }

    private func moveFiles(_ files: [URL], into dir: URL, failures: inout [String]) -> Int {
        var moved = 0
        for f in files {
            let dest = Self.uniqueDestination(dir.appendingPathComponent(f.lastPathComponent), fm: fm)
            do { try fm.moveItem(at: f, to: dest); moved += 1 }
            catch { failures.append("\(f.lastPathComponent): \(error.localizedDescription)") }
        }
        return moved
    }

    static func isSafeRenameName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
    }

    private static func report(_ base: String, failures: [String]) -> String {
        guard !failures.isEmpty else { return base }
        let shown = failures.prefix(5).joined(separator: "; ")
        let more = failures.count > 5 ? " (+\(failures.count - 5) more)" : ""
        return "\(base)\n\(failures.count) failed: \(shown)\(more)"
    }

    static func category(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "tiff", "svg": return "Images"
        case "pdf", "doc", "docx", "txt", "rtf", "pages", "md", "odt": return "Documents"
        case "xls", "xlsx", "csv", "numbers": return "Spreadsheets"
        case "ppt", "pptx", "key": return "Presentations"
        case "mp3", "wav", "aac", "flac", "m4a", "aiff": return "Audio"
        case "mp4", "mov", "avi", "mkv", "m4v", "webm": return "Video"
        case "zip", "tar", "gz", "rar", "7z", "dmg", "pkg": return "Archives"
        case "swift", "js", "ts", "py", "java", "c", "cpp", "h", "html", "css", "json", "sh", "rb", "go", "rs": return "Code"
        default: return "Other"
        }
    }

    static func uniqueDestination(_ url: URL, fm: FileManager) -> URL {
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while i < 10000 {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
        let unique = ext.isEmpty ? "\(base) \(UUID().uuidString)" : "\(base) \(UUID().uuidString).\(ext)"
        return dir.appendingPathComponent(unique)
    }

    static func confirm(title: String, message: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = destructive ? .warning : .informational
        alert.addButton(withTitle: destructive ? "Move to Trash" : "Proceed")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private extension String {
    /// First index of any of the given single-character strings.
    func rangeOf(anyOf chars: [String]) -> String.Index? {
        var best: String.Index?
        for c in chars {
            if let r = range(of: c), best == nil || r.lowerBound < best! { best = r.lowerBound }
        }
        return best
    }
}
