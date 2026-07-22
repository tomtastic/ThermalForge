import ArgumentParser
import Foundation
import ThermalForgeCore

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the background daemon (one-time, requires sudo)"
    )

    func run() throws {
        guard geteuid() == 0 else {
            throw ValidationError("Run with sudo: sudo thermalforge install")
        }

        let binaryPath = ProcessInfo.processInfo.arguments[0]
        let installPath = ThermalForgeDaemon.installPath

        // Copy binary to /usr/local/bin
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: "/usr/local/bin",
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: installPath) {
            try fm.removeItem(atPath: installPath)
        }
        try fm.copyItem(atPath: binaryPath, toPath: installPath)

        // Write launchd plist
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(ThermalForgeDaemon.label)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(installPath)</string>
                    <string>daemon</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
                <key>ProcessType</key>
                <string>Adaptive</string>
                <key>LowPriorityIO</key>
                <true/>
            </dict>
            </plist>
            """
        try plist.write(
            toFile: ThermalForgeDaemon.plistPath,
            atomically: true, encoding: .utf8
        )
        // Stop a loaded older daemon before bootstrapping the replacement. Do
        // not gate on socket health because socket paths can change by version.
        let launchd = LaunchdCoordinator()
        if case .loaded = try launchd.serviceState(label: ThermalForgeDaemon.label) {
            try launchd.bootout(label: ThermalForgeDaemon.label)
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Start new daemon
        try launchd.bootstrap(plistPath: ThermalForgeDaemon.plistPath)

        // Verify
        Thread.sleep(forTimeInterval: 1.0)
        guard ThermalForgeDaemon.isRunning else {
            throw ValidationError("Daemon failed to start. Try: sudo launchctl list | grep thermalforge")
        }
        print("Done.")
    }
}
