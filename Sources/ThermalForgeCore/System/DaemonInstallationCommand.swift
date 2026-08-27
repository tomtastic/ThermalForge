import Foundation

public enum DaemonInstallationCommand {
    /// Builds the AppleScript used by the menu-bar app to launch the bundled
    /// installer with administrator privileges. The bundled executable must be
    /// run directly: copying over a previously executed Mach-O in place can
    /// leave macOS's code-signing state attached to the old vnode and cause
    /// taskgated to kill the replacement before it starts.
    public static func administratorAppleScript(executablePath: String) -> String {
        let command = "\(shellQuote(executablePath)) install"
        return "do shell script \"\(appleScriptString(command))\" with administrator privileges"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
