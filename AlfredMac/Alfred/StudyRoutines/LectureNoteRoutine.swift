// MARK: - LectureNoteRoutine
//
// The lecture engine: turns dictated notes or a pasted transcript into a
// topic-organized summary plus study questions. Actual audio transcription is
// out of scope — a recording path is detected and reported honestly so the
// user can paste the transcript instead of getting a silent no-op.

import Foundation

enum LectureNoteRoutine {

    /// Common audio/video extensions — the "this needs a transcriber" signal.
    private static let audioExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aac", "flac", "ogg", "caf", "aiff",
        "mp4", "mov", "m4v", "webm",
    ]

    static func isRecordingReference(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (trimmed as NSString).pathExtension.lowercased()
        return audioExtensions.contains(ext) || trimmed.hasPrefix("/") || trimmed.hasPrefix("~")
    }

    /// The summary + questions prompt. Works on any text (dictated notes or a
    /// transcript); a bare topic with no real content still gets a topic
    /// outline.
    static func lecturePrompt(title: String, course: String?, content: String) -> String {
        return """
        You are Alfred's lecture-note assistant. Turn the lecture material \
        below into organized notes: a summary organized by topic, the key \
        points per topic, and 3–5 study questions that reinforce it. If a \
        concept maps to a textbook topic, name the topic so the user can look \
        it up.

        Lecture: \(title)
        \(course.map { "Course: \($0)\n" } ?? "")
        Material:
        \(content)

        Respond with EXACTLY ONE JSON object, nothing else, no markdown fences:
        {"summary": "...", "key_points": ["topic: point", "..."], "questions": ["...", "..."]}
        """
    }

    /// The routine-step status text across the day's (or week's) notes.
    static func statusText(notes: [LectureNote]) -> String {
        guard !notes.isEmpty else {
            return "No lecture notes on record yet — dictate your notes or paste a transcript after class."
        }
        return notes.map { note -> String in
            let coursePart = note.course.map { " — \($0)" } ?? ""
            let date = Date(timeIntervalSince1970: note.createdAt)
                .formatted(date: .abbreviated, time: .omitted)
            return "• \(note.title)\(coursePart) (\(date)): \(note.keyPoints.count) key point\(note.keyPoints.count == 1 ? "" : "s"), \(note.questions.count) question\(note.questions.count == 1 ? "" : "s")"
        }.joined(separator: "\n")
    }
}
