import Darwin
import Foundation

/// Atomic rename plus file and directory fsync make first-write permission
/// contingent on a durable recovery obligation, not an in-memory flag.
public final class FileRecoveryMarkerStore: RecoveryMarkerStoring {
    public let directory: URL
    private let markerPath: String
    public init(directory: URL) throws {
        self.directory = directory
        markerPath = directory.appendingPathComponent("recovery.json").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0 else {
            throw RecoveryError.failure("Recovery directory must be owned by the service and not writable by others")
        }
    }
    public func load() throws -> RecoveryMarker? {
        let fd = open(markerPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw ioError("open marker") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0,
              info.st_size > 0, info.st_size <= 65536 else {
            throw RecoveryError.failure("Unsafe or malformed recovery marker")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw ioError("read marker")
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 65536 else { throw RecoveryError.failure("Recovery marker too large") }
        }
        let marker = try JSONDecoder().decode(RecoveryMarker.self, from: data)
        guard marker.version == 1, marker.identity.pid > 1, !marker.generation.isEmpty else {
            throw RecoveryError.failure("Unsupported recovery marker")
        }
        return marker
    }
    public func save(_ marker: RecoveryMarker) throws {
        let data = try JSONEncoder().encode(marker)
        let temporary = directory.appendingPathComponent(".recovery-\(UUID().uuidString)").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ioError("create marker") }
        defer { close(fd); unlink(temporary) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ioError("write marker") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw ioError("sync marker") }
        guard rename(temporary, markerPath) == 0 else { throw ioError("rename marker") }
        try syncDirectory()
    }
    public func clear() throws {
        guard unlink(markerPath) == 0 || errno == ENOENT else { throw ioError("remove marker") }
        try syncDirectory()
    }
    private func syncDirectory() throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ioError("open recovery directory") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw ioError("sync recovery directory") }
    }
    private func ioError(_ operation: String) -> RecoveryError {
        .failure("Cannot \(operation): errno \(errno)")
    }
}
