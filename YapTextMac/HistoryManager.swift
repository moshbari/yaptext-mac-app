import Foundation
import Combine

struct DictationEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    let timestamp: Date
    let language: String  // "EN" | "BN" | "BL"
}

final class HistoryManager: ObservableObject {

    static let shared = HistoryManager()

    let objectWillChange = ObservableObjectPublisher()

    private(set) var entries: [DictationEntry] = [] {
        willSet { objectWillChange.send() }
    }

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.moshbari.yaptextmac.history", qos: .utility)
    private let maxAgeDays: Int = 30

    private init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let folder = appSupport.appendingPathComponent("YapTextMac", isDirectory: true)
        if !fm.fileExists(atPath: folder.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        self.fileURL = folder.appendingPathComponent("history.json")
        load()
    }

    // MARK: - Mode → Language tag

    static func languageTag(forMode mode: TranscriptionManager.TranscriptionMode) -> String {
        switch mode {
        case .english:  return "EN"
        case .bengali:  return "BN"
        case .banglish: return "BL"
        }
    }

    // MARK: - Load / Save

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            entries = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([DictationEntry].self, from: data) {
            entries = decoded.sorted { $0.timestamp > $1.timestamp }
        } else {
            entries = []
        }
    }

    private func persist() {
        let snapshot = entries
        let url = fileURL
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func prune() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: Date()) ?? Date.distantPast
        entries = entries.filter { $0.timestamp >= cutoff }
    }

    // MARK: - Public API

    @discardableResult
    func save(text: String, language: String, timestamp: Date = Date()) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let entry = DictationEntry(id: UUID(), text: trimmed, timestamp: timestamp, language: language)
        DispatchQueue.main.async {
            self.entries.insert(entry, at: 0)
            self.prune()
            self.persist()
        }
        return entry.id
    }

    /// Replace the text of an existing entry (used when polish post-processes a dictation).
    func updateText(id: UUID, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DispatchQueue.main.async {
            if let idx = self.entries.firstIndex(where: { $0.id == id }) {
                self.entries[idx].text = trimmed
                self.persist()
            }
        }
    }

    func delete(id: UUID) {
        DispatchQueue.main.async {
            self.entries.removeAll { $0.id == id }
            self.persist()
        }
    }

    func clearAll() {
        DispatchQueue.main.async {
            self.entries.removeAll()
            self.persist()
        }
    }

    func recent(_ n: Int) -> [DictationEntry] {
        return Array(entries.prefix(n))
    }

    func search(query: String, language: String?) -> [DictationEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            let matchesLang = (language == nil || language == "All") || entry.language == language
            let matchesQuery = q.isEmpty || entry.text.lowercased().contains(q)
            return matchesLang && matchesQuery
        }
    }

    // MARK: - Formatting helpers

    static let exactFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy — h:mm:ss a"
        return f
    }()

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.dateTimeStyle = .named
        return f
    }()

    static func formatExact(_ date: Date) -> String {
        return exactFormatter.string(from: date)
    }

    static func formatRelative(_ date: Date) -> String {
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Export

    func exportAsText(entries: [DictationEntry]? = nil) -> String {
        let list = entries ?? self.entries
        return list.map { entry in
            "[\(HistoryManager.formatExact(entry.timestamp))]  [\(entry.language)]\n\(entry.text)"
        }.joined(separator: "\n\n")
    }
}
