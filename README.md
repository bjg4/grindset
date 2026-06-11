# Grindset ☕

Lock in. A tiny macOS menu bar app that keeps your Mac awake — with a webcam mirror and photo booth thrown in. A homemade, single-file take on Amphetamine + Hand Mirror.

## What it does

- **Left-click the cup** — lock in: instantly toggle keep-awake on/off (indefinite session)
- **Right-click** — menu with timed sessions ("Lock In For" 30 min / 1 h / 2 h / 4 h), lid-close override, Coffee Break, Quit
- **Stay Awake When Lid Closes** — flips `pmset disablesleep` (asks for your admin password); restored automatically on quit
- **Coffee Break** — a small floating, mirrored webcam panel to check how you look before a call
- **Photo Booth** — camera button in the Coffee Break panel: 3·2·1 countdown, flash, photo saved to your Desktop
- Timed sessions show remaining time next to the cup ("☕ 47m") and notify you when they end
- **Battery guard** — on battery at ≤10%, Grindset ends the session and tells you, instead of keeping your Mac awake until it dies (event-driven via IOKit, no polling)

## Safety promises

Sleep state is system-global, so Grindset is paranoid about never leaving your Mac worse than it found it:

- caffeinate is spawned with `-w <pid>` — it dies with the app, even on a crash or force-quit
- The real `pmset` state is read at launch, so an orphaned `disablesleep=1` from a crash heals on the next normal quit
- Quitting normally with lid-override on prompts to restore it; cancelling the password prompt blocks a silent dirty exit
- Logout/shutdown (SIGTERM) does non-interactive cleanup — no password dialogs that stall logout. The lid override can't be restored interactively there; Grindset re-syncs at next launch and restores on your next normal quit
- Grindset only restores a `disablesleep` it set itself — if you run clamshell mode deliberately, it won't touch your setting

If things ever do get stuck: `sudo pmset -a disablesleep 0`

## Install: build it yourself

**Building from source is the only supported install.** This app asks for your admin password and camera access — you should compile the binary you're granting that to. No Xcode project needed, just `swiftc`:

```bash
mkdir -p Grindset.app/Contents/MacOS
swiftc -O -parse-as-library -target arm64-apple-macos13.0 main.swift -o Grindset.app/Contents/MacOS/Grindset
codesign --force --sign - Grindset.app
open Grindset.app
```

On an Intel Mac, use `-target x86_64-apple-macos13.0` instead. Requires macOS 13+. Camera and Desktop access are requested on first use; the lid override asks for your admin password each time.

**Please don't pass around prebuilt copies.** The app is ad-hoc signed: a downloaded copy is quarantined and won't open normally (on macOS 15+ even right-click → Open no longer bypasses this — you'd have to dig into System Settings → Privacy & Security → "Open Anyway"), it only runs on the architecture it was built on, and an unsigned binary that habitually prompts for admin is exactly what you shouldn't teach people to trust. Proper distribution would need a paid Apple Developer ID plus notarization. Until then: share the repo link, not the .app.

## License

MIT © Blake Graham
