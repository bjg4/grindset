# <span data-proof="authored" data-by="ai:unknown">Grindset ☕</span>

<span data-proof="authored" data-by="ai:unknown">Close your lid. Keep your agent working.</span>

<span data-proof="authored" data-by="ai:unknown">Grindset is a macOS menu bar app for the moment you have a local agent or long-running task underway and need to close your laptop. A guarded session keeps the Mac awake with its lid closed, then restores normal sleep when you stop, the timer ends, the battery reaches 10%, or the app exits.</span>

## <span data-proof="authored" data-by="ai:unknown">Use it</span>

<span data-proof="authored" data-by="ai:unknown">Click the cup to</span> **<span data-proof="authored" data-by="ai:unknown">Lock In</span>**<span data-proof="authored" data-by="ai:unknown">, approve the administrator prompt, and wait for</span> **<span data-proof="authored" data-by="ai:unknown">Working with lid closed</span>** <span data-proof="authored" data-by="ai:unknown">before closing your laptop. Click again to</span> **<span data-proof="authored" data-by="ai:unknown">Let It Sleep</span>**<span data-proof="authored" data-by="ai:unknown">. Right-click for a 30-minute, 1-hour, 2-hour, or 4-hour session, Coffee Break, and help.</span>

<span data-proof="authored" data-by="ai:unknown">The administrator prompt is for that session's sleep guard. No permanent privileged service is installed. Cancelling approval leaves the session off.</span>

<span data-proof="authored" data-by="ai:unknown">Keeping the Mac awake lets your agent continue working and use an available network. It cannot preserve Wi-Fi after you leave its coverage, provide connectivity in airplane mode, or prevent the agent itself from failing. Keep the running laptop ventilated; a closed bag is not a suitable place for a sustained workload.</span>

## <span data-proof="authored" data-by="ai:unknown">Other conveniences</span>

* **<span data-proof="authored" data-by="ai:unknown">Coffee Break:</span>** <span data-proof="authored" data-by="ai:unknown">a floating mirrored camera view before a call.</span>

* **<span data-proof="authored" data-by="ai:unknown">Photo Booth:</span>** <span data-proof="authored" data-by="ai:unknown">a countdown and photo saved to your Desktop.</span>

* **<span data-proof="authored" data-by="ai:unknown">Calendar:</span>** <span data-proof="authored" data-by="ai:unknown">a menu bar month grid, with no event access.</span>

* **<span data-proof="authored" data-by="ai:unknown">Timers:</span>** <span data-proof="authored" data-by="ai:unknown">remaining session time beside the cup and an end notification.</span>

## <span data-proof="authored" data-by="ai:unknown">Recovery</span>

<span data-proof="authored" data-by="ai:unknown">The app uses</span> <span data-proof="authored" data-by="ai:unknown">`caffeinate`</span> <span data-proof="authored" data-by="ai:unknown">tied to its process and a separate temporary administrator-owned guard for lid-close support. The guard watches both the app process and a private authenticated connection. It restores the sleep override after a stop request, app crash or force quit, lost connection, deadline, or low battery. Failed restoration is retried until the system confirms normal sleep. Quitting waits for that confirmation.</span>

<span data-proof="authored" data-by="ai:unknown">An override already enabled by another application is left alone and prevents starting a new guarded session. The guard cannot catch its own</span> <span data-proof="authored" data-by="ai:unknown">`SIGKILL`, a kernel crash, or power loss. If both processes are forcibly killed and sleep remains disabled, open Terminal and run:</span>

```sh proof:W3sidHlwZSI6InByb29mQXV0aG9yZWQiLCJmcm9tIjowLCJ0byI6MjgsImF0dHJzIjp7ImJ5IjoiYWk6dW5rbm93biJ9fV0=
sudo pmset -a disablesleep 0
```

<span data-proof="authored" data-by="ai:unknown">Older Grindset sessions are recognized through the existing ownership flag and can be restored from the lid-close menu. Stop the session and quit before deleting the app. No background service needs uninstalling.</span>

## <span data-proof="authored" data-by="ai:unknown">Build and release status</span>

<span data-proof="authored" data-by="ai:unknown">Requires macOS 13 or newer. The build produces Apple Silicon and Intel code; it runs policy tests and nine guard integration tests using a compile-time fake system setting. Tests never change the build machine's sleep behavior.</span>

```sh proof:W3sidHlwZSI6InByb29mQXV0aG9yZWQiLCJmcm9tIjowLCJ0byI6MzYsImF0dHJzIjp7ImJ5IjoiYWk6dW5rbm93biJ9fV0=
bash build.sh
open dist/Grindset.app
```

<span data-proof="authored" data-by="ai:unknown">Use a current Xcode toolchain. Local and CI builds are ad-hoc signed development artifacts. A public download is pending Developer ID signing, notarization, verification of the downloaded packages, and a real closed-lid acceptance test on a MacBook. CI success does not establish physical lid or network behavior.</span>

<span data-proof="authored" data-by="ai:unknown">`release.config.json`</span> <span data-proof="authored" data-by="ai:unknown">adopts the shared Blakeist release contract. Public candidates must include a DMG, an app-only ZIP, SHA-256 checksums, source identity, and acceptance evidence tied to those exact files. No public binary release has been promoted by this change.</span>

## <span data-proof="authored" data-by="ai:unknown">Permissions and privacy</span>

<span data-proof="authored" data-by="ai:unknown">Lid-close sessions request administrator approval. Coffee Break requests camera access only when used. Saving a photo may request Desktop access. Notifications are optional. Camera images remain local, photos are saved to the Desktop, and the calendar does not read events. Grindset has no account or analytics service.</span>

[<span data-proof="authored" data-by="ai:unknown">Help and release information</span>](https://www.blake.ist/tools/grindset/help) <span data-proof="authored" data-by="ai:unknown">·</span> [<span data-proof="authored" data-by="ai:unknown">Report a problem</span>](https://github.com/bjg4/grindset/issues)

## <span data-proof="authored" data-by="ai:unknown">Changes in the release candidate</span>

* <span data-proof="authored" data-by="ai:unknown">Made every Lock In session include protected lid-close work.</span>

* <span data-proof="authored" data-by="ai:unknown">Added an independently running sleep guard and crash recovery tests.</span>

* <span data-proof="authored" data-by="ai:unknown">Added a universal build, icon, license, CI artifacts, and a common packaging configuration.</span>

* <span data-proof="authored" data-by="ai:unknown">Added clear permission, recovery, and release guidance.</span>

<span data-proof="authored" data-by="ai:unknown">MIT © Blake Graham. See LICENSE.</span>