# Awake ☕

A tiny macOS menu bar app that keeps your Mac awake — with a webcam mirror and photo booth thrown in. A homemade, single-file take on Amphetamine + Hand Mirror.

## What it does

- **Left-click the cup** — instantly toggle keep-awake on/off (indefinite session)
- **Right-click** — menu with timed sessions (30 min / 1 h / 2 h / 4 h), lid-close override, Coffee Break, Quit
- **Stay Awake When Lid Closes** — flips `pmset disablesleep` (asks for your admin password); restored automatically on quit
- **Coffee Break** — a small floating, mirrored webcam panel to check how you look before a call
- **Photo Booth** — camera button in the Coffee Break panel: 3·2·1 countdown, flash, photo saved to your Desktop
- Timed sessions notify you when they end

## Safety promises

Sleep state is system-global, so Awake is paranoid about never leaving your Mac worse than it found it:

- caffeinate is spawned with `-w <pid>` — it dies with the app, even on a crash or force-quit
- The real `pmset` state is read at launch, so an orphaned `disablesleep=1` from a crash heals on the next normal quit
- Quitting with lid-override on prompts to restore it; cancelling the password prompt blocks a silent dirty exit
- Logout/shutdown (SIGTERM) does non-interactive cleanup — no password dialogs that stall logout

If things ever do get stuck: `sudo pmset -a disablesleep 0`

## Build

No Xcode project — just `swiftc`:

```bash
swiftc -O -parse-as-library main.swift -o Awake.app/Contents/MacOS/Awake
codesign --force --sign - Awake.app
open Awake.app
```

Requires macOS 13+. Camera and Desktop access are requested on first use; the lid override asks for your admin password each time.

## Gatekeeper note

The app is ad-hoc signed. If you download a built copy (rather than building it yourself), macOS will refuse to open it normally — **right-click the app → Open → Open** the first time. Rebuilding locally re-signs it for your machine and may re-trigger the camera/Desktop permission prompts.

## License

MIT © Blake Graham
