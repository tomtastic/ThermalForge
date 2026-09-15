import Darwin
import Foundation

/// Serializes install/uninstall transactions, not normal SMC operations.
/// The inode remains in place so waiting installers always share the same lock.
public final class ServiceInstallationLock {
    private let fd: Int32
    public init(path: String = "/var/run/com.thermalforge.install.lock") throws {
        let descriptor = open(path, O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BackendStorageError.invalid("Cannot open installation lock: errno \(errno)") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
            close(descriptor)
            throw BackendStorageError.invalid("Unsafe installation lock")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw BackendStorageError.invalid("Another installation or uninstall is in progress")
        }
        fd = descriptor
    }
    deinit { close(fd) }
}
