import Foundation

// MARK: - File search service

final class FileSearchService: ReadOnlyIntegrationProtocol {
    let actionType: ActionType = .searchFiles

    func performSearch(query: String) async throws -> [IntegrationSearchResult] {
        guard query.count >= 2 else { throw IntegrationError.queryTooShort }

        let raw = try searchFilesSync(query: query)

        guard !raw.isEmpty else { throw IntegrationError.noResults }

        return raw.prefix(50).map { url, modified, size in
            let sizeString = byteCountFormatter.string(fromByteCount: size)
            let dateString = dateFormatter.string(from: modified)
            return IntegrationSearchResult(
                title: url.lastPathComponent,
                subtitle: url.path,
                source: "Files",
                icon: "doc",
                metadata: [
                    "path": url.path,
                    "modified": dateString,
                    "size": sizeString
                ]
            )
        }
    }

    // MARK: - Private

    private func searchFilesSync(query: String) throws -> [(url: URL, modified: Date, size: Int64)] {
        var results: [(url: URL, modified: Date, size: Int64)] = []

        for directory in searchDirectories() {
            guard directory.startAccessingSecurityScopedResource() else { continue }
            defer { directory.stopAccessingSecurityScopedResource() }

            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                // Treat .app/.xcodeproj/.rtfd/.key/.pages bundles as opaque — they can each hold
                // thousands of files. Behavior change: files INSIDE packages become unfindable, which
                // is the right trade for a user-document search.
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard results.count < 50 else { break }

                guard fileURL.lastPathComponent.localizedCaseInsensitiveContains(query) else { continue }

                guard let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let modDate = resourceValues.contentModificationDate
                else { continue }

                let fileSize = resourceValues.fileSize ?? 0
                results.append((url: fileURL, modified: modDate, size: Int64(fileSize)))
            }

            guard results.count < 50 else { break }
        }

        results.sort { $0.modified.timeIntervalSinceReferenceDate > $1.modified.timeIntervalSinceReferenceDate }
        return results
    }

    private func searchDirectories() -> [URL] {
        let fm = FileManager.default
        let dirs: [FileManager.SearchPathDirectory] = [
            .documentDirectory,
            .desktopDirectory,
            .downloadsDirectory
        ]
        return dirs.compactMap { fm.urls(for: $0, in: .userDomainMask).first }
    }

    private let byteCountFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
