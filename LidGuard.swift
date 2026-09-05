import Foundation
import Darwin
import IOKit.ps

// This helper is launched with an administrator's approval for one session.
// It exposes no general-purpose privileged operation and installs no daemon.
// The parent owns the listening socket; credentials and PID are checked before
// touching pmset. A kernel process watch and socket EOF both end the lease.
@main
enum LidGuard {
    #if GUARD_TESTING
    static var restoreFailures = Int(ProcessInfo.processInfo.environment["GRINDSET_TEST_RESTORE_FAILURES"] ?? "0") ?? 0
    #endif
    static func pmset(_ value: Bool? = nil) throws -> Bool {
        #if GUARD_TESTING
        let path = ProcessInfo.processInfo.environment["GRINDSET_TEST_STATE"]!
        if let value {
            if !value && restoreFailures > 0 { restoreFailures -= 1; throw GuardError.pmset }
            try (value ? "1" : "0").write(toFile: path, atomically: true, encoding: .utf8)
        }
        return try String(contentsOfFile: path, encoding: .utf8) == "1"
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = value.map { ["-a", "disablesleep", $0 ? "1" : "0"] } ?? ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        // A hung system utility must not prevent this guard from retrying cleanup.
        guard finished.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) != .success {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            pipe.fileHandleForReading.closeFile()
            throw GuardError.pmset
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pipe.fileHandleForReading.closeFile()
        guard process.terminationStatus == 0 else { throw GuardError.pmset }
        if value != nil { return try pmset() }
        let output = String(decoding: data, as: UTF8.self)
        guard let line = output.split(separator: "\n").first(where: { $0.contains("SleepDisabled") }) else {
            throw GuardError.pmset
        }
        return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        #endif
    }

    enum GuardError: Error { case pmset, connection, credentials }

    static func send(_ fd: Int32, _ status: String, reason: String? = nil) {
        var object = ["status": status]
        if let reason { object["reason"] = reason }
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        data.withUnsafeBytes { bytes in
            _ = Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
        }
    }

    static func battery() -> (Bool, Int?) {
        #if GUARD_TESTING
        if let percent = ProcessInfo.processInfo.environment["GRINDSET_TEST_BATTERY"].flatMap(Int.init) { return (true, percent) }
        return (false, nil)
        #else
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (false, nil) }
        let onBattery = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPSBatteryPowerValue
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return (onBattery, current * 100 / maximum)
        }
        return (onBattery, nil)
        #endif
    }

    static func main() {
        let arguments = CommandLine.arguments
        #if !GUARD_TESTING
        guard geteuid() == 0 else { exit(77) }
        #endif
        guard arguments.count == 4,
              let parent = Int32(arguments[1]), parent > 1,
              let owner = UInt32(arguments[2]), owner != 0 else { exit(64) }
        let path = arguments[3]
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { exit(71) }
        defer { close(fd) }
        signal(SIGPIPE, SIG_IGN)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { exit(64) }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { exit(69) }
        var uid: uid_t = 0
        var gid: gid_t = 0
        var peerPID: pid_t = 0
        var peerSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == owner,
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerSize) == 0, peerPID == parent else {
            send(fd, "error", reason: "credentials")
            exit(77)
        }
        let queue = kqueue()
        guard queue >= 0 else { exit(71) }
        defer { close(queue) }
        var event = kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ENABLE),
                           fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        guard kevent(queue, &event, 1, nil, 0, nil) == 0 else {
            send(fd, "error", reason: "parent-exited")
            exit(69)
        }
        // Ignore process termination signals and receive them through kqueue so
        // normal cleanup still executes. SIGKILL cannot be handled by any app.
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            var sig = kevent(ident: UInt(number), filter: Int16(EVFILT_SIGNAL), flags: UInt16(EV_ADD | EV_ENABLE),
                             fflags: 0, data: 0, udata: nil)
            guard kevent(queue, &sig, 1, nil, 0, nil) == 0 else { exit(71) }
        }
        var owned = false
        var stopReason = "stopped"
        do {
            // Do not adopt or change a sleep override established by another app.
            guard try !pmset() else {
                send(fd, "error", reason: "sleep-already-disabled")
                return
            }
            // Claim cleanup responsibility before the system mutation, including
            // the case where pmset succeeds but the subsequent read fails.
            owned = true
            guard try pmset(true) else { throw GuardError.pmset }
            send(fd, "active")
            var deadline: TimeInterval?
            var buffer = Data()
            while true {
                var processEvent = kevent()
                var noWait = timespec(tv_sec: 0, tv_nsec: 0)
                let events = kevent(queue, nil, 0, &processEvent, 1, &noWait)
                let alive = events == 0 && kill(parent, 0) == 0
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                let polled = poll(&descriptor, 1, 1000)
                var connected = polled >= 0
                var requested = false
                if descriptor.revents != 0 {
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    let length = recv(fd, &bytes, bytes.count, 0)
                    if length <= 0 { connected = false }
                    else {
                        buffer.append(contentsOf: bytes.prefix(length))
                        if buffer.count > 8192 { connected = false }
                        while let end = buffer.firstIndex(of: 10) {
                            let line = buffer.prefix(upTo: end)
                            buffer.removeSubrange(...end)
                            guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                                  let command = message["command"] as? String else { throw GuardError.connection }
                            if command == "stop" { requested = true }
                            else if command == "configure" { deadline = message["deadline"] as? Double }
                            else { throw GuardError.connection }
                        }
                    }
                }
                let (onBattery, percent) = battery()
                if let reason = LidLeasePolicy.stopReason(parentAlive: alive, connected: connected, stopRequested: requested,
                    now: Date().timeIntervalSince1970, deadline: deadline, onBattery: onBattery, percent: percent) {
                    stopReason = reason
                    break
                }
            }
        } catch {
            stopReason = "guard-error"
        }
        if owned {
            // Keep the privileged process alive until restoration is confirmed.
            // The parent can exit; restoration does not depend on another prompt.
            while true {
                do {
                    if try !pmset(false) { break }
                } catch {}
                send(fd, "restoring", reason: "retrying-sleep-restore")
                sleep(2)
            }
            send(fd, "restored", reason: stopReason)
        }
    }
}
