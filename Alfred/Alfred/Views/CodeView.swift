//
//  CodeView.swift
//  Alfred
//
//  The Code tab: AlfredCode — remote agentic coding on the Mac, steered from
//  the phone. Lists every coding session, starts new ones against a project
//  folder, and hands off to CodeSessionView for the live view.
//
//  Everything goes over the WebSocket as JSON-RPC — code.sessions /
//  code.start_session — and the Mac pushes code.chunk / code.status /
//  code.test_result / code.git_status notifications that keep the open
//  session view live while it's on screen.
//

import SwiftUI

struct CodeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    private var socket: AlfredWebSocketClient { .shared }

    @State private var sessions: [CodeSessionSummary] = []
    @State private var loading = false
    @State private var showNewSession = false
    @State private var openSession: CodeSessionSummary?

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background
                content
            }
            .navigationTitle("Code")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNewSession = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(palette.accentBright)
                    }
                    .disabled(!settings.isConfigured)
                    .accessibilityLabel("Start a coding session")
                }
            }
        }
        .sheet(isPresented: $showNewSession) {
            NewCodeSessionSheet { session in
                showNewSession = false
                openSession = session
            }
        }
        .navigationDestination(item: $openSession) { session in
            CodeSessionView(session: session)
        }
        .task { await reload() }
        .task { await observeCodeEvents() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            notConnected
        } else if sessions.isEmpty && !loading {
            emptyState
        } else {
            sessionList
        }
    }

    private var notConnected: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(palette.textFaint)
            Text("Not connected")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .padding(.top, 16)
            Text("AlfredCode runs on your Mac. Connect in Settings and your coding sessions will show up here.")
                .font(.system(size: 15))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [palette.accentSoft, palette.accent],
                        startPoint: .top, endPoint: .bottom))
            Text("No coding sessions yet")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .padding(.top, 16)
            Text("Tell Alfred what to build and which project folder to work in — his coding agent does the rest, streaming here live.")
                .font(.system(size: 15))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 40)
            Button {
                showNewSession = true
            } label: {
                Text("Start a session")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.backgroundTop)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(palette.accentBright)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 22)
            Spacer()
            Spacer()
        }
    }

    private var sessionList: some View {
        List {
            Section("Sessions") {
                ForEach(sessions) { session in
                    sessionRow(session)
                        .contentShape(Rectangle())
                        .onTapGesture { openSession = session }
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onDelete { offsets in
                    let toDelete = offsets.map { sessions[$0] }
                    Task {
                        for session in toDelete {
                            _ = await socket.deleteCodeSession(id: session.id)
                        }
                        await reload()
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await reload() }
    }

    private func sessionRow(_ session: CodeSessionSummary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.prompt)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                }
                Text(session.projectPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    statusBadge(session.status)
                    Text(session.projectType.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textFaint)
                }
            }
            Spacer(minLength: 0)
            if session.status.isActive {
                ProgressView()
                    .tint(palette.accentBright)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textFaint)
            }
        }
        .padding(14)
        .background(palette.surface.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.surfaceBorder, lineWidth: 1))
    }

    private func statusBadge(_ status: CodeSessionStatus) -> some View {
        Text(status.displayName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(status.isError ? palette.danger : palette.accentBright)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background((status.isError ? palette.danger : palette.accent).opacity(0.14))
            .clipShape(Capsule())
    }

    // MARK: - Live updates

    private func reload() async {
        guard settings.isConfigured else { return }
        loading = true
        defer { loading = false }
        sessions = await socket.listCodeSessions()
    }

    /// Keep the list in sync while a session streams in the background: status
    /// flips (and the swipe-delete list) should reflect the live Mac, not a
    /// stale snapshot. The open session view consumes its own stream; here we
    /// only refresh statuses cheaply.
    private func observeCodeEvents() async {
        for await update in socket.updates() {
            switch update {
            case .codeSessionStatus(let id, _):
                await reload()
            case .codeChunk(let id, _):
                // A chunk means generating — refresh so the row shows the
                // spinner without waiting for a status flip.
                if let index = sessions.firstIndex(where: { $0.sessionId.uuidString == id }),
                   sessions[index].status != .generating {
                    sessions[index].status = .generating
                }
            case .codeTestResult, .codeGitStatus:
                await reload()
            default:
                break
            }
        }
    }
}

// MARK: - New session sheet

/// Step through what a session needs: the request, the project folder (from
/// the Mac's own scan of candidate projects, or typed by hand), and which
/// agent to run. "Start" calls code.start_session and hands the result back.
private struct NewCodeSessionSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    private var socket: AlfredWebSocketClient { .shared }

    let onStarted: (CodeSessionSummary) -> Void

    @State private var prompt = ""
    @State private var projects: [CodeProjectPayload] = []
    @State private var loadingProjects = false
    @State private var manualPath = ""
    @State private var agent: CodeAgentChoice = .opencode
    @State private var starting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background
                form
            }
            .navigationTitle("New coding session")
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

    private var form: some View {
        Form {
            Section("What should he build?") {
                TextField("e.g. Add error handling to the API endpoint", text: $prompt, axis: .vertical)
                    .lineLimit(3...6)
                    .foregroundStyle(palette.textPrimary)
            }

            Section("Project folder") {
                if loadingProjects {
                    HStack(spacing: 8) {
                        ProgressView().tint(palette.accentBright)
                        Text("Scanning your Mac…")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textSecondary)
                    }
                } else if !projects.isEmpty {
                    ForEach(projects.prefix(6)) { project in
                        Button {
                            manualPath = project.path
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: projectTypeIcon(project.type))
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.accentBright)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(palette.textPrimary)
                                    Text(project.path)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(palette.textFaint)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if manualPath == project.path {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(palette.accentBright)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                TextField("or type a path on the Mac (~/Projects/app)", text: $manualPath)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(palette.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Agent") {
                ForEach(CodeAgentChoice.allCases) { choice in
                    Button {
                        agent = choice
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.displayName)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(palette.textPrimary)
                                Text(choice.blurb)
                                    .font(.system(size: 12))
                                    .foregroundStyle(palette.textSecondary)
                            }
                            Spacer(minLength: 0)
                            if agent == choice {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(palette.accentBright)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.danger)
                }
            }

            Section {
                Button {
                    start()
                } label: {
                    HStack(spacing: 8) {
                        if starting {
                            ProgressView().tint(palette.backgroundTop)
                        }
                        Text(starting ? "Starting…" : "Start session")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(palette.backgroundTop)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canStart || starting)
                .listRowBackground(palette.accentBright.opacity(canStart ? 1 : 0.35))
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }

    private var canStart: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !manualPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !starting
    }

    private func projectTypeIcon(_ type: CodeProjectType) -> String {
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

    private func loadProjects() async {
        guard settings.isConfigured else { return }
        loadingProjects = true
        defer { loadingProjects = false }
        projects = await socket.listCodeProjects()
    }

    private func start() {
        guard canStart else { return }
        starting = true
        errorMessage = nil
        Task {
            guard let session = await socket.startCodeSession(
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                projectPath: manualPath.trimmingCharacters(in: .whitespacesAndNewlines),
                agent: agent.rawValue) else {
                starting = false
                errorMessage = "The Mac couldn't start that session. Check the folder path and that the agent is installed."
                return
            }
            onStarted(session)
        }
    }
}
