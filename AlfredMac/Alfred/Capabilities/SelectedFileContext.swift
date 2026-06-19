import Foundation

struct SelectedFileSnapshot: Sendable {
    let fileURLs: [URL]
    let folderURL: URL?
    let usesRememberedFileAccess: Bool
    let usesRememberedFolderAccess: Bool

    static let empty = SelectedFileSnapshot(
        fileURLs: [],
        folderURL: nil,
        usesRememberedFileAccess: false,
        usesRememberedFolderAccess: false
    )

    var isEmpty: Bool {
        fileURLs.isEmpty && folderURL == nil
    }

    var securityScopedURLs: [URL] {
        var urls: [URL] = []
        if usesRememberedFileAccess {
            urls.append(contentsOf: fileURLs)
        }
        if usesRememberedFolderAccess, let folderURL {
            urls.append(folderURL)
        }
        return urls
    }
}

@MainActor
final class SelectedFileContext {
    private(set) var fileURLs: [URL] = []
    private(set) var folderURL: URL?
    private(set) var usesRememberedFileAccess = false
    private(set) var usesRememberedFolderAccess = false

    var isEmpty: Bool {
        fileURLs.isEmpty && folderURL == nil
    }

    func selectFiles(_ urls: [URL], remembered: Bool = false) {
        fileURLs = urls
        folderURL = nil
        usesRememberedFileAccess = remembered
        usesRememberedFolderAccess = false
    }

    func selectFolder(_ url: URL, remembered: Bool = false) {
        fileURLs = []
        folderURL = url
        usesRememberedFileAccess = false
        usesRememberedFolderAccess = remembered
    }

    func clear() {
        fileURLs = []
        folderURL = nil
        usesRememberedFileAccess = false
        usesRememberedFolderAccess = false
    }

    func restoreRemembered(fileURLs: [URL], folderURL: URL?) {
        self.fileURLs = fileURLs
        self.folderURL = folderURL
        usesRememberedFileAccess = !fileURLs.isEmpty
        usesRememberedFolderAccess = folderURL != nil
    }

    func snapshot() -> SelectedFileSnapshot {
        SelectedFileSnapshot(
            fileURLs: fileURLs,
            folderURL: folderURL,
            usesRememberedFileAccess: usesRememberedFileAccess,
            usesRememberedFolderAccess: usesRememberedFolderAccess
        )
    }
}
