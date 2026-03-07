# 🎙️ YapTextMac

A native macOS menu bar app that transcribes your voice using **OpenAI Whisper API** and automatically types it into the active text field — or copies it to your clipboard.

![macOS](https://img.shields.io/badge/macOS-13.0+-blue) ![Swift](https://img.shields.io/badge/Swift-5.9+-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **OpenAI Whisper API** — Superior transcription accuracy
- **Menu Bar App** — Lives in your menu bar, always accessible
- **Global Hotkey** — `⌘⇧D` to start/stop recording from anywhere
- **Smart Text Insertion** — Auto-detects focused text fields:
  - Text field focused → types directly into it
  - No text field → copies to clipboard
- **Visual Feedback** — Menu bar icon animates red while recording, orange while transcribing, and shows a toast notification when done
- **Auto-Stop** — Stops recording after 2.5s of silence
- **Secure API Key** — Stored in macOS Keychain
- **Lightweight** — No Dock icon, minimal resource usage (~30MB RAM)

## Quick Install (Terminal)

```bash
git clone https://github.com/moshbari/yaptext-mac-app.git
cd yaptext-mac-app
bash install.sh
```

This builds the app and places `YapTextMac.app` on your Desktop. Requires Xcode installed (for the Swift compiler).

## Manual Install (Xcode)

1. Open Xcode → File → New → Project → macOS → App
2. Product Name: `YapTextMac`, Interface: SwiftUI, Language: Swift
3. Delete auto-generated `ContentView.swift` and `YapTextMacApp.swift`
4. Drag all `.swift` files from `YapTextMac/` folder into Xcode
5. In **Signing & Capabilities**: Remove App Sandbox
6. In **Info** tab: Add `Privacy - Microphone Usage Description` and `Application is agent (UIElement) = YES`
7. In **General** tab: Add frameworks — AVFoundation, Carbon, ApplicationServices, Security
8. Press `⌘R` to build and run

## Usage

| Action | How |
|--------|-----|
| Start/Stop recording | `⌘⇧D` globally, or click mic icon → Start |
| Configure API key | Click mic icon → gear ⚙️ → paste key |
| Auto-type into text box | Click into any text field first, then dictate |
| Copy to clipboard | Dictate without focusing a text field |
| Quit | Click mic icon → ✕ button |

## Menu Bar States

| Icon | Meaning |
|------|---------|
| 🎤 (normal) | Idle — ready to record |
| 🎤 (red, pulsing) | Recording your voice |
| ⏳ (orange) | Sending to Whisper API |
| ✅ (green/blue) | Done — text inserted or copied |

## Requirements

- macOS 13.0 (Ventura) or later
- OpenAI API key with Whisper access
- Microphone
- Accessibility permission (for auto-typing into text fields)

## Permissions

| Permission | Why | Required? |
|-----------|-----|-----------|
| Microphone | Record your voice | Yes |
| Accessibility | Type into other apps' text fields | Optional (falls back to clipboard) |

Grant Accessibility: **System Settings → Privacy & Security → Accessibility → add YapTextMac**

## Cost

OpenAI Whisper API: ~$0.006/minute. A 10-second dictation costs less than $0.001.

## Architecture

```
YapTextMac/
├── YapTextMacApp.swift          → App entry point (menu bar only)
├── AppDelegate.swift            → Menu bar icon, animations, hotkey, toast notifications
├── TranscriptionManager.swift   → Audio recording, Whisper API, text insertion, Keychain
├── MainView.swift               → SwiftUI popover UI + settings
├── Info.plist                   → App configuration
└── YapTextMac.entitlements      → Permissions
```

## How It Works

1. Records audio to a temp `.m4a` file (16kHz mono AAC)
2. Monitors audio levels every 200ms for silence detection
3. After 2.5s silence → sends audio to OpenAI Whisper API
4. Checks if a text field is focused via macOS Accessibility API
5. Text field found → inserts directly (or simulates ⌘V for web/Electron apps)
6. No text field → copies to clipboard
7. Shows toast notification + flashes menu bar icon
8. Cleans up temp audio file

## License

MIT — do whatever you want with it.

## Author

Built by **Mosh Bari** with the help of Claude AI.
