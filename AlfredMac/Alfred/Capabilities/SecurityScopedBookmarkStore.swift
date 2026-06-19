import Foundation

struct SecurityScopedBookmarkResolution {
    let urls: [URL]
    let isStale: Bool
}

struct SecurityScopedBookmarkStore {
    private let service = "com.alfred.app"
    private let rememberedFilesAccount = "alfred.remembered.files"
    private let rememberedFolderAccount = "alfred.remembered.folder"

    func rememberFiles(_ urls: [URL]) throws {
        let bookmarks = try urls.map { url in
            try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        try save(bookmarks, account: rememberedFilesAccount)
    }

    func rememberFolder(_ url: URL) throws {
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        try save([bookmark], account: rememberedFolderAccount)
    }

    func resolveFiles() throws -> SecurityScopedBookmarkResolution? {
        try resolve(account: rememberedFilesAccount)
    }

    func resolveFolder() throws -> SecurityScopedBookmarkResolution? {
        try resolve(account: rememberedFolderAccount)
    }

    func forgetFiles() {
        KeychainHelper.delete(service: service, account: rememberedFilesAccount)
    }

    func forgetFolder() {
        KeychainHelper.delete(service: service, account: rememberedFolderAccount)
    }

    var hasRememberedFiles: Bool {
        KeychainHelper.load(service: service, account: rememberedFilesAccount) != nil
    }

    var hasRememberedFolder: Bool {
        KeychainHelper.load(service: service, account: rememberedFolderAccount) != nil
    }

    private func save(_ bookmarks: [Data], account: String) throws {
        let encoded = try PropertyListEncoder().encode(bookmarks)
        KeychainHelper.save(service: service, account: account, value: encoded.base64EncodedString())
    }

    private func resolve(account: String) throws -> SecurityScopedBookmarkResolution? {
        guard let encoded = KeychainHelper.load(service: service, account: account),
              let data = Data(base64Encoded: encoded)
        else { return nil }

        let bookmarks = try PropertyListDecoder().decode([Data].self, from: data)
        var isStale = false
        let urls = try bookmarks.map { bookmark -> URL in
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            isStale = isStale || stale
            return url
        }

        return SecurityScopedBookmarkResolution(urls: urls, isStale: isStale)
    }
}

struct SecurityScopedResourceAccess {
    private let accessedURLs: [URL]

    init(urls: [URL]) {
        accessedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
    }

    func stop() {
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }
}
