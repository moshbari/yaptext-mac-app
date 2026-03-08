import Foundation
import AVFoundation
import Cocoa
import ApplicationServices
import Combine

class TranscriptionManager: ObservableObject {
    
    var isRecording: Bool = false { willSet { objectWillChange.send() } }
    var transcribedText: String = "" { willSet { objectWillChange.send() } }
    var statusMessage: String = "Ready — Press ⌘⇧D or click Start" { willSet { objectWillChange.send() } }
    var lastAction: String = "" { willSet { objectWillChange.send() } }
    var hasPermissions: Bool = false { willSet { objectWillChange.send() } }
    var apiKey: String = "" {
        willSet { objectWillChange.send() }
        didSet { saveAPIKey(apiKey) }
    }
    
    let objectWillChange = ObservableObjectPublisher()
    
    private var audioRecorder: AVAudioRecorder?
    private var audioFileURL: URL?
    private var levelTimer: Timer?
    private let silenceTimeout: TimeInterval = 30.0
    private var lastSpeechTime: Date = Date()
    private let silenceThreshold: Float = -40.0
    
    init() {
        let saved = TranscriptionManager.loadAPIKey() ?? ""
        self.apiKey = saved
        checkMicrophonePermission()
    }
    
    func requestPermissions() { checkMicrophonePermission() }
    
    private func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasPermissions = true
            statusMessage = "Ready — Press ⌘⇧D or click Start"
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.hasPermissions = granted
                    self?.statusMessage = granted ? "Ready — Press ⌘⇧D or click Start" : "⚠️ Microphone access denied."
                }
            }
        case .denied, .restricted:
            hasPermissions = false
            statusMessage = "⚠️ Microphone access denied. Enable in System Settings → Privacy."
        @unknown default: break
        }
    }
    
    func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }
    
    func startRecording() {
        guard hasPermissions else { requestPermissions(); return }
        guard !apiKey.isEmpty else { statusMessage = "⚠️ Enter your OpenAI API key first"; return }
        
        transcribedText = ""
        lastAction = ""
        
        let tempDir = FileManager.default.temporaryDirectory
        audioFileURL = tempDir.appendingPathComponent("yaptextmac_\(UUID().uuidString).m4a")
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
        statusMessage = "🎙️ Listening..."
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
        statusMessage = "⏳ Transcribing with Whisper..."
        NSSound(named: "Pop")?.play()
        
        if let fileURL = audioFileURL {
            sendToWhisper(fileURL: fileURL)
        } else {
            statusMessage = "Ready — Press ⌘⇧D or click Start"
        }
    }
    
    private func checkAudioLevel() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let averagePower = recorder.averagePower(forChannel: 0)
        if averagePower > silenceThreshold {
            lastSpeechTime = Date()
        } else if Date().timeIntervalSince(lastSpeechTime) >= silenceTimeout {
            DispatchQueue.main.async { [weak self] in self?.stopRecording() }
        }
    }
    
    private func sendToWhisper(fileURL: URL) {
        guard !apiKey.isEmpty else { statusMessage = "⚠️ No API key configured"; return }
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let audioData = try? Data(contentsOf: fileURL) else {
            statusMessage = "⚠️ Could not read audio file"; return
        }
        guard audioData.count > 1000 else {
            statusMessage = "Recording too short. Try again."
            cleanup(fileURL: fileURL); return
        }
        
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("model", "whisper-1")
        appendField("language", "en")
        appendField("response_format", "text")
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            defer { self?.cleanup(fileURL: fileURL) }
            DispatchQueue.main.async {
                if let error = error {
                    self?.statusMessage = "⚠️ Network error: \(error.localizedDescription)"; return
                }
                guard let http = response as? HTTPURLResponse, let data = data else {
                    self?.statusMessage = "⚠️ Invalid response"; return
                }
                if http.statusCode == 200 {
                    if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        self?.transcribedText = text
                        self?.finishTranscription()
                    } else { self?.statusMessage = "No speech detected. Try again." }
                } else if http.statusCode == 401 {
                    self?.statusMessage = "⚠️ Invalid API key. Check settings."
                } else if http.statusCode == 429 {
                    self?.statusMessage = "⚠️ Rate limited. Wait and try again."
                } else {
                    let e = String(data: data, encoding: .utf8) ?? "Unknown"
                    self?.statusMessage = "⚠️ API error (\(http.statusCode)): \(String(e.prefix(100)))"
                }
            }
        }.resume()
    }
    
    private func cleanup(fileURL: URL) { try? FileManager.default.removeItem(at: fileURL) }
    
    private func finishTranscription() {
        let text = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { statusMessage = "Ready — Press ⌘⇧D or click Start"; return }
        
        // Always copy to clipboard
        copyToClipboard(text)
        
        // Also try to insert into focused text field
        if insertTextIntoFocusedField(text) {
            lastAction = "✅ Inserted into active text field + 📋 clipboard"
            statusMessage = "Done — Text inserted + copied"
        } else {
            lastAction = "📋 Copied to clipboard"
            statusMessage = "Done — Copied to clipboard"
        }
    }
    
    private func insertTextIntoFocusedField(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement else { return false }
        
        let axElement = element as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role)
        
        if let roleStr = role as? String,
           roleStr == kAXTextFieldRole || roleStr == kAXTextAreaRole || roleStr == "AXComboBox" || roleStr == "AXSearchField" {
            var currentValue: CFTypeRef?
            AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &currentValue)
            let newText: String
            if let existing = currentValue as? String, !existing.isEmpty {
                newText = existing + " " + text
            } else {
                newText = text
            }
            return AXUIElementSetAttributeValue(axElement, kAXValueAttribute as CFString, newText as CFTypeRef) == .success
        }
        return insertViaKeyboardSimulation(text)
    }
    
    private func insertViaKeyboardSimulation(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        let prev = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        
        if let prev = prev {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pasteboard.clearContents()
                pasteboard.setString(prev, forType: .string)
            }
        }
        return true
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    
    private func saveAPIKey(_ key: String) {
        guard let data = key.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.moshbari.yaptextmac",
            kSecAttrAccount as String: "openai-api-key"
        ]
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = data
        SecItemAdd(q as CFDictionary, nil)
    }
    
    static func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.moshbari.yaptextmac",
            kSecAttrAccount as String: "openai-api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
