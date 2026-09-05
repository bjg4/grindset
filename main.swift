import Cocoa
import AVFoundation
import UserNotifications
import IOKit.ps

// Borderless panels refuse key status by default; we need it for Esc-to-close.
// Esc only reaches us while the panel is key (most recently clicked); when
// another app is active, the ✕ button is the reliable close affordance.
final class BreakPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        AppDelegate.shared.closeCoffeeBreak()
    }
}

// Calendar popover host: scroll up/down (or trackpad swipe) steps months,
// the way Itsycal does. Precise trackpad deltas accumulate to a step and
// ignore inertia overshoot; a notched mouse wheel steps once per notch.
final class CalendarHostView: NSView {
    var onScrollStep: ((Int) -> Void)?
    private var accum: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            if event.momentumPhase != [] { return }
            accum += event.scrollingDeltaY
            let step: CGFloat = 22
            while accum >= step { onScrollStep?(-1); accum -= step }
            while accum <= -step { onScrollStep?(1); accum += step }
        } else if event.scrollingDeltaY > 0 {
            onScrollStep?(-1)
        } else if event.scrollingDeltaY < 0 {
            onScrollStep?(1)
        }
    }
}

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    // NSApplication.delegate is unowned(unsafe); keep a strong reference
    static let shared = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = shared
        app.run()
    }

    var statusItem: NSStatusItem!
    var caffeinate: Process?
    var sessionTimer: Timer?
    var sessionEndsAt: Date?
    var lidSleepDisabled = false
    var lidSession: LidSession?
    var lidTransition = false
    var waitingToQuit = false
    var sigtermSource: DispatchSourceSignal?
    var breakPanel: BreakPanel?
    var captureSession: AVCaptureSession?
    var clickOutsideMonitor: Any?
    var photoOutput: AVCapturePhotoOutput?
    var countdownTimer: Timer?
    var countdownLabel: NSTextField?
    var snapButton: NSButton?
    var welcomePopover: NSPopover?
    var notificationAuthRequested = false
    var tickTimer: Timer?
    var powerSourceRunLoopSource: CFRunLoopSource?
    var dateStatusItem: NSStatusItem!
    var calendarPopover: NSPopover?
    var calendarVC: NSViewController?
    var calendarHost: CalendarHostView?
    var displayedMonth = Date()

    // Also documented in README ("≤10%") — keep the two in sync.
    let batteryGuardPercent = 10

    // Tracks whether Grindset (not the user or another tool) set disablesleep=1.
    static let ownsDisableSleepKey = "grindsetSetDisableSleep"

    var isAwake: Bool { caffeinate?.isRunning == true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        exitIfAlreadyRunning()

        // Reflect the real pmset state at launch — but only adopt (and later
        // restore) a disablesleep WE set. A user who configured clamshell mode
        // deliberately shouldn't have Grindset revert it at quit. The ownership
        // flag persists across crashes, so kill -9 orphans still heal.
        let systemDisabled = Self.systemSleepDisabled()
        if !systemDisabled {
            UserDefaults.standard.set(false, forKey: Self.ownsDisableSleepKey)
        }
        lidSleepDisabled = systemDisabled && UserDefaults.standard.bool(forKey: Self.ownsDisableSleepKey)

        installSigtermHandler()
        installPowerSourceObserver()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Grindset — click to lock in, right-click for options"
        }
        updateIcon()
        setupDateItem()
        NotificationCenter.default.addObserver(self, selector: #selector(dayChanged),
                                               name: .NSCalendarDayChanged, object: nil)
        showWelcomeIfNeeded()
    }

    func showWelcomeIfNeeded() {
        let key = "didShowWelcome"
        guard !UserDefaults.standard.bool(forKey: key), let button = statusItem.button else { return }
        UserDefaults.standard.set(true, forKey: key)

        let label = NSTextField(wrappingLabelWithString:
            "Click the cup to lock in — your Mac stays awake.\nRight-click for timers, lid settings, and Coffee Break.")
        label.font = .systemFont(ofSize: 13)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 264, height: 70))
        label.frame = container.bounds.insetBy(dx: 14, dy: 12)
        container.addSubview(label)
        let vc = NSViewController()
        vc.view = container

        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        welcomePopover = pop
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.welcomePopover?.performClose(nil)
            self?.welcomePopover = nil
        }
    }

    @objc func statusButtonClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if isAwake {
            stopAwake()
        } else {
            startAwake(duration: nil)
        }
    }

    func showMenu() {
        // Menus are built fresh on demand; attach one just long enough to pop it,
        // otherwise left-click would open the menu instead of firing the action.
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in self?.statusItem.menu = nil }
    }

    // Two instances would fight over the single global disablesleep value.
    func exitIfAlreadyRunning() {
        // Fallback for bare-binary runs without Info.plist — keep in sync with CFBundleIdentifier.
        let bundleID = Bundle.main.bundleIdentifier ?? "local.blakeg.grindset"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            others.first?.activate()
            exit(0) // plain exit: must not trigger the quit-time restore path
        }
    }

    // Logout/shutdown delivers SIGTERM; never show an interactive admin prompt
    // there (the logout watchdog would SIGKILL us mid-dialog). Kill the child
    // and rely on the launch-time pmset sync to repair disablesleep next run.
    func installSigtermHandler() {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { [weak self] in
            self?.stopCaffeinate()
            exit(0)
        }
        src.resume()
        sigtermSource = src
    }

    static func systemSleepDisabled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
        return false
    }

    // MARK: - Menu

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if isAwake {
            menu.addItem(makeItem("Let It Sleep", #selector(stopAwake), key: "s"))
        } else {
            menu.addItem(makeItem("Lock In", #selector(startIndefinite), key: "a"))
        }

        let forItem = NSMenuItem(title: "Lock In For", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let durations: [(String, TimeInterval)] = [
            ("30 minutes", 30 * 60),
            ("1 hour", 60 * 60),
            ("2 hours", 2 * 60 * 60),
            ("4 hours", 4 * 60 * 60),
        ]
        for (label, secs) in durations {
            let item = makeItem(label, #selector(startTimed(_:)))
            item.representedObject = secs
            sub.addItem(item)
        }
        forItem.submenu = sub
        menu.addItem(forItem)

        let lid = makeItem(lidTransition ? "Updating Lid-Close Session…" : "Keep Working With Lid Closed", #selector(toggleLid))
        lid.state = lidSleepDisabled ? .on : .off
        lid.isEnabled = !lidTransition
        menu.addItem(lid)

        menu.addItem(makeItem(breakPanel?.isVisible == true
            ? "End Coffee Break"
            : "Coffee Break", #selector(toggleCoffeeBreak), key: "b"))

        menu.addItem(.separator())
        let help = NSMenuItem(title: "Help and Release Information", action: #selector(openHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        menu.addItem(makeItem("Quit Grindset", #selector(quit), key: "q"))
        return menu
    }

    func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    func statusText() -> String {
        if lidTransition { return "Updating lid-close protection…" }
        if lidSleepDisabled {
            if let ends = sessionEndsAt { return "Working with lid closed until \(Self.timeFormatter.string(from: ends))" }
            return "Working with lid closed"
        }
        if isAwake {
            if let ends = sessionEndsAt {
                return "Locked in until \(Self.timeFormatter.string(from: ends))"
            }
            return "Locked in indefinitely"
        }
        return "Sleeping normally"
    }

    // "47m" / "1h 12m" beside the cup during timed sessions — the icon answers
    // "am I awake?"; this answers "for how much longer?".
    func remainingText() -> String? {
        guard isAwake, let ends = sessionEndsAt else { return nil }
        let mins = max(0, Int(ceil(ends.timeIntervalSinceNow / 60)))
        return mins >= 60 ? "\(mins / 60)h \(mins % 60)m" : "\(mins)m"
    }

    func updateIcon() {
        let name = isAwake ? "cup.and.saucer.fill" : "cup.and.saucer"
        var stateLabel = lidSleepDisabled ? "Grindset — keeping your Mac awake with the lid closed" :
            (isAwake ? "Grindset — locked in, keeping your Mac awake" : "Grindset — sleeping normally")
        if lidTransition { stateLabel = "Grindset — updating lid-close protection" }
        let remaining = remainingText()
        if let remaining { stateLabel += ", \(remaining) remaining" }
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: stateLabel) {
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.imagePosition = remaining == nil ? .imageOnly : .imageLeft
            statusItem.button?.title = remaining.map { " " + $0 } ?? ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = (isAwake ? "☕︎" : "○") + (remaining.map { " " + $0 } ?? "")
        }
        statusItem.button?.setAccessibilityLabel(stateLabel)
    }

    // MARK: - Keep awake

    @objc func startIndefinite() { startAwake(duration: nil) }

    @objc func startTimed(_ sender: NSMenuItem) {
        guard let secs = sender.representedObject as? TimeInterval else { return }
        startAwake(duration: secs)
    }

    func startAwake(duration: TimeInterval?) {
        stopCaffeinate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -d display, -i idle, -m disk, -s system (AC); -w ties the assertion
        // to our pid so caffeinate exits even if this app crashes or is killed.
        p.arguments = ["-dims", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                // Only react if this process is still the active one — i.e. it
                // died on its own (killall, crash), not via our own stop call.
                guard let self, self.caffeinate === proc else { return }
                self.stopAwake()
            }
        }
        do {
            try p.run()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't start keep-awake"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            updateIcon()
            return
        }
        caffeinate = p

        if let duration {
            sessionEndsAt = Date().addingTimeInterval(duration)
            let t = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
                self?.sessionExpired()
            }
            t.tolerance = min(30, duration * 0.02)
            RunLoop.main.add(t, forMode: .common) // fires even while menu is open
            sessionTimer = t
        }
        if !notificationAuthRequested {
            notificationAuthRequested = true
            let center = UNUserNotificationCenter.current()
            center.delegate = self // present banners even when we're "frontmost"
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        startTick()
        updateIcon()
        lidSession?.configure(deadline: sessionEndsAt)
        checkBatteryGuard()
    }

    // MARK: - Session tick (menu bar countdown + battery guard)

    // The 30s tick only feeds the menu bar countdown text; battery is
    // event-driven via IOKit, no polling.
    func startTick() {
        guard tickTimer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateIcon()
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // macOS calls us on every power-source change (plug/unplug, charge level),
    // so the guard reacts instantly and costs nothing in between.
    func installPowerSourceObserver() {
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { delegate.checkBatteryGuard() } // explicit main-thread contract
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceRunLoopSource = source
    }

    func batteryStatus() -> (onBattery: Bool, percent: Int)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let onBattery = providing == kIOPSBatteryPowerValue
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let capacity = desc[kIOPSCurrentCapacityKey] as? Int,
                  let maxCapacity = desc[kIOPSMaxCapacityKey] as? Int, maxCapacity > 0 else { continue }
            return (onBattery, capacity * 100 / maxCapacity)
        }
        return nil // desktop Mac: no battery to guard
    }

    // Keeping an unplugged laptop awake until it dies is the one way this app
    // can genuinely hurt — stop the session before that happens.
    func checkBatteryGuard() {
        guard isAwake || lidSleepDisabled, let status = batteryStatus(), status.onBattery,
              status.percent <= batteryGuardPercent else { return }
        stopAwake()
        NSSound(named: "Glass")?.play()
        let content = UNMutableNotificationContent()
        content.title = "Battery low — ending your session"
        content.body = "Grindset stopped at \(status.percent)% and is restoring normal sleep."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // The timer ending a session is the most consequential state change the app
    // makes — unlike a user click, it must not pass silently.
    func sessionExpired() {
        stopAwake()
        NSSound(named: "Glass")?.play()
        let content = UNMutableNotificationContent()
        content.title = "Grindset complete"
        content.body = lidSleepDisabled ? "Restoring normal sleep, including when the lid is closed." : "Letting your Mac sleep again."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    @objc func stopAwake() {
        stopCaffeinate()
        if let lidSession {
            lidTransition = true
            lidSession.stop()
        }
        updateIcon()
    }

    func stopCaffeinate() {
        if let p = caffeinate, p.isRunning { p.terminate() }
        caffeinate = nil
        sessionTimer?.invalidate()
        sessionTimer = nil
        sessionEndsAt = nil
        stopTick()
    }

    // MARK: - Lid sleep (pmset disablesleep)

    @objc func toggleLid() {
        guard !lidTransition else { return }
        if let lidSession {
            lidTransition = true
            lidSession.stop()
            updateIcon()
            return
        }
        // Recover a setting left by a version that predates the session guard.
        if lidSleepDisabled {
            if setDisableSleep(false) {
                lidSleepDisabled = false
                UserDefaults.standard.set(false, forKey: Self.ownsDisableSleepKey)
                updateIcon()
            }
            return
        }
        if let battery = batteryStatus(), battery.onBattery, battery.percent <= batteryGuardPercent {
            showLidError("Charge your Mac above \(batteryGuardPercent)% or connect power before starting a lid-close session.")
            return
        }
        if !isAwake { startAwake(duration: nil) }
        guard isAwake else { return }
        let session = LidSession()
        lidSession = session
        lidTransition = true
        session.onStatus = { [weak self, weak session] status, reason in
            guard let self, let session, self.lidSession === session else { return }
            switch status {
            case "active":
                self.lidSleepDisabled = true
                self.lidTransition = false
                UserDefaults.standard.set(true, forKey: Self.ownsDisableSleepKey)
                session.configure(deadline: self.sessionEndsAt)
            case "restored":
                self.lidSleepDisabled = false
                self.lidTransition = false
                self.lidSession = nil
                UserDefaults.standard.set(false, forKey: Self.ownsDisableSleepKey)
                if reason != "stopped" { self.stopCaffeinate() }
                if self.waitingToQuit { NSApp.reply(toApplicationShouldTerminate: true) }
            case "restoring":
                self.lidTransition = true
            case "error":
                self.lidSession = nil
                self.lidTransition = false
                self.showLidError(reason == "sleep-already-disabled"
                    ? "Another setting already disables system sleep. Restore that setting first so Grindset can safely own and clean up its session."
                    : (reason ?? "The sleep guard could not start."))
            case "disconnected":
                self.lidSession = nil
                self.lidTransition = false
                self.lidSleepDisabled = Self.systemSleepDisabled()
                if self.lidSleepDisabled {
                    self.stopCaffeinate()
                    self.showLidError("The sleep guard disconnected before confirming cleanup. Use the lid-close menu item to restore sleep, or run sudo pmset -a disablesleep 0.")
                } else {
                    UserDefaults.standard.set(false, forKey: Self.ownsDisableSleepKey)
                    if self.waitingToQuit { NSApp.reply(toApplicationShouldTerminate: true) }
                }
            default: break
            }
            self.updateIcon()
        }
        do { try session.start(deadline: sessionEndsAt) }
        catch {
            lidSession = nil
            lidTransition = false
            showLidError(error.localizedDescription)
        }
        updateIcon()
    }

    func showLidError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Lid-close session needs attention"
        alert.informativeText = message
        alert.runModal()
        if waitingToQuit {
            waitingToQuit = false
            NSApp.reply(toApplicationShouldTerminate: false)
        }
    }

    @objc func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://www.blake.ist/tools/grindset/help")!)
    }

    @discardableResult
    func setDisableSleep(_ disabled: Bool) -> Bool {
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        return error == nil
    }

    // MARK: - Coffee Break (webcam mirror)

    @objc func toggleCoffeeBreak() {
        if breakPanel?.isVisible == true {
            closeCoffeeBreak()
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted {
                    self.showCoffeeBreak()
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Camera access needed"
                    alert.informativeText = "Allow Grindset to use the camera in System Settings → Privacy & Security → Camera, then try again."
                    alert.runModal()
                }
            }
        }
    }

    func showCoffeeBreak() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            let alert = NSAlert()
            alert.messageText = "No camera found"
            alert.runModal()
            return
        }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard session.canAddInput(input) else {
            let alert = NSAlert()
            alert.messageText = "Couldn't start the camera"
            alert.informativeText = "It may be in use by another app."
            alert.runModal()
            return
        }
        session.addInput(input)

        let output = AVCapturePhotoOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            photoOutput = output
            // Configure mirroring at setup, before startRunning — mutating the
            // connection while the session runs races its internal queue.
            if let conn = output.connection(with: .video), conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = true // match the mirrored preview
            }
        }

        let size = NSSize(width: 320, height: 240)
        // Clamp to the screen the status item is actually on (multi-display).
        let visible = statusItem.button?.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Drop the panel just below the status item, clamped to the screen.
        var origin = NSPoint(x: visible.maxX - size.width - 16,
                             y: visible.maxY - size.height - 8)
        if let buttonWindow = statusItem.button?.window {
            let f = buttonWindow.frame
            origin.x = min(max(f.midX - size.width / 2, visible.minX + 8),
                           visible.maxX - size.width - 8)
            origin.y = f.minY - size.height - 8
        }

        let panel = BreakPanel(contentRect: NSRect(origin: origin, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true

        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.masksToBounds = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        // A mirror should mirror — flip like the front camera in Photo Booth.
        if let conn = preview.connection {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }
        view.layer?.addSublayer(preview)

        let snap = makeOverlayButton(symbol: "camera.fill", label: "Take Photo", size: 44,
                                     action: #selector(snapTapped))
        snap.frame.origin = NSPoint(x: (size.width - 44) / 2, y: 12)
        view.addSubview(snap)
        snapButton = snap

        let close = makeOverlayButton(symbol: "xmark", label: "Close Coffee Break", size: 24,
                                      action: #selector(closeBreakTapped))
        close.frame.origin = NSPoint(x: size.width - 32, y: size.height - 32)
        view.addSubview(close)

        panel.contentView = view
        panel.makeKeyAndOrderFront(nil) // key (without activating) so Esc works

        // startRunning blocks; keep the menu bar responsive.
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }

        captureSession = session
        breakPanel = panel
        armClickOutsideMonitor()
    }

    func armClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeCoffeeBreak()
        }
    }

    func disarmClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    func makeOverlayButton(symbol: String, label: String, size: CGFloat, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.45, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(config)
        button.setAccessibilityLabel(label)
        button.isBordered = false
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        button.layer?.cornerRadius = size / 2
        button.frame = NSRect(x: 0, y: 0, width: size, height: size)
        return button
    }

    @objc func snapTapped() { beginCountdown() }
    @objc func closeBreakTapped() { closeCoffeeBreak() }

    func closeCoffeeBreak() {
        disarmClickOutsideMonitor()
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownLabel = nil
        photoOutput = nil
        snapButton = nil
        if let session = captureSession {
            captureSession = nil // clear before the async stop so no caller sees a stopping session
            // Turn the camera (and its indicator light) off immediately.
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }
        breakPanel?.orderOut(nil)
        breakPanel = nil
    }

    // MARK: - Photo booth

    func announce(_ text: String) {
        guard let view = breakPanel?.contentView else { return }
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    func beginCountdown() {
        guard countdownTimer == nil, let view = breakPanel?.contentView else { return }
        snapButton?.isHidden = true
        // The user is posing, not clicking — a stray click on another window
        // must not kill the panel mid-countdown. Re-armed after the flash.
        disarmClickOutsideMonitor()
        announce("Taking a photo in 3")
        let label = NSTextField(labelWithString: "3")
        label.font = .systemFont(ofSize: 110, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 10
        label.shadow = shadow
        let labelHeight = ceil(110 * 1.25) // countdown font size × line height
        label.frame = view.bounds.insetBy(dx: 0, dy: max(0, (view.bounds.height - labelHeight) / 2))
        view.addSubview(label)
        countdownLabel = label
        NSSound(named: "Tink")?.play()

        var remaining = 3
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            remaining -= 1
            if remaining > 0 {
                self.countdownLabel?.stringValue = "\(remaining)"
                NSSound(named: "Tink")?.play()
                self.announce("\(remaining)")
            } else {
                timer.invalidate()
                self.countdownTimer = nil
                self.countdownLabel?.removeFromSuperview()
                self.countdownLabel = nil
                self.capturePhoto()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        countdownTimer = t
    }

    func capturePhoto() {
        guard let output = photoOutput, captureSession?.isRunning == true else {
            // Capture can't proceed; restore the panel to its idle state.
            snapButton?.isHidden = false
            armClickOutsideMonitor()
            return
        }
        // JPEG is always available on macOS 13+; a codec fallback would silently
        // write HEIC bytes into a .jpg file.
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        NSSound(named: "Pop")?.play()
        announce("Snap")
        output.capturePhoto(with: settings, delegate: self)
        flashPanel()
    }

    func flashPanel() {
        guard let view = breakPanel?.contentView else { return }
        let finish = { [weak self] in
            // Panel may have been closed during the flash; don't re-arm a
            // global monitor with nothing left to guard.
            guard let self, self.breakPanel != nil else { return }
            self.snapButton?.isHidden = false
            self.armClickOutsideMonitor()
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finish() // the Pop sound is the capture cue; skip the flash
            return
        }
        let flash = NSView(frame: view.bounds)
        flash.wantsLayer = true
        flash.layer?.backgroundColor = NSColor.white.cgColor
        view.addSubview(flash)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            flash.animator().alphaValue = 0
        }, completionHandler: {
            flash.removeFromSuperview()
            finish()
        })
    }

    static let photoNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    // MARK: - Calendar (Itsycal-lite: day number in the bar, month-grid popover)

    static let monthTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        return f
    }()

    func setupDateItem() {
        dateStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = dateStatusItem.button {
            button.target = self
            button.action = #selector(dateItemClicked)
            button.font = .systemFont(ofSize: 13, weight: .medium)
        }
        updateDateItem()
    }

    @objc func dayChanged() {
        DispatchQueue.main.async { [weak self] in self?.updateDateItem() }
    }

    func updateDateItem() {
        let now = Date()
        let day = "\(Calendar.current.component(.day, from: now))"
        if let button = dateStatusItem?.button {
            button.image = Self.dateBadgeImage(day)
            button.imagePosition = .imageOnly
            button.title = ""
            button.setAccessibilityLabel("Calendar — \(Self.fullDateFormatter.string(from: now))")
            button.toolTip = Self.fullDateFormatter.string(from: now)
        }
    }

    // The day number inside a rounded-rect outline, rendered as a template
    // image so the menu bar tints it (white on dark, dark on light) for free.
    static func dateBadgeImage(_ text: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let height: CGFloat = 15
        let width = max(height, ceil(textSize.width) + 10)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let box = rect.insetBy(dx: 0.75, dy: 0.75)
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            path.lineWidth = 1.2
            NSColor.black.setStroke()
            path.stroke()
            let origin = NSPoint(x: (rect.width - textSize.width) / 2,
                                 y: (rect.height - textSize.height) / 2)
            (text as NSString).draw(at: origin, withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc func dateItemClicked() {
        if let pop = calendarPopover, pop.isShown {
            pop.performClose(nil)
            return
        }
        guard let button = dateStatusItem.button else { return }
        updateDateItem()
        displayedMonth = Date() // always open on the current month

        let host = CalendarHostView()
        host.onScrollStep = { [weak self] direction in
            guard let self else { return }
            self.displayedMonth = Calendar.current.date(
                byAdding: .month, value: direction, to: self.displayedMonth) ?? self.displayedMonth
            self.refreshCalendar()
        }
        calendarHost = host
        let size = populateCalendar(into: host)

        let vc = NSViewController()
        vc.view = host
        calendarVC = vc
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = vc
        pop.contentSize = size
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        calendarPopover = pop
    }

    @objc func prevMonth() {
        displayedMonth = Calendar.current.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
        refreshCalendar()
    }

    @objc func nextMonth() {
        displayedMonth = Calendar.current.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
        refreshCalendar()
    }

    @objc func jumpToToday() {
        displayedMonth = Date()
        refreshCalendar()
    }

    func refreshCalendar() {
        guard let host = calendarHost else { return }
        let size = populateCalendar(into: host) // keep the same host so scroll stays live
        calendarPopover?.contentSize = size // constant: month grid is always 6 rows
        // Crossfade the new month in — height is fixed, so nothing jumps.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           let content = host.subviews.last {
            content.wantsLayer = true
            content.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                content.animator().alphaValue = 1
            }
        }
    }

    private func navButton(_ symbol: String, _ action: Selector, label: String) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.setAccessibilityLabel(label)
        return button
    }

    private func weekdayLabel(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return label
    }

    private func dayCell(_ date: Date?) -> NSView {
        let cell = NSView()
        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.widthAnchor.constraint(equalToConstant: 30).isActive = true
        cell.heightAnchor.constraint(equalToConstant: 26).isActive = true
        guard let date else { return cell } // blank padding cell

        let label = NSTextField(labelWithString: "\(Calendar.current.component(.day, from: date))")
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        if Calendar.current.isDateInToday(date) {
            let circle = NSView()
            circle.wantsLayer = true
            circle.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            circle.layer?.cornerRadius = 11
            circle.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(circle)
            NSLayoutConstraint.activate([
                circle.widthAnchor.constraint(equalToConstant: 22),
                circle.heightAnchor.constraint(equalToConstant: 22),
                circle.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                circle.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            label.textColor = .alternateSelectedControlTextColor // correct "text on accent" token
            label.setAccessibilityLabel("Today, " + Self.fullDateFormatter.string(from: date))
        } else {
            label.textColor = .labelColor
        }

        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // Cells for the displayed month: leading blanks to the first weekday, then
    // each day, padded to whole weeks. Respects the locale's first weekday.
    private func monthCells(_ month: Date) -> [Date?] {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: month)
        guard let first = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: first) else { return [] }
        let leading = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for day in range {
            cells.append(cal.date(byAdding: .day, value: day - 1, to: first))
        }
        while cells.count < 42 { cells.append(nil) } // always 6 rows → stable popover height
        return cells
    }

    @discardableResult
    func populateCalendar(into host: CalendarHostView) -> NSSize {
        host.subviews.forEach { $0.removeFromSuperview() }
        let cal = Calendar.current
        let gridWidth: CGFloat = 7 * 30 + 6 * 2

        let prev = navButton("chevron.left", #selector(prevMonth), label: "Previous month")
        let next = navButton("chevron.right", #selector(nextMonth), label: "Next month")
        let title = NSButton(title: "", target: self, action: #selector(jumpToToday))
        title.isBordered = false
        title.attributedTitle = NSAttributedString(
            string: Self.monthTitleFormatter.string(from: displayedMonth),
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                         .foregroundColor: NSColor.labelColor])
        title.toolTip = "Jump to today"
        let header = NSStackView(views: [prev, title, next])
        header.orientation = .horizontal
        header.distribution = .equalSpacing
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: gridWidth).isActive = true

        // Weekday symbols rotated to the locale's first weekday.
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let firstIndex = cal.firstWeekday - 1
        let ordered = (0..<7).map { symbols[($0 + firstIndex) % 7] }

        let grid = NSGridView(numberOfColumns: 7, rows: 0)
        grid.rowSpacing = 2
        grid.columnSpacing = 2
        grid.addRow(with: ordered.map { weekdayLabel($0) })
        let cells = monthCells(displayedMonth)
        for weekStart in stride(from: 0, to: cells.count, by: 7) {
            grid.addRow(with: (weekStart..<weekStart + 7).map { dayCell(cells[$0]) })
        }

        let stack = NSStackView(views: [header, grid])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Proper frosted popover material so dark text reads on a light panel
        // instead of bleeding through to the desktop.
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        host.addSubview(backdrop)
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: host.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])

        // Size deterministically from the laid-out content — host.fittingSize
        // on a bare NSView over-reports, which left a tall empty band.
        host.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        host.setFrameSize(size)
        return size
    }

    // MARK: - Quit

    @objc func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let lidSession {
            waitingToQuit = true
            lidTransition = true
            lidSession.stop()
            updateIcon()
            return .terminateLater
        }
        // Don't stop the session here — a cancelled quit must leave it running;
        // applicationWillTerminate cleans up on actual exit.
        guard lidSleepDisabled else { return .terminateNow }
        if setDisableSleep(false) {
            lidSleepDisabled = false
            UserDefaults.standard.set(false, forKey: Self.ownsDisableSleepKey)
            return .terminateNow
        }
        // Restore failed (cancelled password prompt or pmset error). Don't
        // exit with sleep silently disabled — make the user choose.
        let alert = NSAlert()
        alert.messageText = "Lid-close sleep is still disabled"
        alert.informativeText = "The setting couldn't be restored. Quit anyway and the Mac won't sleep when closed (fix later with: sudo pmset -a disablesleep 0), or cancel and try again."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        if alert.runModal() == .alertFirstButtonReturn {
            updateIcon()
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopCaffeinate()
    }
}

extension AppDelegate: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Couldn't take the photo"
                alert.informativeText = error?.localizedDescription ?? "No image data returned."
                alert.runModal()
            }
            return
        }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let url = desktop.appendingPathComponent(
            "Coffee Break \(Self.photoNameFormatter.string(from: Date())).jpg")
        do {
            try data.write(to: url)
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            // Desktop may be TCC-denied — don't lose the shot; fall back to /tmp.
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            if (try? data.write(to: fallback)) != nil {
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([fallback])
                    let alert = NSAlert()
                    alert.messageText = "Saved to a temporary folder instead"
                    alert.informativeText = "Grindset couldn't write to your Desktop. Allow Desktop access in System Settings → Privacy & Security → Files and Folders, then move the photo somewhere safe — temporary files don't survive forever."
                    alert.runModal()
                }
            } else {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't save the photo"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    // Without this, macOS suppresses banners whenever the app is "frontmost"
    // (which a nonactivating accessory app can technically be).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
