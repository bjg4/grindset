# Product

## Register

product

## Users

One person: a Mac-using professional who runs long tasks (builds, agents, deploys) and presentations, often on a laptop. Context is "mid-task, hands busy" — they interact with Awake for one second at a time, from the menu bar, usually without looking. Secondary moment: about to hop on a video call and wanting a quick mirror check without opening Photo Booth.

## Product Purpose

Awake is a homemade Amphetamine replacement: keep the Mac from sleeping (one click, or timed sessions), optionally survive a closed lid, and take a "Coffee Break" — a tiny webcam mirror with a 3·2·1 photo booth. Success = the common case is one click, the system's sleep state is never silently left broken, and using it makes you smile slightly.

## Brand Personality

Playful utility. Warm, charming, a bit cheeky — the coffee metaphor carries the voice (cup icon, "Coffee Break", "Let It Sleep") the way Hand Mirror's friendliness does. Charm lives in naming, iconography, and micro-moments (countdown ticks, camera flash); the mechanics underneath stay dead serious.

## Anti-references

- Enterprise utility design: settings panes, tabs, preference windows. Awake must never grow a Preferences window.
- Menu bar apps with 15-item menus (classic Bartender-era clutter). The menu is six rows; it stays six rows.
- Gimmick apps where the joke outranks the job — no animated mascots, no coffee puns in error messages that obscure what went wrong.
- Electron-style non-native chrome. It's AppKit; it should feel like macOS.

## Design Principles

1. **One click to the common case.** Toggling keep-awake is a single left-click on the cup. Anything more frequent than weekly must not live behind a menu.
2. **Never leave the machine worse than you found it.** Sleep state is system-global; every exit path (quit, crash, logout) must restore or surface it. Safety messaging is honest, specific, and includes the manual fix.
3. **Glanceable truth.** The icon always reflects the real system state, not the app's belief — filled cup means actually awake, checkbox means pmset actually says so.
4. **Native first, charm second.** SF Symbols, system fonts, standard controls. The playfulness is in the words and moments, never at the cost of feeling like macOS.
5. **Charm in the verbs.** "Coffee Break", "Let It Sleep", a 3·2·1 tick-tick-flash — personality lives in named actions and tiny rituals, not decoration.

## Accessibility & Inclusion

- Status icon and overlay buttons carry accessibility descriptions; state changes must be discernible without color alone (filled vs. outline cup, checkmarks).
- Overlay text/controls on the camera preview need shadow or scrim — webcam feeds are unpredictable backgrounds.
- Countdown should be perceivable by sound (ticks) and sight (numerals), not either alone.
- Respect Reduced Motion for the flash and any future animation; keep all timing user-cancelable.
