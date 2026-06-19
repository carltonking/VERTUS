import Foundation
import EventKit
import OSLog

// MARK: - Calendar read service

final class CalendarReadService: ReadOnlyIntegrationProtocol {
    let actionType: ActionType = .queryMemory

    func performSearch(query: String) async throws -> [IntegrationSearchResult] {
        guard query.count >= 2 else { throw IntegrationError.queryTooShort }

        let results = try await fetchViaEventKit(query: query)

        guard !results.isEmpty else { throw IntegrationError.noResults }
        return results
    }

    private func fetchViaEventKit(query: String) async throws -> [IntegrationSearchResult] {
        let store = EKEventStore()

        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess:
            break
        case .writeOnly:
            throw IntegrationError.permissionDenied
        case .notDetermined:
            let granted = try await store.requestAccess(to: .event)
            guard granted else { throw IntegrationError.permissionDenied }
        case .denied, .restricted:
            throw IntegrationError.permissionDenied
        @unknown default:
            throw IntegrationError.permissionDenied
        }

        let now = Date()
        let end = now.addingTimeInterval(24 * 3600)

        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        guard !events.isEmpty else { throw IntegrationError.noResults }

        let matched = events.filter { event in
            (event.title ?? "").localizedCaseInsensitiveContains(query) ||
            (event.location ?? "").localizedCaseInsensitiveContains(query) ||
            (event.notes ?? "").localizedCaseInsensitiveContains(query)
        }

        guard !matched.isEmpty else { throw IntegrationError.noResults }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        return matched.prefix(20).map { event in
            let startStr = formatter.string(from: event.startDate)
            let endStr = formatter.string(from: event.endDate)
            return IntegrationSearchResult(
                title: event.title ?? "Untitled Event",
                subtitle: startStr,
                source: "Calendar",
                icon: "calendar",
                metadata: [
                    "title": event.title ?? "",
                    "start": startStr,
                    "end": endStr,
                    "location": event.location ?? "No location"
                ]
            )
        }
    }
}
