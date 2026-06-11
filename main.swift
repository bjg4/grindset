import Cocoa
import AVFoundation
import UserNotifications
import IOKit.ps

// Borderless panels refuse key status by default; we need it for Esc-to-close.
final class BreakPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        AppDelegate.shared.closeCoffeeBreak()
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
    var sigtermSource: DispatchSourceSignal?
    var breakPanel: NSPanel?
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

    var isAwake: Bool { caffeinate?.isRunning == true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        exitIfAlreadyRunning()

        // Reflect the real pmset state at launch. A crash or kill -9 can't run
        // the quit-time restore, so disablesleep=1 may be orphaned system-wide;
        // syncing here means the next normal quit heals it.
        lidSleepDisabled = Self.systemSleepDisabled()

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

        let lid = makeItem("Stay Awake When Lid Closes", #selector(toggleLid))
        lid.state = lidSleepDisabled ? .on : .off
        menu.addItem(lid)

        menu.addItem(makeItem(breakPanel?.isVisible == true
            ? "End Coffee Break"
            : "Coffee Break", #selector(toggleCoffeeBreak), key: "b"))

        menu.addItem(.separator())
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
        var stateLabel = isAwake ? "Grindset — locked in, keeping your Mac awake" : "Grindset — sleeping normally"
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
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        startTick()
        updateIcon()
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
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().checkBatteryGuard()
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
        guard isAwake, let status = batteryStatus(), status.onBattery, status.percent <= 10 else { return }
        stopAwake()
        NSSound(named: "Glass")?.play()
        let content = UNMutableNotificationContent()
        content.title = "Battery low — letting your Mac sleep"
        content.body = lidSleepDisabled
            ? "Grindset stopped at \(status.percent)%. Heads up: lid-close sleep is still disabled."
            : "Grindset stopped keeping your Mac awake at \(status.percent)%."
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
        content.body = "Letting your Mac sleep again."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    @objc func stopAwake() {
        stopCaffeinate()
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
        let turningOn = !lidSleepDisabled
        if setDisableSleep(turningOn) {
            lidSleepDisabled = turningOn
        }
        // On failure (cancelled prompt) the checkbox simply doesn't change.
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
                    alert.informativeText = "Allow Awake to use the camera in System Settings → Privacy & Security → Camera, then try again."
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
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCapturePhotoOutput()
        if session.canAddOutput(output) { session.addOutput(output) }
        photoOutput = output

        let size = NSSize(width: 320, height: 240)
        let visible = NSScreen.main?.visibleFrame
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
            // Turn the camera (and its indicator light) off immediately.
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
            captureSession = nil
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
        label.frame = view.bounds.insetBy(dx: 0, dy: (view.bounds.height - 130) / 2)
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
        // Bake in the same mirroring the preview shows.
        if let conn = output.connection(with: .video), conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }
        let settings: AVCapturePhotoSettings
        if output.availablePhotoCodecTypes.contains(.jpeg) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        } else {
            settings = AVCapturePhotoSettings()
        }
        NSSound(named: "Pop")?.play()
        announce("Snap")
        output.capturePhoto(with: settings, delegate: self)
        flashPanel()
    }

    func flashPanel() {
        guard let view = breakPanel?.contentView else { return }
        let finish = { [weak self] in
            self?.snapButton?.isHidden = false
            self?.armClickOutsideMonitor()
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

    // MARK: - Quit

    @objc func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stopCaffeinate()
        guard lidSleepDisabled else { return .terminateNow }
        if setDisableSleep(false) {
            lidSleepDisabled = false
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
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Couldn't save the photo"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}
