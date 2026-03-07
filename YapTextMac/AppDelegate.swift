import Cocoa
import SwiftUI
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var transcriptionManager: TranscriptionManager!
    private var hotKeyRef: EventHotKeyRef?
    private var animationTimer: Timer?
    private var animationFrame: Int = 0
    private var toastWindow: NSWindow?
    private var stateCheckTimer: Timer?
    private var lastKnownRecording: Bool = false
    private var lastKnownAction: String = ""
    private var toastDismissWork: DispatchWorkItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        transcriptionManager = TranscriptionManager()
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            setIdleIcon()
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 420)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MainView(transcriptionManager: transcriptionManager)
        )
        
        registerGlobalHotKey()
        transcriptionManager.requestPermissions()
        
        // Simple polling timer
        stateCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pollStateChanges()
        }
    }
    
    // MARK: - State Polling
    
    private func pollStateChanges() {
        let isRecording = transcriptionManager.isRecording
        let isTranscribing = transcriptionManager.statusMessage.contains("⏳")
        let currentAction = transcriptionManager.lastAction
        
        // Handle recording state change
        if isRecording && !lastKnownRecording {
            lastKnownRecording = true
            startRecordingAnimation()
        } else if !isRecording && lastKnownRecording {
            lastKnownRecording = false
            stopRecordingAnimation()
            if isTranscribing {
                showTranscribingIcon()
            } else {
                setIdleIcon()
            }
        }
        
        // Handle transcribing
        if !isRecording && isTranscribing {
            showTranscribingIcon()
        }
        
        // Handle done states — reset icon
        if !isRecording && !isTranscribing && !currentAction.isEmpty && currentAction == lastKnownAction {
            // Already handled
        }
        
        // Handle new action
        if !currentAction.isEmpty && currentAction != lastKnownAction {
            lastKnownAction = currentAction
            stopRecordingAnimation()
            
            let preview = String(transcriptionManager.transcribedText.prefix(80))
            let previewText = transcriptionManager.transcribedText.count > 80 ? preview + "..." : preview
            
            if currentAction.contains("clipboard") {
                showToast(title: "📋 Copied to Clipboard!", subtitle: "Press ⌘V to paste anywhere", preview: previewText)
                flashMenuBarIcon(systemName: "doc.on.clipboard.fill", color: NSColor.systemBlue)
            } else if currentAction.contains("Inserted") {
                showToast(title: "✅ Text Inserted!", subtitle: "Typed into the active text field", preview: previewText)
                flashMenuBarIcon(systemName: "checkmark.circle.fill", color: NSColor.systemGreen)
            }
        }
    }
    
    // MARK: - Toast Notification (simple NSPanel approach)
    
    private func showToast(title: String, subtitle: String, preview: String) {
        // Cancel any pending dismiss
        toastDismissWork?.cancel()
        
        // Close existing toast
        if let existing = toastWindow {
            existing.orderOut(nil)
            existing.close()
            toastWindow = nil
        }
        
        guard let screen = NSScreen.main else { return }
        
        let toastWidth: CGFloat = 320
        let toastHeight: CGFloat = 80
        
        let xPos = screen.frame.maxX - toastWidth - 20
        let yPos = screen.frame.maxY - toastHeight - 40
        
        // Use NSPanel for a lightweight floating window
        let panel = NSPanel(
            contentRect: NSRect(x: xPos, y: yPos, width: toastWidth, height: toastHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isReleasedWhenClosed = false
        
        // Build the view using NSView (no SwiftUI for the toast — more stable)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: toastWidth, height: toastHeight))
        
        // Background
        let bgView = NSVisualEffectView(frame: container.bounds)
        bgView.material = .hudWindow
        bgView.state = .active
        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = 14
        bgView.layer?.masksToBounds = true
        container.addSubview(bgView)
        
        // Title label
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 16, y: toastHeight - 30, width: toastWidth - 32, height: 20)
        container.addSubview(titleLabel)
        
        // Subtitle label
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.frame = NSRect(x: 16, y: toastHeight - 48, width: toastWidth - 32, height: 16)
        container.addSubview(subtitleLabel)
        
        // Preview label
        if !preview.isEmpty {
            let previewLabel = NSTextField(labelWithString: "\"\(preview)\"")
            previewLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
            previewLabel.textColor = .tertiaryLabelColor
            previewLabel.lineBreakMode = .byTruncatingTail
            previewLabel.frame = NSRect(x: 16, y: 8, width: toastWidth - 32, height: 16)
            container.addSubview(previewLabel)
        }
        
        panel.contentView = container
        
        // Show with fade-in
        panel.alphaValue = 0
        panel.orderFront(nil)
        toastWindow = panel
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        })
        
        // Auto-dismiss after 3 seconds
        let dismissWork = DispatchWorkItem { [weak self] in
            guard let self = self, let window = self.toastWindow else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.4
                window.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                window.orderOut(nil)
                window.close()
                if self?.toastWindow === window {
                    self?.toastWindow = nil
                }
            })
        }
        toastDismissWork = dismissWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: dismissWork)
    }
    
    private func flashMenuBarIcon(systemName: String, color: NSColor) {
        stopRecordingAnimation()
        guard let button = statusItem.button else { return }
        
        if let image = NSImage(systemSymbolName: systemName, accessibilityDescription: "Done") {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .bold)
            let configured = image.withSymbolConfiguration(config) ?? image
            button.image = configured
            button.contentTintColor = color
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.setIdleIcon()
        }
    }
    
    // MARK: - Menu Bar Icon
    
    private func startRecordingAnimation() {
        animationTimer?.invalidate()
        animationFrame = 0
        
        if let button = statusItem.button,
           let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording") {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .bold)
            button.image = image.withSymbolConfiguration(config) ?? image
            button.contentTintColor = NSColor.systemRed
        }
        
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let button = self.statusItem.button else { return }
            self.animationFrame = (self.animationFrame + 1) % 2
            let iconName = self.animationFrame == 0 ? "mic.fill" : "mic.circle.fill"
            if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Recording") {
                let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .bold)
                button.image = image.withSymbolConfiguration(config) ?? image
                button.contentTintColor = NSColor.systemRed
            }
        }
    }
    
    private func showTranscribingIcon() {
        animationTimer?.invalidate()
        animationTimer = nil
        if let button = statusItem.button,
           let image = NSImage(systemSymbolName: "ellipsis.circle.fill", accessibilityDescription: "Transcribing") {
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            button.image = image.withSymbolConfiguration(config) ?? image
            button.contentTintColor = NSColor.systemOrange
        }
    }
    
    private func stopRecordingAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationFrame = 0
    }
    
    private func setIdleIcon() {
        guard let button = statusItem.button else { return }
        if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "YapTextMac") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            button.image = image.withSymbolConfiguration(config) ?? image
            button.contentTintColor = nil
        }
    }
    
    // MARK: - Popover
    
    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown { popover.performClose(nil) }
            else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }
    
    // MARK: - Global Hotkey (⌘⇧D)
    
    func registerGlobalHotKey() {
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x5953_4352)
        hotKeyID.id = 1
        
        let modifiers: UInt32 = UInt32(cmdKey | shiftKey)
        let keyCode: UInt32 = 2
        
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return noErr }
                let ad = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                ad.handleHotKey()
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil
        )
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
    
    func handleHotKey() {
        DispatchQueue.main.async { [weak self] in self?.transcriptionManager.toggleRecording() }
    }
}
