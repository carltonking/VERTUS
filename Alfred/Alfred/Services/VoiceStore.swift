//
//  VoiceStore.swift
//  Alfred
//
//  Full-duplex voice with the Mac. The phone pumps 24 kHz float32 mic frames to the WebSocket
//  bridge (one 1920-sample frame per message), which feeds them to Moshi-MLX; the bridge streams
//  back the model's speech as the same framing, plus JSON text tokens so the app can show a live
//  transcript of what Alfred says while the audio plays.
//

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class VoiceStore {
    enum Phase: Equatable {
        case idle
        case connecting
        case streaming
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    /// True while Alfred's audio frames are actively arriving, so the UI can show a speaking
    /// animation. Cleared shortly after the stream goes quiet.
    private(set) var isResponding = false

    private var socket: URLSessionWebSocketTask?
    private var audio: VoiceAudioIO?
    private var sendBuffered: [Data] = []
    private var isSending = false
    private var respondResetTask: Task<Void, Never>?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    // MARK: - Start / stop

    func start(host: String) async {
        stop()

        do {
            let io = try VoiceAudioIO()
            audio = io
            io.onFrame = { @Sendable [weak self] data in
                Task { @MainActor in self?.enqueueToSend(data) }
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        var address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.hasPrefix("ws://"), !address.hasPrefix("wss://") {
            address = "ws://" + address
        }
        if address.isEmpty {
            address = "ws://localhost"
        }
        var urlString = address
        if let url = URL(string: address), url.port == nil {
            urlString = address + ":8765"
        }
        guard let url = URL(string: urlString), url.host != nil else {
            phase = .failed(VoiceError.noHost.localizedDescription)
            return
        }

        phase = .connecting
        transcript = ""

        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try audio?.start()
        } catch {
            phase = .failed("Mic couldn't start: \(error.localizedDescription)")
            return
        }

        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        phase = .streaming
        await receiveLoop(socket)
    }

    func stop() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        audio?.stop()
        audio = nil
        sendBuffered.removeAll()
        isSending = false
        respondResetTask?.cancel()
        respondResetTask = nil
        isResponding = false
        if phase == .streaming || phase == .connecting {
            phase = .idle
        }
    }

    // MARK: - Outgoing frames

    private func enqueueToSend(_ frame: Data) {
        Task { @MainActor in
            guard let socket = self.socket else { return }
            sendBuffered.append(frame)
            guard !isSending else { return }
            isSending = true
            while !sendBuffered.isEmpty {
                let next = sendBuffered.removeFirst()
                do {
                    try await socket.send(.data(next))
                } catch {
                    break
                }
            }
            isSending = false
        }
    }

    // MARK: - Incoming messages

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while socket === self.socket {
            do {
                let message = try await socket.receive()
                switch message {
                case .data(let data):
                    markResponding()
                    audio?.play(data)
                case .string(let string):
                    appendTranscript(from: string)
                @unknown default:
                    break
                }
            } catch {
                if socket === self.socket {
                    phase = .failed("Lost the voice connection.")
                }
                return
            }
        }
    }

    private func markResponding() {
        isResponding = true
        respondResetTask?.cancel()
        respondResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            isResponding = false
        }
    }

    private func appendTranscript(from message: String) {
        // Binary is ping-ponged by the timeout check during connection; any string we get that
        // isn't the {"text":"..."} envelope is not the model talking. Bridge sends only JSON.
        guard message.hasPrefix("{\"text\":") else { return }
        transcript += message
            .dropFirst("{\"text\":".count)
            .dropLast(2)
            .replacingOccurrences(of: "\\\"", with: "\"")
    }
}