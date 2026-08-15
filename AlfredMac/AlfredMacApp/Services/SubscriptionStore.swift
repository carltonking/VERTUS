//
//  SubscriptionStore.swift
//  AlfredMacApp
//
//  Calendar subscriptions: feeds the user pasted a URL for (webcal:// or .ics). Alfred's backend
//  fetches and parses the feed (api/feed.ts), and this store mirrors the events into a local
//  EventKit calendar named "Alfred Subscriptions", so they show up in every Calendar view just
//  like native events.
//
//  Ported from the iOS app (Alfred/Alfred/Services/SubscriptionStore.swift) with two adaptations:
//  the mirror calendar's colour uses NSColor, and the local-source fallback is "On My Mac".
//
//  The app owns the subscription list; the backend is a stateless fetcher. Each sync is
//  "fetch the feed again, reconcile the mirror": events by UID are created or updated in place,
//  and events whose UID vanished from the feed are deleted. The mirror calendar is entirely
//  Alfred's — a subscription removed from the list clears its events.
//

import EventKit
import Foundation
import Observation
import SwiftUI

// MARK: - Models

/// One subscription the user added, as stored in this app.
struct CalendarSubscription: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var url: String
    let createdAt: Date
}

/// One event from the backend feed. Dates ride as epoch milliseconds so decoding never trips
/// over ISO8601's optional fractional seconds.
struct FeedEvent: Identifiable, Codable, Hashable {
    let uid: String
    let title: String
    let start: Double?
    let end: Double?
    /// "YYYYMMDD" for all-day events (wall date, timezone-free).
    let date: String?
    let allDay: Bool
    let location: String?
    let description: String?

    var id: String { uid }
}

// MARK: - The store

@MainActor
@Observable
final class SubscriptionStore {
    enum SyncState: Equatable {
        case idle
        case syncing
        case synced(Date)
        case failed(String)
    }

    private(set) var subscriptions: [CalendarSubscription] = []
    private(set) var syncStates: [String: SyncState] = [:]
    private(set) var isSyncingAll = false

    /// The EventKit calendar the mirror writes into. Created lazily, reused forever after.
    private var mirrorCalendar: EKCalendar?

    private static let storageKey = "alfred.subscriptions"
    private static let mirrorCalendarTitle = "Alfred Subscriptions"

    /// UID → EventKit identifier, persisted so a rename or a moved event still reconciles. The
    /// mirror's own URL property carries the same identity, but a map avoids re-fetching the whole
    /// calendar every sync. Keys are namespaced per subscription: two feeds can legitimately use
    /// the same UID (many exporters just use the title).
    private var mirrorIndex: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "alfred.subscriptionMirror") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "alfred.subscriptionMirror") }
    }

    private static func indexKey(_ subscription: CalendarSubscription, _ uid: String) -> String {
        "\(subscription.id)/\(uid)"
    }

    /// The URL stamped on each mirrored event so it can be found later without the index.
    private static func identityURL(_ subscription: CalendarSubscription, _ uid: String) -> URL {
        URL(string: "alfred://subscription/\(subscription.id)/\(uid)")!
    }

    private let eventStore = EKEventStore()
    private let calendar = Calendar.current

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([CalendarSubscription].self, from: data) {
            subscriptions = decoded
        }
    }

    // MARK: List management

    func add(name: String, url: String) {
        let subscription = CalendarSubscription(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Calendar" : url)
                : name.trimmingCharacters(in: .whitespacesAndNewlines),
            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date()
        )
        subscriptions.append(subscription)
        persist()
        syncStates[subscription.id] = .idle
    }

    func remove(_ subscription: CalendarSubscription) {
        subscriptions.removeAll { $0.id == subscription.id }
        persist()
        syncStates[subscription.id] = nil
        clearMirroredEvents(for: subscription)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(subscriptions) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: Syncing

    /// Fetch every subscription's feed and reconcile its mirror. Runs each subscription
    /// sequentially — a feed is a few hundred KB and the backend is the bottleneck, but the
    /// EventKit writes are cheap, and the whole pass is one pull-to-refresh.
    func syncAll(endpoint: URL?, token: String) async {
        guard !subscriptions.isEmpty else { return }
        isSyncingAll = true
        defer { isSyncingAll = false }

        for subscription in subscriptions {
            await sync(subscription, endpoint: endpoint, token: token)
        }
    }

    func sync(_ subscription: CalendarSubscription, endpoint: URL?, token: String) async {
        syncStates[subscription.id] = .syncing
        defer { if syncStates[subscription.id] == .syncing { syncStates[subscription.id] = .idle } }

        guard let feedURL = feedURL(endpoint: endpoint) else {
            syncStates[subscription.id] = .failed("Alfred isn't connected. Add your address in Settings first.")
            return
        }
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            syncStates[subscription.id] = .failed("Alfred isn't connected. Add your token in Settings first.")
            return
        }

        do {
            let events = try await fetchFeed(url: feedURL, urlParameter: subscription.url, token: token)
            try reconcile(subscription, with: events)
            syncStates[subscription.id] = .synced(Date())
        } catch {
            syncStates[subscription.id] = .failed(message(for: error))
        }
    }

    private func feedURL(endpoint: URL?) -> URL? {
        guard let endpoint else { return nil }
        return endpoint.deletingLastPathComponent().appendingPathComponent("feed")
    }

    private func fetchFeed(url: URL, urlParameter: String, token: String) async throws -> [FeedEvent] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["url": urlParameter])
        request.timeoutInterval = 45

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NSError(domain: "feed", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't reach Alfred's server."])
        }

        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "feed", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Alfred sent something unreadable."])
        }

        struct FeedReply: Decodable { let ok: Bool; let error: String?; let events: [FeedEvent]? }

        let reply = try? JSONDecoder().decode(FeedReply.self, from: data)
        switch http.statusCode {
        case 200:
            guard let reply, reply.ok == true, let events = reply.events else {
                throw NSError(domain: "feed", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Alfred sent an empty feed."])
            }
            return events
        case 401:
            throw NSError(domain: "feed", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "That token was rejected — it must match APP_TOKEN."])
        case 503:
            throw NSError(domain: "feed", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The server has no APP_TOKEN set."])
        default:
            let message = reply?.error?.isEmpty == false ? reply!.error! : "Alfred's server answered \(http.statusCode)."
            throw NSError(domain: "feed", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func message(for error: Error) -> String {
        (error as NSError).localizedDescription
    }

    // MARK: The mirror calendar

    /// The writable EventKit calendar the mirror lives in, created on first use. macOS always has
    /// a local source ("On My Mac") to put it in, so it never has to borrow someone else's account.
    private func ensureMirrorCalendar() throws -> EKCalendar {
        if let mirrorCalendar { return mirrorCalendar }

        if let existing = eventStore.calendars(for: .event).first(where: { $0.title == Self.mirrorCalendarTitle }) {
            mirrorCalendar = existing
            return existing
        }

        let new = EKCalendar(for: .event, eventStore: eventStore)
        new.title = Self.mirrorCalendarTitle
        new.cgColor = NSColor.systemBlue.cgColor
        if let local = eventStore.sources.first(where: { $0.sourceType == .local }) {
            new.source = local
        } else if let defaultSource = eventStore.defaultCalendarForNewEvents?.source {
            new.source = defaultSource
        }
        try eventStore.saveCalendar(new, commit: true)
        mirrorCalendar = new
        return new
    }

    /// Create/update/delete mirrored events so the mirror matches the feed exactly.
    private func reconcile(_ subscription: CalendarSubscription, with events: [FeedEvent]) throws {
        guard let mirror = try? ensureMirrorCalendar() else { return }

        var index = mirrorIndex
        let wantedKeys = Set(events.map { Self.indexKey(subscription, $0.uid) })

        // Delete mirrored events whose UID is no longer in the feed.
        for (key, identifier) in index where key.hasPrefix(subscription.id + "/") && !wantedKeys.contains(key) {
            if let event = eventStore.event(withIdentifier: identifier) {
                try eventStore.remove(event, span: .thisEvent)
            }
            index[key] = nil
        }

        // Upsert the rest.
        for feedEvent in events {
            let key = Self.indexKey(subscription, feedEvent.uid)
            if let identifier = index[key], let existing = eventStore.event(withIdentifier: identifier) {
                apply(feedEvent, to: existing)
                try eventStore.save(existing, span: .thisEvent)
            } else {
                let event = EKEvent(eventStore: eventStore)
                event.calendar = mirror
                event.url = Self.identityURL(subscription, feedEvent.uid)
                apply(feedEvent, to: event)
                try eventStore.save(event, span: .thisEvent)
                index[key] = event.eventIdentifier
            }
        }

        mirrorIndex = index
    }

    private func apply(_ feed: FeedEvent, to event: EKEvent) {
        event.title = feed.title
        event.location = feed.location
        event.notes = feed.description
        event.isAllDay = feed.allDay
        if feed.allDay, let date = feed.date {
            let y = Int(date.prefix(4)) ?? 1970
            let m = Int(date.dropFirst(4).prefix(2)) ?? 1
            let d = Int(date.dropFirst(6).prefix(2)) ?? 1
            let start = calendar.date(from: DateComponents(year: y, month: m, day: d)) ?? Date()
            event.startDate = start
            event.endDate = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        } else {
            event.startDate = Date(timeIntervalSince1970: (feed.start ?? 0) / 1000)
            event.endDate = Date(timeIntervalSince1970: (feed.end ?? (feed.start ?? 0)) / 1000)
        }
    }

    /// Delete every mirrored event a removed subscription created. The mirror calendar can hold
    /// events from several subscriptions, so they're found by their stamped identity URL rather
    /// than by wiping the whole calendar.
    private func clearMirroredEvents(for subscription: CalendarSubscription) {
        guard let mirror = eventStore.calendars(for: .event).first(where: { $0.title == Self.mirrorCalendarTitle }) else {
            mirrorIndex = mirrorIndex.filter { !$0.key.hasPrefix(subscription.id + "/") }
            return
        }

        let predicate = eventStore.predicateForEvents(
            withStart: calendar.date(byAdding: .year, value: -1, to: Date()) ?? Date(),
            end: calendar.date(byAdding: .year, value: 3, to: Date()) ?? Date(),
            calendars: [mirror]
        )
        let prefix = "alfred://subscription/\(subscription.id)/"
        for event in eventStore.events(matching: predicate)
        where event.url?.absoluteString.hasPrefix(prefix) == true {
            try? eventStore.remove(event, span: .thisEvent)
        }
        mirrorIndex = mirrorIndex.filter { !$0.key.hasPrefix(subscription.id + "/") }
    }
}
