# YapTextMac — Standing Instructions for Claude

Read this before touching this repo. It encodes hard-won lessons that bite every edit cycle if forgotten.

---

## 🚨 MANDATORY: Accessibility re-grant after every `install.sh` run

**The single most important thing about this app.** Read carefully.

### What happens
`install.sh` ad-hoc signs the build (`codesign --force --deep --sign -`). Every rebuild produces a new cdhash, and macOS keys Accessibility permission to that exact cdhash. As a result, **every install invalidates the previous Accessibility grant** — install.sh also calls `tccutil reset` explicitly to give a clean slate.

User-visible symptom: transcription works, text is copied to clipboard, but **auto-paste silently does nothing**. The app falls back to clipboard-only mode.

### ❌ Do NOT propose the self-signed-cert workaround again
A previous session implemented a stable self-signed cert in a custom keychain to keep the DR (and therefore the AX grant) stable across rebuilds. Mechanically the DR was stable (verified — CDHash changed, DR didn't), but **macOS TCC silently rejected AX grants for the cert-signed binary**: toggling YapTextMac ON in System Settings recorded the row, but `AXIsProcessTrusted()` kept returning `false`. Hours were burned. **If you ever consider this path again, you MUST also add the cert to the system trust store (`security add-trusted-cert` with admin escalation) AND verify TCC actually accepts the grant via the debug log before claiming victory.** Without the trust-store step, the cert breaks AX entirely.

The real root-cause fix is an Apple Developer ID ($99/yr) — until then, manual re-grant is unavoidable.

### The standing rule
Any task that ends with `install.sh` being run — directly or indirectly — must:

1. **Call out the AX re-grant in the post-install report, prominently at the top, in bold or with ⚠️.** Don't bury it.
2. **The app itself now has a big red "Auto-paste is OFF" banner** at the top of the popover when AX is denied, with a one-tap "Grant Accessibility" button (fires `requestAccessibilityPermission()` AND opens the AX pane). Tell the user about that button by name — it's the friendliest recovery path.
3. **Verify the current TCC state when in doubt:**
   ```bash
   sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
     "SELECT service, client, auth_value FROM access \
      WHERE client = 'com.moshbari.yaptextmac' AND service = 'kTCCServiceAccessibility';"
   ```
   Note: AX rows live in `/Library/Application Support/com.apple.TCC/TCC.db` (system db, sudo needed), NOT the user db. The user db only holds Microphone/Camera. Don't conclude "AX is not granted" from the user db being empty for that service.
4. **Never claim "auto-paste is working" without that verification — or without the user doing a real test dictation.**
5. **Tell the user the System Settings pane is already open** (install.sh opens it at the end).
6. **Tell the user to remove any stale `YapTextMac` entry** in the AX list before adding the new one (old entries point to the previous cdhash and won't apply).

### Why it can't be auto-fixed
Granting Accessibility requires user consent through System Settings. macOS does not allow programmatic grants without Full Disk Access + direct sqlite manipulation of `TCC.db`, which is fragile and not advisable. An Apple Developer ID would solve this; until then, manual re-grant is the path.

---

## Architecture (as of 2026-05)

Two transcription backends, one polish backend:

| Feature | Backend | Where the key lives |
|---|---|---|
| English transcription (`⌘⇧D`) | YapText API on Railway → OpenAI Whisper | Server |
| Bengali transcription (`⌘⇧E`) | YapText API on Railway → Sarvam saaras:v3 | Server |
| Banglish transcription (`⌘⇧P`) | YapText API on Railway → Sarvam (translit) | Server |
| Polish (tones) | OpenAI Chat Completions, direct | User's OpenAI key in Settings |

**Why Polish stays on direct OpenAI:** the Mac has Polish tones (`fixOnly`, `concise`, `elaborate`, `email`, `message`) that the server's `/polish` endpoint doesn't recognize. The server silently maps unknown tones to "professional" — silently breaking 5 Mac tones. Until those tones are added server-side, Polish must call OpenAI directly.

**Railway base URL:** `https://yaptext-api-production.up.railway.app`
**App secret:** sent in `X-App-Secret` header on every request. Same value as the iOS app uses. It's not a real secret — it's embedded in the binary. Server-side rate limiting is the actual protection.

**Settings UI:**
- OpenAI key field: kept, relabeled "for Polish only"
- Sarvam key field: kept in the layout, disabled (`.disabled(true).opacity(0.5)`) so existing keychain entries aren't orphaned. Do **not** remove the field outright — we may revert to BYOK in the future.

---

## Install/deploy flow

The repo has two build paths that must stay in sync:

1. **`xcodebuild`** — used for quick syntax/build checks. Produces a debug `.app` in `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/YapTextMac.app`.
2. **`install.sh`** — the canonical installer. Compiles with `swiftc` directly (not `xcodebuild`), bundles the result into `/Applications/YapTextMac.app` (or `~/Desktop` if `/Applications` isn't writable), ad-hoc signs it, runs `tccutil reset`, and (after a `y` prompt) opens System Settings → Accessibility.

If you change the source-file list in the app, **update `install.sh` too** — its `swiftc` command lists files explicitly. A missing file there means `xcodebuild` passes but `install.sh` fails to compile.

The `install.sh` ends with an interactive `read -p` for "Launch now?". Pipe `echo "y" | bash install.sh` when running non-interactively.

---

## Commit conventions

- Imperative subject line, ~60 chars max, no period
- Body explains the *why*, not the *what* (the diff already shows what)
- Co-author footer with the model identifier — match the style in `git log`
- Never use `--no-verify` or `--no-gpg-sign` without explicit user permission

---

## Things NOT to do

- Don't add features the user didn't ask for. The "Polish" tone palette, the silence-timeout default, and the menu-bar UI are all dialed in — leave them alone unless asked.
- Don't `git push --force` without asking.
- Don't paste GitHub tokens. If a push needs auth, ask the user to run `gh auth login` or add an SSH key.
- Don't remove the disabled Sarvam field. Hide ≠ delete. The keychain entry should survive.
- Don't migrate Polish to the server unless the server's `/polish` endpoint adds the missing Mac tones (`fixOnly`, `concise`, `elaborate`, `email`, `message`) first.
