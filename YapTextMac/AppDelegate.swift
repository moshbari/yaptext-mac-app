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
    
    // Floating recording overlay
    private var overlayWindow: NSPanel?
    private var overlayTimerLabel: NSTextField?
    private var overlayStatusLabel: NSTextField?
    private var overlayDots: [NSView] = []
    private var overlayAnimTimer: Timer?
    private var recordingStartTime: Date?
    private var recordingTimerUpdate: Timer?
    private var overlayDotFrame: Int = 0
    
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
            showRecordingOverlay()
        } else if !isRecording && lastKnownRecording {
            lastKnownRecording = false
            stopRecordingAnimation()
            if isTranscribing {
                showTranscribingIcon()
                updateOverlayToTranscribing()
            } else {
                setIdleIcon()
                dismissOverlay()
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
            
            // Show done state in overlay then dismiss
            updateOverlayToDone(action: currentAction)
            
            let preview = String(transcriptionManager.transcribedText.prefix(80))
            let previewText = transcriptionManager.transcribedText.count > 80 ? preview + "..." : preview
            
            if currentAction.contains("clipboard") && !currentAction.contains("Inserted") {
                showToast(title: "📋 Copied to Clipboard!", subtitle: "Press ⌘V to paste anywhere", preview: previewText)
                flashMenuBarIcon(systemName: "doc.on.clipboard.fill", color: NSColor.systemBlue)
            } else if currentAction.contains("Inserted") {
                showToast(title: "✅ Text Inserted + Copied!", subtitle: "Also copied to clipboard", preview: previewText)
                flashMenuBarIcon(systemName: "checkmark.circle.fill", color: NSColor.systemGreen)
            }
        }
    }
    
    // MARK: - Floating Recording Overlay
    
    private func showRecordingOverlay() {
        dismissOverlay()
        
        guard let screen = NSScreen.main else { return }
        
        let overlayWidth: CGFloat = 340
        let overlayHeight: CGFloat = 44
        let xPos = (screen.frame.width - overlayWidth) / 2 + screen.frame.origin.x
        let yPos = screen.frame.origin.y + 80 // near bottom of screen
        
        let panel = NSPanel(
            contentRect: NSRect(x: xPos, y: yPos, width: overlayWidth, height: overlayHeight),
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
        
        let container = NSView(frame: NSRect(x: 0, y: 0, width: overlayWidth, height: overlayHeight))
        
        // Dark rounded background
        let bgView = NSVisualEffectView(frame: container.bounds)
        bgView.material = .hudWindow
        bgView.state = .active
        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = 22
        bgView.layer?.masksToBounds = true
        bgView.layer?.borderWidth = 1.0
        bgView.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.5).cgColor
        container.addSubview(bgView)
        
        // Animated dots (4 red dots)
        overlayDots = []
        let dotsStartX: CGFloat = 16
        for i in 0..<4 {
            let dot = NSView(frame: NSRect(x: dotsStartX + CGFloat(i) * 10, y: 17, width: 6, height: 6))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            container.addSubview(dot)
            overlayDots.append(dot)
        }
        
        // Timer label (red)
        let timerLabel = NSTextField(labelWithString: "00:00")
        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timerLabel.textColor = NSColor.systemRed
        timerLabel.frame = NSRect(x: 60, y: 12, width: 50, height: 20)
        container.addSubview(timerLabel)
        overlayTimerLabel = timerLabel
        
        // Status label
        let statusLabel = NSTextField(labelWithString: "Recording — press ⌘⇧D to stop")
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.frame = NSRect(x: 114, y: 12, width: 220, height: 20)
        container.addSubview(statusLabel)
        overlayStatusLabel = statusLabel
        
        panel.contentView = container
        
        // Show with fade-in
        panel.alphaValue = 0
        panel.orderFront(nil)
        overlayWindow = panel
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        })
        
        // Start timer
        recordingStartTime = Date()
        recordingTimerUpdate = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateRecordingTimer()
        }
        
        // Start dot animation
        overlayDotFrame = 0
        overlayAnimTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.animateOverlayDots()
        }
    }
    
    private func updateRecordingTimer() {
        guard let start = recordingStartTime else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        let mins = elapsed / 60
        let secs = elapsed % 60
        overlayTimerLabel?.stringValue = String(format: "%02d:%02d", mins, secs)
    }
    
    private func animateOverlayDots() {
        overlayDotFrame = (overlayDotFrame + 1) % 4
        for (i, dot) in overlayDots.enumerated() {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                let scale: CGFloat = (i == overlayDotFrame || i == (overlayDotFrame + 1) % 4) ? 1.0 : 0.5
                dot.animator().alphaValue = scale
            })
        }
    }
    
    private func updateOverlayToTranscribing() {
        // Stop timer and dot animation
        recordingTimerUpdate?.invalidate()
        recordingTimerUpdate = nil
        overlayAnimTimer?.invalidate()
        overlayAnimTimer = nil
        
        // Update dots to orange
        for dot in overlayDots {
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            dot.alphaValue = 1.0
        }
        
        // Update border color
        if let bgView = overlayWindow?.contentView?.subviews.first as? NSVisualEffectView {
            bgView.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.5).cgColor
        }
        
        // Update labels
        overlayTimerLabel?.textColor = NSColor.systemOrange
        overlayStatusLabel?.stringValue = "Transcribing..."
        overlayStatusLabel?.textColor = NSColor.systemOrange
        
        // Pulse animation for dots
        overlayAnimTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.overlayDotFrame = (self.overlayDotFrame + 1) % 4
            for (i, dot) in self.overlayDots.enumerated() {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.3
                    dot.animator().alphaValue = (i == self.overlayDotFrame) ? 1.0 : 0.3
                })
            }
        }
    }
    
    private func updateOverlayToDone(action: String) {
        overlayAnimTimer?.invalidate()
        overlayAnimTimer = nil
        recordingTimerUpdate?.invalidate()
        recordingTimerUpdate = nil
        
        // Update dots to green
        for dot in overlayDots {
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            dot.alphaValue = 1.0
        }
        
        if let bgView = overlayWindow?.contentView?.subviews.first as? NSVisualEffectView {
            bgView.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.5).cgColor
        }
        
        overlayTimerLabel?.textColor = NSColor.systemGreen
        overlayTimerLabel?.stringValue = "✓"
        
        if action.contains("Inserted") {
            overlayStatusLabel?.stringValue = "Done — Text inserted + copied"
        } else {
            overlayStatusLabel?.stringValue = "Done — Copied to clipboard"
        }
        overlayStatusLabel?.textColor = NSColor.systemGreen
        
        // Auto-dismiss after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.dismissOverlay()
        }
    }
    
    private func dismissOverlay() {
        overlayAnimTimer?.invalidate()
        overlayAnimTimer = nil
        recordingTimerUpdate?.invalidate()
        recordingTimerUpdate = nil
        recordingStartTime = nil
        overlayDots = []
        
        guard let window = overlayWindow else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            window.orderOut(nil)
            window.close()
            if self?.overlayWindow === window {
                self?.overlayWindow = nil
            }
        })
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
            configured.isTemplate = false
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
            let configured = image.withSymbolConfiguration(config) ?? image
            configured.isTemplate = false
            button.image = configured
            button.contentTintColor = NSColor.systemRed
        }
        
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let button = self.statusItem.button else { return }
            self.animationFrame = (self.animationFrame + 1) % 2
            let iconName = self.animationFrame == 0 ? "mic.fill" : "mic.circle.fill"
            if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "Recording") {
                let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .bold)
                let configured = image.withSymbolConfiguration(config) ?? image
                configured.isTemplate = false
                button.image = configured
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
            let configured = image.withSymbolConfiguration(config) ?? image
            configured.isTemplate = false
            button.image = configured
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
            let configured = image.withSymbolConfiguration(config) ?? image
            configured.isTemplate = true
            button.image = configured
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
