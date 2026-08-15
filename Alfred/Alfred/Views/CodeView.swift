//
//  CodeView.swift
//  Alfred
//
//  The Code tab: AlfredCode, prompt-first. It opens on a composer, not a list —
//  pick the project folder, type (or dictate) what you want built, and send.
//  The agent starts on the Mac and streams back into CodeSessionView live.
//
//  Layout, top to bottom:
//
//    📁 Select Project           — tap for ProjectSelectorView
//    /Users/carlton/…/myapp      — the chosen folder, remembered across launches
//
//    What do you want me to code?   ← growing text field
//    [mic]                 [send ↑]
//    Fix bugs · Add feature · Refactor · Write tests   ← quick chips
//
//    Recent in this project  ▾    ← collapsible, last 5 in the chosen folder
//      • Refactored auth (2h ago) — tap to reopen, swipe to delete
//
//  Everything goes over the WebSocket as JSON-RPC (code.start_session,
//  code.sessions); the Mac pushes code.chunk / code.status / code.test_result
//  notifications that keep the recent list and the open session view live.
//

import SwiftUI
import Speech
import AVFoundation
import UIKit

struct CodeView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.palette) private var palette

    private var socket: AlfredWebSocketClient { .shared }

    @State private var sessions: [CodeSessionSummary] = []
    @State private var prompt = ""
    @State private var dictationBase = ""
    @State private var dictationError: String?
    @State private var dictation = CodeDictationController()
    @FocusState private var inputFocused: Bool

    @State private var showProjectPicker = false
    @State private var starting = false
    @State private var startError: String?
    @State private var openSession: CodeSessionSummary?
    @State private var sessionPendingDelete: CodeSessionSummary?
    @State private var showRecent = true
    /// True once the Mac has answered a fetch — the recent list only shows the
    /// empty state after a real answer, not during the first (slow) connect.
    @State private var hasLoaded = false

    /// CodeGraph: the graph status line on the project card, and the search
    /// sheet over the project's graph.
    @State private var graphStatus: CodeGraphStatusPayload?
    @State private var showGraphSearch = false
    @State private var graphQuery = ""
    @State private var graphResults: String?
    @State private var graphSearching = false

    /// Understand-Anything: the interactive knowledge graph sheet — search,
    /// impact, trace, and a clickable graph over the same project.
    @State private var understandStatus: UnderstandStatusPayload?
    @State private var showUnderstandGraph = false

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
        }
        .sheet(isPresented: $showProjectPicker) {
            ProjectSelectorView()
        }
        .sheet(isPresented: $showGraphSearch) {
            GraphSearchView(
                projectPath: settings.selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines),
                socket: socket,
                palette: palette)
        }
        .sheet(isPresented: $showUnderstandGraph) {
            KnowledgeGraphView(
                projectPath: settings.selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .navigationDestination(item: $openSession) { session in
            CodeSessionView(session: session)
        }
        .confirmationDialog(
            "Delete this session? Everything it produced is removed from Alfred.",
            isPresented: Binding(
                get: { sessionPendingDelete != nil },
                set: { if !$0 { sessionPendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: sessionPendingDelete) { session in
                Button("Delete", role: .destructive) {
                    Task {
                        _ = await socket.deleteCodeSession(id: session.id)
                        await reload()
                    }
                }
                Button("Cancel", role: .cancel) { sessionPendingDelete = nil }
            }
        .task { await reload() }
        .task { await observeCodeEvents() }
        .onChange(of: settings.codeSessionsEnabled) { _, enabled in
            // Re-enabling shows the Mac's current list, not the snapshot from
            // whenever the tab last fetched.
            if enabled { Task { await reload() } }
        }
        .onChange(of: socket.state) { _, state in
            // The socket can land after this tab's first fetch (discovery is
            // async), and RootView keeps tabs alive so .task won't re-run on a
            // tab switch. Once the link is up, pull the real list.
            if state == .connected {
                Task { await reload() }
                Task { await refreshGraphStatus() }
                Task { await refreshUnderstandStatus() }
            }
        }
        .onChange(of: settings.selectedProjectPath) { _, _ in
            // A new project means a new graph (or none yet) — re-ask the Mac.
            graphStatus = nil
            understandStatus = nil
            Task { await refreshGraphStatus() }
            Task { await refreshUnderstandStatus() }
        }
        .task { await refreshGraphStatus() }
        .task { await refreshUnderstandStatus() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !settings.codeSessionsEnabled {
            turnedOff
        } else if !linkAvailable {
            notConnected
        } else {
            composer
        }
    }

    // MARK: - Link state

    /// These tabs talk to the Mac only over the live socket — the relay's
    /// configured state (host + token) is irrelevant here. A socket host
    /// (pinned or discovered) or an active connection is what matters.
    private var linkAvailable: Bool {
        socket.isConnected || settings.socketURL != nil
    }

    /// Shown when the Settings toggle is off — a pointer back, not a dead end.
    private var turnedOff: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(palette.textFaint)
            Text("Code sessions are off")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .padding(.top, 16)
            Text("Turn them back on in Settings and AlfredCode will be ready to take your requests here.")
                .font(.system(size: 15))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
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
            Text("AlfredCode runs on your Mac. Connect in Settings and you can start a session right from here.")
                .font(.system(size: 15))
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 40)
            Spacer()
            Spacer()
        }
    }

    // MARK: - Composer

    private var composer: some View {
        List {
            Section {
                projectCard
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                graphSearchRow
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                understandGraphRow
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                promptCard
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                chips
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                if let startError {
                    Text(startError)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.danger)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            Section {
                recentToggleRow
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                if showRecent {
                    if recentSessions.isEmpty {
                        recentEmptyRow
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(recentSessions) { session in
                            recentRow(session)
                                .contentShape(Rectangle())
                                .onTapGesture { openSession = session }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        sessionPendingDelete = session
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await reload() }
    }

    // MARK: - Graph search row

    /// "Search codebase…" — a graph query over the chosen project, straight to
    /// CodeGraph on the Mac (no grep, no file reads). Shown only when a project
    /// is picked; the sheet explains the state if the graph isn't ready.
    private var graphSearchRow: some View {
        let project = settings.selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return Button {
            guard !project.isEmpty else { return }
            graphQuery = ""
            graphResults = nil
            showGraphSearch = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.accentBright)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Search codebase")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                    Text(graphStatusSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textFaint)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(project.isEmpty)
    }

    /// One honest line under the search row: what the graph state actually is.
    private var graphStatusSubtitle: String {
        guard let status = graphStatus else {
            return "Ask Alfred's graph where things live"
        }
        if !status.available {
            return "CodeGraph isn't installed on your Mac"
        }
        if !status.indexed {
            return "Not indexed yet — open a session to index, or search to check"
        }
        // A healthy graph with unparseable counts (codegraph's status layout
        // isn't stable API) reads better as the raw text than "0 symbols".
        if status.symbolCount == 0 && status.fileCount == 0 && !status.text.isEmpty {
            return status.text
        }
        return "\(status.symbolCount) symbols · \(status.fileCount) files indexed"
    }

    private func refreshGraphStatus() async {
        let project = settings.selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, linkAvailable else { return }
        graphStatus = await socket.codeGraphStatus(projectPath: project)
        NSLog("[code] graph status for %@: %@", project, graphStatus?.indexed == true ? "indexed" : "not indexed")
    }

    // MARK: - Knowledge graph row

    /// "Explore visually…" — the Understand-Anything sheet: search, impact,
    /// trace, and a clickable graph of the chosen project. The twin of the
    /// CodeGraph search row: that one is token-first (for agents), this one is
    /// visual (for the human).
    private var understandGraphRow: some View {
        let project = settings.selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return Button {
            guard !project.isEmpty else { return }
            showUnderstandGraph = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.accentBright)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Explore visually")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                    Text(understandStatusSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textFaint)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(project.isEmpty)
    }

    /// One honest line under the row: what the knowledge graph state is.
    private var understandStatusSubtitle: String {
        guard let status = understandStatus else {
            return "Ask, trace and click through your codebase"
        }
        switch status.state {
        case .notInstalled:
            return "Install Understand-Anything on your Mac to explore"
        case .notAnalyzed:
            return "Not analyzed — open to build the knowledge graph"
        case .analyzing:
            return "Analyzing project…"
        case .ready:
            return status.text
        case .failed:
            return "Analysis failed — open to see why"
        }
    }

    private func refreshUnderstandStatus() async {
        let project = settings.selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, linkAvailable else { return }
        understandStatus = await socket.codeUnderstandStatus(projectPath: project)
    }

    // MARK: - Project card

    private var projectCard: some View {
        Button {
            showProjectPicker = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(palette.accentBright)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(projectTitle)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Text(projectSubtitle)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.textFaint)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(palette.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var projectTitle: String {
        let path = settings.selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "Select Project" }
        let leaf = (path as NSString).lastPathComponent
        return leaf.isEmpty ? path : leaf
    }

    private var projectSubtitle: String {
        let path = settings.selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "Tap to choose where on your Mac Alfred should work" }
        return path
    }

    // MARK: - Prompt card

    private var promptCard: some View {
        VStack(spacing: 12) {
            TextField("What do you want me to code?", text: $prompt, axis: .vertical)
                .lineLimit(3...10)
                .focused($inputFocused)
                .font(.system(size: 16))
                .foregroundStyle(palette.textPrimary)
            // No submitLabel/onSubmit: return inserts a newline, the iMessage
            // pattern — prompts are multi-line, and Send is one tap away.

            HStack(spacing: 10) {
                dictationButton
                Spacer(minLength: 0)
                if let dictationError {
                    Text(dictationError)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textFaint)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                sendButton
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.surfaceBorder, lineWidth: 1))
    }

    /// iMessage-style send: a filled circle that lifts the prompt off the phone
    /// and onto the Mac. Disabled until there's both a project and a prompt.
    private var sendButton: some View {
        Button {
            start()
        } label: {
            Group {
                if starting {
                    ProgressView()
                        .tint(palette.backgroundTop)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(palette.backgroundTop)
                }
            }
            .frame(width: 40, height: 40)
            .background(Circle().fill(palette.accentBright.opacity(canSend ? 1 : 0.35)))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel("Send to Alfred")
    }

    private var dictationButton: some View {
        Button {
            if dictation.isListening {
                dictation.stop()
            } else {
                startDictation()
            }
        } label: {
            Image(systemName: dictation.isListening ? "stop.circle.fill" : "mic.fill")
                .font(.system(size: 20))
                .foregroundStyle(dictation.isListening ? palette.danger : palette.textSecondary)
                .frame(width: 40, height: 40)
                .background(dictation.isListening ? palette.danger.opacity(0.12) : Color.clear)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(starting)
        .accessibilityLabel(dictation.isListening ? "Stop dictation" : "Dictate")
    }

    private var canSend: Bool {
        // The send needs a live link: with the Mac asleep the request would
        // spin for its 30s timeout before failing. Compose freely while
        // reconnecting; Send wakes up with the socket.
        socket.isConnected
            && !settings.selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !starting
    }

    // MARK: - Quick chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(QuickChip.all) { chip in
                    Button {
                        // Pre-fill with the action so the user adds the detail.
                        prompt = chip.prefill
                        inputFocused = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: chip.icon)
                                .font(.system(size: 11))
                            Text(chip.title)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(palette.accentBright)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(palette.accent.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(starting)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Recent sessions

    private var recentToggleRow: some View {
        Button {
            withAnimation(.snappy) { showRecent.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.accentBright)
                Text(recentTitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.textFaint)
                    .rotationEffect(.degrees(showRecent ? 0 : -90))
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recentTitle)
    }

    private var recentTitle: String {
        let project = settings.selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return project.isEmpty ? "Recent sessions" : "Recent in this project"
    }

    private var recentEmptyRow: some View {
        Text(recentEmptyText)
            .font(.system(size: 13))
            .foregroundStyle(palette.textFaint)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recentEmptyText: String {
        if !hasLoaded {
            // A host may be pinned/discovered while the Mac is offline — don't
            // spin "Loading…" forever; say what's actually true.
            return socket.isConnected
                ? "Loading from your Mac…"
                : "Not connected — your Mac isn't answering right now."
        }
        let project = settings.selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !project.isEmpty {
            return "No sessions in this project yet — your first will land here."
        }
        return "No coding sessions yet — describe what you want above and Alfred's agent will build it."
    }

    /// The last five sessions in the chosen project (or the five most recent
    /// overall before a project is picked). `~`/absolute-path tolerance keeps
    /// a `~/Projects/x` pick matching the Mac's reported `/Users/…/x`.
    private var recentSessions: [CodeSessionSummary] {
        let project = settings.selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = project.isEmpty
            ? sessions
            : sessions.filter { isInProject($0, project) }
        return Array(filtered.prefix(5))
    }

    private func isInProject(_ session: CodeSessionSummary, _ project: String) -> Bool {
        if session.projectPath == project { return true }
        // Only the ~/ shorthands need the leaf fallback: the Mac reports
        // absolute paths, so a selection from its own scan must match exactly
        // (otherwise ~/Projects/app and ~/Developer/app share sessions).
        guard project.hasPrefix("~/") else { return false }
        let leaf = (project as NSString).lastPathComponent
        guard leaf.count > 1 else { return false }
        return session.projectPath.hasSuffix("/\(leaf)")
    }

    private func recentRow(_ session: CodeSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(session.prompt)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(timeAgo(session.updatedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textFaint)
            }
            HStack(spacing: 8) {
                statusBadge(session.status)
                if let test = session.lastTestResult {
                    Image(systemName: test.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(test.success ? palette.success : palette.danger)
                }
                Text(session.projectType.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textFaint)
                Spacer(minLength: 0)
                if session.status.isActive {
                    ProgressView()
                        .tint(palette.accentBright)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Badge helpers

    private func statusColor(_ status: CodeSessionStatus) -> Color {
        switch status {
        case .idle: return palette.textFaint
        case .generating: return palette.accentBright
        case .paused: return .yellow
        case .completed: return palette.success
        case .error: return palette.danger
        }
    }

    private func statusBadge(_ status: CodeSessionStatus) -> some View {
        let color = statusColor(status)
        return Text(status.displayName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.14))
            .clipShape(Capsule())
    }

    private func timeAgo(_ timestamp: TimeInterval) -> String {
        // An unset timestamp would read as "millions of hours ago".
        guard timestamp > 0 else { return "just now" }
        let minutes = Int(max(0, Date().timeIntervalSince1970 - timestamp) / 60)
        switch minutes {
        case ..<1: return "just now"
        case ..<60: return "\(minutes)m ago"
        default: return "\(minutes / 60)h ago"
        }
    }

    // MARK: - Actions

    private func start() {
        guard canSend else { return }
        inputFocused = false
        if dictation.isListening { dictation.stop() }
        starting = true
        startError = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = settings.selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            guard let session = await socket.startCodeSession(
                prompt: text, projectPath: path, agent: "opencode") else {
                starting = false
                startError = "The Mac couldn't start that session. Check the folder exists there and that the coding agent is installed."
                return
            }
            starting = false
            prompt = ""
            // Land it under Recent immediately, before the Mac's push arrives.
            if !sessions.contains(where: { $0.id == session.id }) {
                sessions.insert(session, at: 0)
            }
            openSession = session
            NSLog("[code] started session %@ in %@", session.id.uuidString, path)
        }
    }

    // MARK: - Dictation

    private func startDictation() {
        inputFocused = false
        dictationBase = prompt
        dictationError = nil
        // Capture the *bindings*, not the view: CodeView is a value type, so a
        // closure that captured self would mutate a throwaway copy. Bindings
        // reach the real @State storage no matter where they're written from.
        let promptBinding = $prompt
        let baseBinding = $dictationBase
        let errorBinding = $dictationError
        let controller = dictation
        controller.start(
            partial: { text in
                promptBinding.wrappedValue = baseBinding.wrappedValue + (text.isEmpty ? "" : " " + text)
            },
            finish: { transcript in
                if let transcript, !transcript.isEmpty {
                    promptBinding.wrappedValue = baseBinding.wrappedValue + " " + transcript
                } else {
                    // Nothing usable (cancelled, or a failed start) — restore
                    // what was there and only explain if it's a real block.
                    promptBinding.wrappedValue = baseBinding.wrappedValue
                    if controller.unavailable {
                        errorBinding.wrappedValue = "Dictation isn't available — check Speech Recognition in Settings > Privacy."
                    }
                }
                baseBinding.wrappedValue = ""
            })
    }

    // MARK: - Live updates

    private func reload() async {
        guard linkAvailable else {
            NSLog("[code] reload skipped — no live link (socket %@, host %@)",
                  socket.isConnected ? "connected" : "down", settings.socketHost)
            return
        }
        // Once the Mac has answered, never wipe a good list with a dead-socket
        // [] (listCodeSessions returns [] on failure too) — keep showing
        // last-known data until the link is back.
        if hasLoaded && !socket.isConnected {
            NSLog("[code] socket down — keeping last-known list")
            return
        }
        sessions = await socket.listCodeSessions()
        hasLoaded = true
        NSLog("[code] reload — %d sessions from Mac", sessions.count)
    }

    /// Keep the recent list in sync while a session streams in the background.
    /// Most events mutate the matching row in place — a chunk appends, a status
    /// flip recolours the badge, a test result stamps the row — so the list
    /// tracks the Mac without a full re-fetch each time.
    private func observeCodeEvents() async {
        NSLog("[code] observing code session events")
        for await update in socket.updates() {
            switch update {
            case .codeSessionStatus(let id, let status):
                NSLog("[code] event code.status — %@ (%@)", status, id)
                if let index = sessions.firstIndex(where: { $0.sessionId.uuidString == id }) {
                    if let newStatus = CodeSessionStatus(rawValue: status) {
                        sessions[index].status = newStatus
                    }
                } else {
                    // A session we don't know about — started on the Mac itself
                    // or via a bar tool. Pull the fresh list so it appears here.
                    await reload()
                }
            case .codeChunk(let id, let text):
                if let index = sessions.firstIndex(where: { $0.sessionId.uuidString == id }) {
                    sessions[index].generatedCode += text
                    if sessions[index].status != .generating {
                        sessions[index].status = .generating
                    }
                }
            case .codeTestResult(let id, let success, let output, let duration, let command):
                NSLog("[code] event code.test_result — %@ success=%@", id, success ? "ok" : "fail")
                if let index = sessions.firstIndex(where: { $0.sessionId.uuidString == id }) {
                    sessions[index].lastTestResult = CodeTestResultPayload(
                        success: success, output: output, duration: duration, command: command)
                }
            case .codeGitStatus:
                await reload()
            default:
                break
            }
        }
    }
}

// MARK: - Graph search

/// A sheet that queries the chosen project's CodeGraph index. One field, one
/// answer: the raw symbol-search results from the Mac, plus an honest status
/// line when the graph isn't ready (rather than a spinner that never settles).
private struct GraphSearchView: View {
    let projectPath: String
    let socket: AlfredWebSocketClient
    let palette: Palette

    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool
    @State private var query = ""
    @State private var results: String?
    @State private var statusText = ""
    @State private var searching = false
    @State private var hasQueried = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The query bar, pinned so results scroll beneath it.
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(palette.textFaint)
                    TextField("Where does the mail sending live?", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($fieldFocused)
                        .onSubmit { Task { await search() } }
                        .submitLabel(.search)
                    if searching {
                        ProgressView()
                            .tint(palette.accentBright)
                            .controlSize(.small)
                    }
                    Button {
                        Task { await search() }
                    } label: {
                        Text("Search")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.accentBright)
                    }
                    .buttonStyle(.plain)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searching)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                if hasQueried {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if let results, !results.isEmpty {
                                Text(results)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(palette.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                            } else {
                                emptyHint
                            }
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        Spacer()
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(palette.textFaint)
                        Text(statusText)
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 12)
                            .padding(.horizontal, 36)
                        Spacer()
                        Spacer()
                    }
                }
            }
            .navigationTitle("Search codebase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(palette.accentBright)
                }
            }
        }
        .task {
            await checkGraph()
            fieldFocused = true
        }
    }

    private var emptyHint: some View {
        Text("No matches — try a symbol name (\"MailManager\") or a concept (\"auth\").")
            .font(.system(size: 13))
            .foregroundStyle(palette.textFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }

    private func checkGraph() async {
        if let status = await socket.codeGraphStatus(projectPath: projectPath) {
            if !status.available {
                statusText = "CodeGraph isn't installed on your Mac. Install it, then index this project."
            } else if !status.indexed {
                statusText = "This project isn't indexed yet. Start a session to index it, then search."
            } else {
                statusText = "\(status.symbolCount) symbols indexed — ask for what you're looking for."
            }
        } else {
            statusText = "Couldn't reach your Mac right now."
        }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searching = true
        hasQueried = true
        results = await socket.codeGraphSearch(projectPath: projectPath, query: trimmed)
        searching = false
    }
}

// MARK: - Quick chips

/// The four preset actions under the composer. Tapping pre-fills the prompt so
/// the user adds the detail ("Fix bugs: …"). SF Symbols rather than emoji — the
/// app is deliberately monochrome and emoji would break the palette.
private struct QuickChip: Identifiable {
    let id: String
    let title: String
    let icon: String
    let prefill: String

    static let all: [QuickChip] = [
        QuickChip(id: "fix", title: "Fix bugs", icon: "ladybug.fill", prefill: "Fix bugs: "),
        QuickChip(id: "feature", title: "Add feature", icon: "sparkles", prefill: "Add feature: "),
        QuickChip(id: "refactor", title: "Refactor", icon: "arrow.triangle.2.circlepath", prefill: "Refactor: "),
        QuickChip(id: "tests", title: "Write tests", icon: "checkmark.seal.fill", prefill: "Write tests: "),
    ]
}

// MARK: - Dictation

/// One-shot on-device dictation for the composer. Owns the audio engine and
/// recognition task for the lifetime of a single recording; the view asks it
/// to start (supplying callbacks) and later stop. Everything routes through
/// the main actor so the view can mutate its prompt safely from callbacks.
@MainActor
private final class CodeDictationController {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private(set) var isListening = false
    /// True when the last attempt failed for a reason the user can't fix by
    /// speaking again (denied permission, no recognizer) — the view explains
    /// rather than silently swallowing the tap.
    private(set) var unavailable = false

    private var onPartial: ((String) -> Void)?
    private var onFinish: ((String?) -> Void)?

    /// Read on the audio thread by the tap closure. Appending a buffer to a
    /// request after `endAudio()` can raise an Objective-C exception on some
    /// OS versions, so the closure must stop feeding as soon as teardown
    /// begins. A plain Bool is fine for that handshake (worst case one stale
    /// buffer slips through the transition); `nonisolated(unsafe)` because the
    /// audio thread isn't main-actor isolated.
    private nonisolated(unsafe) var acceptingAudio = false

    func start(partial: @escaping (String) -> Void, finish: @escaping (String?) -> Void) {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            unavailable = true
            finish(nil)
            return
        }

        onPartial = partial
        onFinish = finish
        unavailable = false

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                guard status == .authorized else {
                    self.unavailable = true
                    self.finishSending(nil)
                    return
                }
                self.begin(recognizer)
            }
        }
    }

    func stop() {
        guard isListening else { return }
        // Ending the audio makes the recognition task deliver its final
        // transcript, which flows through the normal finish path.
        request?.endAudio()
        // Failsafe: if the recognizer never settles (rare), force a teardown.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, self.isListening else { return }
            self.teardown()
            self.finishSending(nil)
        }
    }

    private func begin(_ recognizer: SFSpeechRecognizer) {
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.onPartial?(result.bestTranscription.formattedString)
                }
                if error != nil || result?.isFinal == true {
                    let transcript = result?.bestTranscription.formattedString
                    self.teardown()
                    self.finishSending(transcript)
                }
            }
        }

        // No usable input (e.g. the simulator without a mic) — degrade to the
        // typed prompt before any state is touched.
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            NSLog("[code] dictation — no usable audio input")
            finishSending(nil)
            return
        }

        self.engine = engine
        self.request = request
        self.task = task
        isListening = true

        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            NSLog("[code] dictation — audio session failed: %@", error.localizedDescription)
        }

        acceptingAudio = true
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // No `request` captured here — read the flag instead, so teardown
            // (which stops the engine and removes the tap) can cut delivery.
            guard let self, self.acceptingAudio else { return }
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("[code] dictation — engine failed to start: %@", error.localizedDescription)
            teardown()
            finishSending(nil)
        }
    }

    private func teardown() {
        // Cut the tap first: appending to a request past endAudio can throw on
        // some OS versions, and in-flight buffers are still being delivered.
        acceptingAudio = false
        engine?.stop()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        request = nil
        task?.cancel()
        task = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func finishSending(_ transcript: String?) {
        onFinish?(transcript)
        onFinish = nil
        onPartial = nil
    }
}
