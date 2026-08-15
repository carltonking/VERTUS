//
//  NYUCanvasClient.swift
//  Alfred
//
//  The Canvas LMS REST API client — NYU's instance at canvas.nyu.edu.
//
//  Canvas is the supported, credential-light path into the NYU systems the
//  owner cares about: a personal access token (Settings → NYU, or the token
//  Canvas generates at Profile → Settings → Approved Integrations) reads
//  everything Alfred tracks — courses, assignments, grades, announcements,
//  the syllabus body, and class-meeting calendar events. Nothing here ever
//  touches a password or the NYU portal: Canvas's API is what the portal's
//  own data feeds from, and token auth means the Mac never holds (or
//  replays) a NetID password.
//
//  Design notes:
//   * Parsing is static and tolerant — every `parse…` function takes the
//     raw JSON dictionaries Canvas returns and produces models, dropping
//     malformed rows instead of failing the whole sync. The static parsers
//     are unit-tested against fixture JSON.
//   * One page per resource (per_page bounded). A semester's worth of
//     assignments is a few hundred rows at most; pagination is deliberately
//     out of scope rather than half-handled.
//   * The client is a value type the manager owns — tests can construct one
//     with any base URL and fixture-serving session without touching the
//     real token or network.

import Foundation

// MARK: - Models

/// One course with the owner's enrollment: current score (grades) plus the
/// syllabus body and teacher name for the course card.
struct NYUCourse: Codable, Equatable {
    var id: Int
    var name: String
    var code: String
    var term: String
    var professor: String
    /// The plain-text syllabus (HTML stripped) — the queryable source for
    /// "what's the grading breakdown / final exam date".
    var syllabus: String
    /// `computed_current_score` from the student enrollment.
    var currentScore: Double?
    /// `computed_final_score` — the projected grade if everything stayed put.
    var projectedScore: Double?
}

/// One assignment with the owner's submission (when one exists). `status` is
/// derived from `submission` + `due_at` by the manager, not stored here.
struct NYUAssignment: Codable, Equatable {
    var id: Int
    var courseID: Int
    var name: String
    var details: String
    /// Unix timestamp; nil = no due date (open-ended).
    var dueAt: TimeInterval?
    var pointsPossible: Double
    var submittedAt: TimeInterval?
    var score: Double?
    var url: String
}

/// A professor announcement — the closest thing to a guaranteed-read email.
struct NYUAnnouncement: Codable, Equatable {
    var id: Int
    var courseID: Int
    var title: String
    var message: String
    var postedAt: TimeInterval
}

/// One calendar event on a course's calendar — class meetings (which reveal
/// the weekly schedule + location) and one-off course events.
struct NYUCalendarEvent: Codable, Equatable {
    var id: Int
    var courseID: Int
    var title: String
    var startAt: TimeInterval
    var endAt: TimeInterval
    var location: String?
    /// Canvas event_type: "event" (class meeting), "assignment", "quiz"…
    var eventType: String
}

// MARK: - Client

enum NYUCanvasError: LocalizedError {
    case unauthorized
    case http(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Canvas rejected the token — check it in Settings (NYU → Canvas token)."
        case .http(let code):
            return "Canvas returned HTTP \(code)."
        case .network(let detail):
            return "Couldn't reach Canvas: \(detail)"
        }
    }
}

/// A minimal Canvas REST client. `token` is a personal access token; every
/// request carries it as the `Authorization: Bearer` header. All fetches are
/// bounded to one page (per_page ≤ 100) — enough for a semester's data.
struct NYUCanvasClient {
    var token: String
    var baseURL = URL(string: "https://canvas.nyu.edu/api/v1")!

    // MARK: - Endpoints

    /// Active enrollments with total scores + syllabus body + teachers.
    func fetchCourses() async throws -> [NYUCourse] {
        let raw = try await get(path: "courses", query: [
            URLQueryItem(name: "enrollment_state", value: "active"),
            URLQueryItem(name: "enrollment_type", value: "student"),
            URLQueryItem(name: "include", value: "total_scores,syllabus_body,teachers"),
            URLQueryItem(name: "per_page", value: "50"),
        ])
        return Self.parseCourses(raw)
    }

    /// A course's assignments with the owner's submission included.
    func fetchAssignments(courseID: Int) async throws -> [NYUAssignment] {
        let raw = try await get(path: "courses/\(courseID)/assignments", query: [
            URLQueryItem(name: "include", value: "submission"),
            URLQueryItem(name: "per_page", value: "100"),
        ])
        return Self.parseAssignments(raw, courseID: courseID)
    }

    /// Announcements across the given course contexts, newest first.
    func fetchAnnouncements(courseIDs: [Int]) async throws -> [NYUAnnouncement] {
        guard !courseIDs.isEmpty else { return [] }
        let contextCodes = courseIDs.map { "course_\($0)" }
        let raw = try await get(path: "announcements", query: [
            URLQueryItem(name: "context_codes[]", value: contextCodes.joined(separator: ",")),
            URLQueryItem(name: "per_page", value: "20"),
        ])
        return Self.parseAnnouncements(raw)
    }

    /// Calendar events for one course — class meetings with locations.
    func fetchCalendarEvents(courseID: Int) async throws -> [NYUCalendarEvent] {
        let raw = try await get(path: "calendar_events", query: [
            URLQueryItem(name: "context_codes[]", value: "course_\(courseID)"),
            URLQueryItem(name: "per_page", value: "100"),
        ])
        return Self.parseCalendarEvents(raw, courseID: courseID)
    }

    // MARK: - Transport

    private func get(path: String, query: [URLQueryItem]) async throws -> [[String: Any]] {
        var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = query
        guard let url = components.url else { throw NYUCanvasError.network("bad URL") }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NYUCanvasError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NYUCanvasError.network("no HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw NYUCanvasError.unauthorized
        default:
            throw NYUCanvasError.http(http.statusCode)
        }
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return array
    }

    // MARK: - Parsing (static, tolerant, unit-tested)

    static func parseCourses(_ rows: [[String: Any]]) -> [NYUCourse] {
        rows.compactMap { row in
            guard let id = row["id"] as? Int else { return nil }
            let enrollments = (row["enrollments"] as? [[String: Any]]) ?? []
            let enrollment = enrollments.first { ($0["type"] as? String) == "student" }
            let teachers = (row["teachers"] as? [[String: Any]]) ?? []
            let professor = teachers.compactMap { $0["display_name"] as? String }
                .first ?? ""
            let term = (row["term"] as? [String: Any])?["name"] as? String ?? ""
            return NYUCourse(
                id: id,
                name: row["name"] as? String ?? "Course \(id)",
                code: row["course_code"] as? String ?? "",
                term: term,
                professor: professor,
                syllabus: Self.plainText(from: row["syllabus_body"] as? String),
                currentScore: enrollment.flatMap { Self.number($0["computed_current_score"]) },
                projectedScore: enrollment.flatMap { Self.number($0["computed_final_score"]) })
        }
    }

    static func parseAssignments(_ rows: [[String: Any]], courseID: Int) -> [NYUAssignment] {
        rows.compactMap { row in
            guard let id = row["id"] as? Int else { return nil }
            let submission = (row["submission"] as? [String: Any])
            return NYUAssignment(
                id: id,
                courseID: courseID,
                name: row["name"] as? String ?? "Assignment \(id)",
                details: Self.plainText(from: row["description"] as? String),
                dueAt: Self.timestamp(row["due_at"] as? String),
                pointsPossible: Self.number(row["points_possible"]) ?? 0,
                submittedAt: submission.flatMap { Self.timestamp($0["submitted_at"] as? String) },
                score: submission.flatMap { Self.number($0["score"]) },
                url: row["html_url"] as? String ?? "")
        }
    }

    static func parseAnnouncements(_ rows: [[String: Any]]) -> [NYUAnnouncement] {
        rows.compactMap { row in
            guard let id = row["id"] as? Int else { return nil }
            // Announcements carry the course context in their URL
            // ("courses/123/discussion_topics/456") or a context_code.
            var courseID = 0
            if let contextCode = row["context_code"] as? String,
               contextCode.hasPrefix("course_"),
               let parsed = Int(contextCode.dropFirst(7)) {
                courseID = parsed
            } else if let url = row["url"] as? String,
                      let range = url.range(of: "courses/") {
                let rest = url[range.upperBound...]
                if let end = rest.firstIndex(of: "/"),
                   let parsed = Int(rest[..<end]) {
                    courseID = parsed
                }
            }
            guard courseID > 0 else { return nil }
            return NYUAnnouncement(
                id: id,
                courseID: courseID,
                title: row["title"] as? String ?? "Announcement",
                message: Self.plainText(from: row["message"] as? String),
                postedAt: Self.timestamp(row["posted_at"] as? String) ?? 0)
        }
    }

    static func parseCalendarEvents(_ rows: [[String: Any]], courseID: Int) -> [NYUCalendarEvent] {
        rows.compactMap { row in
            guard let id = row["id"] as? Int,
                  let start = Self.timestamp(row["start_at"] as? String) else { return nil }
            return NYUCalendarEvent(
                id: id,
                courseID: courseID,
                title: row["title"] as? String ?? "Course event",
                startAt: start,
                endAt: Self.timestamp(row["end_at"] as? String) ?? start + 3600,
                location: row["location_name"] as? String,
                eventType: row["event_type"] as? String ?? "event")
        }
    }

    // MARK: - Formatting helpers

    /// Any JSON number (Int or Double literal, JSONSerialization's NSNumber)
    /// as a Double — Swift's `as? Double` fails on Int literals, which bites
    /// in fixtures and is fragile for real payloads too.
    static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// Parse Canvas's ISO-8601 timestamps (with or without fractional seconds).
    static func timestamp(_ raw: String?) -> TimeInterval? {
        guard let raw, !raw.isEmpty else { return nil }
        let forms = [Self.iso8601, Self.iso8601Fractional]
        for form in forms {
            if let date = form.date(from: raw) {
                return date.timeIntervalSince1970
            }
        }
        return nil
    }

    private static let iso8601: ISO8601DateFormatter = {
        let form = ISO8601DateFormatter()
        form.formatOptions = [.withInternetDateTime]
        return form
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let form = ISO8601DateFormatter()
        form.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return form
    }()

    /// Strip HTML to plain text — syllabus bodies and assignment descriptions
    /// arrive as rich HTML.
    static func plainText(from html: String?) -> String {
        guard let html else { return "" }
        var text = html
        for tag in ["<br>", "<br/>", "<br />", "</p>", "</div>", "</li>", "</h1>", "</h2>", "</h3>", "</h4>"] {
            text = text.replacingOccurrences(of: tag, with: "\n")
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}
