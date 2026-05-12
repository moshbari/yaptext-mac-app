import SwiftUI

struct MainView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    @StateObject private var polishService = PolishService()
    @State private var showSettings = false
    @State private var selectedTone: PolishService.Tone = .fixOnly
    @State private var showPolishedSection = false
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("YapTextMac")
                    .font(.headline)
                Text(appVersion)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
                Spacer()
                Button(action: { showSettings.toggle() }) {
                    Image(systemName: "gearshape.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
                
                Button(action: { NSApp.terminate(nil) }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            if showSettings {
                settingsSection
            } else {
                mainSection
            }
        }
        .padding()
        .frame(width: 360)
    }
    
    // MARK: - Main Section
    
    private var mainSection: some View {
        VStack(spacing: 14) {
            // API Key Warning
            if transcriptionManager.apiKey.isEmpty && transcriptionManager.sarvamApiKey.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Add your API keys in")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Settings") { showSettings = true }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(6)
            } else if transcriptionManager.apiKey.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("OpenAI key missing — ⌘⇧D won't work")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Add") { showSettings = true }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(6)
            } else if transcriptionManager.sarvamApiKey.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Sarvam key missing — ⌘⇧E / ⌘⇧P won't work")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Add") { showSettings = true }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(6)
            }
            
            Divider()
            
            // Status
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(currentStatusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            
            // Transcription Display
            GroupBox(label: Text(showPolishedSection ? "Polished" : "Transcription").font(.caption).foregroundColor(.secondary)) {
                ScrollView {
                    Text(displayText.isEmpty ? "Your transcription will appear here..." : displayText)
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(displayText.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 130)
            }
            
            // Toggle between original and polished
            if !polishService.polishedText.isEmpty {
                HStack(spacing: 8) {
                    Button(action: { showPolishedSection = false }) {
                        Text("Original")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(showPolishedSection ? Color.clear : Color.accentColor.opacity(0.2))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { showPolishedSection = true }) {
                        Text("✨ Polished")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(showPolishedSection ? Color.accentColor.opacity(0.2) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                }
            }
            
            // AI Polish Section
            if !transcriptionManager.transcribedText.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(.accentColor)
                                .font(.caption)
                            Text("Polish with AI")
                                .font(.caption)
                                .fontWeight(.medium)
                            Spacer()
                        }
                        
                        HStack(spacing: 8) {
                            Picker("", selection: $selectedTone) {
                                ForEach(PolishService.Tone.allCases, id: \.self) { tone in
                                    Label(tone.rawValue, systemImage: tone.icon).tag(tone)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            
                            Button(action: polishNow) {
                                if polishService.isPolishing {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "wand.and.stars")
                                }
                            }
                            .disabled(polishService.isPolishing || transcriptionManager.apiKey.isEmpty)
                            .help("Polish text with selected tone")
                        }
                        
                        if let err = polishService.errorMessage {
                            Text("⚠️ \(err)")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(6)
                }
            }
            
            // Last Action
            if !transcriptionManager.lastAction.isEmpty {
                HStack {
                    Text(transcriptionManager.lastAction)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                    Spacer()
                }
            }
            
            // Controls
            HStack(spacing: 12) {
                Button(action: {
                    polishService.polishedText = ""
                    polishService.errorMessage = nil
                    showPolishedSection = false
                    transcriptionManager.toggleRecording()
                }) {
                    HStack {
                        Image(systemName: transcriptionManager.isRecording ? "stop.fill" : "mic.fill")
                        Text(transcriptionManager.isRecording ? "Stop" : "Start")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(transcriptionManager.isRecording ? .red : .accentColor)
                .keyboardShortcut(.return, modifiers: [])
                
                Button(action: copyCurrentDisplay) {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(displayText.isEmpty)
                .help("Copy to clipboard")
            }
            
            // Footer
            HStack {
                Image(systemName: "command")
                    .font(.caption2)
                Image(systemName: "shift")
                    .font(.caption2)
                Text("D — Global hotkey")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                
                if transcriptionManager.checkAccessibilityPermission() {
                    Label("AX", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.green)
                } else {
                    Button(action: {
                        _ = transcriptionManager.checkAccessibilityPermission()
                    }) {
                        Label("Grant AX", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Grant Accessibility to enable auto-insertion into text fields")
                }
            }
        }
    }
    
    // MARK: - Polish Action
    
    private func polishNow() {
        polishService.polish(
            text: transcriptionManager.transcribedText,
            tone: selectedTone,
            apiKey: transcriptionManager.apiKey
        )
        observePolishCompletion()
    }
    
    private func observePolishCompletion() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !polishService.polishedText.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(polishService.polishedText, forType: .string)
                transcriptionManager.lastAction = "✨ Polished — copied to clipboard, paste with ⌘V"
                showPolishedSection = true
            } else if polishService.isPolishing {
                observePolishCompletion()
            }
        }
    }
    
    private func copyCurrentDisplay() {
        let text = displayText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        transcriptionManager.lastAction = "📋 Copied to clipboard"
    }
    
    // MARK: - Settings Section
    
    private var settingsSection: some View {
        ScrollView {
            VStack(spacing: 14) {
                Divider()
                
                // API Key
                GroupBox("OpenAI API Key (for English / Polish)") {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("sk-...", text: $transcriptionManager.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                            Text("Stored securely in macOS Keychain")
                                .font(.caption2)
                        }
                        .foregroundColor(.secondary)
                        
                        if !transcriptionManager.apiKey.isEmpty {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text("Key saved")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    .padding(6)
                }

                // Sarvam API Key — for Bengali (⌘⇧E) and Banglish (⌘⇧P)
                GroupBox("Sarvam API Key (for Bengali / Banglish)") {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("sk_...", text: $transcriptionManager.sarvamApiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                            Text("Stored securely in macOS Keychain")
                                .font(.caption2)
                        }
                        .foregroundColor(.secondary)

                        if !transcriptionManager.sarvamApiKey.isEmpty {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text("Key saved")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }

                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                            Text("Get a free key at sarvam.ai")
                                .font(.caption2)
                        }
                        .foregroundColor(.secondary)
                    }
                    .padding(6)
                }
                
                // Permissions
                GroupBox("Permissions") {
                    VStack(alignment: .leading, spacing: 8) {
                        permissionRow(
                            icon: "mic.fill",
                            label: "Microphone",
                            granted: transcriptionManager.hasPermissions
                        )
                        permissionRow(
                            icon: "accessibility",
                            label: "Accessibility (for text field insertion)",
                            granted: transcriptionManager.checkAccessibilityPermission()
                        )
                        
                        Button("Open System Settings → Privacy") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                        }
                        .font(.caption)
                    }
                    .padding(6)
                }
                
                // Silence Timeout
                GroupBox("Silence Auto-Stop") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Stop recording after this much silence:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Picker("", selection: $transcriptionManager.silenceTimeoutSeconds) {
                            ForEach(TranscriptionManager.silenceOptions, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                            Text("Lower = faster auto-stop. Higher = more thinking time between words.")
                                .font(.caption2)
                        }
                        .foregroundColor(.secondary)
                    }
                    .padding(6)
                }
                
                // Auto-paste toggle
                GroupBox("Auto-Paste") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $transcriptionManager.autoPasteEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-paste into active text field")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text("After transcription, simulates ⌘V into the app you were using when you started recording.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        
                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                            Text("Tip: Click in your text field FIRST, then press the shortcut (⌘⇧D / ⌘⇧E / ⌘⇧P).")
                                .font(.caption2)
                        }
                        .foregroundColor(.secondary)
                    }
                    .padding(6)
                }
                
                // How It Works
                GroupBox("How It Works") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Three shortcuts — each picks the language:")
                            .fontWeight(.medium)
                        Text("• ⌘⇧D → English (OpenAI Whisper)")
                        Text("• ⌘⇧E → Bengali script (Sarvam)")
                        Text("• ⌘⇧P → Banglish / Romanized (Sarvam)")
                        Divider()
                        Text("1. Click in your text field")
                        Text("2. Press the shortcut for the language you'll speak")
                        Text("3. Speak — press the same shortcut again to stop")
                        Text("4. Auto-stops after \(Int(transcriptionManager.silenceTimeoutSeconds))s of silence")
                        Text("5. Text auto-inserts into focused field + clipboard")
                        Text("6. Optional: Pick a tone and tap ✨ to polish with AI (English only)")
                    }
                    .font(.caption)
                    .padding(6)
                }
                
                Button(action: { showSettings = false }) {
                    HStack {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
        }
        .frame(maxHeight: 500)
    }
    
    // MARK: - Helpers
    
    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return "v\(v)"
    }
    
    private var displayText: String {
        if showPolishedSection && !polishService.polishedText.isEmpty {
            return polishService.polishedText
        }
        return transcriptionManager.transcribedText
    }
    
    private var currentStatusMessage: String {
        if polishService.isPolishing { return "✨ Polishing with AI..." }
        return transcriptionManager.statusMessage
    }
    
    private var statusColor: Color {
        if transcriptionManager.isRecording { return .red }
        if polishService.isPolishing { return .purple }
        if transcriptionManager.statusMessage.contains("⏳") { return .orange }
        if transcriptionManager.statusMessage.contains("Done") { return .green }
        return .green
    }
    
    private func permissionRow(icon: String, label: String, granted: Bool) -> some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 16)
            Text(label)
                .font(.caption)
            Spacer()
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(granted ? .green : .red)
                .font(.caption)
        }
    }
}

struct SettingsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("YapTextMac Settings")
                .font(.title2)
            Text("Use the gear icon in the popover to configure your API key and permissions.")
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding()
        .frame(width: 300, height: 150)
    }
}
