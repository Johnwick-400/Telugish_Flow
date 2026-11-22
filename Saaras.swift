import AVFoundation
import Foundation

enum RecordedTranscriptionError: LocalizedError {
    case http(Int), invalidResponse, invalidAudio, realtime(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .invalidResponse: return "The service did not return a transcript."
        case .invalidAudio: return "Hold the shortcut a little longer and speak."
        case .realtime(let code): return "Realtime rejected the request (\(code))."
        }
    }
}

enum Saaras {
    static func request(wav: Data, key: String, keyterms: [String] = []) -> URLRequest {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.sarvam.ai/speech-to-text")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "api-subscription-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        var fields = [("model", "saaras:v4"), ("mode", "translit"), ("language_code", "te-IN")]
        if !keyterms.isEmpty, let encoded = try? JSONEncoder().encode(keyterms) {
            fields.append(("keyterms", String(decoding: encoded, as: UTF8.self)))
        }
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    static func transcribe(wav: Data, key: String, keyterms: [String] = []) async throws -> String {
        let request = request(wav: wav, key: key, keyterms: keyterms)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RecordedTranscriptionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw RecordedTranscriptionError.http(http.statusCode) }
        struct Reply: Decodable { let transcript: String }
        return try JSONDecoder().decode(Reply.self, from: data).transcript
    }
}

extension CloudDictation {
    static func recordingPCM(at url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard file.length > 0, file.length <= Int64(source.sampleRate * 30),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)),
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 720_032) else {
            throw RecordedTranscriptionError.invalidAudio
        }
        try file.read(into: input)
        var supplied = false
        let status = converter.convert(to: output, error: nil) { _, inputStatus in
            inputStatus.pointee = supplied ? .endOfStream : .haveData
            defer { supplied = true }
            return supplied ? nil : input
        }
        guard status != .error, output.frameLength >= 2_400,
              let samples = output.int16ChannelData?[0] else {
            throw RecordedTranscriptionError.invalidAudio
        }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }

    static func transcribeRecording(at url: URL, key: String) async throws -> String {
        let pcm = try recordingPCM(at: url)
        let socket = makeSocket(key: key)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let timeout = Task {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }
        try await send(sessionConfiguration, to: socket)
        while try await event(from: socket)["type"] as? String != "session.updated" {}
        for offset in stride(from: 0, to: pcm.count, by: 9_600) {
            let chunk = pcm[offset..<min(offset + 9_600, pcm.count)]
            try await send(["type": "input_audio_buffer.append", "audio": chunk.base64EncodedString()], to: socket)
        }
        try await send(["type": "input_audio_buffer.commit"], to: socket)
        while true {
            let message = try await event(from: socket)
            switch message["type"] as? String {
            case "conversation.item.input_audio_transcription.completed":
                guard let transcript = message["transcript"] as? String else {
                    throw RecordedTranscriptionError.invalidResponse
                }
                return transcript
            case "conversation.item.input_audio_transcription.failed":
                throw RecordedTranscriptionError.invalidResponse
            default: continue
            }
        }
    }

    private static func event(from socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        let data: Data
        switch try await socket.receive() {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: throw RecordedTranscriptionError.invalidResponse
        }
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RecordedTranscriptionError.invalidResponse
        }
        if event["type"] as? String == "error" {
            let code = (event["error"] as? [String: Any])?["code"] as? String
            let safeCode = code.flatMap { $0.range(of: "^[a-z0-9_.-]{1,64}$", options: .regularExpression) == nil ? nil : $0 }
            throw RecordedTranscriptionError.realtime(safeCode ?? "service_error")
        }
        return event
    }
}
