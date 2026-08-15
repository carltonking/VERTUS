import Foundation

// MARK: - Speaker notes
//
// The content turn already produces per-slide notes (see SlideContentGenerator).
// This pass *refines* them into a full presenting script: an intro, per-slide
// speaking points with a time budget, and a conclusion/Q&A block — the
// "present without memorizing, but understand the content" deliverable. It is
// a separate Hermes turn on the skill's own session, so adding notes later
// (the add_speaker_notes tool) costs one turn, not a whole new deck.

/// The refined speaker-notes plan, as decoded from the model's JSON reply.
struct SpeakerNotesPlan: Codable, Equatable, Sendable {
    var intro: String
    var totalMinutes: Double
    /// Per-slide notes, aligned by 1-based slide index.
    var slides: [SlideNotes]
    var qa: String

    struct SlideNotes: Codable, Equatable, Sendable {
        var index: Int
        var points: String
        var minutes: Double
    }

    /// Decode the model's reply, tolerating fences and prose around the JSON.
    static func parse(_ text: String) -> SpeakerNotesPlan? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        let jsonText = String(text[start...end])
        guard let data = jsonText.data(using: .utf8),
              let plan = try? JSONDecoder().decode(SpeakerNotesPlan.self, from: data)
        else { return nil }
        return plan
    }
}

/// Builds the refinement prompt and the final markdown script.
enum SpeakerNotesGenerator {

    static func prompt(topic: String, tone: PresentationTone, content: SlideContent) -> String {
        let slideList = content.slides.enumerated().map { index, slide in
            "\"\(index + 1)\": \"\(slide.title)\" — \(slide.bullets.joined(separator: " | "))"
        }.joined(separator: "\n")
        return """
        Write a presenting script for the deck below. The deck is: \(topic)

        Deck structure (slide number: title — bullets):
        \(slideList)

        Tone: \(tone.displayName.lowercased()) — specific, natural, human. Never generic filler.

        Answer ONLY with a JSON object — no prose, no code fences:
        {
          "intro": "one short paragraph for the title slide: hook + what the talk covers",
          "totalMinutes": 10,
          "slides": [
            {"index": 1, "points": "2-4 sentences of what to say on slide 1 — the key point to land, an example or story, and roughly how long", "minutes": 1.5}
          ],
          "qa": "one paragraph of likely audience questions with model answers, for the final slide"
        }

        Rules:
        - One "slides" entry per slide, in order, with a 1-based "index".
        - Every entry's "points" must be specific to that slide's bullets — \
        name the actual facts, numbers or examples on it. Never write "explain \
        the slide".
        - "minutes" per slide should sum to roughly "totalMinutes"; harder \
        slides get more time.
        """
    }

    /// Run the refinement turn and decode the plan.
    static func generate(session: HermesSession, topic: String, tone: PresentationTone,
                         content: SlideContent) async throws -> SpeakerNotesPlan {
        let prompt = Self.prompt(topic: topic, tone: tone, content: content)
        var transcript = ""
        for await event in await session.prompt(prompt, capture: false) {
            switch event {
            case .text(let chunk): transcript += chunk
            case .failed(let message):
                throw PresentationError.modelFailed(message)
            case .thought, .toolStarted, .toolProgress, .usage, .finished:
                break
            }
        }
        guard let plan = SpeakerNotesPlan.parse(transcript) else {
            throw PresentationError.unparseableContent(transcript)
        }
        return plan
    }

    /// Render the plan as a markdown file the user can read while presenting.
    static func markdown(topic: String, content: SlideContent, plan: SpeakerNotesPlan) -> String {
        var lines: [String] = []
        lines.append("# \(content.title)")
        lines.append("")
        lines.append("Speaker notes · ~\(Int(plan.totalMinutes.rounded())) minutes")
        lines.append("")
        lines.append("## Intro")
        lines.append(plan.intro)
        lines.append("")

        let notesByIndex = Dictionary(uniqueKeysWithValues: plan.slides.map { ($0.index, $0) })
        for (index, slide) in content.slides.enumerated() {
            let number = index + 1
            let notes = notesByIndex[number]
            lines.append("## Slide \(number): \(slide.title)")
            lines.append("")
            if let notes {
                lines.append("_\(Int(notes.minutes.rounded())) min_")
                lines.append("")
                lines.append(notes.points)
            } else {
                lines.append(slide.notes.isEmpty ? "(no notes)" : slide.notes)
            }
            lines.append("")
        }

        lines.append("## Conclusion & Q&A")
        lines.append(plan.qa.isEmpty ? "Field questions; recap the three key takeaways." : plan.qa)
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
