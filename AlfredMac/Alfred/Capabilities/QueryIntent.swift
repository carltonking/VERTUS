import Foundation

struct QueryIntent: Equatable {
    let wantsWebSearch: Bool
    let wantsScreenContext: Bool
    let wantsCalendarContext: Bool
    let appControlQuery: String?
    let shellCommand: String?

    var hasSideEffect: Bool {
        appControlQuery != nil || shellCommand != nil
    }

    static func analyze(_ query: String) -> QueryIntent {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        // A calendar/reminders query ("what's on my calendar this week") must not also trigger a web
        // search just because it contains a time word like "this week" — that pollutes the answer with
        // generic links. Calendar intent wins.
        let calendarContext = detectsCalendarContext(lowered)
        return QueryIntent(
            wantsWebSearch: detectsWebSearch(lowered) && !calendarContext,
            wantsScreenContext: detectsScreenContext(lowered),
            wantsCalendarContext: calendarContext,
            appControlQuery: extractAppControlQuery(from: trimmed, lowered: lowered),
            shellCommand: extractShellCommand(from: trimmed)
        )
    }

    // Keyword/prefix tables are compile-time constants; hold them as statics so analyze() (per
    // bar submission) reuses them instead of rebuilding each Array literal every call.
    private static let webSearchKeywords = [
        // explicit search asks
        "search for ", "web search ", "search the web", "look up ", "google ",
        "find online ", "find me ",
        // current / time-sensitive info
        "latest ", "recent ", "news about ", "news on ", "in the news",
        "current ", "right now", "this week", "this month", "this year",
        // briefing / recency vocabulary (research routines)
        "today", "this morning", "briefing", "headlines", "as of ",
        "up to date", "what's happening", "over the last", "past 24", "last 24",
        "weather", "forecast", "temperature",
        "price of", "stock price", "how much is", "who won", "what happened",
        // link / source requests
        "links to", "links for", "give me links", "a link to", "url for",
        "website for", "websites for", "send me a link", "find a link",
    ]

    private static let screenContextKeywords = [
        "use screen",
        "use my screen",
        "look at my screen",
        "look at this screen",
        "read this screen",
        "what do you see",
        "what's on my screen",
        "screenshot",
        "capture screen",
        "current window",
        "visible page",
    ]

    private static let calendarContextKeywords = [
        "my calendar",
        "upcoming events",
        "calendar events",
        "my reminders",
        "upcoming reminders",
        "what meetings",
        "what appointments",
    ]

    private static let appControlPrefixes = ["open ", "launch ", "start ", "switch to ", "focus ", "activate ", "hide ", "quit "]

    private static let shellCommandPrefixes = ["run:", "execute:", "bash:"]

    private static func detectsWebSearch(_ lowered: String) -> Bool {
        webSearchKeywords.contains { lowered.contains($0) }
    }

    private static func detectsScreenContext(_ lowered: String) -> Bool {
        screenContextKeywords.contains { lowered.contains($0) }
    }

    private static func detectsCalendarContext(_ lowered: String) -> Bool {
        calendarContextKeywords.contains { lowered.contains($0) }
    }

    private static func extractAppControlQuery(from query: String, lowered: String) -> String? {
        guard appControlPrefixes.contains(where: { lowered.hasPrefix($0) }) else { return nil }
        return query
    }

    static func extractShellCommand(from query: String) -> String? {
        if let start = query.firstIndex(of: "`"),
           let end = query[query.index(after: start)...].firstIndex(of: "`") {
            return String(query[query.index(after: start)..<end])
        }

        let loweredQuery = query.lowercased()
        for prefix in shellCommandPrefixes {
            if let range = loweredQuery.range(of: prefix), range.lowerBound == query.startIndex {
                let after = String(query[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty { return after }
            }
        }
        return nil
    }
}
