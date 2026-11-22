import Foundation

struct HistoryEntry: Codable {
    let id: UUID
    let date: Date
    var raw: String?
    var output: String?
    var failure: String?

    var title: String {
        let summary = output?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "\(date.formatted(date: .omitted, time: .shortened)) · \(summary.map { String($0.prefix(45)) } ?? "Transcription failed")"
    }
}

final class DictationHistory {
    private let folder: URL
    private let index: URL
    private let limit = 12
    private(set) var entries: [HistoryEntry]

    init(folder: URL = URL.applicationSupportDirectory.appending(path: "Telugish Dictation/History")) {
        self.folder = folder
        index = folder.appending(path: "history.json")
        if let data = try? Data(contentsOf: index),
           let loaded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = loaded
        } else {
            entries = []
        }
    }

    func audio(for id: UUID) -> URL? {
        let url = audioURL(for: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func audioURL(for id: UUID) -> URL {
        folder.appending(path: id.uuidString + ".wav")
    }

    func save(_ entry: HistoryEntry, recording: URL? = nil) throws {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let existing = entries.contains { $0.id == entry.id }
        let updated = existing ? entries.map { $0.id == entry.id ? entry : $0 } : [entry] + entries
        let retained = Array(updated.prefix(limit))
        let evicted = updated.dropFirst(limit)
        let audioFile = audioURL(for: entry.id)
        if let recording, !existing {
            try files.copyItem(at: recording, to: audioFile)
        }
        do {
            try JSONEncoder().encode(retained).write(to: index, options: .atomic)
        } catch {
            if recording != nil && !existing { try? files.removeItem(at: audioFile) }
            throw error
        }
        entries = retained
        for old in evicted { try? files.removeItem(at: audioURL(for: old.id)) }
    }

    func removeAudio() throws {
        for entry in entries {
            if let url = audio(for: entry.id) { try FileManager.default.removeItem(at: url) }
        }
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        entries = []
    }
}
