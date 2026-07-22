import Darwin
import Foundation

// MARK: - Calibration Persistence

extension CalibrationData {
    public static var applicationSupportDirectory: URL {
        applicationSupportDirectory(forHomeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func applicationSupportDirectory(forHomeDirectory homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/ThermalForge", isDirectory: true)
    }

    /// File path for a given lid state in the effective user's home directory.
    public static func filePath(forLidClosed lidClosed: Bool) -> URL {
        filePath(forLidClosed: lidClosed, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func filePath(forLidClosed lidClosed: Bool, homeDirectory: URL) -> URL {
        applicationSupportDirectory(forHomeDirectory: homeDirectory)
            .appendingPathComponent("calibration_\(lidClosed ? "lid_closed" : "lid_open").json")
    }

    static func allFilePaths(homeDirectory: URL) -> [URL] {
        let directory = applicationSupportDirectory(forHomeDirectory: homeDirectory)
        return [
            filePath(forLidClosed: false, homeDirectory: homeDirectory),
            filePath(forLidClosed: true, homeDirectory: homeDirectory),
            directory.appendingPathComponent("calibration.json"),
        ]
    }

    static func resetFilePaths(currentHome: URL, consoleHome: URL?) -> [URL] {
        UserHomeDirectoryResolver.homeDirectories(
            currentHome: currentHome,
            consoleHome: consoleHome
        ).flatMap(allFilePaths(homeDirectory:))
    }

    /// Remove lid-open, lid-closed, and legacy calibration files for root and
    /// the active console user. The CLI requires root before invoking this.
    @discardableResult
    public static func clearAllStoredCalibration() throws -> [URL] {
        let consoleHome = UserHomeDirectoryResolver.activeConsoleUser()?.homeDirectory
        let paths = resetFilePaths(
            currentHome: FileManager.default.homeDirectoryForCurrentUser,
            consoleHome: consoleHome
        )
        return try removeCalibrationFiles(at: paths)
    }

    static func removeCalibrationFiles(
        at paths: [URL],
        fileManager: FileManager = .default
    ) throws -> [URL] {
        var removed: [URL] = []
        for path in paths where fileManager.fileExists(atPath: path.path) {
            try fileManager.removeItem(at: path)
            removed.append(path)
        }
        return removed
    }

    /// Save calibration and return every path written.
    @discardableResult
    public func save() throws -> [URL] {
        let path = Self.filePath(forLidClosed: lidClosed)
        let directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: path, options: .atomic)

        var savedPaths = [path]
        if geteuid() == 0,
           let consoleUser = UserHomeDirectoryResolver.activeConsoleUser(),
           let userPath = try copyToConsoleUser(data: data, consoleUser: consoleUser)
        {
            savedPaths.append(userPath)
        }
        return savedPaths
    }

    private func copyToConsoleUser(data: Data, consoleUser: ConsoleUserInfo) throws -> URL? {
        let userPath = Self.filePath(
            forLidClosed: lidClosed,
            homeDirectory: consoleUser.homeDirectory
        )
        guard userPath.standardizedFileURL != Self.filePath(forLidClosed: lidClosed).standardizedFileURL else {
            return nil
        }

        let userDirectory = userPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        try data.write(to: userPath, options: .atomic)

        // Files created by a sudo calibration otherwise remain root-owned.
        _ = chown(userDirectory.path, consoleUser.uid, consoleUser.gid)
        _ = chown(userPath.path, consoleUser.uid, consoleUser.gid)
        _ = chmod(userPath.path, 0o644)
        TFLogger.shared.info("Copied calibration to console user: \(userPath.path)")
        return userPath
    }

    /// Load calibration data matching the current lid state.
    public static func load(
        lidStateProvider: any LidStateProvider = MacLidStateProvider()
    ) -> CalibrationData? {
        load(forLidClosed: lidStateProvider.isLidClosed)
    }

    static func load(
        lidStateProvider: any LidStateProvider,
        pathForLidState: (Bool) -> URL
    ) -> CalibrationData? {
        let lidClosed = lidStateProvider.isLidClosed
        return load(forLidClosed: lidClosed, from: pathForLidState(lidClosed))
    }

    /// A missing state-specific file means that state is uncalibrated. Legacy
    /// data is deliberately not substituted because its lid state is unknown.
    public static func load(forLidClosed lidClosed: Bool) -> CalibrationData? {
        load(forLidClosed: lidClosed, from: filePath(forLidClosed: lidClosed))
    }

    /// Path-injectable loader used by tests and by the state-specific loader.
    static func load(forLidClosed lidClosed: Bool, from specificPath: URL) -> CalibrationData? {
        guard let calibration = loadFromFile(specificPath) else { return nil }
        guard calibration.lidClosed == lidClosed else {
            TFLogger.shared.error("Calibration file lid state does not match its filename — ignoring")
            return nil
        }
        return calibration
    }

    static func loadFromFile(_ url: URL) -> CalibrationData? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        guard let data = try? Data(contentsOf: url) else {
            TFLogger.shared.error("Calibration file exists but couldn't be read — deleting")
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        guard let calibration = try? JSONDecoder().decode(CalibrationData.self, from: data) else {
            TFLogger.shared.error("Calibration file is corrupted (JSON decode failed) — deleting")
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        return calibration
    }

}
