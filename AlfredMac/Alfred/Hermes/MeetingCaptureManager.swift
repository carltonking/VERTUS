import AVFoundation
import Foundation
import Speech

/// Captures meeting/conversation audio from the microphone and transcribes it on-device with the
/// Speech framework (free, private). On stop it summarizes the transcript locally via Ollama and
/// stores transcript + summary as a searchable memory.
///
/// Mic-only: this captures your side + room audio. Capturing other participants from system audio
/// would require ScreenCaptureKit (a deliberate follow-up). Manual start/stop keeps it consensual
/// and battery-friendly (no always-on recording).
@MainActor
final class MeetingCaptureManager: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var liveTranscript = ""
    @Published private(set) var status = "Idle."

    private let store: MemoryStore
    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var startedAt: Date?

    init(store: MemoryStore) { self.store = store }

    func toggle() async {
        if isRecording { await stopAndSummarize() } else { await start() }
    }

    func start() async {
        guard !isRecording else { return }
        guard await VoiceInputCapability.requestAuthorization() else {
            status = "Speech recognition not authorized (System Settings → Privacy → Speech Recognition)."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            status = "Speech recognizer unavailable."
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        startedAt = Date()
        liveTranscript = ""

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in self.liveTranscript = result.bestTranscription.formattedString }
            }
            if error != nil {
                Task { @MainActor in if self.isRecording { self.status = "Transcription stream ended." } }
            }
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            status = "Recording + transcribing on-device…"
        } catch {
            status = "Microphone start failed: \(error.localizedDescription)"
            cleanup()
        }
    }

    func stopAndSummarize() async {
        guard isRecording else { return }
        let transcript = liveTranscript
        let started = startedAt ?? Date()
        cleanup()
        isRecording = false

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "No speech captured."
            return
        }
        status = "Summarizing on-device…"

        let system = """
            You summarize a meeting transcript. Output a 2–3 sentence summary, then a blank line, \
            then a markdown list of action items (each line starting with '- '). If there are no \
            action items, write '- None'.
            """
        let summary = await LocalLearningLLM.shared.run(system: system, prompt: String(transcript.prefix(8000)))
        let title = Self.titleFor(date: started)

        let meeting = MeetingRecord(
            id: nil,
            started_at: started.timeIntervalSince1970,
            ended_at: Date().timeIntervalSince1970,
            title: title,
            transcript: transcript,
            summary: summary,
            action_items: nil
        )
        store.insertMeeting(meeting)
        if let summary {
            try? store.save(content: "Meeting (\(title)): \(summary)", tags: ["meeting"])
        }
        status = summary == nil
            ? "Saved transcript. (Ollama offline — no summary; run `ollama pull llama3.1:8b`.)"
            : "Saved meeting with summary."
    }

    private func cleanup() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private static func titleFor(date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return "Meeting " + f.string(from: date)
    }
}
