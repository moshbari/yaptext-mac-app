import Foundation
import Combine

// Tracks audio recordings that have been captured but not yet successfully
// transcribed. The audio file stays on disk until transcription succeeds, so
// the user never loses a long dictation to a transient "Server busy" error.

struct PendingRecording: Identifiable, Codable, Equatable {
    let id: UUID
    let fileName: String        // file basename inside the recordings folder
    let mode: String            // "english" | "bengali" | "banglish"
    let timestamp: Date
    var lastError: String?      // nil while a retry is in flight
    var retryCount: Int         // number of failed attempts so far
    var isRetrying: Bool        // true while a request is in flight

    var fileURL: URL {
        PendingRecordingsManager.recordingsFolder.appendingPathComponent(fileName)
    }

    var languageTag: String {
        switch mode {
        case "english":  return "EN"
        case "bengali":  return "BN"
        case "banglish": return "BL"
        default:         return "?"
        }
    }

    var displayMode: String {
        switch mode {
        case "english":  return "English"
        case "bengali":  return "Bengali"
        case "banglish": return "Banglish"
        default:         return mode
        }
    }
}

final class PendingRecordingsManager: ObservableObject {

    static let shared = PendingRecordingsManager()

    let objectWillChange = ObservableObjectPublisher()

    private(set) var entries: [PendingRecording] = [] {
        willSet { objectWillChange.send() }
    }

    private let indexURL: URL
    private let queue = DispatchQueue(label: "com.moshbari.yaptextmac.pending", qos: .utility)
    private let maxAgeDays: Int = 30

    static let recordingsFolder: URL = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let folder = appSupport
            .appendingPathComponent("YapTextMac", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }()

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let folder = appSupport.appendingPathComponent("YapTextMac", isDirectory: true)
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        self.indexURL = folder.appendingPathComponent("pending.json")
        load()
        pruneStaleAndOrphaned()
    }

    // MARK: - Load / Save

    private func load() {
        guard FileManager.default.fileExists(atPath: indexURL.path),
              let data = try? Data(contentsOf: indexURL) else {
            entries = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([PendingRecording].self, from: data) {
            // Reset isRetrying — anything in flight at quit time is no longer in flight.
            entries = decoded.map { e in
                var copy = e
                copy.isRetrying = false
                return copy
            }.sorted { $0.timestamp > $1.timestamp }
        } else {
            entries = []
        }
    }

    private func persist() {
        let snapshot = entries
        let url = indexURL
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Remove rows older than maxAgeDays, and rows whose audio file is missing.
    /// Also delete audio files on disk that no row references.
    private func pruneStaleAndOrphaned() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) ?? Date.distantPast
        let fm = FileManager.default

        var changed = false
        let kept = entries.filter { entry in
            if entry.timestamp < cutoff {
                try? fm.removeItem(at: entry.fileURL)
                changed = true
                return false
            }
            if !fm.fileExists(atPath: entry.fileURL.path) {
                changed = true
                return false
            }
            return true
        }
        if changed { entries = kept; persist() }

        // Orphan sweep — any *.m4a in the folder not referenced by an entry.
        let referenced = Set(entries.map { $0.fileName })
        if let files = try? fm.contentsOfDirectory(at: PendingRecordingsManager.recordingsFolder,
                                                  includingPropertiesForKeys: nil) {
            for f in files where !referenced.contains(f.lastPathComponent) {
                try? fm.removeItem(at: f)
            }
        }
    }

    // MARK: - Mutations (always on main, since views observe this)

    /// Create a new pending row and return the persistent file URL the recorder
    /// should write to. The audio file itself is created by AVAudioRecorder; we
    /// just reserve the row + path.
    @discardableResult
    func register(mode: String, timestamp: Date = Date()) -> PendingRecording {
        let id = UUID()
        let fileName = "rec_\(id.uuidString).m4a"
        let entry = PendingRecording(
            id: id,
            fileName: fileName,
            mode: mode,
            timestamp: timestamp,
            lastError: nil,
            retryCount: 0,
            isRetrying: false
        )
        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            self.persist()
        }
        return entry
    }

    func markRetrying(id: UUID) {
        DispatchQueue.main.async {
            if let i = self.entries.firstIndex(where: { $0.id == id }) {
                self.entries[i].isRetrying = true
                self.entries[i].lastError = nil
                self.persist()
            }
        }
    }

    func markFailed(id: UUID, error: String) {
        DispatchQueue.main.async {
            if let i = self.entries.firstIndex(where: { $0.id == id }) {
                self.entries[i].isRetrying = false
                self.entries[i].lastError = error
                self.entries[i].retryCount += 1
                self.persist()
            }
        }
    }

    /// Remove the row and delete its audio file. Call after a successful transcription.
    func remove(id: UUID) {
        DispatchQueue.main.async {
            guard let i = self.entries.firstIndex(where: { $0.id == id }) else { return }
            let url = self.entries[i].fileURL
            self.entries.remove(at: i)
            self.persist()
            try? FileManager.default.removeItem(at: url)
        }
    }

    func find(id: UUID) -> PendingRecording? {
        return entries.first(where: { $0.id == id })
    }
}
