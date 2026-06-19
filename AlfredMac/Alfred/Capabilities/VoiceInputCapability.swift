import AVFoundation
import Foundation
import Speech

final class VoiceInputCapability: @unchecked Sendable {
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer: SFSpeechRecognizer
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isRecording = false

    private let silenceTimeout: TimeInterval = 2.0

    init?(locale: Locale = Locale(identifier: "en-US")) {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return nil }
        self.speechRecognizer = recognizer
    }

    // MARK: - Authorization

    static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    static var isAuthorized: Bool {
        authorizationStatus == .authorized
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Microphone

    var isMicrophoneAvailable: Bool {
        audioEngine.inputNode.numberOfInputs > 0
    }

    // MARK: - Recording

    func transcribe() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            stopRecording()

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request

            var lastTranscriptionTime = Date()
            let finishGate = FinishGate()

            recognitionTask = speechRecognizer.recognitionTask(with: request) { result, error in
                guard finishGate.tryFinish() else { return }

                if let error {
                    let nsError = error as NSError
                    if nsError.domain == "SFSpeechRecognizerErrorDomain" && nsError.code == 1 {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: LLMError.networkError("Recognition failed: \(error.localizedDescription)"))
                    }
                    return
                }

                guard let result else { return }

                let transcription = result.bestTranscription.formattedString
                if !transcription.isEmpty {
                    lastTranscriptionTime = Date()
                }

                if result.isFinal {
                    continuation.yield(transcription)
                    continuation.finish()
                } else {
                    continuation.yield(transcription)
                }
            }

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }

            do {
                try audioEngine.start()
                isRecording = true
            } catch {
                finishGate.tryFinish()
                continuation.finish(throwing: LLMError.networkError("Failed to start audio engine: \(error.localizedDescription)"))
                return
            }

            let silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                guard Date().timeIntervalSince(lastTranscriptionTime) >= self.silenceTimeout else { return }
                self.stopRecording()
            }
            RunLoop.current.add(silenceTimer, forMode: .common)

            continuation.onTermination = { @Sendable _ in
                self.stopRecording()
                silenceTimer.invalidate()
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }

    deinit {
        stopRecording()
    }
}

private final class FinishGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func tryFinish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}
