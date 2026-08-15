//
//  KnowledgeGraphView.swift
//  AlfredMacApp
//
//  The interactive knowledge-graph sheet over the chosen project — the visual
//  half of Understand-Anything. Where CodeGraph answers "where does this live"
//  in tokens, this answers it in pictures:
//
//    • Status card — analyzed?, counts, the raw state text, Analyze /
//      Re-analyze, and Open Dashboard (the tool's full interactive viewer,
//      served by the Mac and reachable over the LAN).
//    • Modes — Search (symbol/concept search over the graph), Impact (what
//      breaks if you change X), Trace (a path between two symbols, or back to
//      a root), Explore (architectural layers + the whole project at a
//      glance).
//    • Canvas — the graph itself: pan, pinch-zoom, click a node to see its
//      summary, neighbors and layers.
//
//  Ported from Alfred/Alfred/Views/KnowledgeGraphView.swift — the dashboard
//  opens via NSWorkspace, and pinch-zoom is a MagnifyGesture (macOS 14).
//
//  Everything comes from the Mac over the socket (`code.understand_*`) and is
//  computed there from .ua/knowledge-graph.json — this app never sees the raw
//  graph JSON.

import SwiftUI

/// The four ways to interrogate the graph.
enum UnderstandGraphMode: String, CaseIterable, Identifiable {
    case search, impact, trace, explore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: return "Search"
        case .impact: return "Impact"
        case .trace: return "Trace"
        case .explore: return "Explore"
        }
    }

    var icon: String {
        switch self {
        case .search: return "magnifyingglass"
        case .impact: return "arrow.triangle.branch"
        case .trace: return "point.topleft.down.curvedto.point.bottomright.up"
        case .explore: return "square.3.layers.3d"
        }
    }

    var placeholder: String {
        switch self {
        case .search: return "Where does authentication live?"
        case .impact: return "What breaks if I change…"
        case .trace: return "Trace from… (to… optional)"
        case .explore: return ""
        }
    }

    var hint: String {
        switch self {
        case .search: return "Search files, functions and classes by name or meaning."
        case .impact: return "Everything that depends on a symbol — what breaks if it changes."
        case .trace: return "An execution path between two symbols, or back to a root."
        case .explore: return "The project's layers, and the whole graph at a glance."
        }
    }
}

/// The sheet that runs the knowledge graph for the picked project.
struct KnowledgeGraphView: View {
    let projectPath: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    private var socket: AlfredWebSocketClient { .shared }

    @State private var status: UnderstandStatusPayload?
    @State private var analyzing = false
    @State private var dashboardError: String?

    @State private var mode: UnderstandGraphMode = .search
    @State private var query = ""
    @State private var queryExtra = ""
    @State private var busy = false
    @State private var errorText: String?

    @State private var hits: [UnderstandHitPayload] = []
    @State private var impactHits: [UnderstandImpactHitPayload] = []
    @State private var layers: [UnderstandLayerSummaryPayload] = []
    @State private var trace: UnderstandTracePayload?
    @State private var traceNames: [String] = []
    @State private var canvasGraph: UnderstandGraphPayload?
    @State private var detailNode: UnderstandNodePayload?

    @State private var detailExplanation: UnderstandExplainPayload?
    @State private var showDetail = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background
                VStack(spacing: 0) {
                    statusCard
                    modePicker
                    content
                }
            }
            .navigationTitle("Knowledge graph")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(palette.accentBright)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await refreshStatus() }
        .onDisappear { pollTask?.cancel() }
        .sheet(isPresented: $showDetail) {
            if let node = detailNode {
                UnderstandNodeDetailView(
                    projectPath: projectPath,
                    node: node,
                    explanation: detailExplanation,
                    palette: palette)
            }
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(statusColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.textPrimary)
                    Text(statusDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if analyzing {
                    ProgressView()
                        .tint(palette.accentBright)
                        .controlSize(.small)
                    Text("Analyzing…")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                } else if let status, status.state.isReady {
                    Button {
                        Task { await openDashboard() }
                    } label: {
                        Label("Open dashboard", systemImage: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(UnderstandActionButtonStyle(palette: palette))
                }

                Spacer(minLength: 0)

                Button {
                    Task { await analyze(force: status?.state.isReady == true) }
                } label: {
                    Text(analyzeButtonTitle)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(UnderstandActionButtonStyle(palette: palette))
                .disabled(analyzing || !(status?.installed ?? false))
            }

            if let dashboardError {
                Text(dashboardError)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.danger)
            }
            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.danger)
            }
        }
        .padding(14)
        .background(palette.surface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(palette.surfaceBorder, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var statusIcon: String {
        guard let status else { return "questionmark.circle" }
        switch status.state {
        case .ready: return "point.3.connected.trianglepath.dotted"
        case .analyzing: return "ellipsis.circle"
        case .notInstalled: return "exclamationmark.triangle"
        case .notAnalyzed: return "plus.circle"
        case .failed: return "xmark.octagon"
        }
    }

    private var statusColor: Color {
        guard let status else { return palette.textFaint }
        switch status.state {
        case .ready: return palette.success
        case .analyzing: return palette.accentBright
        case .failed: return palette.danger
        case .notInstalled, .notAnalyzed: return palette.textFaint
        }
    }

    private var statusTitle: String {
        guard let status else { return "Checking the Mac…" }
        switch status.state {
        case .ready: return "Graph ready"
        case .analyzing: return "Analyzing project"
        case .notInstalled: return "Not installed on your Mac"
        case .notAnalyzed: return "Not analyzed yet"
        case .failed: return "Analysis failed"
        }
    }

    private var statusDetail: String {
        guard let status else { return "Asking your Mac about this project." }
        if status.state == .notInstalled {
            return "Install Understand-Anything on the Mac, then reopen this. The install command is shown in Settings."
        }
        return status.text
    }

    private var analyzeButtonTitle: String {
        guard let status else { return "Analyze" }
        return status.state.isReady ? "Re-analyze" : "Analyze"
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        HStack(spacing: 6) {
            ForEach(UnderstandGraphMode.allCases) { m in
                Button {
                    mode = m
                    clearResults()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: m.icon)
                            .font(.system(size: 11))
                        Text(m.title)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 11)
                    .foregroundStyle(mode == m ? palette.textPrimary : palette.textSecondary)
                    .background(mode == m ? palette.surface : Color.clear)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(
                            mode == m ? palette.surfaceBorder : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if mode == .explore {
            exploreContent
        } else {
            queryContent
        }
    }

    private var queryContent: some View {
        VStack(spacing: 0) {
            // Query bar.
            HStack(spacing: 10) {
                Image(systemName: mode.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textFaint)
                TextField(mode.placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit { Task { await runModeQuery() } }
                if mode == .trace {
                    TextField("to…", text: $queryExtra)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textSecondary)
                        .onSubmit { Task { await runModeQuery() } }
                        .frame(maxWidth: 110)
                }
                if busy {
                    ProgressView()
                        .tint(palette.accentBright)
                        .controlSize(.small)
                }
                Button {
                    Task { await runModeQuery() }
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(palette.accentBright)
                }
                .buttonStyle(.plain)
                .disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Text(mode.hint)
                .font(.system(size: 11))
                .foregroundStyle(palette.textFaint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            Divider().overlay(palette.surfaceBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch mode {
                    case .search: searchResults
                    case .impact: impactResults
                    case .trace: traceResults
                    case .explore: EmptyView()
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchResults: some View {
        if hits.isEmpty && !busy {
            emptyResults("No matches — try a symbol name (\"MailManager\") or a concept (\"auth\").")
        } else {
            ForEach(hits) { hit in
                Button {
                    Task { await showDetail(hit.id) }
                } label: {
                    hitRow(hit.name, type: hit.type, path: hit.filePath,
                           summary: hit.summary, badge: "\(hit.score)")
                }
                .buttonStyle(.plain)
                Divider().overlay(palette.surfaceBorder)
            }
        }
    }

    // MARK: - Impact results

    @ViewBuilder
    private var impactResults: some View {
        if impactHits.isEmpty && !busy {
            emptyResults("Nothing depends on that yet — try a function or class name.")
        } else {
            let direct = impactHits.filter { $0.depth == 0 }.count
            HStack {
                Text("\(impactHits.count) node\(impactHits.count == 1 ? "" : "s") affected — \(direct) directly")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                Spacer()
                Button {
                    Task { await showImpactGraph() }
                } label: {
                    Label("Show in graph", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.accentBright)
                .disabled(canvasGraph != nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ForEach(impactHits) { hit in
                Button {
                    Task { await showDetail(hit.id) }
                } label: {
                    hitRow(hit.name, type: hit.type, path: hit.filePath,
                           summary: hit.summary, badge: "depth \(hit.depth)",
                           indent: min(hit.depth, 3))
                }
                .buttonStyle(.plain)
                Divider().overlay(palette.surfaceBorder)
            }
        }
    }

    // MARK: - Trace results

    @ViewBuilder
    private var traceResults: some View {
        if let trace {
            if trace.nodeIDs.isEmpty {
                emptyResults("No path between those two.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(trace.nodeIDs.count) hop\(trace.nodeIDs.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                    ForEach(Array(trace.nodeIDs.enumerated()), id: \.offset) { index, nodeID in
                        HStack(spacing: 8) {
                            if index > 0, index < trace.edgeTypes.count {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 10))
                                    .foregroundStyle(palette.textFaint)
                            }
                            let name = index < traceNames.count ? traceNames[index] : nodeID
                            Button {
                                Task { await showDetail(nodeID) }
                            } label: {
                                Text(name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(palette.textPrimary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(16)
            }
        } else if !busy {
            emptyResults("Trace a path — e.g. from \"login\" to \"database\".")
        }
    }

    // MARK: - Explore

    private var exploreContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button {
                        Task { await loadPreview() }
                    } label: {
                        Label("Show whole project", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(UnderstandActionButtonStyle(palette: palette))
                    .disabled(busy)

                    Spacer()

                    if busy {
                        ProgressView()
                            .tint(palette.accentBright)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                if let canvasGraph {
                    UnderstandGraphCanvasView(graph: canvasGraph, palette: palette) { node in
                        Task { await showDetail(node.id) }
                    }
                    .frame(height: 340)
                    .background(palette.surface.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(palette.surfaceBorder, lineWidth: 1))
                    .padding(.horizontal, 16)
                }

                if layers.isEmpty && !busy {
                    emptyResults("No layers yet — analyze the project to see its architecture.")
                } else {
                    ForEach(layers) { layer in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(layer.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(palette.textPrimary)
                                Spacer()
                                Text("\(layer.nodeCount)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(palette.textSecondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(palette.surface)
                                    .clipShape(Capsule())
                            }
                            if !layer.description.isEmpty {
                                Text(layer.description)
                                    .font(.system(size: 12))
                                    .foregroundStyle(palette.textSecondary)
                            }
                            if !layer.sampleNodes.isEmpty {
                                Text(layer.sampleNodes.prefix(5).joined(separator: " · "))
                                    .font(.system(size: 11))
                                    .foregroundStyle(palette.textFaint)
                                    .lineLimit(2)
                            }
                        }
                        .padding(14)
                        .background(palette.surface.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(palette.surfaceBorder, lineWidth: 1))
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 24)
        }
        .task { if layers.isEmpty { await loadLayers() } }
    }

    // MARK: - Rows

    private func hitRow(_ name: String, type: String, path: String, summary: String,
                        badge: String, indent: Int = 0) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(palette.textFaint)
                .frame(width: CGFloat(indent) * 10 + 2, height: 1)
                .padding(.top, 9)
                .opacity(indent == 0 ? 0 : 0.5)
            Image(systemName: UnderstandNodeStyle.icon(for: type))
                .font(.system(size: 13))
                .foregroundStyle(UnderstandNodeStyle.color(for: type, palette: palette))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Text(type)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.textFaint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(palette.surface)
                        .clipShape(Capsule())
                }
                if !path.isEmpty {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(palette.textFaint)
                        .lineLimit(1)
                }
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Text(badge)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.textFaint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func emptyResults(_ text: String) -> some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 40)
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(palette.textFaint)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(palette.textFaint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func clearResults() {
        hits = []
        impactHits = []
        trace = nil
        traceNames = []
        canvasGraph = nil
        errorText = nil
        dashboardError = nil
    }

    private func refreshStatus() async {
        status = await socket.codeUnderstandStatus(projectPath: projectPath)
        if let status, status.state.isAnalyzing {
            startPolling()
        }
    }

    /// While the Mac analyzes, poll status so the card flips to ready without
    /// the user doing anything. The Mac also broadcasts code.understand_status,
    /// but polling is simpler and works over any socket state.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                let fresh = await socket.codeUnderstandStatus(projectPath: projectPath)
                guard let fresh else { continue }
                status = fresh
                analyzing = fresh.state.isAnalyzing
                if fresh.state.isReady || fresh.state.isFailure {
                    break
                }
            }
        }
    }

    private func analyze(force: Bool) async {
        guard let status, status.installed else { return }
        analyzing = true
        errorText = nil
        dashboardError = nil
        let state = await socket.codeUnderstandAnalyze(projectPath: projectPath, force: force)
        if let state {
            analyzing = state.state.isAnalyzing
            if state.state.isAnalyzing {
                startPolling()
            } else {
                await refreshStatus()
            }
        } else {
            analyzing = false
            errorText = "Couldn't reach the Mac to start the analysis."
        }
    }

    private func openDashboard() async {
        dashboardError = nil
        let urlString = await socket.codeUnderstandOpen(projectPath: projectPath)
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            dashboardError = "Couldn't start the dashboard — check the Mac (Node.js + network for the first launch)."
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func runModeQuery() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        busy = true
        errorText = nil
        defer { busy = false }

        switch mode {
        case .search:
            hits = await socket.codeUnderstandSearch(projectPath: projectPath, query: trimmed)
            impactHits = []
            trace = nil
        case .impact:
            impactHits = await socket.codeUnderstandImpact(projectPath: projectPath, target: trimmed)
            hits = []
            trace = nil
            canvasGraph = nil
        case .trace:
            let extra = queryExtra.trimmingCharacters(in: .whitespacesAndNewlines)
            if let t = await socket.codeUnderstandTrace(projectPath: projectPath, origin: trimmed, target: extra) {
                trace = t
                traceNames = await resolveTraceNames(t.nodeIDs)
            } else {
                trace = UnderstandTracePayload(nodeIDs: [], edgeTypes: [])
            }
            hits = []
            impactHits = []
        case .explore:
            break
        }
    }

    /// Map trace node ids to display names with one search-free call: ask the
    /// Mac to explain the first few, falling back to the id.
    private func resolveTraceNames(_ ids: [String]) async -> [String] {
        var names: [String] = []
        for id in ids.prefix(12) {
            if let explanation = await socket.codeUnderstandExplain(projectPath: projectPath, nodeID: id) {
                names.append(explanation.node.name)
            } else {
                names.append(id)
            }
        }
        return names
    }

    private func showImpactGraph() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        busy = true
        canvasGraph = await socket.codeUnderstandGraph(projectPath: projectPath, center: trimmed, depth: 1, limit: 60)
        busy = false
    }

    private func loadLayers() async {
        layers = await socket.codeUnderstandArchitecture(projectPath: projectPath)
    }

    private func loadPreview() async {
        busy = true
        canvasGraph = await socket.codeUnderstandPreview(projectPath: projectPath, limit: 60)
        busy = false
    }

    private func showDetail(_ nodeID: String) async {
        detailNode = nil
        detailExplanation = await socket.codeUnderstandExplain(projectPath: projectPath, nodeID: nodeID)
        if let explanation = detailExplanation {
            detailNode = explanation.node
            showDetail = true
        }
    }
}

// MARK: - Node detail

/// A node's record: summary, signature, layers, and its neighbors split into
/// "depends on" / "depended on by".
struct UnderstandNodeDetailView: View {
    let projectPath: String
    let node: UnderstandNodePayload
    let explanation: UnderstandExplainPayload?
    let palette: Palette

    @Environment(\.dismiss) private var dismiss
    @State private var expandedNeighbors = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if let explanation {
                        if !explanation.layers.isEmpty {
                            layerChips(explanation.layers)
                        }
                        neighborsSection(explanation)
                    }
                }
                .padding(16)
            }
            .background(palette.background)
            .navigationTitle("Node")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(palette.accentBright)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: UnderstandNodeStyle.icon(for: node.type))
                    .font(.system(size: 16))
                    .foregroundStyle(UnderstandNodeStyle.color(for: node.type, palette: palette))
                Text(node.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Text(node.type)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textFaint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(palette.surface)
                    .clipShape(Capsule())
            }
            if !node.filePath.isEmpty {
                Text(node.filePath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.textFaint)
            }
            if !node.signature.isEmpty {
                Text(node.signature)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(palette.textSecondary)
                    .padding(10)
                    .background(palette.surface.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if !node.summary.isEmpty {
                Text(node.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func layerChips(_ layers: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LAYERS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.textFaint)
            HStack(spacing: 6) {
                ForEach(layers, id: \.self) { layer in
                    Text(layer)
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(palette.surface)
                        .clipShape(Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func neighborsSection(_ explanation: UnderstandExplainPayload) -> some View {
        let incoming = explanation.neighbors.filter { $0.direction == "in" }
        let outgoing = explanation.neighbors.filter { $0.direction == "out" }
        VStack(alignment: .leading, spacing: 12) {
            neighborList(title: "DEPENDED ON BY (\(incoming.count))", neighbors: incoming)
            neighborList(title: "DEPENDS ON (\(outgoing.count))", neighbors: outgoing)
        }
    }

    private func neighborList(title: String, neighbors: [UnderstandExplainPayload.UnderstandNeighborPayload]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.textFaint)
            if neighbors.isEmpty {
                Text("None")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textFaint)
            } else {
                ForEach(neighbors.prefix(expandedNeighbors ? neighbors.count : 8), id: \.self) { neighbor in
                    HStack(spacing: 8) {
                        Image(systemName: UnderstandNodeStyle.icon(for: neighbor.node.type))
                            .font(.system(size: 11))
                            .foregroundStyle(UnderstandNodeStyle.color(for: neighbor.node.type, palette: palette))
                            .frame(width: 16)
                        Text(neighbor.node.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                        Text(neighbor.type)
                            .font(.system(size: 10))
                            .foregroundStyle(palette.textFaint)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3)
                }
                if neighbors.count > 8 {
                    Button(expandedNeighbors ? "Show less" : "Show all \(neighbors.count)") {
                        expandedNeighbors.toggle()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(palette.accentBright)
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(palette.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Node style

/// Icon + color per node type, monochrome-safe.
enum UnderstandNodeStyle {
    static func icon(for type: String) -> String {
        switch type.lowercased() {
        case "file": return "doc"
        case "function": return "f.square"
        case "class": return "c.square"
        case "module": return "square.stack.3d.up"
        case "concept": return "lightbulb"
        case "config": return "gearshape"
        case "document": return "book"
        case "service": return "server.rack"
        case "table": return "tablecells"
        case "endpoint": return "arrow.up.right.circle"
        case "pipeline": return "point.3.connected.trianglepath.dotted"
        case "schema": return "square.3.layers.3d"
        case "resource": return "cube"
        default: return "circle"
        }
    }

    static func color(for type: String, palette: Palette) -> Color {
        switch type.lowercased() {
        case "file": return palette.accentBright
        case "function": return palette.accent
        case "class": return palette.accentSoft
        case "endpoint", "service", "pipeline", "schema", "table", "resource": return palette.textSecondary
        case "config", "document": return palette.textFaint
        default: return palette.textFaint
        }
    }
}

// MARK: - Button style

struct UnderstandActionButtonStyle: ButtonStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(palette.surface)
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(palette.surfaceBorder, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Canvas

/// A node's layout position plus its radius, computed once per payload.
private struct UnderstandGraphLayoutNode: Identifiable {
    let node: UnderstandNodePayload
    let position: CGPoint
    let radius: CGFloat

    var id: String { node.id }
}

/// The interactive graph: nodes and edges drawn on a Canvas with pan, pinch
/// zoom and click-to-inspect. Layout is a circle by degree (the busiest nodes
/// on top, the focused center dead-center), which reads as "architecture"
/// without a force simulation.
struct UnderstandGraphCanvasView: View {
    let graph: UnderstandGraphPayload
    let palette: Palette
    var onNodeTap: (UnderstandNodePayload) -> Void = { _ in }

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var selectedID: String?
    @State private var lastGraph: UnderstandGraphPayload?
    @State private var layout: [UnderstandGraphLayoutNode] = []
    @State private var edgeLines: [(from: CGPoint, to: CGPoint, type: String)] = []
    @State private var nodePositions: [String: CGPoint] = [:]

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Canvas { context, size in
                    drawEdges(context: &context, size: size, center: center)
                    drawNodes(context: &context, size: size, center: center)
                }
                .contentShape(Rectangle())
                .gesture(magnification)
                .simultaneousGesture(pan)
                .gesture(tapGesture(in: geo.size, center: center))

                // A small reset affordance when the user has wandered.
                if scale != 1 || offset != .zero {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    scale = 1
                                    offset = .zero
                                    selectedID = nil
                                }
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 12))
                                    .foregroundStyle(palette.textSecondary)
                                    .padding(8)
                                    .background(palette.surface.opacity(0.9))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(10)
                }
            }
        }
        .onChange(of: graph) { _, _ in rebuild() }
        .onAppear { rebuild() }
    }

    // MARK: Layout

    /// Compute positions once per payload: the focused node dead-center, the
    /// rest on a circle ordered by degree (busiest first, top of the canvas).
    private func rebuild() {
        layout = []
        edgeLines = []
        nodePositions = [:]
        selectedID = nil

        var degree: [String: Int] = [:]
        for edge in graph.edges {
            degree[edge.source, default: 0] += 1
            degree[edge.target, default: 0] += 1
        }

        let centerID = graph.center
        let rest = graph.nodes
            .filter { $0.id != centerID }
            .sorted { (degree[$0.id, default: 0], $0.type) > (degree[$1.id, default: 0], $1.type) }

        let count = max(rest.count, 1)
        // Radius grows slowly so a crowded graph still separates.
        let radius = CGFloat(min(320, 110 + count * 9))

        var items: [UnderstandGraphLayoutNode] = []
        var positions: [String: CGPoint] = [:]

        if let centerID, let centerNode = graph.nodes.first(where: { $0.id == centerID }) {
            let item = UnderstandGraphLayoutNode(node: centerNode, position: .zero, radius: nodeRadius(centerNode, degree: degree[centerID] ?? 0))
            items.append(item)
            positions[centerID] = .zero
        }

        for (index, node) in rest.enumerated() {
            let angle = -Double.pi / 2 + Double(index) / Double(count) * 2 * Double.pi
            let position = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
            items.append(UnderstandGraphLayoutNode(
                node: node,
                position: position,
                radius: nodeRadius(node, degree: degree[node.id] ?? 0)))
            positions[node.id] = position
        }

        layout = items
        nodePositions = positions
        edgeLines = graph.edges.compactMap { edge in
            guard let from = positions[edge.source], let to = positions[edge.target] else { return nil }
            return (from, to, edge.type)
        }
    }

    /// Files are the big anchors; functions are small dots; the rest in between.
    private func nodeRadius(_ node: UnderstandNodePayload, degree: Int) -> CGFloat {
        let base: CGFloat
        switch node.type.lowercased() {
        case "file": base = 16
        case "class": base = 13
        case "function": base = 10
        default: base = 12
        }
        return base + min(4, CGFloat(max(0, degree)) * 0.15)
    }

    // MARK: Drawing

    private func drawEdges(context: inout GraphicsContext, size: CGSize, center: CGPoint) {
        for edge in edgeLines {
            let from = transformed(edge.from, size: size, center: center)
            let to = transformed(edge.to, size: size, center: center)
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            context.stroke(path, with: .color(palette.surfaceBorder.opacity(0.55)), lineWidth: 1)
        }
        // Highlighted edges of the selected node, drawn on top with labels.
        guard let selectedID, let selectedPosition = nodePositions[selectedID] else { return }
        let fromCenter = transformed(selectedPosition, size: size, center: center)
        for edge in graph.edges where edge.source == selectedID || edge.target == selectedID {
            let otherID = edge.source == selectedID ? edge.target : edge.source
            guard let otherPosition = nodePositions[otherID] else { continue }
            let to = transformed(otherPosition, size: size, center: center)
            var path = Path()
            path.move(to: fromCenter)
            path.addLine(to: to)
            context.stroke(path, with: .color(palette.accent.opacity(0.9)), lineWidth: 1.5)
            let mid = CGPoint(x: (fromCenter.x + to.x) / 2, y: (fromCenter.y + to.y) / 2 - 6)
            context.draw(Text(edge.type)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(palette.textSecondary),
                at: mid)
        }
    }

    private func drawNodes(context: inout GraphicsContext, size: CGSize, center: CGPoint) {
        for item in layout {
            let point = transformed(item.position, size: size, center: center)
            let isSelected = item.node.id == selectedID
            let radius = item.radius * (isSelected ? 1.25 : 1)

            let color = UnderstandNodeStyle.color(for: item.node.type, palette: palette)
            context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                width: radius * 2, height: radius * 2)),
                         with: .color(color.opacity(isSelected ? 0.95 : 0.75)))
            context.stroke(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                           with: .color(palette.backgroundTop.opacity(0.8)), lineWidth: 1)

            // Label only the anchors (files/classes) and the selected node.
            let isAnchor = item.node.type.lowercased() == "file"
                || item.node.type.lowercased() == "class"
            if isAnchor || isSelected {
                context.draw(Text(item.node.name)
                    .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(palette.textSecondary),
                    at: CGPoint(x: point.x, y: point.y + radius + 9))
            }
        }
    }

    /// Graph space → canvas space.
    private func transformed(_ point: CGPoint, size: CGSize, center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + offset.width + point.x * scale,
                y: center.y + offset.height + point.y * scale)
    }

    /// Canvas space → graph space (inverse of transformed).
    private func untransformed(_ point: CGPoint, size: CGSize, center: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - center.x - offset.width) / scale,
                y: (point.y - center.y - offset.height) / scale)
    }

    // MARK: Gestures

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = max(0.4, min(4, value.magnification))
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = value.translation
            }
    }

    private func tapGesture(in size: CGSize, center: CGPoint) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let graphPoint = untransformed(value.location, size: size, center: center)
                guard let hit = layout
                    .map({ ($0, hypot($0.position.x - graphPoint.x, $0.position.y - graphPoint.y)) })
                    .filter({ $0.1 <= max(24, $0.0.radius + 6) })
                    .min(by: { $0.1 < $1.1 })
                else {
                    selectedID = nil
                    return
                }
                selectedID = hit.0.node.id
                onNodeTap(hit.0.node)
            }
    }
}
