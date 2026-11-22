import AVFoundation
import Foundation

// A single socket and ordered audio stream per push-to-talk turn.
final class CloudDictation {
    private let engine = AVAudioEngine()
    private let socket: URLSessionWebSocketTask
    private let chunks: AsyncStream<Data>.Continuation
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var captureActive = false

    init(key: String, completion: @escaping (String?) -> Void) throws {
        socket = Self.makeSocket(key: key)
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        chunks = continuation

        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: format) else {
            throw CloudError.audioFormat
        }
        input.installTap(onBus: 0, bufferSize: 2_048, format: source) { buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 24_000 / source.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var supplied = false
            let status = converter.convert(to: output, error: nil) { _, inputStatus in
                inputStatus.pointee = supplied ? .noDataNow : .haveData
                defer { supplied = true }
                return supplied ? nil : buffer
            }
            if status != .error, output.frameLength > 0, let samples = output.int16ChannelData?[0] {
                continuation.yield(Data(bytes: samples, count: Int(output.frameLength) * 2))
            }
        }
        do {
            try engine.start()
            captureActive = true
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }

        let connection = socket
        connection.resume()
        sender = Task {
            do {
                try await Self.send(Self.sessionConfiguration, to: connection)
                var byteCount = 0
                for await chunk in stream {
                    try Task.checkCancellation()
                    byteCount += chunk.count
                    try await Self.send(["type": "input_audio_buffer.append",
                                         "audio": chunk.base64EncodedString()], to: connection)
                }
                guard byteCount >= 4_800 else { completion(""); return }
                try await Self.send(["type": "input_audio_buffer.commit"], to: connection)
            } catch {
                if !Task.isCancelled { completion(nil) }
            }
        }
        receiver = Task {
            do {
                while !Task.isCancelled {
                    let message = try await connection.receive()
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: continue
                    }
                    guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let type = event["type"] as? String else { continue }
                    switch type {
                    case "conversation.item.input_audio_transcription.completed":
                        completion(event["transcript"] as? String)
                        return
                    case "error", "conversation.item.input_audio_transcription.failed":
                        completion(nil)
                        return
                    default: continue
                    }
                }
            } catch {
                if !Task.isCancelled { completion(nil) }
            }
        }
    }

    func finish() {
        if captureActive {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            captureActive = false
        }
        chunks.finish()
    }

    func cancel() {
        sender?.cancel()
        receiver?.cancel()
        finish()
        socket.cancel(with: .normalClosure, reason: nil)
    }

    static func makeSocket(key: String) -> URLSessionWebSocketTask {
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return URLSession.shared.webSocketTask(with: request)
    }

    static let sessionConfiguration: [String: Any] = [
        "type": "session.update",
        "session": [
            "type": "transcription",
            "audio": ["input": [
                "format": ["type": "audio/pcm", "rate": 24_000],
                "transcription": [
                    "model": "gpt-live-transcribe",
                    "languages": ["te", "en"],
                    "prompt": "Natural Telugu-English code-switching. Use Romanized Telugu and preserve English terms.",
                    "delay": "low"
                ],
                "turn_detection": NSNull()
            ]]
        ]
    ]

    static func send(_ event: [String: Any], to socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: event)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private enum CloudError: Error { case audioFormat }
}
