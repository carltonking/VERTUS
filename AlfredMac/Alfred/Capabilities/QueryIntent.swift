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

        return QueryIntent(
            wantsWebSearch: detectsWebSearch(lowered),
            wantsScreenContext: detectsScreenContext(lowered),
            wantsCalendarContext: detectsCalendarContext(lowered),
            appControlQuery: extractAppControlQuery(from: trimmed, lowered: lowered),
            shellCommand: extractShellCommand(from: trimmed)
        )
    }

    private static func detectsWebSearch(_ lowered: String) -> Bool {
        let explicit = [
            // explicit search asks
            "search for ", "web search ", "search the web", "look up ", "google ",
            "find online ", "find me ",
            // current / time-sensitive info
            "latest ", "recent ", "news about ", "news on ", "in the news",
            "current ", "right now", "this week", "this month", "this year",
            "weather", "forecast", "temperature",
            "price of", "stock price", "how much is", "who won", "what happened",
            // link / source requests
            "links to", "links for", "give me links", "a link to", "url for",
            "website for", "websites for", "send me a link", "find a link",
        ]
        return explicit.contains { lowered.contains($0) }
    }

    private static func detectsScreenContext(_ lowered: String) -> Bool {
        let explicit = [
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
        return explicit.contains { lowered.contains($0) }
    }

    private static func detectsCalendarContext(_ lowered: String) -> Bool {
        let explicit = [
            "my calendar",
            "upcoming events",
            "calendar events",
            "my reminders",
            "upcoming reminders",
            "what meetings",
            "what appointments",
        ]
        return explicit.contains { lowered.contains($0) }
    }

    private static func extractAppControlQuery(from query: String, lowered: String) -> String? {
        let prefixes = ["open ", "launch ", "start ", "switch to ", "focus ", "activate ", "hide ", "quit "]
        guard prefixes.contains(where: { lowered.hasPrefix($0) }) else { return nil }
        return query
    }

    static func extractShellCommand(from query: String) -> String? {
        if let start = query.firstIndex(of: "`"),
           let end = query[query.index(after: start)...].firstIndex(of: "`") {
            return String(query[query.index(after: start)..<end])
        }

        for prefix in ["run:", "execute:", "bash:"] {
            if let range = query.lowercased().range(of: prefix), range.lowerBound == query.startIndex {
                let after = String(query[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !after.isEmpty { return after }
            }
        }
        return nil
    }
}
