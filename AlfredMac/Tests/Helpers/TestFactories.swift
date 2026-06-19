import Foundation
@testable import Alfred

enum TestFactories {
    static func makeMemory(
        id: UUID = UUID(),
        category: MemoryCategory = .goals,
        content: String = "Test memory content",
        source: String = "test",
        importance: Double = 0.5,
        createdAt: Date = Date(),
        lastReferenced: Date = Date(),
        mentionCount: Int = 1,
        archived: Bool = false
    ) -> RelationshipMemory {
        RelationshipMemory(
            id: id,
            category: category,
            content: content,
            source: source,
            importance: importance,
            createdAt: createdAt,
            lastReferenced: lastReferenced,
            mentionCount: mentionCount,
            correctedAt: nil,
            archivedAt: archived ? Date() : nil,
            reasonSaved: "test",
            manualOverride: false,
            manualImportance: nil
        )
    }

    static func makeReflection(
        id: UUID = UUID(),
        type: ReflectionType = .pattern,
        content: String = "Test reflection",
        supportingMemoryIds: [UUID] = [],
        confidence: Double = 0.5,
        createdAt: Date = Date()
    ) -> Reflection {
        Reflection(
            id: id,
            type: type,
            content: content,
            supportingMemoryIds: supportingMemoryIds,
            confidence: confidence,
            createdAt: createdAt,
            lastPresented: nil,
            dismissed: false
        )
    }

    static func makeWorkflow(
        id: UUID = UUID(),
        title: String = "Test Workflow",
        steps: [WorkflowStep] = [WorkflowStep(type: .query, title: "Step 1")],
        createdAt: Date = Date(),
        lastUsed: Date = Date(),
        useCount: Int = 1,
        archived: Bool = false
    ) -> Workflow {
        Workflow(id: id, title: title, steps: steps, sourceMemoryIds: [])
    }

    static func makeLink(
        id: UUID = UUID(),
        from: UUID,
        to: UUID,
        type: LinkType = .keywordOverlap,
        strength: Double = 0.5,
        userConfirmed: Bool = false,
        userRejected: Bool = false,
        createdAt: Date = Date()
    ) -> MemoryLink {
        MemoryLink(
            id: id,
            fromId: from,
            toId: to,
            type: type,
            strength: strength,
            userConfirmed: userConfirmed,
            userRejected: userRejected,
            createdAt: createdAt,
            lastVerifiedAt: Date(),
            lastReferencedAt: nil
        )
    }

    static func makeSuggestion(
        type: SuggestionType = .tip,
        title: String = "Test Suggestion",
        subtitle: String = "Subtitle",
        action: SuggestionAction = .openQuery("test"),
        confidence: Double = 0.5
    ) -> MemorySuggestion {
        MemorySuggestion.make(type: type, title: title, subtitle: subtitle, action: action, confidence: confidence)
    }
}
