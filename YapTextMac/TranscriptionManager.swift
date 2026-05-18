import Foundation
import AVFoundation
import Cocoa
import ApplicationServices
import Combine

class TranscriptionManager: ObservableObject {

    // MARK: - Transcription Mode

    enum TranscriptionMode {
        case english   // Whisper, ⌘⇧D
        case bengali   // Sarvam transcribe, ⌘⇧E
        case banglish  // Sarvam translit,   ⌘⇧P

        var label: String {
            switch self {
            case .english:  return "English"
            case .bengali:  return "Bengali"
            case .banglish: return "Banglish"
            }
        }

        var shortcutLabel: String {
            switch self {
            case .english:  return "⌘⇧D"
            case .bengali:  return "⌘⇧E"
            case .banglish: return "⌘⇧P"
            }
        }
    }

    // MARK: - Published State

    var isRecording: Bool = false { willSet { objectWillChange.send() } }
    var transcribedText: String = "" { willSet { objectWillChange.send() } }
    var statusMessage: String = "Ready — ⌘⇧D (EN), ⌘⇧E (BN), ⌘⇧P (Banglish)" { willSet { objectWillChange.send() } }
    var lastAction: String = "" { willSet { objectWillChange.send() } }
    var hasPermissions: Bool = false { willSet { objectWillChange.send() } }
    var currentMode: TranscriptionMode = .english { willSet { objectWillChange.send() } }

    var apiKey: String = "" {
        willSet { objectWillChange.send() }
        didSet { saveAPIKey(apiKey, account: "openai-api-key") }
    }
    var sarvamApiKey: String = "" {
        willSet { objectWillChange.send() }
        didSet { saveAPIKey(sarvamApiKey, account: "sarvam-api-key") }
    }
    var silenceTimeoutSeconds: Double = 3.0 {
        willSet { objectWillChange.send() }
        didSet { UserDefaults.standard.set(silenceTimeoutSeconds, forKey: "silenceTimeoutSeconds") }
    }
    var autoPasteEnabled: Bool = true {
        willSet { objectWillChange.send() }
        didSet { UserDefaults.standard.set(autoPasteEnabled, forKey: "autoPasteEnabled") }
    }

    // Per-recording target app for auto-paste, keyed by PendingRecording.id.
    // Only the initial attempt has an entry here. Retries (fired later from
    // the UI button) have no target app and fall back to clipboard-only.
    private var targetApps: [UUID: NSRunningApplication] = [:]

    /// ID of the most-recently-saved history entry. PolishService updates this
    /// when the user polishes the latest dictation, so history reflects the
    /// final polished version rather than the raw transcript.
    var lastHistoryEntryID: UUID?

    /// ID of the in-flight recording (set in startRecording, cleared after
    /// transcription resolves). Needed so stopRecording can route to the
    /// right pending entry.
    private var currentPendingID: UUID?

    let objectWillChange = ObservableObjectPublisher()

    static let silenceOptions: [(label: String, value: Double)] = [
        ("3 seconds", 3.0),
        ("5 seconds", 5.0),
        ("10 seconds", 10.0),
        ("15 seconds", 15.0),
        ("30 seconds", 30.0),
        ("60 seconds", 60.0)
    ]

    private var audioRecorder: AVAudioRecorder?
    private var audioFileURL: URL?
    private var levelTimer: Timer?
    private var lastSpeechTime: Date = Date()
    private let silenceThreshold: Float = -40.0

    // Service for Bengali / Banglish
    private let sarvamService = SarvamService()

    init() {
        // Load both API keys from Keychain (different accounts, same service)
        self.apiKey       = TranscriptionManager.loadAPIKey(account: "openai-api-key") ?? ""
        self.sarvamApiKey = TranscriptionManager.loadAPIKey(account: "sarvam-api-key") ?? ""

        let savedTimeout = UserDefaults.standard.double(forKey: "silenceTimeoutSeconds")
        self.silenceTimeoutSeconds = savedTimeout > 0 ? savedTimeout : 3.0
        if let savedAutoPaste = UserDefaults.standard.object(forKey: "autoPasteEnabled") as? Bool {
            self.autoPasteEnabled = savedAutoPaste
        }
        checkMicrophonePermission()
    }

    func requestPermissions() { checkMicrophonePermission() }

    private func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasPermissions = true
            statusMessage = "Ready — ⌘⇧D (EN), ⌘⇧E (BN), ⌘⇧P (Banglish)"
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.hasPermissions = granted
                    self?.statusMessage = granted
                        ? "Ready — ⌘⇧D (EN), ⌘⇧E (BN), ⌘⇧P (Banglish)"
                        : "⚠️ Microphone access denied."
                }
            }
        case .denied, .restricted:
            hasPermissions = false
            statusMessage = "⚠️ Microphone access denied. Enable in System Settings → Privacy."
        @unknown default: break
        }
    }

    /// Silent check — call from view code freely; will NOT show a system prompt.
    func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Triggers the macOS system prompt. Call ONLY from an explicit user action
    /// (e.g. a "Grant Accessibility" button), never from a view render.
    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// DEPRECATED — kept only so any external caller still compiles.
    /// Returns the current trust state WITHOUT prompting.
    func checkAccessibilityPermission() -> Bool {
        return isAccessibilityTrusted()
    }

    // MARK: - Toggle Recording (mode-aware)

    /// Called from a hotkey or UI button. If already recording, stops.
    /// If not recording, starts a new recording in the given mode.
    func toggleRecording(mode: TranscriptionMode = .english) {
        if isRecording {
            stopRecording()
        } else {
            startRecording(mode: mode)
        }
    }

    func startRecording(mode: TranscriptionMode = .english) {
        guard hasPermissions else { requestPermissions(); return }

        // Validate the right API key is set for the requested mode
        switch mode {
        case .english:
            guard !apiKey.isEmpty else {
                statusMessage = "⚠️ Enter your OpenAI API key in Settings first"
                return
            }
        case .bengali, .banglish:
            guard !sarvamApiKey.isEmpty else {
                statusMessage = "⚠️ Enter your Sarvam API key in Settings first"
                return
            }
        }

        currentMode = mode

        transcribedText = ""
        lastAction = ""

        // Reserve a persistent slot in PendingRecordingsManager. AVAudioRecorder
        // writes directly into this path; the file survives transcription failures
        // until the user retries successfully (or deletes the row).
        let pending = PendingRecordingsManager.shared.register(mode: modeTag(mode))
        currentPendingID = pending.id
        audioFileURL = pending.fileURL

        // Capture target app for auto-paste — only if it's NOT YapTextMac itself.
        // Stored per-pending-id so a manual retry later doesn't try to paste into
        // a stale (possibly terminated) app.
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let app = frontmost, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApps[pending.id] = app
        }

        guard let fileURL = audioFileURL else { return }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
        } catch {
            statusMessage = "⚠️ Recording failed: \(error.localizedDescription)"
            return
        }

        isRecording = true
        statusMessage = "🎙️ Listening (\(mode.label))..."
        lastSpeechTime = Date()

        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.checkAudioLevel()
        }

        NSSound(named: "Tink")?.play()
    }

    func stopRecording() {
        levelTimer?.invalidate()
        levelTimer = nil
        audioRecorder?.stop()
        isRecording = false

        switch currentMode {
        case .english:
            statusMessage = "⏳ Transcribing with Whisper..."
        case .bengali:
            statusMessage = "⏳ Transcribing Bengali with Sarvam..."
        case .banglish:
            statusMessage = "⏳ Transcribing Banglish with Sarvam..."
        }
        NSSound(named: "Pop")?.play()

        guard let pendingID = currentPendingID else {
            statusMessage = "Ready — ⌘⇧D (EN), ⌘⇧E (BN), ⌘⇧P (Banglish)"
            return
        }
        currentPendingID = nil

        // First attempt + up to 2 auto-retries (5s, 15s). Manual retries from
        // the UI hit attemptTranscription directly with isAutoRetry=false.
        attemptTranscription(pendingID: pendingID, autoRetryRemaining: 2)
    }

    // MARK: - Retry entry point (called from MainView's pending list)

    /// User-triggered retry for a recording that ran out of auto-retries.
    /// Refreshes status to indicate work is in flight and re-fires the request.
    func retryPending(id: UUID) {
        guard let entry = PendingRecordingsManager.shared.find(id: id) else { return }
        statusMessage = "⏳ Retrying \(entry.displayMode)…"
        attemptTranscription(pendingID: id, autoRetryRemaining: 0)
    }

    // MARK: - Transcription request fanout (initial + retries)

    private func attemptTranscription(pendingID: UUID, autoRetryRemaining: Int) {
        guard let entry = PendingRecordingsManager.shared.find(id: pendingID) else { return }
        PendingRecordingsManager.shared.markRetrying(id: pendingID)

        let mode = transcriptionMode(forTag: entry.mode)
        switch mode {
        case .english:
            sendToWhisper(pendingID: pendingID,
                          fileURL: entry.fileURL,
                          autoRetryRemaining: autoRetryRemaining)
        case .bengali:
            sendToSarvam(pendingID: pendingID,
                         fileURL: entry.fileURL,
                         mode: .bengali,
                         autoRetryRemaining: autoRetryRemaining)
        case .banglish:
            sendToSarvam(pendingID: pendingID,
                         fileURL: entry.fileURL,
                         mode: .banglish,
                         autoRetryRemaining: autoRetryRemaining)
        }
    }

    /// Either schedule another auto-retry or leave the row as a manual-retry
    /// candidate. Either way the audio file stays on disk.
    private func handleTranscriptionFailure(pendingID: UUID,
                                            error: String,
                                            autoRetryRemaining: Int) {
        if autoRetryRemaining > 0 {
            // Backoff: 5s then 15s. Status shows what's happening so the user
            // doesn't think the app is frozen.
            let delay: TimeInterval = (autoRetryRemaining == 2) ? 5 : 15
            statusMessage = "⚠️ \(error) — retrying in \(Int(delay))s…"
            PendingRecordingsManager.shared.markFailed(id: pendingID, error: error)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.attemptTranscription(pendingID: pendingID,
                                           autoRetryRemaining: autoRetryRemaining - 1)
            }
        } else {
            PendingRecordingsManager.shared.markFailed(id: pendingID, error: error)
            statusMessage = "⚠️ \(error) — tap Retry in the Pending list."
            lastAction = "💾 Recording saved — retry from the popover."
        }
    }

    private func checkAudioLevel() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let averagePower = recorder.averagePower(forChannel: 0)
        if averagePower > silenceThreshold {
            lastSpeechTime = Date()
        } else if Date().timeIntervalSince(lastSpeechTime) >= silenceTimeoutSeconds {
            DispatchQueue.main.async { [weak self] in self?.stopRecording() }
        }
    }

    // MARK: - English pipeline (OpenAI Whisper)

    private func sendToWhisper(pendingID: UUID, fileURL: URL, autoRetryRemaining: Int) {
        // English transcription is now routed through the YapText server on
        // Railway (same backend the iOS app uses). The server holds the
        // OpenAI key and handles long-audio chunking/punctuation. The user's
        // OpenAI key in Settings is no longer needed for transcription —
        // it's kept only for the Polish feature, which still calls OpenAI
        // directly to preserve Mac-specific tones the server doesn't know.

        guard FileManager.default.fileExists(atPath: fileURL.path),
              let audioData = try? Data(contentsOf: fileURL) else {
            handleTranscriptionFailure(pendingID: pendingID,
                                       error: "Could not read audio file",
                                       autoRetryRemaining: autoRetryRemaining)
            return
        }
        // Too-short recordings will never transcribe — drop the row + file.
        guard audioData.count > 1000 else {
            statusMessage = "Recording too short. Try again."
            PendingRecordingsManager.shared.remove(id: pendingID)
            targetApps.removeValue(forKey: pendingID)
            return
        }

        // YapText API (Railway) — same constants used by SarvamService.
        let apiBaseURL = "https://yaptext-api-production.up.railway.app"
        let appSecret = "6cf0dbc29b678a29f462c945b1f09c15fc02ae03d07d626071912fc1c09e7e61"

        let boundary = "yaptext-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "\(apiBaseURL)/transcribe")!)
        request.httpMethod = "POST"
        request.setValue(appSecret, forHTTPHeaderField: "X-App-Secret")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        var body = Data()

        // language field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("english\r\n".data(using: .utf8)!)

        // audio file field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.handleTranscriptionFailure(pendingID: pendingID,
                                                   error: "Network error: \(error.localizedDescription)",
                                                   autoRetryRemaining: autoRetryRemaining)
                    return
                }
                guard let http = response as? HTTPURLResponse, let data = data else {
                    self.handleTranscriptionFailure(pendingID: pendingID,
                                                   error: "Invalid response",
                                                   autoRetryRemaining: autoRetryRemaining)
                    return
                }
                if http.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let text = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !text.isEmpty {
                        self.transcribedText = text
                        self.finishTranscription(pendingID: pendingID)
                    } else {
                        // 200 but no speech — not worth keeping the audio.
                        self.statusMessage = "No speech detected. Try again."
                        PendingRecordingsManager.shared.remove(id: pendingID)
                        self.targetApps.removeValue(forKey: pendingID)
                    }
                } else if http.statusCode == 401 {
                    // Auth failure is not transient — manual retry won't help either.
                    self.statusMessage = "⚠️ App auth failed. Update YapText to the latest version."
                    PendingRecordingsManager.shared.markFailed(id: pendingID,
                                                               error: "App auth failed (update needed)")
                } else if http.statusCode == 429 {
                    self.handleTranscriptionFailure(pendingID: pendingID,
                                                   error: "Server busy",
                                                   autoRetryRemaining: autoRetryRemaining)
                } else {
                    var msg = "Server error (\(http.statusCode))"
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let err = json["error"] as? String {
                        msg = err
                    }
                    self.handleTranscriptionFailure(pendingID: pendingID,
                                                   error: String(msg.prefix(120)),
                                                   autoRetryRemaining: autoRetryRemaining)
                }
            }
        }.resume()
    }

    // MARK: - Bengali / Banglish pipeline (Sarvam)

    private func sendToSarvam(pendingID: UUID,
                              fileURL: URL,
                              mode: SarvamService.SarvamMode,
                              autoRetryRemaining: Int) {
        sarvamService.transcribe(
            fileURL: fileURL,
            apiKey: sarvamApiKey,
            mode: mode
        ) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let text):
                self.transcribedText = text
                self.finishTranscription(pendingID: pendingID)
            case .failure(let reason):
                self.handleTranscriptionFailure(pendingID: pendingID,
                                                error: reason,
                                                autoRetryRemaining: autoRetryRemaining)
            }
        }
    }

    // MARK: - Finalize (copy + auto-paste)

    private func finishTranscription(pendingID: UUID) {
        // Capture mode BEFORE removing the row (remove() dispatches async).
        let mode = pendingEntryMode(pendingID: pendingID) ?? currentMode

        // The audio for this row has been transcribed — drop the file + row.
        PendingRecordingsManager.shared.remove(id: pendingID)
        let targetApp = targetApps.removeValue(forKey: pendingID)

        let text = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusMessage = "Ready — ⌘⇧D (EN), ⌘⇧E (BN), ⌘⇧P (Banglish)"
            return
        }

        // Persist to history (the polished version, if any, will overwrite this entry's text)
        lastHistoryEntryID = HistoryManager.shared.save(
            text: text,
            language: HistoryManager.languageTag(forMode: mode)
        )

        // Always copy to clipboard first
        copyToClipboard(text)

        // If auto-paste is OFF → just clipboard
        guard autoPasteEnabled else {
            lastAction = "📋 Copied — paste with ⌘V"
            statusMessage = "Done (\(mode.label)) — Copied to clipboard"
            return
        }

        // Need Accessibility permission to simulate keystrokes
        guard AXIsProcessTrusted() else {
            lastAction = "📋 Copied — Grant Accessibility for auto-paste"
            statusMessage = "Done — Copied to clipboard"
            return
        }

        // Need a target app that isn't YapTextMac, and still running.
        // Manual retries have no stored targetApp — they always fall through here.
        guard let target = targetApp, !target.isTerminated else {
            lastAction = "📋 Copied — paste with ⌘V"
            statusMessage = "Done (\(mode.label)) — Copied to clipboard"
            return
        }

        // Activate the target app, then paste
        target.activate(options: .activateIgnoringOtherApps)
        let appName = target.localizedName ?? "app"
        statusMessage = "⌘V → \(appName)..."

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.simulateCmdV()
            self?.lastAction = "✅ Auto-pasted into \(appName)"
            self?.statusMessage = "Done (\(mode.label)) — Auto-pasted into \(appName)"
        }
    }

    // MARK: - Mode tag helpers (bridge between the enum and the persisted string)

    private func modeTag(_ mode: TranscriptionMode) -> String {
        switch mode {
        case .english:  return "english"
        case .bengali:  return "bengali"
        case .banglish: return "banglish"
        }
    }

    private func transcriptionMode(forTag tag: String) -> TranscriptionMode {
        switch tag {
        case "bengali":  return .bengali
        case "banglish": return .banglish
        default:         return .english
        }
    }

    /// Resolve a pending row's mode at success time. The row is removed
    /// just before this is called, so we also fall through to `currentMode`.
    private func pendingEntryMode(pendingID: UUID) -> TranscriptionMode? {
        guard let tag = PendingRecordingsManager.shared.find(id: pendingID)?.mode else { return nil }
        return transcriptionMode(forTag: tag)
    }

    private func simulateCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Keychain (shared service, different accounts per key)

    private func saveAPIKey(_ key: String, account: String) {
        guard let data = key.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.moshbari.yaptextmac",
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
    }

    static func loadAPIKey(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.moshbari.yaptextmac",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
