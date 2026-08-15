import Foundation
import Network

// MARK: - Understand-Anything (interactive knowledge graph)
//
// Understand-Anything (Egonex-AI/Understand-Anything) turns a codebase into an
// interactive knowledge graph — every file, function and class is a node,
// imports/calls/dependencies are edges, plus architectural layers and a guided
// tour. It ships an interactive web dashboard (pan/zoom/click/export) that the
// tool's own viewer serves locally from `.ua/knowledge-graph.json`.
//
// Alfred integrates it the same way CodeGraph is integrated, but for humans:
// the phone gets visual answers (a graph you can click through) instead of
// token-optimized payloads for an agent. The manager owns:
//
//   1. Discovery. The plugin lives at ~/.understand-anything/repo (the
//      installer's clone) or the universal ~/.understand-anything-plugin
//      symlink; the data dir is `.ua/` (or legacy `.understand-anything/`).
//
//   2. Analysis. Building the graph runs the official `/understand` pipeline
//      (tree-sitter + LLM agents), which is a Claude-Code-style skill — so
//      Alfred drives it through the coding agent it already spawns (see
//      AlfredCodeManager.startSession). The session shows up in the Code tab
//      and streams progress; this manager polls for the finished
//      knowledge-graph.json and broadcasts code.understand_status.
//
//   3. Local queries. Once the graph exists, search / impact / explain /
//      architecture / trace all read knowledge-graph.json directly on the Mac
//      — deterministic, instant, no agent, no tokens. These back both the
//      phone's Knowledge Graph sheet and the understand_* MCP tools Hermes
//      gets.
//
//   4. The dashboard. `openDashboard` starts the standalone viewer
//      (`npx …/understand-anything-viewer.tgz`, which serves the full
//      interactive dashboard read-only from disk) and — because the viewer
//      binds 127.0.0.1 — a tiny TCP proxy on the LAN so the phone can open
//      the same URL.
//
// Everything degrades gracefully: plugin missing, no node, an unanalyzed
// project, a viewer that won't start → the phone gets an honest state, never
// a crash.

// MARK: - Graph models
//
// The wire shape of `.ua/knowledge-graph.json` (schema 1.0.0). Decoding is
// deliberately tolerant: the pipeline's real graphs carry a few extra fields
// (signature, line numbers, languageNotes) that are optional here, and a graph
// that's missing layers/tour (deterministic-only runs) still parses.

/// A node: a file, function, class, config, document, endpoint, …
struct UnderstandNode: Codable, Equatable, Identifiable {
    var id: String
    var type: String
    var name: String
    var filePath: String?
    var summary: String?
    var tags: [String]?
    var complexity: String?
    var signature: String?
    var startLine: Int?
    var endLine: Int?
    var languageNotes: String?

    /// Short display name: the function/class name, or the file's last path
    /// component for file-level nodes.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let filePath, !filePath.isEmpty {
            return (filePath as NSString).lastPathComponent
        }
        return id
    }

    /// The node's human category, for badges and canvas coloring.
    var category: UnderstandNodeCategory {
        UnderstandNodeCategory(rawValue: type)
    }
}

/// The 13 node types the schema defines, grouped for display and canvas color.
enum UnderstandNodeCategory: String {
    case file, function, `class`, module, concept, config, document
    case service, table, endpoint, pipeline, schema, resource
    case other

    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "file": self = .file
        case "function": self = .function
        case "class": self = .class
        case "module": self = .module
        case "concept": self = .concept
        case "config": self = .config
        case "document": self = .document
        case "service": self = .service
        case "table": self = .table
        case "endpoint": self = .endpoint
        case "pipeline": self = .pipeline
        case "schema": self = .schema
        case "resource": self = .resource
        default: self = .other
        }
    }

    /// Nodes worth searching and showing first in symbol lists.
    var isCodeSymbol: Bool {
        switch self {
        case .file, .function, .class, .module, .endpoint, .service, .pipeline, .schema, .table, .resource, .concept:
            return true
        case .config, .document, .other:
            return false
        }
    }
}

/// An edge between two nodes: imports, calls, depends_on, contains, …
struct UnderstandEdge: Codable, Equatable, Identifiable {
    var source: String
    var target: String
    var type: String
    var weight: Double?

    var id: String { "\(source) → \(target) [\(type)]" }
}

/// An architectural layer (Phase 4 of the pipeline): a named group of nodes.
struct UnderstandLayer: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var description: String?
    var nodeIds: [String]
}

/// A guided-tour step (Phase 5): an ordered walk through key nodes.
struct UnderstandTourStep: Codable, Equatable {
    var order: Int
    var title: String
    var description: String?
    var nodeIds: [String]
    var languageLesson: String?
}

/// The whole knowledge graph. `project` holds the pipeline's metadata.
struct UnderstandGraph: Codable, Equatable {
    var version: String?
    var project: UnderstandGraphProject?
    var nodes: [UnderstandNode]
    var edges: [UnderstandEdge]
    var layers: [UnderstandLayer]?
    var tour: [UnderstandTourStep]?

    struct UnderstandGraphProject: Codable, Equatable {
        var name: String?
        var languages: [String]?
        var frameworks: [String]?
        var description: String?
        var analyzedAt: String?
        var gitCommitHash: String?
    }
}

// The tolerant decoder lives in an extension so the memberwise initializer
// stays available for the subgraph builders (neighborhood/graphPreview).
extension UnderstandGraph {
    private enum CodingKeys: String, CodingKey {
        case version, project, nodes, edges, layers, tour
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        project = try c.decodeIfPresent(UnderstandGraphProject.self, forKey: .project)
        nodes = try c.decodeIfPresent([UnderstandNode].self, forKey: .nodes) ?? []
        edges = try c.decodeIfPresent([UnderstandEdge].self, forKey: .edges) ?? []
        layers = try c.decodeIfPresent([UnderstandLayer].self, forKey: .layers)
        tour = try c.decodeIfPresent([UnderstandTourStep].self, forKey: .tour)
    }
}

// MARK: - Query results
//
// Small Codable shapes the socket server serializes straight to the phone and
// the MCP tools render as text.

/// One search hit, with a relevance score (higher is better).
struct UnderstandHit: Codable, Equatable {
    var id: String
    var name: String
    var type: String
    var filePath: String?
    var summary: String?
    var tags: [String]?
    var score: Int
}

/// One dependent found by impact analysis: the node plus how deep it sits
/// below the changed target (0 = direct) and the node-id chain back to it.
struct UnderstandImpactHit: Codable, Equatable {
    var id: String
    var name: String
    var type: String
    var filePath: String?
    var summary: String?
    var depth: Int
    var path: [String]
}

/// A trace path: ordered nodes plus the edge types between consecutive ones.
struct UnderstandTrace: Codable, Equatable {
    var nodeIDs: [String]
    var edgeTypes: [String]
}

/// A node's explanation: the node, its direct neighbors (with edge types), and
/// the layers it belongs to.
struct UnderstandExplanation: Codable, Equatable {
    var node: UnderstandNode
    var neighbors: [UnderstandNeighbor]
    var layers: [String]

    struct UnderstandNeighbor: Codable, Equatable {
        var direction: String      // "in" | "out"
        var type: String           // the edge type
        var node: UnderstandNode
    }
}

/// A layer summary for the architecture view.
struct UnderstandLayerSummary: Codable, Equatable {
    var id: String
    var name: String
    var description: String?
    var nodeCount: Int
    var sampleNodes: [String]
}

// MARK: - Manager

@MainActor
final class UnderstandAnythingManager {

    static let shared = UnderstandAnythingManager()

    // MARK: Persisted settings

    private let enabledKey = "alfred.understandEnabled"
    private let indexOnLoadKey = "alfred.understandIndexOnLoad"

    /// Master switch. Off means no analysis sessions, no MCP tools and no
    /// dashboard — code sessions run exactly as before. Defaults ON.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Analyze a project automatically when a code session starts there.
    /// Defaults OFF: the full `/understand` pipeline runs LLM agents and burns
    /// tokens, so it's opt-in per project (or via the routine / phone button).
    var indexOnLoad: Bool {
        UserDefaults.standard.object(forKey: indexOnLoadKey) as? Bool ?? false
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }

    func setIndexOnLoad(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: indexOnLoadKey)
    }

    // MARK: Discovery

    /// The plugin root (a directory with package.json + pnpm-workspace.yaml),
    /// or nil if Understand-Anything isn't installed. The installer always
    /// creates the universal symlink, so checking that + the clone paths
    /// covers every install style the skill itself supports.
    private(set) var pluginRoot: String?
    private var didProbePlugin = false

    func refreshPlugin() {
        pluginRoot = Self.resolvePluginRoot()
        didProbePlugin = true
    }

    /// True when the plugin checkout is present anywhere Alfred knows about.
    /// The graph queries don't need it (they read the JSON), but analysis
    /// (via the agent's skill) and the dashboard tooling do.
    var isInstalled: Bool {
        if !didProbePlugin { refreshPlugin() }
        return pluginRoot != nil
    }

    /// The `node` binary used to run the standalone viewer. Node >= 18 is the
    /// viewer's only requirement.
    private(set) var nodePath: String?
    private var didProbeNode = false
    private(set) var npxPath: String?
    private var didProbeNpx = false

    func refreshNode() {
        nodePath = Self.resolveNode()
        npxPath = Self.resolveNpx(nodePath: nodePath)
        didProbeNode = true
        didProbeNpx = true
    }

    var nodeAvailable: Bool {
        if !didProbeNode { refreshNode() }
        return nodePath != nil
    }

    var npxAvailable: Bool {
        if !didProbeNpx { refreshNode() }
        return npxPath != nil
    }

    /// The full integration (plugin + node) — what the phone's status shows
    /// as "installed".
    var isAvailable: Bool { isInstalled && nodeAvailable }

    nonisolated static func resolvePluginRoot() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.understand-anything-plugin",                       // universal symlink
            "\(home)/.understand-anything/repo/understand-anything-plugin", // installer clone
            "\(home)/understand-anything/understand-anything-plugin",    // manual clone (skill's list)
            "\(home)/.codex/understand-anything/understand-anything-plugin",
            "\(home)/.opencode/understand-anything/understand-anything-plugin",
        ]
        for path in candidates where Self.isPluginRoot(path) {
            return path
        }
        return nil
    }

    /// A candidate is a plugin root when it has the workspace markers the
    /// skill's own pre-flight checks for.
    nonisolated static func isPluginRoot(_ path: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: (path as NSString).appendingPathComponent("package.json"))
            && fm.fileExists(atPath: (path as NSString).appendingPathComponent("pnpm-workspace.yaml"))
    }

    nonisolated static func resolveNode() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "\(home)/.local/bin/node",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        guard let output = runCapture(
            executable: "/bin/zsh",
            arguments: ["-lc", "command -v node"],
            directory: nil,
            timeout: 5),
            let line = output.split(separator: "\n").first
        else { return nil }
        let path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// `npx` normally lives next to node; a GUI launch's PATH may not include
    /// it, so resolve it explicitly (Process can't be handed "npx" as a bare
    /// name — the executable must be a real path).
    nonisolated static func resolveNpx(nodePath: String?) -> String? {
        if let nodePath {
            let sibling = ((nodePath as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("npx")
            if FileManager.default.isExecutableFile(atPath: sibling) {
                return sibling
            }
        }
        guard let output = runCapture(
            executable: "/bin/zsh",
            arguments: ["-lc", "command -v npx"],
            directory: nil,
            timeout: 5),
            let line = output.split(separator: "\n").first
        else { return nil }
        let path = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    // MARK: Per-project state

    /// Where a project's knowledge graph stands. Cached so the phone's status
    /// calls are instant after the first real check.
    enum GraphState: Equatable {
        case notInstalled      // plugin (or node) missing
        case notAnalyzed       // no .ua/ graph yet
        case analyzing         // agent pipeline in flight
        case ready(nodeCount: Int, edgeCount: Int, layerCount: Int)
        case failed(String)    // analysis ran but produced no usable graph

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var isAnalyzing: Bool {
            if case .analyzing = self { return true }
            return false
        }
    }

    /// Broadcast hooks, wired by the app to push `code.understand_status` to
    /// phones when a background analysis finishes (or fails).
    var onStateChange: ((String, GraphState) -> Void)?

    private var states: [String: GraphState] = [:]

    func graphState(projectPath: String) -> GraphState {
        states[projectPath] ?? .notAnalyzed
    }

    // MARK: Data directory

    /// `.ua/`, or the legacy `.understand-anything/` when it already exists —
    /// the pipeline keeps using whatever a project already has.
    static func dataDirectory(for projectPath: String) -> String {
        let fm = FileManager.default
        let legacy = (projectPath as NSString).appendingPathComponent(".understand-anything")
        if fm.fileExists(atPath: legacy) { return legacy }
        return (projectPath as NSString).appendingPathComponent(".ua")
    }

    /// The knowledge graph file for a project, or nil when absent.
    static func graphFile(for projectPath: String) -> String? {
        let file = (Self.dataDirectory(for: projectPath) as NSString).appendingPathComponent("knowledge-graph.json")
        return FileManager.default.fileExists(atPath: file) ? file : nil
    }

    // MARK: Index lifecycle

    /// Make sure a project has a usable graph, returning its state. Unlike
    /// CodeGraph's ensureIndexed this never *starts* an analysis by itself —
    /// the `/understand` pipeline runs LLM agents and costs tokens, so it's
    /// always triggered explicitly (phone button, routine, or the
    /// analyze-on-load setting). Use `analyze` for that.
    ///
    /// Reading a graph deliberately doesn't require the plugin to be
    /// installed: a project with a committed `.ua/` (the tool's recommended
    /// docs-as-code pattern) is fully queryable without it — the plugin is
    /// only needed to *build* the graph.
    func ensureAnalyzed(projectPath: String) async -> GraphState {
        guard isEnabled else { return .notAnalyzed }
        let expanded = (projectPath as NSString).expandingTildeInPath

        if let graph = await loadGraph(projectPath: expanded) {
            let state = Self.readyState(for: graph)
            states[expanded] = state
            return state
        }
        states[expanded] = .notAnalyzed
        return .notAnalyzed
    }

    /// Start (or re-run) an analysis of a project. The pipeline is driven by
    /// the coding agent — the session appears in the Code tab and streams
    /// progress — and this manager watches for the finished graph, updating
    /// the cached state and broadcasting code.understand_status. Never throws;
    /// failures land in `.failed` with a readable reason.
    @discardableResult
    func analyze(projectPath: String, force: Bool = false) async -> GraphState {
        guard isEnabled else { return .notAnalyzed }
        guard isInstalled else { return .notInstalled }
        guard nodeAvailable else { return .failed("Node.js isn't installed on the Mac — the analysis pipeline needs it.") }
        let expanded = (projectPath as NSString).expandingTildeInPath

        // A forced re-run must actually rebuild: the pipeline decides
        // incrementally when the graph exists, so move it out of the way and
        // let the agent do a full pass.
        let graphFile = Self.graphFile(for: expanded)
        if force, let graphFile {
            try? FileManager.default.removeItem(atPath: graphFile)
        }

        states[expanded] = .analyzing
        onStateChange?(expanded, .analyzing)
        NSLog("[understand] analyzing %@…", expanded)

        let prompt = Self.understandPrompt(projectPath: expanded, full: force)
        let session = try? await AlfredCodeManager.shared.startSession(
            prompt: prompt, projectPath: expanded, agent: .opencode)
        guard let session else {
            let state = GraphState.failed("Couldn't start the analysis agent.")
            states[expanded] = state
            onStateChange?(expanded, state)
            return state
        }

        // Watch for the finished graph. The session runs for minutes on a big
        // project, so poll in the background and never block the caller.
        let state = await waitForGraph(projectPath: expanded, sessionID: session.sessionId)
        states[expanded] = state
        onStateChange?(expanded, state)
        return state
    }

    /// Poll for the graph to appear (up to 30 minutes — a big first analysis
    /// can take a while), reading the session's status to distinguish "still
    /// working" from "gave up".
    private func waitForGraph(projectPath: String, sessionID: UUID, timeout: TimeInterval = 1800) async -> GraphState {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if let graph = await loadGraph(projectPath: projectPath) {
                NSLog("[understand] graph ready for %@ (%d nodes, %d edges)", projectPath,
                      graph.nodes.count, graph.edges.count)
                return Self.readyState(for: graph)
            }
            // The session ended without producing a graph — that's a failure,
            // not "keep waiting".
            if let session = AlfredCodeManager.shared.session(id: sessionID) {
                if session.status == .error {
                    return .failed("The analysis agent reported an error. Open the session in the Code tab to see what happened.")
                }
                if session.status == .completed {
                    return .failed("The analysis finished but produced no graph. The Understand-Anything skill may not be installed for the coding agent (install it with: curl -fsSL https://raw.githubusercontent.com/Egonex-AI/Understand-Anything/main/install.sh | bash -s hermes).")
                }
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        return .failed("Analysis timed out after \(Int(timeout / 60)) minutes.")
    }

    private static func readyState(for graph: UnderstandGraph) -> GraphState {
        .ready(nodeCount: graph.nodes.count,
               edgeCount: graph.edges.count,
               layerCount: graph.layers?.count ?? 0)
    }

    /// The prompt that drives the official `/understand` pipeline through the
    /// coding agent. The skill is a platform skill; the agent resolves it the
    /// same way Claude Code would (skill dirs for its platform), and degrades
    /// honestly when it isn't installed.
    static func understandPrompt(projectPath: String, full: Bool) -> String {
        """
        Run the Understand-Anything skill (/understand) on the project at \(projectPath) \
        to build its interactive knowledge graph.

        The skill produces \(projectPath)/.ua/knowledge-graph.json (or .understand-anything/ \
        if that directory already exists), plus config.json, intermediate/, meta.json. \
        Use \(full ? "--full" : "") so it does \(full ? "a full rebuild" : "an incremental update") \
        — the defaults are fine if it needs to detect the language first.

        When the graph is written, report the skill's summary line: project name, files \
        analyzed, nodes and edges created, and the layers identified. If the skill \
        (/understand) is not available to you, STOP and report exactly: \
        "The Understand-Anything skill isn't installed for this agent." — do not try to \
        build the graph by hand.

        This analysis belongs to the project at \(projectPath). Work only inside that directory.
        """
    }

    // MARK: - Graph loading

    /// Load and cache the latest graph for a project. `cache` is keyed by
    /// graph-file mtime so a re-analysis (new file) is picked up, but repeated
    /// status checks inside a second don't re-decode a big JSON.
    private var graphCache: [String: (mtime: TimeInterval, graph: UnderstandGraph)] = [:]

    private func loadGraph(projectPath: String) async -> UnderstandGraph? {
        guard let file = Self.graphFile(for: projectPath) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: file)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if let cached = graphCache[file], abs(cached.mtime - mtime) < 1 {
            return cached.graph
        }
        // Decode off the main actor — graphs can be several MB.
        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: URL(fileURLWithPath: file))
        }.value
        guard let data else { return nil }
        let graph = try? JSONDecoder().decode(UnderstandGraph.self, from: data)
        if let graph {
            graphCache[file] = (mtime, graph)
        }
        return graph
    }

    /// The loaded knowledge graph for a project, or nil when there isn't one
    /// (or it can't be parsed). Public for the routines and tests.
    func graph(projectPath: String) async -> UnderstandGraph? {
        await loadGraph(projectPath: (projectPath as NSString).expandingTildeInPath)
    }

    // MARK: - Status

    /// A project's graph status for the phone: state, counts, and a one-line
    /// human reading. Never throws — a missing plugin or an unanalyzed project
    /// are states, not errors.
    func status(projectPath: String) async -> (
        state: GraphState, available: Bool, installed: Bool, text: String) {
        let expanded = (projectPath as NSString).expandingTildeInPath
        let state = await ensureAnalyzed(projectPath: expanded)

        let text: String
        switch state {
        case .notInstalled:
            text = "Understand-Anything isn't installed on the Mac. Install it with: curl -fsSL https://raw.githubusercontent.com/Egonex-AI/Understand-Anything/main/install.sh | bash"
        case .notAnalyzed:
            text = "This project hasn't been analyzed yet — tap Analyze to build its knowledge graph."
        case .analyzing:
            text = "Analyzing project… the graph builds in the Code tab."
        case .ready(let nodes, let edges, let layers):
            text = "\(nodes) nodes · \(edges) edges · \(layers) layer\(layers == 1 ? "" : "s") — click through the graph to explore"
        case .failed(let message):
            text = message
        }
        return (state, isAvailable, isInstalled, text)
    }

    // MARK: - Queries (deterministic, local)

    /// The edge types that count as "depends on" for impact analysis. The
    /// schema's semantic/behavioral edges are the interesting ones; `contains`
    /// (file → child) is included but handled specially because it's
    /// structural, and `tested_by` has its own direction rule (see
    /// directDependents).
    private static let dependencyEdgeTypes: Set<String> = [
        "imports", "calls", "depends_on", "inherits", "implements", "contains",
        "reads_from", "writes_to", "transforms", "validates",
        "configures", "serves", "deploys", "triggers", "migrates",
        "routes", "defines_schema", "subscribes", "publishes", "middleware",
        "documents", "related", "similar_to",
    ]

    /// Search the graph: name first, then summary/tags/path. Pure local fuzzy
    /// scoring — no model, no embeddings, instant on any graph size.
    func search(query: String, projectPath: String, limit: Int = 25) async -> [UnderstandHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let graph = await loadGraph(projectPath: projectPath) else { return [] }
        let terms = trimmed.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)

        var hits: [UnderstandHit] = []
        for node in graph.nodes {
            let name = node.name.lowercased()
            let file = (node.filePath ?? "").lowercased()
            let summary = (node.summary ?? "").lowercased()
            let tags = (node.tags ?? []).map { $0.lowercased() }

            var score = 0
            // Whole-name equality is the strongest signal.
            if name == trimmed.lowercased() { score = 100 }
            else if name.hasPrefix(trimmed.lowercased()) { score = 90 }
            else if name.contains(trimmed.lowercased()) { score = 80 }
            else if file.contains(trimmed.lowercased()) { score = 70 }
            else if tags.contains(where: { $0.contains(trimmed.lowercased()) }) { score = 55 }
            else if summary.contains(trimmed.lowercased()) { score = 45 }
            else {
                // All query terms must appear somewhere in the node's text.
                let haystack = "\(name) \(file) \(summary) \(tags.joined(separator: " "))"
                if terms.allSatisfy({ haystack.contains($0) }) { score = 40 }
            }
            // A short query matching a long name is weaker than one matching a
            // distinctive name.
            if score > 0 && name.count > trimmed.count * 3 { score -= 10 }

            guard score >= 30 else { continue }
            // Prefer code symbols over config/docs when scores tie.
            if node.category.isCodeSymbol { score += 5 }
            hits.append(UnderstandHit(
                id: node.id, name: node.displayName, type: node.type,
                filePath: node.filePath, summary: node.summary,
                tags: node.tags, score: score))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Impact analysis: everything that breaks (transitively) if `target`
    /// changes. `target` may be a node id or a symbol name; multiple matches
    /// are all analyzed and merged.
    func impact(of target: String, projectPath: String, maxDepth: Int = 4, limit: Int = 120) async -> [UnderstandImpactHit] {
        guard let graph = await loadGraph(projectPath: projectPath) else { return [] }
        let centers = resolveNodes(named: target, in: graph)
        guard !centers.isEmpty else { return [] }

        // Depth 0 = depends on the target directly; each hop adds 1.
        let dependents = directDependents(of: centers, in: graph)
        var visited: Set<String> = centers
        var results: [UnderstandImpactHit] = []
        var frontier = dependents.map { ($0, 0, [$0]) }   // (id, depth, path from target)
        var guardCount = 0

        while !frontier.isEmpty, guardCount < 5000 {
            guardCount += 1
            let (id, depth, path) = frontier.removeFirst()
            guard visited.insert(id).inserted else { continue }
            if let node = graph.nodes.first(where: { $0.id == id }) {
                results.append(UnderstandImpactHit(
                    id: node.id, name: node.displayName, type: node.type,
                    filePath: node.filePath, summary: node.summary,
                    depth: depth, path: path))
                if results.count >= limit { break }
            }
            guard depth < maxDepth else { continue }
            for next in directDependents(of: [id], in: graph) where !visited.contains(next) {
                frontier.append((next, depth + 1, path + [next]))
            }
        }
        return results.sorted { $0.depth != $1.depth ? $0.depth < $1.depth : $0.name < $1.name }
    }

    /// Nodes whose change breaks `centers`, one hop. Direction rules:
    ///   * most edges (imports, calls, depends_on, …): source depends on
    ///     target, so "A imports X" ⇒ A breaks when X changes.
    ///   * contains (file → child): the *file* is the dependent of a changed
    ///     function/class (it no longer compiles).
    ///   * tested_by (prod → test): the *test* breaks when the prod code
    ///     changes.
    private func directDependents(of centers: Set<String>, in graph: UnderstandGraph) -> [String] {
        var out: [String] = []
        for edge in graph.edges {
            let type = edge.type.lowercased()
            if type == "tested_by" {
                if centers.contains(edge.source) { out.append(edge.target) }
                continue
            }
            guard Self.dependencyEdgeTypes.contains(type) else { continue }
            if type == "contains" {
                if centers.contains(edge.target) { out.append(edge.source) }
                continue
            }
            if centers.contains(edge.target) { out.append(edge.source) }
        }
        return Array(Set(out)).sorted()
    }

    /// Resolve a free-form target (id, or a symbol/file name) to node ids.
    /// Exact id wins; then exact/prefix name matches, preferring code symbols.
    private func resolveNodes(named target: String, in graph: UnderstandGraph) -> Set<String> {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if graph.nodes.contains(where: { $0.id == trimmed }) { return [trimmed] }

        let lower = trimmed.lowercased()
        var exact: [String] = []
        var prefix: [String] = []
        var contains: [String] = []
        for node in graph.nodes {
            let name = node.name.lowercased()
            if name == lower { exact.append(node.id) }
            else if name.hasPrefix(lower) { prefix.append(node.id) }
            else if name.contains(lower) { contains.append(node.id) }
        }
        let ranked = exact.isEmpty ? (prefix.isEmpty ? contains : prefix) : exact
        // Prefer code symbols over config/docs noise, keep at most 12.
        let symbols = ranked.filter { id in
            graph.nodes.first(where: { $0.id == id })?.category.isCodeSymbol == true
        }
        return Set(Array((symbols.isEmpty ? ranked : symbols).prefix(12)))
    }

    /// Explain one node: its own record, direct neighbors with edge types, and
    /// the layers it belongs to.
    func explain(nodeID: String, projectPath: String) async -> UnderstandExplanation? {
        guard let graph = await loadGraph(projectPath: projectPath),
              let node = graph.nodes.first(where: { $0.id == nodeID })
        else { return nil }

        var neighbors: [UnderstandExplanation.UnderstandNeighbor] = []
        for edge in graph.edges {
            if edge.source == nodeID, let target = graph.nodes.first(where: { $0.id == edge.target }) {
                neighbors.append(.init(direction: "out", type: edge.type, node: target))
            } else if edge.target == nodeID, let source = graph.nodes.first(where: { $0.id == edge.source }) {
                neighbors.append(.init(direction: "in", type: edge.type, node: source))
            }
        }
        neighbors.sort { $0.node.displayName < $1.node.displayName }

        let layerNames = (graph.layers ?? [])
            .filter { $0.nodeIds.contains(nodeID) }
            .map(\.name)
        return UnderstandExplanation(node: node, neighbors: neighbors, layers: layerNames)
    }

    /// Architecture: the pipeline's layers when present, else a fallback group
    /// by top-level directory so an analyzed project always has a picture.
    func architecture(projectPath: String) async -> [UnderstandLayerSummary] {
        guard let graph = await loadGraph(projectPath: projectPath) else { return [] }

        if let layers = graph.layers, !layers.isEmpty {
            return layers.map { layer in
                UnderstandLayerSummary(
                    id: layer.id,
                    name: layer.name,
                    description: layer.description,
                    nodeCount: layer.nodeIds.count,
                    sampleNodes: layer.nodeIds.prefix(5).compactMap { id in
                        graph.nodes.first(where: { $0.id == id })?.displayName
                    })
            }.sorted { $0.nodeCount > $1.nodeCount }
        }

        // Fallback: group file-level nodes by their top-level directory.
        var groups: [String: [String]] = [:]
        for node in graph.nodes where node.filePath != nil {
            let path = node.filePath!
            let parts = path.split(separator: "/")
            let key = parts.count > 1 ? String(parts[0]) : "/"
            groups[key, default: []].append(node.id)
        }
        return groups
            .map { key, ids in
                UnderstandLayerSummary(
                    id: "dir:\(key)",
                    name: key == "/" ? "Root" : key,
                    description: nil,
                    nodeCount: ids.count,
                    sampleNodes: ids.prefix(5).compactMap { id in
                        graph.nodes.first(where: { $0.id == id })?.displayName
                    })
            }
            .sorted { $0.nodeCount > $1.nodeCount }
    }

    /// A path between two nodes (by id or name), following calls/imports/
    /// depends_on forward. With no explicit target, walks *backward* from the
    /// origin along the same edges to a root — "where does this come from?"
    /// trace.
    func trace(from origin: String, to target: String?, projectPath: String) async -> UnderstandTrace? {
        guard let graph = await loadGraph(projectPath: projectPath) else { return nil }
        let starts = resolveNodes(named: origin, in: graph)
        guard let start = starts.first else { return nil }

        let forwardTypes: Set<String> = ["calls", "imports", "depends_on", "inherits", "implements", "reads_from", "writes_to"]

        if let target, !target.isEmpty {
            guard let end = resolveNodes(named: target, in: graph).first else { return nil }
            // BFS over forward edges.
            var queue: [(String, [String], [String])] = [(start, [start], [])]
            var visited: Set<String> = [start]
            while !queue.isEmpty {
                let (current, nodes, types) = queue.removeFirst()
                if current == end {
                    return UnderstandTrace(nodeIDs: nodes, edgeTypes: types)
                }
                for edge in graph.edges where edge.source == current && forwardTypes.contains(edge.type.lowercased()) {
                    guard visited.insert(edge.target).inserted else { continue }
                    queue.append((edge.target, nodes + [edge.target], types + [edge.type]))
                }
            }
            return nil
        }

        // Backward walk: from `start`, keep moving to the caller/importer with
        // the most incoming edges until there is none (a root) or we loop.
        var chain: [String] = [start]
        var seen: Set<String> = [start]
        var current = start
        while true {
            var candidates: [String] = []
            for edge in graph.edges where edge.target == current && forwardTypes.contains(edge.type.lowercased()) {
                candidates.append(edge.source)
            }
            // Prefer the file node when we're at a function (its containing
            // file is the natural "one level up").
            let next = candidates
                .filter { !seen.contains($0) }
                .max { a, b in
                    let da = degree(of: a, in: graph)
                    let db = degree(of: b, in: graph)
                    return da < db
                }
            guard let next else { break }
            chain.append(next)
            seen.insert(next)
            current = next
        }
        return UnderstandTrace(nodeIDs: chain, edgeTypes: Array(repeating: "calls", count: chain.count - 1))
    }

    /// A bounded subgraph around `center` (for the phone's canvas): BFS over
    /// all edge types up to `depth`, capped at `limit` nodes.
    func neighborhood(around center: String, projectPath: String, depth: Int = 1, limit: Int = 60) async -> UnderstandGraph? {
        guard let graph = await loadGraph(projectPath: projectPath),
              let start = resolveNodes(named: center, in: graph).first
        else { return nil }

        var included: Set<String> = [start]
        var frontier: Set<String> = [start]
        var level = 0
        while level < max(1, min(depth, 3)), included.count < limit {
            var next: Set<String> = []
            for id in frontier {
                for edge in graph.edges where edge.source == id || edge.target == id {
                    let other = edge.source == id ? edge.target : edge.source
                    if !included.contains(other), included.count + next.count < limit {
                        next.insert(other)
                    }
                }
            }
            guard !next.isEmpty else { break }
            included.formUnion(next)
            frontier = next
            level += 1
        }

        let nodes = graph.nodes.filter { included.contains($0.id) }
        let edges = graph.edges.filter { included.contains($0.source) && included.contains($0.target) }
        return UnderstandGraph(version: graph.version, project: graph.project,
                               nodes: nodes, edges: edges, layers: nil, tour: nil)
    }

    /// The whole project at a glance for the canvas: the highest-degree nodes
    /// plus the edges between them. One request, instant, gives the
    /// architecture picture without shipping the whole JSON to the phone.
    func graphPreview(projectPath: String, limit: Int = 60) async -> UnderstandGraph? {
        guard let graph = await loadGraph(projectPath: projectPath), !graph.nodes.isEmpty else { return nil }

        var degree: [String: Int] = [:]
        for edge in graph.edges {
            degree[edge.source, default: 0] += 1
            degree[edge.target, default: 0] += 1
        }
        // Keep file-level nodes (they're the picture's backbones) and let the
        // highest-degree symbols ride along.
        let ranked = graph.nodes
            .sorted { (degree[$0.id, default: 0], $0.category.isCodeSymbol ? 1 : 0) >
                      (degree[$1.id, default: 0], $1.category.isCodeSymbol ? 1 : 0) }
            .prefix(limit)
        let ids = Set(ranked.map(\.id))
        let edges = graph.edges.filter { ids.contains($0.source) && ids.contains($0.target) }
        return UnderstandGraph(version: graph.version, project: graph.project,
                               nodes: Array(ranked), edges: edges, layers: nil, tour: nil)
    }

    private func degree(of id: String, in graph: UnderstandGraph) -> Int {
        graph.edges.reduce(0) { $0 + (($1.source == id || $1.target == id) ? 1 : 0) }
    }

    // MARK: - Dashboard (viewer + LAN proxy)

    private var viewerProcesses: [String: Process] = [:]
    private var viewerURLs: [String: String] = [:]
    private var proxyListeners: [String: NWListener] = [:]
    private var proxyPorts: [String: Int] = [:]

    /// Start the interactive dashboard for a project and return a URL the
    /// phone (or the Mac) can open. The standalone viewer serves the full
    /// dashboard — pan/zoom/click/export — read-only from `.ua/` on disk. It
    /// binds 127.0.0.1, so Alfred also runs a tiny TCP proxy on the LAN and
    /// returns that address; the token the viewer mints gates access.
    ///
    /// Reuses a running viewer/proxy per project. Nil when the graph is
    /// missing or the viewer can't start (network for the first npx fetch,
    /// Node missing, …).
    func openDashboard(projectPath: String) async -> String? {
        guard isEnabled else { return nil }
        let expanded = (projectPath as NSString).expandingTildeInPath
        guard Self.graphFile(for: expanded) != nil else { return nil }
        guard nodeAvailable, let node = nodePath, npxAvailable, let npx = npxPath else { return nil }

        if let existing = viewerURLs[expanded] { return existing }

        guard let port = await startViewer(projectPath: expanded, node: node, npx: npx) else {
            NSLog("[understand] viewer failed to start for %@", expanded)
            return nil
        }
        guard let proxyPort = startLANProxy(for: expanded, toLocalPort: port) else {
            // Proxy failed — the Mac itself can still open the local URL.
            NSLog("[understand] LAN proxy failed for %@ — falling back to localhost", expanded)
            let url = "http://127.0.0.1:\(port)/"
            viewerURLs[expanded] = url
            return url
        }
        let url = "http://\(Self.lanIPAddress() ?? "127.0.0.1"):\(proxyPort)/"
        viewerURLs[expanded] = url
        return url
    }

    /// Launch the standalone viewer, wait for it to print its tokenized URL,
    /// and return the *port*. The tgz needs a network fetch on first use
    /// (npx caches it); `--no-open` stops it hijacking the user's browser.
    private func startViewer(projectPath: String, node: String, npx: String) async -> Int? {
        let url = "https://github.com/Egonex-AI/Understand-Anything/releases/latest/download/understand-anything-viewer.tgz"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        // npx resolves the tarball URL; --yes skips its install prompt.
        process.arguments = ["--yes", url, projectPath, "--no-open"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Read stdout on a background queue; stop reading once the URL line
        // lands (the server keeps running, so EOF never comes).
        let box = ViewerURLBox()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                box.markFailed()
                return
            }
            box.append(String(decoding: data, as: UTF8.self))
            if box.portValue() != nil {
                h.readabilityHandler = nil
            }
        }

        do {
            try process.run()
        } catch {
            return nil
        }
        viewerProcesses[projectPath] = process

        // Wait up to 60s for the port.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let port = box.portValue() {
                NSLog("[understand] viewer up for %@ on port %d", projectPath, port)
                return port
            }
            if box.failedValue() || !process.isRunning {
                NSLog("[understand] viewer exited early for %@ (npx may need network the first time)", projectPath)
                return nil
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    /// A small locked box for the viewer's stdout, shared between the
    /// readability handler (background queue) and the polling caller.
    private final class ViewerURLBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        var port: Int?
        var failed = false

        func append(_ chunk: String) {
            lock.lock()
            buffer += chunk
            if port == nil,
               let range = buffer.range(of: #"127\.0\.0\.1:(\d+)"#, options: .regularExpression) {
                let match = String(buffer[range])
                port = match.split(separator: ":").last.flatMap { Int($0) }
            }
            lock.unlock()
        }

        func portValue() -> Int? {
            lock.lock()
            defer { lock.unlock() }
            return port
        }

        func markFailed() {
            lock.lock()
            failed = true
            lock.unlock()
        }

        func failedValue() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return failed
        }
    }

    /// Forward the viewer's 127.0.0.1 port to the LAN so the phone can open
    /// the dashboard. Plain byte-pumping over NWListener/NWConnection handles
    /// both HTTP and the dashboard's WebSocket (Vite HMR) transparently.
    private func startLANProxy(for projectPath: String, toLocalPort localPort: Int) -> Int? {
        guard proxyListeners[projectPath] == nil else { return proxyPorts[projectPath] }

        var chosenPort = localPort
        var listener: NWListener?
        for _ in 0..<20 {
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(chosenPort))!)
                break
            } catch {
                chosenPort += 1
            }
        }
        guard let listener else { return nil }

        listener.newConnectionHandler = { connection in
            self.bridge(connection, to: localPort)
        }
        listener.stateUpdateHandler = { state in
            if case .failed = state {
                NSLog("[understand] proxy listener failed on port %d", chosenPort)
            }
        }
        listener.start(queue: .init(label: "com.alfred.understand.proxy"))
        proxyListeners[projectPath] = listener
        proxyPorts[projectPath] = chosenPort
        NSLog("[understand] LAN proxy %d → 127.0.0.1:%d for %@", chosenPort, localPort, projectPath)
        return chosenPort
    }

    /// Pump bytes between one LAN connection and the local viewer. Nonisolated:
    /// NWListener's connection handler runs off the main actor.
    nonisolated private func bridge(_ incoming: NWConnection, to localPort: Int) {
        let outgoing = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(localPort))!,
            using: .tcp)
        let queue = DispatchQueue(label: "com.alfred.understand.bridge")
        incoming.start(queue: queue)
        outgoing.start(queue: queue)
        // One pump per direction; each re-arms itself until the peer closes.
        pump(incoming, to: outgoing)
        pump(outgoing, to: incoming)
    }

    nonisolated private func pump(_ from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                to.cancel()
                from.cancel()
                return
            }
            self.pump(from, to: to)
        }
    }

    /// The Mac's LAN IPv4 (en0/en1 …), used to hand the phone a reachable
    /// dashboard URL. Falls back to 127.0.0.1 when no interface is up.
    nonisolated static func lanIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            _ = getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                            &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let candidate = String(cString: host)
            // Skip link-local; prefer a routable address.
            if !candidate.hasPrefix("169.254.") {
                address = candidate
                break
            }
            if address == nil { address = candidate }
        }
        return address
    }

    // MARK: - Process helper

    /// Capture a short-lived command's stdout with a hard timeout (mirrors
    /// CodeGraphManager). Used for the discovery probes.
    nonisolated static func runCapture(executable: String, arguments: [String],
                                       directory: String?, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        let drained = DispatchSemaphore(value: 0)
        var output = ""
        DispatchQueue.global().async {
            output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            drained.signal()
        }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard drained.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        return output
    }
}
