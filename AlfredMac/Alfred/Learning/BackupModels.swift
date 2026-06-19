import Foundation

struct BackupMetadata: Codable, Identifiable {
    let id: String
    let filename: String
    let createdAt: Date
    let size: Int64
    let encrypted: Bool
    let memoryCount: Int
    let reflectionCount: Int
    let workflowCount: Int
    let linkCount: Int
    let version: String
}

struct BackupData: Codable {
    let version: String
    let exportedAt: Date
    let appVersion: String
    let relationshipMemories: [RelationshipMemory]
    let reflections: [Reflection]
    let workflows: [Workflow]
    let links: [MemoryLink]
    let metadata: BackupDataMetadata

    enum CodingKeys: String, CodingKey {
        case version, exportedAt, appVersion, relationshipMemories, reflections, workflows, links, metadata
    }

    init(
        version: String,
        exportedAt: Date,
        appVersion: String,
        relationshipMemories: [RelationshipMemory],
        reflections: [Reflection],
        workflows: [Workflow],
        links: [MemoryLink],
        metadata: BackupDataMetadata
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.relationshipMemories = relationshipMemories
        self.reflections = reflections
        self.workflows = workflows
        self.links = links
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        relationshipMemories = try container.decode([RelationshipMemory].self, forKey: .relationshipMemories)
        reflections = try container.decode([Reflection].self, forKey: .reflections)
        workflows = try container.decode([Workflow].self, forKey: .workflows)
        links = try container.decodeIfPresent([MemoryLink].self, forKey: .links) ?? []
        metadata = try container.decode(BackupDataMetadata.self, forKey: .metadata)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(exportedAt, forKey: .exportedAt)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(relationshipMemories, forKey: .relationshipMemories)
        try container.encode(reflections, forKey: .reflections)
        try container.encode(workflows, forKey: .workflows)
        try container.encode(links, forKey: .links)
        try container.encode(metadata, forKey: .metadata)
    }
}

struct BackupDataMetadata: Codable {
    let memoryCount: Int
    let reflectionCount: Int
    let workflowCount: Int
    let linkCount: Int
    let sourceDevice: String
    let alfredVersion: String
}

enum MergeStrategy {
    case replace
    case merge
}

struct MergeResult {
    let addedCount: Int
    let updatedCount: Int
    let skippedCount: Int
    let conflictCount: Int
    let linkCount: Int
}
