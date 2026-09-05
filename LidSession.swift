import Cocoa
import Darwin

/// The user process owns a private socket. Closing it ends the privileged lease.
final class LidSession {
    var onStatus: ((String, String?) -> Void)?
    private var listener: Int32 = -1
    private var connection: Int32 = -1
    private var directory: String = ""
    private let io = DispatchQueue(label: "grindset.lid-lease")
    private let lock = NSLock()
    private var cancelled = false

    func start(deadline: Date?) throws {
        let template = (NSTemporaryDirectory() + "grindset-lid.XXXXXX").utf8CString
        var mutable = Array(template)
        guard let path = mkdtemp(&mutable) else { throw failure("Could not create a private session directory.") }
        directory = String(cString: path)
        let socketPath = directory + "/guard.sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw failure("Could not create the session connection.") }
        var noSignal: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw failure("Session path is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(listener, 1) == 0 else { throw failure("Could not listen for the sleep guard.") }
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("GrindsetLidGuard"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw failure("The sleep guard is missing. Reinstall Grindset.")
        }
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "\(quote(executable.path)) \(getpid()) \(getuid()) \(quote(socketPath)) </dev/null >/dev/null 2>&1 &"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        if let error { throw failure(error[NSAppleScript.errorMessage] as? String ?? "Administrator approval was cancelled.") }
        let server = listener
        io.async { [weak self] in
            guard let self else { return }
            var descriptor = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 15000) > 0 else {
                self.deliver("error", "The sleep guard did not start. Your sleep settings were not intentionally changed.")
                return
            }
            let client = accept(server, nil, nil)
            guard client >= 0 else { self.deliver("error", "Could not connect to the sleep guard."); return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == 0 else {
                close(client)
                self.deliver("error", "The sleep guard could not be authenticated.")
                return
            }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            self.lock.lock()
            self.connection = client
            let cancelled = self.cancelled
            self.lock.unlock()
            if cancelled { self.stop() }
            else { self.configure(deadline: deadline) }
            var buffer = Data()
            while true {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let length = recv(client, &bytes, bytes.count, 0)
                if length <= 0 { break }
                buffer.append(contentsOf: bytes.prefix(length))
                if buffer.count > 8192 { break }
                while let end = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: end)
                    buffer.removeSubrange(...end)
                    if let message = try? JSONSerialization.jsonObject(with: line) as? [String: String],
                       let status = message["status"] {
                        self.deliver(status, message["reason"])
                    }
                }
            }
            self.lock.lock()
            if self.connection == client { self.connection = -1 }
            self.lock.unlock()
            close(client)
            self.deliver("disconnected", nil)
        }
    }

    func configure(deadline: Date?) {
        var message: [String: Any] = ["command": "configure"]
        message["deadline"] = deadline.map { $0.timeIntervalSince1970 } ?? NSNull()
        send(message)
    }

    func stop() {
        lock.lock()
        cancelled = true
        lock.unlock()
        send(["command": "stop"])
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(10)
        lock.lock()
        defer { lock.unlock() }
        guard connection >= 0 else { return }
        data.withUnsafeBytes { bytes in
            _ = Darwin.send(connection, bytes.baseAddress, bytes.count, 0)
        }
    }

    private func deliver(_ status: String, _ reason: String?) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(status, reason) }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "Grindset.LidGuard", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    deinit {
        if connection >= 0 { close(connection) }
        if listener >= 0 { close(listener) }
        if !directory.isEmpty { try? FileManager.default.removeItem(atPath: directory) }
    }
}
