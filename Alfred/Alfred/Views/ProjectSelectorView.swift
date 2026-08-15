//
//  ProjectSelectorView.swift
//  Alfred
//
//  The folder picker for the Code tab's composer. Three ways in, matching how
//  people actually think about it:
//
//    1. "From your Mac" — AlfredCode's own scan (code.projects): real project
//       folders with their detected type.
//    2. "Common folders" — the usual dev roots, as `~/` shorthands the Mac
//       resolves (the phone never knows the Mac's home directory).
//    3. "Custom path" — type anything; the Mac will try to use it verbatim.
//
//  Picking a folder stores it in AppSettings.selectedProjectPath so the
//  composer remembers it across launches, then dismisses.
//

import SwiftUI

struct ProjectSelectorView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    private var socket: AlfredWebSocketClient { .shared }

    @State private var projects: [CodeProjectPayload] = []
    @State private var loadingProjects = false
    @State private var manualPath = ""

    /// Dev roots offered alongside the Mac's scan. `~/` is intentional — the
    /// Mac expands it against its own home; these are also the shorthands
    /// people type in the custom field.
    private static let devRoots = ["~/Projects", "~/Developer", "~/Desktop", "~/Documents", "~/Downloads"]

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background
                list
            }
            .navigationTitle("Select project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(palette.textSecondary)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await loadProjects() }
    }

    // MARK: - List

    private var list: some View {
        List {
            Section {
                if loadingProjects {
                    HStack(spacing: 10) {
                        ProgressView().tint(palette.accentBright)
                        Text("Scanning your Mac…")
                            .font(.system(size: 14))
                            .foregroundStyle(palette.textSecondary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if projects.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No projects found on the Mac")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                        Text("Create a folder there and open this again to rescan — or pick one of the common folders below.")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textSecondary)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(projects) { project in
                        projectRow(
                            title: project.name,
                            path: project.path,
                            icon: typeIcon(project.type))
                    }
                }
            } header: {
                Text("From your Mac")
            }
            .listRowBackground(Color.clear)

            Section("Common folders") {
                ForEach(Self.devRoots, id: \.self) { root in
                    projectRow(
                        title: root,
                        path: root,
                        icon: "folder")
                }
            }
            .listRowBackground(Color.clear)

            Section("Custom path") {
                TextField("e.g. ~/Downloads/my-app", text: $manualPath)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(palette.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { useManualPath() }
                if !manualPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        useManualPath()
                    } label: {
                        Text("Use \"\\(manualPath.trimmingCharacters(in: .whitespacesAndNewlines))\"")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.accentBright)
                    }
                }
            }
            .listRowBackground(Color.clear)

            if !settings.selectedProjectPath.isEmpty {
                Section {
                    Button {
                        settings.selectedProjectPath = ""
                        dismiss()
                    } label: {
                        Text("Clear selection")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(palette.danger)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Row

    private func projectRow(title: String, path: String, icon: String) -> some View {
        Button {
            settings.selectedProjectPath = path
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.accentBright)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected(path) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.accentBright)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Highlights the currently-stored project — exact string match, since the
    /// stored path is always whatever the user (or the Mac's scan) supplied.
    private func isSelected(_ path: String) -> Bool {
        settings.selectedProjectPath == path
    }

    private func useManualPath() {
        let path = manualPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        settings.selectedProjectPath = path
        dismiss()
    }

    private func typeIcon(_ type: CodeProjectType) -> String {
        switch type {
        case .node: return "server.rack"
        case .python: return "snake"
        case .swift: return "swift"
        case .rust: return "gearshape.2"
        case .go: return "g.circle"
        case .ruby: return "gem"
        case .java: return "cup.and.saucer"
        case .other: return "folder"
        }
    }

    // MARK: - Data

    private func loadProjects() async {
        guard settings.socketURL != nil || AlfredWebSocketClient.shared.isConnected else { return }
        loadingProjects = true
        defer { loadingProjects = false }
        projects = await socket.listCodeProjects()
        NSLog("[code] project picker — %d projects from Mac", projects.count)
    }
}
