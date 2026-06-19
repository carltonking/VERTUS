import SwiftUI

// MARK: - Category Colors

private extension MemoryCategory {
    var dashboardColor: Color {
        switch self {
        case .goals: return .green
        case .projects: return .blue
        case .preferences: return .purple
        case .skills: return .orange
        case .workflows: return .teal
        case .recurringProblems: return .red
        case .longTermInterests: return .pink
        }
    }
}

private let relDateFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return f
}()

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

// MARK: - Dashboard View

struct MemoryDashboardView: View {
    let relationshipService: RelationshipMemoryService?
    let reflectionService: MemoryReflectionService?
    let backupService: MemoryBackupService?
    let workflowDetectionService: WorkflowDetectionService?
    let memoryLinkService: MemoryLinkService?
    @State private var memories: [RelationshipMemory] = []
    @State private var reflections: [Reflection] = []
    @State private var workflows: [Workflow] = []
    @State private var selectedTab = 0
    @State private var searchText = ""
    @State private var categoryFilter: MemoryCategory? = nil
    @State private var importanceFilter: ImportanceFilter = .all
    @State private var showArchived = false
    @State private var showLinksOnly = false
    @State private var sortOrder: MemorySortOrder = .importance
    @State private var selectedMemoryIDs: Set<UUID> = []
    @State private var selectedMemory: RelationshipMemory? = nil
    @State private var selectedReflection: Reflection? = nil
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: DeleteTarget? = nil
    @State private var showReflectionSupporting = false
    @State private var showLinkSheet = false
    @State private var linkSheetTarget: RelationshipMemory?
    @State private var linkSheetSelectedMemoryId: UUID?
    @State private var linkSheetType: LinkType = .keywordOverlap
    @State private var showingBackupBrowser = false
    @State private var showImportMergeOptions = false
    @State private var importData: Data?
    @State private var importURL: URL?
    @State private var backupStatusMessage: String?
    @State private var isBackupStatusError = false

    enum ImportanceFilter: String, CaseIterable {
        case all = "All"
        case high = "High (>0.7)"
        case medium = "Medium (0.3–0.7)"
        case low = "Low (<0.3)"
    }

    enum MemorySortOrder: String, CaseIterable {
        case importance = "Importance"
        case lastReferenced = "Last Referenced"
        case createdAt = "Created At"
        case category = "Category"
    }

    enum DeleteTarget {
        case single(UUID)
        case bulk(Set<UUID>)
        case allMemories
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            switch selectedTab {
            case 0: memoriesTab
            case 1: reflectionsTab
            case 2: workflowsTab
            default: Color.clear
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear(perform: loadData)
        .onReceive(NotificationCenter.default.publisher(for: .relationshipMemoryUpdated)) { _ in loadData() }
        .onReceive(NotificationCenter.default.publisher(for: .reflectionsUpdated)) { _ in loadData() }
        .alert(item: $deleteTarget) { target in
            switch target {
            case .single(let id):
                return Alert(
                    title: Text("Delete Memory"),
                    message: Text("Delete this memory? This cannot be undone."),
                    primaryButton: .destructive(Text("Delete")) {
                        relationshipService?.forgetMemory(id: id)
                        reflectionService?.handleMemoryRemoved(id: id)
                        selectedMemory = nil
                        loadData()
                    },
                    secondaryButton: .cancel()
                )
            case .bulk(let ids):
                return Alert(
                    title: Text("Delete \(ids.count) Memories?"),
                    message: Text("This cannot be undone."),
                    primaryButton: .destructive(Text("Delete All")) {
                        relationshipService?.bulkDelete(ids: Array(ids))
                        for id in ids { reflectionService?.handleMemoryRemoved(id: id) }
                        selectedMemoryIDs = []
                        loadData()
                    },
                    secondaryButton: .cancel()
                )
            case .allMemories:
                return Alert(
                    title: Text("Delete All Memory Data"),
                    message: Text("Delete all relationship memories? This cannot be undone."),
                    primaryButton: .destructive(Text("Delete All")) {
                        relationshipService?.deleteAllMemories(includeArchived: true)
                        reflectionService?.resetAll()
                        selectedMemoryIDs = []
                        selectedMemory = nil
                        loadData()
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .onExitCommand {
            if !searchText.isEmpty {
                searchText = ""
            } else if selectedMemory != nil {
                selectedMemory = nil
            } else if selectedReflection != nil {
                selectedReflection = nil
            }
        }
        .sheet(isPresented: $showingBackupBrowser) {
            if let bs = backupService {
                BackupBrowserView(backupService: bs)
            }
        }
        .sheet(isPresented: $showLinkSheet) {
            createLinkSheet
        }
        .confirmationDialog(
            "Import Memories",
            isPresented: $showImportMergeOptions,
            titleVisibility: .visible
        ) {
            Button("Replace – Delete current data and import") {
                performImport(strategy: .replace)
            }
            Button("Merge – Combine with existing data") {
                performImport(strategy: .merge)
            }
            Button("Cancel", role: .cancel) {
                importData = nil
                importURL = nil
            }
        } message: {
            Text("Choose how to handle the imported data. Replace will delete all current memories and reflections.")
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack {
            Button("Relationship Memories") { selectedTab = 0 }
                .buttonStyle(.borderedProminent)
                .tint(selectedTab == 0 ? .accentColor : .gray.opacity(0.3))
            Button("Reflections & Insights") { selectedTab = 1 }
                .buttonStyle(.borderedProminent)
                .tint(selectedTab == 1 ? .accentColor : .gray.opacity(0.3))
            Button("Workflows") { selectedTab = 2; loadWorkflows() }
                .buttonStyle(.borderedProminent)
                .tint(selectedTab == 2 ? .accentColor : .gray.opacity(0.3))
            Spacer()
            Text("\(filteredMemories.count) memories")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Memories Tab

    private var memoriesTab: some View {
        VStack(spacing: 0) {
            memoriesToolbar
            Divider()
            memoriesFilters
            Divider()
            if isMinimalMode {
                minimalPlaceholder
            } else {
                HSplitView {
                    memoriesList
                    if let mem = selectedMemory {
                        memoryDetailPanel(mem)
                            .frame(minWidth: 250, maxWidth: 350)
                    }
                }
            }
        }
    }

    private var memoriesToolbar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search memories…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onChange(of: searchText) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { loadData() }
                }

            Spacer()

            if !selectedMemoryIDs.isEmpty {
                Button("Delete (\(selectedMemoryIDs.count))") {
                    deleteTarget = .bulk(selectedMemoryIDs)
                }
                .foregroundColor(.red)
                Button("Archive (\(selectedMemoryIDs.count))") {
                    relationshipService?.bulkArchive(ids: Array(selectedMemoryIDs))
                    selectedMemoryIDs = []
                    loadData()
                }
                Button("Export (\(selectedMemoryIDs.count))") {
                    exportSelected()
                }
            }

            Button("Import") { importFromFile() }

            Button("Export All") { exportAll() }

            Menu("Backup") {
                Button("Create Backup Now") { createBackup(encrypted: false) }
                Button("Create Encrypted Backup Now") { createBackup(encrypted: true) }
                Divider()
                Button("Restore from Backup…") { showingBackupBrowser = true }
                Button("Manage Backups…") { showingBackupBrowser = true }
            }

            Button("Clear All") { deleteTarget = .allMemories }
                .foregroundColor(.red)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var memoriesFilters: some View {
        HStack(spacing: 12) {
            Picker("Category", selection: $categoryFilter) {
                Text("All Categories").tag(MemoryCategory?.none)
                ForEach(MemoryCategory.allCases, id: \.self) { cat in
                    Text(cat.label).tag(MemoryCategory?.some(cat))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)

            Picker("Importance", selection: $importanceFilter) {
                ForEach(ImportanceFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            Toggle("Show Archived", isOn: $showArchived)

            Toggle("Isolated Only", isOn: $showLinksOnly)
                .help("Show only memories with no links")

            Picker("Sort", selection: $sortOrder) {
                ForEach(MemorySortOrder.allCases, id: \.self) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var memoriesList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(sortedMemories) { memory in
                    MemoryRow(
                        memory: memory,
                        isSelected: selectedMemoryIDs.contains(memory.id),
                        isDetailShown: selectedMemory?.id == memory.id,
                        isMinimal: isMinimalMode,
                        onSelect: { toggleSelection(memory.id) },
                        onDetail: { selectedMemory = memory },
                        onEdit: { /* inline edit handled in detail panel */ },
                        onDelete: { deleteTarget = .single(memory.id) },
                        onPromote: { relationshipService?.adjustManualImportance(id: memory.id, delta: 0.1); loadData() },
                        onDemote: { relationshipService?.adjustManualImportance(id: memory.id, delta: -0.1); loadData() }
                    )
                }

                if sortedMemories.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No memories found")
                            .foregroundStyle(.secondary)
                        Text("Try adjusting your filters or search term")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 60)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Memory Row

    struct MemoryRow: View {
        let memory: RelationshipMemory
        let isSelected: Bool
        let isDetailShown: Bool
        let isMinimal: Bool
        let onSelect: () -> Void
        let onDetail: () -> Void
        let onEdit: () -> Void
        let onDelete: () -> Void
        let onPromote: () -> Void
        let onDemote: () -> Void

        var body: some View {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onSelect() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: 20)

                Text(String(memory.content.prefix(80)))
                    .lineLimit(1)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(memory.category.label)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(memory.category.dashboardColor.opacity(0.15))
                    .cornerRadius(4)

                ProgressView(value: memory.effectiveImportance, total: 1.0)
                    .frame(width: 50)
                    .progressViewStyle(.linear)
                    .tint(importanceColor(memory.effectiveImportance))

                Text("\(Int(memory.effectiveImportance * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36)

                Text(relDateFormatter.localizedString(for: memory.lastReferenced, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 80)

                HStack(spacing: 4) {
                    Button(action: onDetail) {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .help("View details")

                    Button(action: onPromote) {
                        Image(systemName: "star")
                    }
                    .buttonStyle(.plain)
                    .help("Promote (+0.1)")

                    Button(action: onDemote) {
                        Image(systemName: "arrowtriangle.down")
                    }
                    .buttonStyle(.plain)
                    .help("Demote (-0.1)")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                    .help("Delete")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isDetailShown ? Color.accentColor.opacity(0.08) : (memory.isArchived ? Color.gray.opacity(0.05) : Color.clear))
            .opacity(memory.isArchived ? 0.6 : 1)
        }

        private func importanceColor(_ val: Double) -> Color {
            if val >= 0.7 { return .green }
            if val >= 0.3 { return .orange }
            return .red
        }
    }

    // MARK: - Memory Detail Panel

    @ViewBuilder
    private func memoryDetailPanel(_ mem: RelationshipMemory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Memory Detail")
                    .font(.headline)
                Spacer()
                Button("Close") { selectedMemory = nil }
                    .buttonStyle(.plain)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    detailField("Content", value: mem.content)
                    detailField("Category", value: mem.category.label)
                    detailField("Source", value: mem.source)
                    detailField("Created", value: isoFormatter.string(from: mem.createdAt))
                    detailField("Last Referenced", value: isoFormatter.string(from: mem.lastReferenced))
                    detailField("Mention Count", value: "\(mem.mentionCount)")
                    detailField("Confidence (Algorithm)", value: String(format: "%.2f", mem.importance))
                    if let mi = mem.manualImportance {
                        detailField("Manual Importance", value: String(format: "%.2f", mi))
                        detailField("Effective", value: String(format: "%.2f", mem.effectiveImportance))
                    }
                    if mem.manualOverride {
                        detailField("Manual Override", value: "Yes")
                    }
                    detailField("Reason Saved", value: mem.reasonSaved)
                    if mem.isArchived, let a = mem.archivedAt {
                        detailField("Archived", value: isoFormatter.string(from: a))
                    }

                    Divider()

                    Text("Edit")
                        .font(.subheadline.bold())

                    Button(mem.isArchived ? "Restore" : "Archive") {
                        if mem.isArchived {
                            relationshipService?.restoreMemory(id: mem.id)
                        } else {
                            relationshipService?.archiveMemory(id: mem.id)
                        }
                        loadData()
                    }

                    if mem.manualOverride {
                        Button("Reset to Algorithm") {
                            relationshipService?.resetManualOverride(id: mem.id)
                            loadData()
                        }
                    }

                    Divider()

                    Text("Relationships")
                        .font(.subheadline.bold())

                    Button("Create Link…") {
                        linkSheetTarget = mem
                        linkSheetType = .keywordOverlap
                        linkSheetSelectedMemoryId = nil
                        showLinkSheet = true
                    }

                    if let linkService = memoryLinkService {
                        let links = linkService.links(for: mem.id)
                        if links.isEmpty {
                            Text("No linked memories")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(links, id: \.id) { link in
                                let isFrom = link.fromId == mem.id
                                let otherId = isFrom ? link.toId : link.fromId
                                let other = relationshipService?.memory(by: otherId)
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(link.type.label)
                                            .font(.caption.bold())
                                            .foregroundStyle(linkTypeColor(link.type))
                                        Text(other?.content.prefix(40) ?? "deleted memory")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(String(format: "%.0f%%", link.strength * 100))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    if !link.userConfirmed && !link.userRejected {
                                        Button("Confirm") {
                                            linkService.confirmLink(id: link.id)
                                            loadData()
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundColor(.green)
                                        Button("Reject") {
                                            linkService.rejectLink(id: link.id)
                                            loadData()
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundColor(.red)
                                    }
                                }
                                .padding(4)
                                .background(Color.gray.opacity(0.06))
                                .cornerRadius(4)
                            }
                        }
                    }
                }
                .padding(4)
            }
        }
        .padding(12)
    }

    private func detailField(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
    }

    private func linkTypeColor(_ type: LinkType) -> Color {
        switch type {
        case .keywordOverlap: return .blue
        case .temporalProximity: return .purple
        case .categoryRelationship: return .green
        case .contradictory: return .orange
        case .causeEffect: return .red
        }
    }

    // MARK: - Reflections Tab

    private var reflectionsTab: some View {
        VStack(spacing: 0) {
            reflectionsToolbar
            Divider()
            if isMinimalMode {
                minimalPlaceholder
            } else {
                reflectionsList
            }
        }
    }

    @State private var reflectionTypeFilter: ReflectionType? = nil
    @State private var reflectionConfidenceFilter: ImportanceFilter = .all
    @State private var showDismissedReflections = false

    private var reflectionsToolbar: some View {
        HStack(spacing: 12) {
            Picker("Type", selection: $reflectionTypeFilter) {
                Text("All Types").tag(ReflectionType?.none)
                ForEach(ReflectionType.allCases, id: \.self) { t in
                    Text(t.label).tag(ReflectionType?.some(t))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 160)

            Picker("Confidence", selection: $reflectionConfidenceFilter) {
                ForEach(ImportanceFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            Toggle("Show dismissed", isOn: $showDismissedReflections)

            Spacer()

            Text("\(filteredReflections.count) reflections")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var reflectionsList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredReflections) { reflection in
                    ReflectionRow(
                        reflection: reflection,
                        isSelected: selectedReflection?.id == reflection.id,
                        onSelect: { selectedReflection = reflection },
                        onDismiss: {
                            if reflection.dismissed {
                                reflectionService?.undismissReflection(id: reflection.id)
                            } else {
                                reflectionService?.dismissReflection(id: reflection.id)
                            }
                            loadData()
                        },
                        onDelete: {
                            reflectionService?.deleteReflection(id: reflection.id)
                            if selectedReflection?.id == reflection.id { selectedReflection = nil }
                            loadData()
                        },
                        onRegenerate: {
                            _ = reflectionService?.regenerateReflection(id: reflection.id)
                            loadData()
                        }
                    )
                }

                if filteredReflections.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "lightbulb")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No reflections found")
                            .foregroundStyle(.secondary)
                        Text("Run memory reflection to generate insights")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 60)
                }
            }
            .padding(.vertical, 4)
        }
    }

    struct ReflectionRow: View {
        let reflection: Reflection
        let isSelected: Bool
        let onSelect: () -> Void
        let onDismiss: () -> Void
        let onDelete: () -> Void
        let onRegenerate: () -> Void

        var body: some View {
            HStack(spacing: 8) {
                Text(reflection.type.label)
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(typeColor(reflection.type).opacity(0.15))
                    .cornerRadius(4)
                    .frame(width: 100, alignment: .center)

                Text(reflection.content)
                    .lineLimit(2)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)

                ProgressView(value: reflection.confidence, total: 1.0)
                    .frame(width: 50)
                    .progressViewStyle(.linear)
                    .tint(confidenceColor(reflection.confidence))

                Text("\(Int(reflection.confidence * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36)

                Text(relDateFormatter.localizedString(for: reflection.createdAt, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 80)

                if reflection.dismissed {
                    Text("Dismissed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 64)
                }

                HStack(spacing: 4) {
                    Button(action: onSelect) {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .help("View details")

                    Button(action: onDismiss) {
                        Image(systemName: reflection.dismissed ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.plain)
                    .help(reflection.dismissed ? "Undismiss" : "Dismiss")

                    Button(action: onRegenerate) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Recalculate confidence")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                    .help("Delete")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(reflection.dismissed ? Color.gray.opacity(0.05) : Color.clear)
            .opacity(reflection.dismissed ? 0.5 : 1)
        }

        private func typeColor(_ type: ReflectionType) -> Color {
            switch type {
            case .pattern: return .blue
            case .contradiction: return .orange
            case .milestone: return .green
            case .timeAssociation: return .purple
            case .toolPreference: return .teal
            }
        }

        private func confidenceColor(_ val: Double) -> Color {
            if val >= 0.7 { return .green }
            if val >= 0.4 { return .orange }
            return .red
        }
    }

    // MARK: - Workflows Tab

    @State private var showArchivedWorkflows = false
    @State private var selectedWorkflow: Workflow? = nil

    private var workflowsTab: some View {
        VStack(spacing: 0) {
            workflowsToolbar
            Divider()
            if isMinimalMode {
                minimalPlaceholder
            } else {
                workflowsContent
            }
        }
    }

    private var workflowsToolbar: some View {
        HStack(spacing: 12) {
            Text("Detected Workflows")
                .font(.headline)

            Spacer()

            Toggle("Show archived", isOn: $showArchivedWorkflows)

            Button("Run Detection") {
                _ = workflowDetectionService?.detectWorkflows()
                loadWorkflows()
            }

            Text("\(displayedWorkflows.count) workflow(s)")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var displayedWorkflows: [Workflow] {
        showArchivedWorkflows
            ? (workflowDetectionService?.archivedWorkflows ?? [])
            : workflows
    }

    private var workflowsContent: some View {
        HSplitView {
            workflowsList
            if let wf = selectedWorkflow {
                workflowDetailPanel(wf)
                    .frame(minWidth: 250, maxWidth: 350)
            }
        }
    }

    private var workflowsList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(displayedWorkflows) { workflow in
                    WorkflowRow(
                        workflow: workflow,
                        isSelected: selectedWorkflow?.id == workflow.id,
                        onSelect: { selectedWorkflow = workflow },
                        onRun: {
                            NotificationCenter.default.post(
                                name: .runWorkflowFromDashboard,
                                object: nil,
                                userInfo: ["workflowID": workflow.id.uuidString]
                            )
                        },
                        onArchive: {
                            workflowDetectionService?.archiveWorkflow(id: workflow.id)
                            loadWorkflows()
                            if selectedWorkflow?.id == workflow.id { selectedWorkflow = nil }
                        },
                        onRestore: {
                            workflowDetectionService?.restoreWorkflow(id: workflow.id)
                            loadWorkflows()
                        },
                        onDelete: {
                            workflowDetectionService?.deleteWorkflow(id: workflow.id)
                            loadWorkflows()
                            if selectedWorkflow?.id == workflow.id { selectedWorkflow = nil }
                        }
                    )
                }

                if displayedWorkflows.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "flowchart")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No workflows detected")
                            .foregroundStyle(.secondary)
                        Text("Run detection or create workflows naturally through your queries")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 60)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func workflowDetailPanel(_ wf: Workflow) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Workflow Detail")
                    .font(.headline)
                Spacer()
                Button("Close") { selectedWorkflow = nil }
                    .buttonStyle(.plain)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    detailField("Title", value: wf.title)
                    detailField("Created", value: isoFormatter.string(from: wf.createdAt))
                    detailField("Last Used", value: isoFormatter.string(from: wf.lastUsed))
                    detailField("Times Used", value: "\(wf.useCount)")
                    detailField("Steps", value: "\(wf.steps.count)")

                    if !wf.sourceMemoryIds.isEmpty {
                        detailField("Source Memories", value: "\(wf.sourceMemoryIds.count) linked")
                    }

                    Divider()

                    Text("Steps")
                        .font(.subheadline.bold())

                    ForEach(wf.steps) { step in
                        HStack(spacing: 6) {
                            Image(systemName: stepTypeIcon(step.type))
                                .foregroundStyle(stepTypeColor(step.type))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.type.rawValue.capitalized)
                                    .font(.caption.bold())
                                Text(step.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(4)
                        .background(Color.gray.opacity(0.06))
                        .cornerRadius(4)
                    }
                }
                .padding(4)
            }
        }
        .padding(12)
    }

    private func stepTypeIcon(_ type: WorkflowStepType) -> String {
        switch type {
        case .query: return "magnifyingglass"
        case .execute: return "play"
        case .wait: return "timer"
        case .notify: return "bell"
        case .confirm: return "questionmark.circle"
        }
    }

    private func stepTypeColor(_ type: WorkflowStepType) -> Color {
        switch type {
        case .query: return .blue
        case .execute: return .green
        case .wait: return .orange
        case .notify: return .purple
        case .confirm: return .yellow
        }
    }

    // MARK: - Workflow Row

    struct WorkflowRow: View {
        let workflow: Workflow
        let isSelected: Bool
        let onSelect: () -> Void
        let onRun: () -> Void
        let onArchive: () -> Void
        let onRestore: () -> Void
        let onDelete: () -> Void

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "flowchart")
                    .foregroundStyle(.teal)
                    .frame(width: 24)

                Text(workflow.title)
                    .lineLimit(1)
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(workflow.steps.count) step(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 70)

                Text("Used \(workflow.useCount) time(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 90)

                Text(relDateFormatter.localizedString(for: workflow.lastUsed, relativeTo: Date()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 80)

                HStack(spacing: 4) {
                    Button(action: onSelect) {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .help("View details")

                    Button(action: onRun) {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.green)
                    .help("Run workflow")

                    if workflow.archived {
                        Button(action: onRestore) {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.plain)
                        .help("Restore")
                    } else {
                        Button(action: onArchive) {
                            Image(systemName: "archivebox")
                        }
                        .buttonStyle(.plain)
                        .help("Archive")
                    }

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                    .help("Delete")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            .opacity(workflow.archived ? 0.5 : 1)
        }
    }

    // MARK: - Minimal Placeholder

    private var minimalPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Memory storage disabled")
                .font(.title3)
            Text("Privacy mode is set to Minimal. Enable a different privacy mode in Settings to access memory features.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private var isMinimalMode: Bool {
        (NSApp.delegate as? AppDelegate)?.appState.privacyMode == .minimal
    }

    private var filteredMemories: [RelationshipMemory] {
        guard let service = relationshipService else { return [] }
        var result = service.allMemoriesIncludingArchived()

        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter { $0.content.lowercased().contains(q) }
        }

        if let cat = categoryFilter {
            result = result.filter { $0.category == cat }
        }

        if !showArchived {
            result = result.filter { !$0.isArchived }
        }

        if showLinksOnly, let linkService = memoryLinkService {
            result = result.filter { mem in
                let linked = linkService.linkedMemoryIds(for: mem.id, minStrength: 0.1)
                return linked.isEmpty
            }
        }

        switch importanceFilter {
        case .all: break
        case .high: result = result.filter { $0.effectiveImportance > 0.7 }
        case .medium: result = result.filter { $0.effectiveImportance >= 0.3 && $0.effectiveImportance <= 0.7 }
        case .low: result = result.filter { $0.effectiveImportance < 0.3 }
        }

        return result
    }

    private var sortedMemories: [RelationshipMemory] {
        switch sortOrder {
        case .importance:
            return filteredMemories.sorted { $0.effectiveImportance > $1.effectiveImportance }
        case .lastReferenced:
            return filteredMemories.sorted { $0.lastReferenced > $1.lastReferenced }
        case .createdAt:
            return filteredMemories.sorted { $0.createdAt > $1.createdAt }
        case .category:
            return filteredMemories.sorted { $0.category.label < $1.category.label }
        }
    }

    private var filteredReflections: [Reflection] {
        guard let service = reflectionService else { return [] }
        var result = service.getReflections(includeDismissed: showDismissedReflections)

        if let type = reflectionTypeFilter {
            result = result.filter { $0.type == type }
        }

        switch reflectionConfidenceFilter {
        case .all: break
        case .high: result = result.filter { $0.confidence > 0.7 }
        case .medium: result = result.filter { $0.confidence >= 0.4 && $0.confidence <= 0.7 }
        case .low: result = result.filter { $0.confidence < 0.4 }
        }

        return result.sorted { $0.createdAt > $1.createdAt }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedMemoryIDs.contains(id) {
            selectedMemoryIDs.remove(id)
        } else {
            selectedMemoryIDs.insert(id)
        }
    }

    private func loadData() {
        memories = relationshipService?.allMemoriesIncludingArchived() ?? []
        reflections = reflectionService?.getReflections(includeDismissed: true) ?? []
        workflows = workflowDetectionService?.allWorkflows ?? []
    }

    private func loadWorkflows() {
        workflows = workflowDetectionService?.allWorkflows ?? []
    }

    // MARK: - Export

    private func exportAll() {
        guard let json = relationshipService?.exportToJSON(includeArchived: false) else { return }
        saveJSONToFile(json)
    }

    private func exportSelected() {
        let selected = memories.filter { selectedMemoryIDs.contains($0.id) }
        guard let data = try? JSONEncoder().encode(selected),
              let json = String(data: data, encoding: .utf8)
        else { return }
        saveJSONToFile(json)
    }

    private func saveJSONToFile(_ json: String) {
        let panel = NSSavePanel()
        panel.title = "Export Memories"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "alfred_memories_\(ISO8601DateFormatter().string(from: Date())).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? json.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Import & Backup

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Memories"
        panel.allowedContentTypes = [.json, .init(importedAs: "com.alfred.backup")]
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a memory export (.json) or backup (.alfredbackup) file"
        panel.allowedContentTypes = [.json, .init(filenameExtension: "alfredbackup") ?? .data]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        importURL = url
        importData = data
        showImportMergeOptions = true
    }

    private func performImport(strategy: MergeStrategy) {
        guard let data = importData, let url = importURL else { return }

        let isEncrypted = url.pathExtension == "alfredbackup"
        let jsonData: Data

        if isEncrypted {
            guard let decrypted = backupService?.decryptBackupData(data) else {
                backupStatusMessage = "Failed to decrypt backup file"
                isBackupStatusError = true
                return
            }
            jsonData = decrypted
        } else {
            jsonData = data
        }

        switch strategy {
        case .replace:
            guard let json = String(data: jsonData, encoding: .utf8) else { return }
            let success = relationshipService?.importFromJSON(json) ?? false
            if success {
                reflectionService?.resetAll()
                backupStatusMessage = "Import complete: data replaced successfully"
            } else {
                backupStatusMessage = "Import failed: invalid data format"
                isBackupStatusError = true
            }
        case .merge:
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let backupData = try? decoder.decode(BackupData.self, from: jsonData) else {
                backupStatusMessage = "Merge failed: invalid data format"
                isBackupStatusError = true
                return
            }

            var added = 0
            var updated = 0
            var skipped = 0

            let existingMemories = relationshipService?.allMemoriesForAnalysis() ?? []
            let existingContentPairs = Set(existingMemories.map { "\($0.content):\($0.category.rawValue)" })

            for memory in backupData.relationshipMemories {
                let contentPair = "\(memory.content):\(memory.category.rawValue)"
                if existingContentPairs.contains(contentPair) {
                    if let existingIdx = existingMemories.firstIndex(where: {
                        $0.content == memory.content && $0.category == memory.category
                    }) {
                        if memory.lastReferenced > existingMemories[existingIdx].lastReferenced {
                            relationshipService?.forceSave(
                                memory.content, category: memory.category,
                                source: "import_merge", importance: memory.importance,
                                reasonSaved: memory.reasonSaved
                            )
                            updated += 1
                        } else {
                            skipped += 1
                        }
                    }
                } else {
                    relationshipService?.forceSave(
                        memory.content, category: memory.category,
                        source: "import_merge", importance: memory.importance,
                        reasonSaved: memory.reasonSaved
                    )
                    added += 1
                }
            }

            backupStatusMessage = "Merge complete: \(added) added, \(updated) updated, \(skipped) skipped"
        }

        importData = nil
        importURL = nil
        loadData()
    }

    private func createBackup(encrypted: Bool) {
        guard let bs = backupService else { return }
        let meta = bs.createBackup(encrypted: encrypted)
        if meta != nil {
            backupStatusMessage = "Backup created successfully"
            isBackupStatusError = false
        } else {
            backupStatusMessage = "Backup failed"
            isBackupStatusError = true
        }
    }

    // MARK: - Link Sheet

    @ViewBuilder
    private var createLinkSheet: some View {
        if let target = linkSheetTarget {
            LinkSheetView(
                source: target,
                relationshipService: relationshipService,
                memoryLinkService: memoryLinkService,
                onCancel: { showLinkSheet = false },
                onCreate: { targetId, type in
                    memoryLinkService?.createManualLink(from: target.id, to: targetId, type: type)
                    showLinkSheet = false
                    loadData()
                }
            )
        }
    }
}

// MARK: - Link Sheet View

private struct LinkSheetView: View {
    let source: RelationshipMemory
    let relationshipService: RelationshipMemoryService?
    let memoryLinkService: MemoryLinkService?
    let onCancel: () -> Void
    let onCreate: (UUID, LinkType) -> Void

    @State private var selectedTarget: UUID?
    @State private var selectedType: LinkType = .keywordOverlap
    @State private var searchText = ""
    @State private var candidateMemories: [RelationshipMemory] = []

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Create Memory Link")
                    .font(.headline)
                Spacer()
                Button("Cancel", action: onCancel)
            }

            Text("Source: \(source.content.prefix(60))")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search memories to link…", text: $searchText)
                    .textFieldStyle(.plain)
                    .onChange(of: searchText) { updateCandidates() }
            }
            .padding(6)
            .background(Color.gray.opacity(0.08))
            .cornerRadius(6)

            Picker("Link Type", selection: $selectedType) {
                ForEach(LinkType.allCases, id: \.self) { type in
                    Text(type.label).tag(type)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(candidateMemories, id: \.id) { mem in
                        HStack {
                            let isSelected = selectedTarget == mem.id
                            Toggle("", isOn: .init(
                                get: { isSelected },
                                set: { if $0 { selectedTarget = mem.id } }
                            ))
                            .labelsHidden()

                            Text(mem.content.prefix(60))
                                .lineLimit(1)
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(mem.category.label)
                                .font(.caption)
                                .padding(.horizontal, 4)
                                .background(mem.category.dashboardColor.opacity(0.15))
                                .cornerRadius(4)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.gray.opacity(selectedTarget == mem.id ? 0.08 : 0))
                        .cornerRadius(4)
                    }

                    if candidateMemories.isEmpty {
                        Text("No memories found. Try a different search term.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Create Link") {
                    if let target = selectedTarget {
                        onCreate(target, selectedType)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTarget == nil)
            }
        }
        .padding(16)
        .frame(width: 420, height: 360)
        .onAppear { updateCandidates() }
    }

    private func updateCandidates() {
        guard let service = relationshipService else {
            candidateMemories = []
            return
        }
        let all = service.allMemoriesForAnalysis()
        let lowered = searchText.lowercased()
        let linkedIds = memoryLinkService?.linkedMemoryIds(for: source.id, minStrength: 0.1) ?? []
        let linkedSet = Set(linkedIds)

        candidateMemories = all.filter { mem in
            guard mem.id != source.id, !linkedSet.contains(mem.id) else { return false }
            if searchText.isEmpty { return true }
            return mem.content.lowercased().contains(lowered)
        }
        .sorted { $0.importance > $1.importance }
    }
}

// MARK: - Alert Item Conformance

extension MemoryDashboardView.DeleteTarget: Identifiable {
    var id: String {
        switch self {
        case .single(let u): return "single-\(u)"
        case .bulk(let s): return "bulk-\(s.count)"
        case .allMemories: return "all"
        }
    }
}
