import SwiftUI

struct MainView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    @State private var showSettings = false
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("YapTextMac")
                    .font(.headline)
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
        .frame(width: 340)
    }
    
    // MARK: - Main Section
    
    private var mainSection: some View {
        VStack(spacing: 14) {
            // API Key Warning
            if transcriptionManager.apiKey.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Set your OpenAI API key in")
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
            }
            
            Divider()
            
            // Status
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(transcriptionManager.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            
            // Transcription Display
            GroupBox {
                ScrollView {
                    Text(transcriptionManager.transcribedText.isEmpty ? "Your transcription will appear here..." : transcriptionManager.transcribedText)
                        .font(.system(.body, design: .rounded))
                        .foregroundColor(transcriptionManager.transcribedText.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 150)
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
                
                Button(action: {
                    if !transcriptionManager.transcribedText.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcriptionManager.transcribedText, forType: .string)
                        transcriptionManager.lastAction = "📋 Copied to clipboard"
                    }
                }) {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(transcriptionManager.transcribedText.isEmpty)
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
    
    // MARK: - Settings Section
    
    private var settingsSection: some View {
        VStack(spacing: 14) {
            Divider()
            
            // API Key
            GroupBox("OpenAI API Key") {
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
            
            // How It Works
            GroupBox("How It Works") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Press ⌘⇧D or click Start to record")
                    Text("2. Speak — press ⌘⇧D again to stop")
                    Text("3. Auto-stops after 30s of silence")
                    Text("4. Audio sent to OpenAI Whisper for transcription")
                    Text("5. Text field focused → inserted + copied to clipboard")
                    Text("6. No text field → copied to clipboard")
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
    
    // MARK: - Helpers
    
    private var statusColor: Color {
        if transcriptionManager.isRecording { return .red }
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
