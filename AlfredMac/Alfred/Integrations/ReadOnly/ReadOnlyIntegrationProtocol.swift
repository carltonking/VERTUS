import Foundation

// MARK: - Integration error

enum IntegrationError: LocalizedError {
    case queryTooShort
    case noResults
    case permissionDenied
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .queryTooShort:      return "Query must be at least 2 characters"
        case .noResults:          return "No results found"
        case .permissionDenied:   return "Permission denied"
        case .underlying(let e):  return e.localizedDescription
        }
    }
}

// MARK: - Result type

struct IntegrationSearchResult: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String
    let source: String
    let icon: String
    let metadata: [String: String]

    init(title: String, subtitle: String, source: String, icon: String, metadata: [String: String] = [:]) {
        self.id = UUID()
        self.title = title
        self.subtitle = subtitle
        self.source = source
        self.icon = icon
        self.metadata = metadata
    }
}

// MARK: - Read-only integration protocol

protocol ReadOnlyIntegrationProtocol: AnyObject {
    var actionType: ActionType { get }
    var actionClass: ActionClass { get }
    func performSearch(query: String) async throws -> [IntegrationSearchResult]
}

extension ReadOnlyIntegrationProtocol {
    var actionClass: ActionClass { .readOnly }
}
