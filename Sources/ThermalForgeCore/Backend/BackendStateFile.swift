import Darwin
import Foundation

/// Bounded, private service state with durable replacement. Callers serialize
/// read/modify/write transactions; readers never follow a state-file symlink.
enum BackendStateFile {
    static let maximumBytes = 2 * 1024 * 1024

    static func prepareDirectory(_ directory: URL, create: Bool) throws -> Bool {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw failure("inspect state directory") }
            guard create else { return false }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try syncDirectory(directory.deletingLastPathComponent())
            guard lstat(directory.path, &info) == 0 else { throw failure("inspect created state directory") }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            throw BackendStorageError.invalid("State directory must be owned by the service and not writable by others")
        }
        return true
    }

    static func read(_ url: URL, root: URL) throws -> Data? {
        guard try prepareDirectory(root, create: false),
              try prepareDirectory(url.deletingLastPathComponent(), create: false) else { return nil }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw failure("open state") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0,
              info.st_size > 0, info.st_size <= maximumBytes else {
            throw BackendStorageError.invalid("Unsafe or oversized state file")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw failure("read state") }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else { throw BackendStorageError.invalid("State file grew beyond its limit") }
        }
    }

    static func write(_ data: Data, to url: URL, root: URL) throws {
        guard data.count <= maximumBytes else { throw BackendStorageError.invalid("State file exceeds its limit") }
        _ = try prepareDirectory(root, create: true)
        let parent = url.deletingLastPathComponent()
        _ = try prepareDirectory(parent, create: true)
        let temporary = parent.appendingPathComponent(".state-\(UUID().uuidString)").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("create state") }
        defer { close(fd); unlink(temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw failure("write state") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw failure("sync state") }
        guard rename(temporary, url.path) == 0 else { throw failure("replace state") }
        try syncDirectory(parent)
    }

    private static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw failure("open state directory") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw failure("sync state directory") }
    }
    private static func failure(_ operation: String) -> BackendStorageError {
        .invalid("Cannot \(operation): errno \(errno)")
    }
}
