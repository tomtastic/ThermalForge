import Darwin
import Foundation

/// One absolute deadline covers connect, request and response, including trickled frames.
public enum UnixSocketTransport {
    public static func roundTrip(_ payload: Data, path: String,
                                 timeout: TimeInterval = BackendTiming.requestDeadline) throws -> Data {
        guard payload.count <= BackendTiming.maximumFrameBytes else {
            throw DaemonError.protocolError("request frame too large")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.connectionFailed }
        defer { close(fd) }
        try configure(fd)
        var address = try socketAddress(path)
        let deadline = BackendTiming.monotonicNow + max(0, timeout)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw DaemonError.notRunning }
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0,
                  socketError == 0 else { throw DaemonError.connectionFailed }
        }
        try writeFrame(payload, to: fd, deadline: deadline)
        return try readFrame(from: fd, deadline: deadline)
    }

    static func configure(_ fd: Int32) throws {
        var noSignal: Int32 = 1
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw DaemonError.connectionFailed
        }
    }

    static func socketAddress(_ path: String) throws -> sockaddr_un {
        guard !path.utf8.contains(0), path.utf8.count < 104 else {
            throw DaemonError.protocolError("Unix socket path is too long or invalid")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, path, 104) }
        }
        return address
    }

    static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - BackendTiming.monotonicNow
            guard remaining > 0 else { throw DaemonError.timedOut }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if result > 0 {
                guard descriptor.revents & Int16(POLLNVAL | POLLERR) == 0 else {
                    throw DaemonError.connectionFailed
                }
                return // HUP is consumed by read, preserving a final response.
            }
            if result == 0 { throw DaemonError.timedOut }
            if errno != EINTR { throw DaemonError.connectionFailed }
        }
    }

    static func readFrame(from fd: Int32, deadline: TimeInterval) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let bytes = buffer[..<count]
                if let end = bytes.firstIndex(of: 10) {
                    data.append(contentsOf: bytes[..<end])
                    guard data.count <= BackendTiming.maximumFrameBytes else {
                        throw DaemonError.protocolError("response frame too large")
                    }
                    return data
                }
                data.append(contentsOf: bytes)
                guard data.count <= BackendTiming.maximumFrameBytes else {
                    throw DaemonError.protocolError("response frame too large")
                }
            } else if count == 0 {
                guard !data.isEmpty else { throw DaemonError.connectionFailed }
                return data
            } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                throw DaemonError.connectionFailed
            }
        }
    }

    static func writeFrame(_ payload: Data, to fd: Int32, deadline: TimeInterval) throws {
        guard payload.count <= BackendTiming.maximumFrameBytes else {
            throw DaemonError.protocolError("response frame too large")
        }
        let bytes = [UInt8](payload) + [10]
        var offset = 0
        while offset < bytes.count {
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            let count = bytes.withUnsafeBufferPointer {
                write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset)
            }
            if count > 0 { offset += count }
            else if count == 0 || (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                throw DaemonError.connectionFailed
            }
        }
    }
}

/// Bounded independent connections ensure one incomplete request cannot stall the service.
public final class UnixSocketListener {
    private let path: String
    private let fd: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "com.thermalforge.socket.accept")
    private let slots = DispatchSemaphore(value: 16)
    private let authorize: (AuthenticatedPeer) -> Bool
    private let handler: (Data, AuthenticatedPeer) -> Data
    private let lock = NSLock()
    private var started = false
    private var stopped = false

    public init(path: String, mode: mode_t = 0o600,
                authorize: @escaping (AuthenticatedPeer) -> Bool,
                handler: @escaping (Data, AuthenticatedPeer) -> Data) throws {
        self.path = path
        self.authorize = authorize
        self.handler = handler
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        fd = descriptor
        guard fd >= 0 else { throw DaemonError.connectionFailed }
        do {
            try UnixSocketTransport.configure(fd)
            var address = try UnixSocketTransport.socketAddress(path)
            // Never replace a live service's socket or follow an arbitrary file.
            var existing = stat()
            if lstat(path, &existing) == 0 {
                guard existing.st_mode & S_IFMT == S_IFSOCK else {
                    throw DaemonError.protocolError("socket path is not a socket")
                }
                let probe = socket(AF_UNIX, SOCK_STREAM, 0)
                guard probe >= 0 else { throw DaemonError.connectionFailed }
                defer { close(probe) }
                try UnixSocketTransport.configure(probe)
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                guard connected < 0, errno == ECONNREFUSED else {
                    throw DaemonError.protocolError("service is already listening")
                }
                guard unlink(path) == 0 else { throw DaemonError.connectionFailed }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(path, mode) == 0, listen(fd, 16) == 0 else {
                throw DaemonError.connectionFailed
            }
        } catch { close(fd); throw error }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptReady() }
        source.setCancelHandler { close(descriptor) }
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        source.resume()
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        if !started { started = true; source.resume() }
        source.cancel()
        unlink(path)
    }

    private func acceptReady() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            guard slots.wait(timeout: .now()) == .success else { close(client); continue }
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { close(client); slots.signal() }
                do {
                    try UnixSocketTransport.configure(client)
                    var uid: uid_t = 0
                    var gid: gid_t = 0
                    var pid: Int32 = 0
                    var size = socklen_t(MemoryLayout<Int32>.size)
                    guard getpeereid(client, &uid, &gid) == 0,
                          getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
                          pid > 0 else { return }
                    let peer = AuthenticatedPeer(uid: uid, pid: pid)
                    guard authorize(peer) else { return }
                    let deadline = BackendTiming.monotonicNow + BackendTiming.requestDeadline
                    let data = try UnixSocketTransport.readFrame(from: client, deadline: deadline)
                    let response = handler(data, peer)
                    try UnixSocketTransport.writeFrame(response, to: client, deadline: deadline)
                } catch { /* A closed or timed-out connection never renews control. */ }
            }
        }
    }

    deinit { stop() }
}
