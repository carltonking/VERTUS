import AppKit
import Foundation

@MainActor
struct FileAccessCapability {
    func chooseFiles() async -> [URL] {
        await openPanel(
            title: "Choose Files",
            message: "Choose the files Alfred may use for this request.",
            canChooseFiles: true,
            canChooseDirectories: false,
            allowsMultipleSelection: true
        )
    }

    func chooseFolder() async -> URL? {
        await openPanel(
            title: "Choose Folder",
            message: "Choose the folder Alfred may use for this request.",
            canChooseFiles: false,
            canChooseDirectories: true,
            allowsMultipleSelection: false
        ).first
    }

    private func openPanel(
        title: String,
        message: String,
        canChooseFiles: Bool,
        canChooseDirectories: Bool,
        allowsMultipleSelection: Bool
    ) async -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = "Choose"
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canCreateDirectories = false
        panel.resolvesAliases = true

        let response = await panel.begin()
        guard response == .OK else { return [] }
        return panel.urls
    }
}
