import Testing

@testable import ThermalForgeCore

@Suite("Daemon installation command")
struct DaemonInstallationCommandTests {
    @Test("Runs the bundled installer directly")
    func runsBundledInstallerDirectly() {
        let bundledPath = "/Applications/ThermalForge.app/Contents/Resources/thermalforge"
        let script = DaemonInstallationCommand.administratorAppleScript(
            executablePath: bundledPath
        )

        #expect(script.contains("'\(bundledPath)' install"))
        #expect(script.hasSuffix("with administrator privileges"))
        #expect(!script.contains("cp "))
        #expect(!script.contains("chmod "))
        #expect(!script.contains("/usr/local/bin/thermalforge' install"))
    }

    @Test("Quotes shell and AppleScript metacharacters")
    func quotesInstallerPath() {
        #expect(
            DaemonInstallationCommand.shellQuote("/tmp/Thermal Forge's CLI")
                == "'/tmp/Thermal Forge'\\''s CLI'"
        )
        #expect(
            DaemonInstallationCommand.appleScriptString("a\\b\"c")
                == "a\\\\b\\\"c"
        )
    }
}
