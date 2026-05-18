import SwiftUI

struct MainView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    @ObservedObject private var history = HistoryManager.shared
    @ObservedObject private var pending = PendingRecordingsManager.shared
    @StateObject private var polishService = PolishService()
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var selectedTone: PolishService.Tone = .fixOnly
    @State private var showPolishedSection = false
    @State private var copiedHistoryID: UUID? = nil
    @State private var pendingToDelete: PendingRecording? = nil
    
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
                Button(action: {
                    showHistory.toggle()
                    if showHistory { showSettings = false }
                }) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(showHistory ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("History")

                Button(action: {
                    showSettings.toggle()
                    if showSettings { showHistory = false }
                }) {
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
            } else if showHistory {
                historySection
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
            // Accessibility banner — the #1 reason auto-paste fails. Shown
            // big and red the moment AX isn't granted, with one-tap actions
            // that open the Settings pane AND fire the system request prompt.
            if !transcriptionManager.isAccessibilityTrusted() {
                axDeniedBanner
            }

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
            
            // Pending recordings — surfaced whenever a recording is still
            // awaiting transcription (server busy, network blip, app quit
            // mid-transcribe). Audio is on disk until the user retries
            // successfully or deletes the row.
            if !pending.entries.isEmpty {
                pendingSection
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
                Text("⌘⇧D / ⌘⇧E / ⌘⇧P — Global hotkeys")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                
                if transcriptionManager.isAccessibilityTrusted() {
                    Label("AX", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.green)

                    // macOS sometimes caches AX trust per-process. If the grant was
                    // toggled WHILE the app was running, the cached state may stay
                    // "denied" until the app restarts — auto-paste silently falls
                    // back to clipboard-only. This button is the safety valve.
                    Button(action: relaunchApp) {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Quit & relaunch — fixes auto-paste if it stopped working after granting AX")
                } else {
                    Button(action: {
                        transcriptionManager.requestAccessibilityPermission()
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
                if let id = transcriptionManager.lastHistoryEntryID {
                    HistoryManager.shared.updateText(id: id, newText: polishService.polishedText)
                }
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
                
                // OpenAI API Key — now only used by the Polish feature.
                // English transcription routes through the YapText server.
                GroupBox("OpenAI API Key (for Polish only)") {
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

                        HStack(spacing: 4) {
                            Image(systemName: "info.circle")
                                .font(.caption2)
                            Text("English / Bengali / Banglish transcription is now handled by the YapText server — no key needed for those.")
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

                // Sarvam key is now handled server-side. Field intentionally
                // disabled (not removed) so we can re-enable if we ever
                // revert to BYOK without losing the keychain entry.
                GroupBox("Sarvam API Key (no longer needed)") {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("sk_...", text: $transcriptionManager.sarvamApiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .disabled(true)
                            .opacity(0.5)

                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption2)
                                .foregroundColor(.green)
                            Text("Bengali / Banglish is now handled by the YapText server — your Sarvam key is no longer required.")
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
                            granted: transcriptionManager.isAccessibilityTrusted()
                        )

                        if !transcriptionManager.isAccessibilityTrusted() {
                            Button("Grant Accessibility…") {
                                transcriptionManager.requestAccessibilityPermission()
                            }
                            .font(.caption)
                        }

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

    // MARK: - Accessibility Denied Banner

    private var axDeniedBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.white)
                Text("Auto-paste is OFF")
                    .font(.system(.body, design: .rounded).weight(.bold))
                    .foregroundColor(.white)
                Spacer()
            }
            Text("macOS needs Accessibility permission to type your transcription into the focused text field. Without it, transcripts only land on the clipboard (paste with ⌘V).")
                .font(.caption)
                .foregroundColor(.white.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: grantAXNow) {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.open.fill")
                        Text("Grant Accessibility")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button(action: openAXPane) {
                    Text("Open Settings")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red)
        .cornerRadius(8)
    }

    /// One-tap recovery: fire the system AX request prompt AND open the
    /// pane simultaneously. The prompt adds YapTextMac to the list with
    /// a toggle; the pane gives the user one click to flip it ON.
    private func grantAXNow() {
        transcriptionManager.requestAccessibilityPermission()
        openAXPane()
    }

    private func openAXPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Pending Recordings Section

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text("Awaiting transcription (\(pending.entries.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                Spacer()
            }

            VStack(spacing: 4) {
                ForEach(pending.entries) { entry in
                    pendingRow(entry)
                }
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
        .cornerRadius(6)
        .alert("Delete this recording?", isPresented: Binding(
            get: { pendingToDelete != nil },
            set: { if !$0 { pendingToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingToDelete = nil }
            Button("Delete", role: .destructive) {
                if let entry = pendingToDelete {
                    PendingRecordingsManager.shared.remove(id: entry.id)
                }
                pendingToDelete = nil
            }
        } message: {
            Text("The saved audio for this dictation will be discarded.")
        }
    }

    private func pendingRow(_ entry: PendingRecording) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.languageTag)
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(historyBadgeColor(entry.languageTag))
                    .cornerRadius(3)
                Text(HistoryManager.formatRelative(entry.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if entry.isRetrying {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                } else {
                    Button(action: { transcriptionManager.retryPending(id: entry.id) }) {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.accentColor)
                    .help("Try transcription again")
                }
                Button(action: { pendingToDelete = entry }) {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .help("Delete recording")
            }
            if let err = entry.lastError, !err.isEmpty {
                Text("⚠️ \(err)" + (entry.retryCount > 1 ? " (\(entry.retryCount) tries)" : ""))
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.4))
        .cornerRadius(4)
    }

    // MARK: - History Section (last 7)

    private var historySection: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Recent Dictations")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(history.entries.count) total")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            if history.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                    Text("No dictations yet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Press ⌘⇧D / ⌘⇧E / ⌘⇧P to start.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(history.recent(7)) { entry in
                            historyRow(entry)
                        }
                    }
                }
                .frame(height: 280)
            }

            Divider()

            Button(action: openFullHistory) {
                HStack {
                    Spacer()
                    Text("View All →")
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                }
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
    }

    private func historyRow(_ entry: DictationEntry) -> some View {
        Button(action: { copyHistoryEntry(entry) }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(HistoryManager.formatRelative(entry.timestamp))
                        .font(.caption.weight(.medium))
                        .foregroundColor(.primary)
                    Text(entry.language)
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(historyBadgeColor(entry.language))
                        .cornerRadius(3)
                    Spacer()
                    if copiedHistoryID == entry.id {
                        Text("Copied!")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
                Text(HistoryManager.formatExact(entry.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(entry.text.prefix(60) + (entry.text.count > 60 ? "…" : ""))
                    .font(.caption2)
                    .foregroundColor(.primary.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func historyBadgeColor(_ lang: String) -> Color {
        switch lang {
        case "EN": return .blue
        case "BN": return .purple
        case "BL": return .orange
        default:   return .gray
        }
    }

    private func copyHistoryEntry(_ entry: DictationEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        withAnimation { copiedHistoryID = entry.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedHistoryID == entry.id {
                withAnimation { copiedHistoryID = nil }
            }
        }
    }

    private func openFullHistory() {
        HistoryWindowController.shared.show()
    }

    // Spawn /usr/bin/open with the app path so the relaunched copy starts
    // fresh, then terminate ourselves. Necessary when AX was granted while
    // the app was running and the cached trust state needs to refresh.
    private func relaunchApp() {
        guard let bundlePath = Bundle.main.bundlePath as String? else { return }
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundlePath]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApp.terminate(nil)
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
