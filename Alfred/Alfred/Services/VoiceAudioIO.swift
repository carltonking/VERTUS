//
//  VoiceAudioIO.swift
//  Alfred
//
//  The raw audio half of voice chat: capture the mic at the hardware rate, resample to the
//  Moshi-MLX wire rate (24 kHz mono float32), chunk into 1920-sample frames, and play the frames
//  that come back. All work here happens off the main actor — AVAudioEngine callbacks run on
//  real-time audio threads, so this class is deliberately with its own serial queue.
//

import AVFoundation
import Foundation

nonisolated final class VoiceAudioIO: @unchecked Sendable {
    /// Matches the bridge: 24 kHz mono, 1920 samples per frame (80 ms).
    static let sampleRate = 24000.0
    static let frameSamples = 1920

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()

    /// Frames of captured PCM handed off on `queue` as float32 little-endian data.
    var onFrame: (@Sendable (Data) -> Void)?

    private let queue = DispatchQueue(label: "alfred.voice.audio")
    private let wireFormat: AVAudioFormat
    private var accumulator: [Float] = []
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?

    init() throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: 1
        ) else {
            throw VoiceError.badFormat
        }
        wireFormat = format
        try configureSession()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: wireFormat)
        engine.prepare()
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() throws {
        try engine.start()
        let input = engine.inputNode

        // `format: nil` is deliberate — asking for an explicit tap format here raises an
        // Objective-C exception on the simulator (AUGraphNodeBaseV3::CreateRecordingTap),
        // which Swift can't catch. The aliased native format is passed to the callback,
        // and handleInput resamples whatever it is down to the wire format.
        input.installTap(
            onBus: 0,
            bufferSize: 2048,
            format: nil
        ) { [weak self] buffer, _ in
            self?.handleInput(buffer)
        }
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        player.stop()
        accumulator.removeAll(keepingCapacity: true)
    }

    // MARK: - Mic -> wire frames

    private func handleInput(_ buffer: AVAudioPCMBuffer) {
        guard let inData = buffer.floatChannelData?[0] else { return }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // Cache the converter keyed on the buffer's format; the simulator may deliver a
        // different native format than a device, and it's constant within a session.
        if converter == nil || converterSource?.sampleRate != buffer.format.sampleRate
            || converterSource?.channelCount != buffer.format.channelCount {
            converterSource = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: wireFormat)
        }
        guard let converter else { return }

        let ratio = Self.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 64
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: wireFormat,
            frameCapacity: outCapacity
        ) else { return }
        outBuffer.frameLength = outCapacity

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        if error != nil { return }

        let samples = outBuffer.floatChannelData![0]
        accumulator.append(contentsOf: UnsafeBufferPointer(
            start: samples,
            count: Int(outBuffer.frameLength)
        ))

        while accumulator.count >= Self.frameSamples {
            let frame = Array(accumulator.prefix(Self.frameSamples))
            accumulator.removeFirst(Self.frameSamples)
            let data = Data(
                bytes: frame,
                count: frame.count * MemoryLayout<Float>.size
            )
            onFrame?(data)
        }
    }

    // MARK: - Wire frames -> speaker

    func play(_ data: Data) {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: wireFormat,
                  frameCapacity: AVAudioFrameCount(count)
              ) else { return }

        data.withUnsafeBytes { raw in
            buffer.floatChannelData![0].update(
                from: raw.bindMemory(to: Float.self).baseAddress!,
                count: count
            )
        }
        buffer.frameLength = AVAudioFrameCount(count)
        player.scheduleBuffer(buffer)
        if !player.isPlaying {
            player.play()
        }
    }

    // MARK: - Session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth]
        )
        try session.setActive(true)
    }
}

enum VoiceError: LocalizedError {
    case badFormat
    case noHost

    var errorDescription: String? {
        switch self {
        case .badFormat: return "The audio format Alfred needs couldn't be created."
        case .noHost: return "The Mac's address isn't set yet — add it in Settings."
        }
    }
}
