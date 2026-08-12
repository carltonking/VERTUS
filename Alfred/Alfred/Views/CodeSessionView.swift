//
//  CodeSessionView.swift
//  Alfred
//
//  The live view of one AlfredCode session. Three sections:
//
//    1. Code display — everything the agent has streamed, appended in real
//       time via pushed code.chunk notifications, auto-scrolled to the tail.
//    2. Git controls — branch, create/switch, uncommitted count, diff, commit,
//       push, pull.
//    3. Tests & actions — run the project's test command, refine the agent,
//       copy the code, stop or discard the session.
//
//  Safety by construction: nothing here executes generated code. The agent
//  works on the Mac; the phone only watches, copies, and asks the Mac to run
//  its own test/commit commands.
//

import SwiftUI

struct CodeSessionView: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    private var socket: AlfredWebSocketClient { .shared }

    /// The session as last known; the pushed events mutate it in place.
    @State private var session: CodeSessionSummary
    /// The fully streamed transcript (session.generatedCode can lag a chunk
    /// behind the local append while the Mac saves).
    @State private var displayCode: String

    @State private var showTestResults = false
    @State private var testResult: CodeTestResultPayload?
    @State private var showRefine = false
    @State private var showCommit = false
    @State private var showBranch = false
    @State private var showDiff = false
    @State private var diffText = ""
    @State private var busy: Busy?
    @State private var toast: String?
    @State private var showStopConfirm = false
    @State private var showDeleteConfirm = false
    @State private var branchList: [String] = []

    private enum Busy: Equatable {
        case tests, committing, branching, pushing, pulling
    }

    init(session: CodeSessionSummary) {
        _session = State(initialValue: session)
        _displayCode = State(initialValue: session.generatedCode)
    }

    var body: some View {
        ZStack {
            palette.background
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    codeCard
                    gitCard
                    actionsCard
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Coding session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(palette.backgroundTop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $showTestResults) {
            TestResultsSheet(result: testResult) {
                showTestResults = false
                Task { await runTests() }
            }
        }
        .sheet(isPresented: $showRefine) {
            RefineSheet { request in
                showRefine = false
                Task { await refine(request) }
            }
        }
        .sheet(isPresented: $showCommit) {
            CommitSheet { message in
                showCommit = false
                Task { await commit(message) }
            }
        }
        .sheet(isPresented: $showBranch) {
            BranchSheet(branches: branchList, currentBranch: session.gitStatus?.currentBranch) { name in
                showBranch = false
                Task { await createOrSwitchBranch(name) }
            }
            .task { await loadBranches() }
        }
        .sheet(isPresented: $showDiff) {
            DiffSheet(diff: diffText)
        }
        .confirmationDialog(
            "Stop this session? The agent is killed but the transcript stays.",
            isPresented: $showStopConfirm, titleVisibility: .visible) {
                Button("Stop", role: .destructive) {
                    Task { await stop() }
                }
                Button("Cancel", role: .cancel) {}
            }
        .confirmationDialog(
            "Delete this session? Everything it produced is removed from Alfred.",
            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task { await delete() }
                }
                Button("Cancel", role: .cancel) {}
            }
        .task { await observe() }
        .task { await loadGitStatus() }
        .overlay(alignment: .bottom) {
            if let toast {
                toastView(toast)
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.prompt)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(session.projectPath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(palette.textSecondary)
            HStack(spacing: 8) {
                statusBadge
                Text(session.projectType.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textFaint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(palette.surfaceBorder.opacity(0.4))
                    .clipShape(Capsule())
                Spacer(minLength: 0)
                if session.status == .generating {
                    HStack(spacing: 5) {
                        ProgressView().tint(palette.accentBright).controlSize(.small)
                        Text("working…")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textSecondary)
                    }
                }
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

    private var statusBadge: some View {
        Text(session.status.displayName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(session.status.isError ? palette.danger : palette.accentBright)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background((session.status.isError ? palette.danger : palette.accent).opacity(0.14))
            .clipShape(Capsule())
    }

    // MARK: - Code display

    private var codeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.accentBright)
                Text("Generated code")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
                Button {
                    copyCode()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.accentBright)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy code")
            }

            if displayCode.isEmpty {
                VStack(spacing: 8) {
                    if session.status == .generating {
                        ProgressView().tint(palette.accentBright)
                        Text("The agent is getting started…")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textSecondary)
                    } else {
                        Text("Nothing streamed yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.textFaint)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                // Auto-scrolling read-only code view. Chunks stream in; the
                // reader stays pinned to the newest line while it's near the
                // bottom, and a "jump to bottom" affordance appears if they've
                // scrolled away.
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(displayCode)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(palette.textPrimary)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .id("code-tail")
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: displayCode) { _, _ in
                        proxy.scrollTo("code-tail", anchor: .bottom)
                    }
                }
                .background(palette.backgroundTop.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // Pause/resume sits right where the code is streaming.
            if session.status == .generating || session.status == .paused {
                HStack(spacing: 10) {
                    if session.status == .generating {
                        pauseButton
                    } else {
                        resumeButton
                    }
                    stopButton
                }
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

    private var pauseButton: some View {
        Button {
            Task { await pause() }
        } label: {
            Label("Pause", systemImage: "pause.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.accentBright)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(palette.accent.opacity(0.14))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var resumeButton: some View {
        Button {
            Task { await resume() }
        } label: {
            Label("Resume", systemImage: "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.accentBright)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(palette.accent.opacity(0.14))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var stopButton: some View {
        Button {
            showStopConfirm = true
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.danger)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(palette.danger.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Git controls

    private var gitCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.accentBright)
                Text("Git")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
                if let git = session.gitStatus {
                    Text(git.currentBranch)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette.accentBright)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(palette.accent.opacity(0.14))
                        .clipShape(Capsule())
                }
            }

            if let git = session.gitStatus {
                HStack(spacing: 12) {
                    LabeledRow(
                        value: "\(git.uncommittedChanges)",
                        label: git.uncommittedChanges == 1 ? "uncommitted change" : "uncommitted changes",
                        icon: "square.and.pencil")
                    Button {
                        Task { await showDiff() }
                    } label: {
                        Text("View changes")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.accentBright)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(palette.surfaceBorder.opacity(0.5))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                gitButton("Commit", icon: "checkmark.circle", action: { showCommit = true }, disabled: busy != nil)
                gitButton("Branch", icon: "arrow.triangle.branch", action: { showBranch = true }, disabled: busy != nil)
                gitButton("Push", icon: "arrow.up.circle", action: { Task { await push() } }, disabled: busy == .pushing)
                gitButton("Pull", icon: "arrow.down.circle", action: { Task { await pull() } }, disabled: busy == .pulling)
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

    private func gitButton(_ title: String, icon: String, action: @escaping () -> Void, disabled: Bool) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(palette.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(palette.backgroundTop.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.surfaceBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    // MARK: - Tests & actions

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.accentBright)
                Text("Tests & actions")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
                if let result = session.lastTestResult {
                    Button {
                        testResult = result
                        showTestResults = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 11))
                            Text(result.success ? "Passed" : "Failed")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(result.success ? palette.success : palette.danger)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let command = session.projectType.testCommand {
                Button {
                    Task { await runTests() }
                } label: {
                    HStack(spacing: 8) {
                        if busy == .tests {
                            ProgressView().tint(palette.backgroundTop)
                        } else {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 13))
                        }
                        Text(busy == .tests ? "Running \(command)…" : "Run tests (\(command))")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.backgroundTop)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.plain)
                .disabled(busy != nil)
                .opacity(busy == nil ? 1 : 0.5)
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
                .background(palette.accentBright)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            } else {
                Text("No test command is defined for \(session.projectType.displayName) projects.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textFaint)
            }

            HStack(spacing: 10) {
                Button {
                    showRefine = true
                } label: {
                    Label("Refine", systemImage: "wand.and.stars")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.accentBright)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(palette.accent.opacity(0.14))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(session.status == .generating || session.status == .paused)

                Spacer(minLength: 0)

                Button {
                    showDeleteConfirm = true
                } label: {
                    Text("Discard")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.danger)
                }
                .buttonStyle(.plain)
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

    // MARK: - Actions

    private func pause() async {
        guard await socket.pauseCodeSession(id: session.id) else { return }
        session.status = .paused
    }

    private func resume() async {
        guard await socket.resumeCodeSession(id: session.id) else { return }
        session.status = .generating
    }

    private func stop() async {
        guard await socket.stopCodeSession(id: session.id) else { return }
        session.status = .completed
        flash("Stopped.")
    }

    private func delete() async {
        guard await socket.deleteCodeSession(id: session.id) else { return }
        dismiss()
    }

    private func refine(_ request: String) async {
        guard await socket.refineCodeSession(id: session.id, request: request) else {
            flash("Couldn't reach the agent.")
            return
        }
        session.status = .generating
        flash("Refining…")
    }

    private func runTests() async {
        busy = .tests
        defer { busy = nil }
        guard let result = await socket.runCodeTests(id: session.id) else {
            flash("Test run failed to reach the Mac.")
            return
        }
        testResult = result
        session.lastTestResult = result
        showTestResults = true
    }

    private func commit(_ message: String) async {
        busy = .committing
        defer { busy = nil }
        guard let hash = await socket.codeGitCommit(id: session.id, message: message) else {
            flash("Commit failed — nothing to commit or git refused.")
            return
        }
        await loadGitStatus()
        flash("Committed \(hash).")
    }

    private func createOrSwitchBranch(_ name: String) async {
        busy = .branching
        defer { busy = nil }
        var status = await socket.codeGitCreateBranch(id: session.id, name: name)
        if status == nil {
            status = await socket.codeGitSwitchBranch(id: session.id, name: name)
        }
        if let status {
            session.gitStatus = status
            flash("On \(status.currentBranch) now.")
        } else {
            flash("Branch change failed.")
        }
    }

    private func push() async {
        busy = .pushing
        defer { busy = nil }
        let message = await socket.codeGitPush(id: session.id)
        flash(message)
    }

    private func pull() async {
        busy = .pulling
        defer { busy = nil }
        let message = await socket.codeGitPull(id: session.id)
        flash(message)
        await loadGitStatus()
    }

    private func showDiff() async {
        diffText = await socket.codeGitDiff(id: session.id)
        showDiff = true
    }

    private func loadGitStatus() async {
        if let status = await socket.codeGitStatus(id: session.id) {
            session.gitStatus = status
        }
    }

    private func loadBranches() async {
        branchList = await socket.codeGitListBranches(id: session.id)
    }

    private func copyCode() {
        UIPasteboard.general.string = displayCode
        flash("Copied.")
    }

    // MARK: - Live updates

    /// Consume the pushed code events for *this* session: chunks append to the
    /// display, status flips re-render the controls, test/git results refresh.
    private func observe() async {
        for await update in socket.updates() {
            let id = session.id.uuidString
            switch update {
            case .codeChunk(let chunkSessionID, let text):
                guard chunkSessionID == id else { continue }
                displayCode += text
            case .codeSessionStatus(let chunkSessionID, let status):
                guard chunkSessionID == id else { continue }
                session.status = CodeSessionStatus(rawValue: status) ?? session.status
            case .codeTestResult(let chunkSessionID, let success, let output, let duration, let command):
                guard chunkSessionID == id else { continue }
                session.lastTestResult = CodeTestResultPayload(
                    success: success, output: output, duration: duration, command: command)
                if session.status != .error { session.status = .completed }
            case .codeGitStatus(let chunkSessionID, let branch, let uncommitted):
                guard chunkSessionID == id else { continue }
                session.gitStatus = CodeGitStatusPayload(
                    currentBranch: branch,
                    uncommittedChanges: uncommitted,
                    unstagedFiles: session.gitStatus?.unstagedFiles ?? [])
            default:
                break
            }
        }
    }

    // MARK: - Toast

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(palette.surface.opacity(0.95))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(palette.surfaceBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func flash(_ text: String) {
        withAnimation(.snappy) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            await MainActor.run {
                withAnimation(.snappy) {
                    if toast == text { toast = nil }
                }
            }
        }
    }
}

// MARK: - Small rows

private struct LabeledRow: View {
    @Environment(\.palette) private var palette
    let value: String
    let label: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(palette.accentBright)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.textPrimary)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textFaint)
            }
        }
    }
}

// MARK: - Test results sheet

private struct TestResultsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    let result: CodeTestResultPayload?
    let onRunAgain: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let result {
                            HStack(spacing: 8) {
                                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(result.success ? palette.success : palette.danger)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.success ? "Tests passed" : "Tests failed")
                                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                                        .foregroundStyle(palette.textPrimary)
                                    Text(String(format: "%.1fs · %@", result.duration, result.command))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(palette.textFaint)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(16)
                            .background(palette.surface.opacity(0.7))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                            Text(result.output.isEmpty ? "(no output)" : result.output)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(palette.textSecondary)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(palette.backgroundTop.opacity(0.6))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            Button {
                                onRunAgain()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 12))
                                    Text("Run again")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundStyle(palette.accentBright)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(palette.accent.opacity(0.14))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("No test output.")
                                .font(.system(size: 14))
                                .foregroundStyle(palette.textFaint)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Test results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(palette.accentBright)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Refine sheet

private struct RefineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    let onSubmit: (String) -> Void

    @State private var request = ""

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background
                VStack(spacing: 0) {
                    TextField("e.g. Add type checking to the generated code", text: $request, axis: .vertical)
                        .lineLimit(3...8)
                        .font(.system(size: 15))
                        .foregroundStyle(palette.textPrimary)
                        .padding(14)
                        .background(palette.surface.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(palette.surfaceBorder, lineWidth: 1))
                        .padding(16)

                    Spacer()
                }
            }
            .navigationTitle("Refine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(palette.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send") {
                        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        onSubmit(text)
                    }
                    .foregroundStyle(palette.accentBright)
                    .fontWeight(.semibold)
                    .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Commit sheet

private struct CommitSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    let onSubmit: (String) -> Void

    @State private var message = ""

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background
                VStack(spacing: 0) {
                    TextField("Commit message", text: $message, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.system(size: 15))
                        .foregroundStyle(palette.textPrimary)
                        .padding(14)
                        .background(palette.surface.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(palette.surfaceBorder, lineWidth: 1))
                        .padding(16)
                    Text("Stages everything in the project and commits on the Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textFaint)
                        .padding(.horizontal, 16)
                    Spacer()
                }
            }
            .navigationTitle("Commit changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(palette.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Commit") {
                        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        onSubmit(text)
                    }
                    .foregroundStyle(palette.accentBright)
                    .fontWeight(.semibold)
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Branch sheet

private struct BranchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    let branches: [String]
    let currentBranch: String?
    let onSubmit: (String) -> Void

    @State private var name = ""
    @State private var switchMode = false

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background
                Form {
                    Picker("Action", selection: $switchMode) {
                        Text("New branch").tag(false)
                        Text("Switch to").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if switchMode {
                        Section("Branches") {
                            ForEach(branches, id: \.self) { branch in
                                Button {
                                    onSubmit(branch)
                                } label: {
                                    HStack {
                                        Text(branch)
                                            .font(.system(size: 14, design: .monospaced))
                                            .foregroundStyle(palette.textPrimary)
                                        if branch == currentBranch {
                                            Spacer()
                                            Text("current")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(palette.textFaint)
                                        }
                                    }
                                }
                            }
                            if branches.isEmpty {
                                Text("No local branches yet — create one first.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.textFaint)
                            }
                        }
                    } else {
                        Section("Branch name") {
                            TextField("e.g. fix-login-bug", text: $name)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundStyle(palette.textPrimary)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Button("Create") {
                            let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            onSubmit(text)
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .scrollContentBackground(.hidden)
                .formStyle(.grouped)
            }
            .navigationTitle("Branches")
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
    }
}

// MARK: - Diff sheet

private struct DiffSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    let diff: String

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background
                ScrollView {
                    Text(diff.isEmpty ? "(no uncommitted changes)" : diff)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.textSecondary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.backgroundTop.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(16)
                }
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(palette.backgroundTop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(palette.accentBright)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
