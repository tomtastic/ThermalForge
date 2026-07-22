import Darwin
import Foundation

struct ConsoleUserInfo {
    let uid: uid_t
    let gid: gid_t
    let homeDirectory: URL
}

/// Resolves the effective user's home and, when running through `sudo`, the
/// active console user's home without relying on environment variables.
public enum UserHomeDirectoryResolver {
    public static func rootAndConsoleUserHomes() -> [URL] {
        homeDirectories(
            currentHome: FileManager.default.homeDirectoryForCurrentUser,
            consoleHome: activeConsoleUser()?.homeDirectory
        )
    }

    static func homeDirectories(currentHome: URL, consoleHome: URL?) -> [URL] {
        var homes = [currentHome.standardizedFileURL]
        if let consoleHome {
            let standardizedConsoleHome = consoleHome.standardizedFileURL
            if !homes.contains(standardizedConsoleHome) {
                homes.append(standardizedConsoleHome)
            }
        }
        return homes
    }

    static func activeConsoleUser() -> ConsoleUserInfo? {
        var consoleStat = stat()
        guard stat("/dev/console", &consoleStat) == 0, consoleStat.st_uid != 0,
              let passwd = getpwuid(consoleStat.st_uid),
              let home = String(validatingUTF8: passwd.pointee.pw_dir)
        else { return nil }

        return ConsoleUserInfo(
            uid: consoleStat.st_uid,
            gid: passwd.pointee.pw_gid,
            homeDirectory: URL(fileURLWithPath: home, isDirectory: true)
        )
    }
}
