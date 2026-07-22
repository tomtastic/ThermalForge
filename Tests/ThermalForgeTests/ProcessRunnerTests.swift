import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Process runner")
struct ProcessRunnerTests {
    @Test("Captures output, error, and non-zero status")
    func capturesProcessResult() throws {
        let result = try ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf output; printf error >&2; exit 7"]
        )

        #expect(result.standardOutput == "output")
        #expect(result.standardError == "error")
        #expect(result.terminationStatus == 7)
        #expect(!result.succeeded)
    }

    @Test("Reports successful commands")
    func reportsSuccess() throws {
        let result = try ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/usr/bin/true")
        )

        #expect(result.succeeded)
        #expect(result.terminationStatus == 0)
    }

    @Test("Propagates launch failures")
    func propagatesLaunchFailure() {
        #expect(throws: (any Error).self) {
            try ProcessRunner().run(
                executableURL: URL(fileURLWithPath: "/path/that/does/not/exist")
            )
        }
    }

    @Test("Drains stdout and stderr concurrently")
    func drainsBothStreams() throws {
        let result = try ProcessRunner().run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "i=0; while [ $i -lt 2000 ]; do printf oooooooooo; printf eeeeeeeeee >&2; i=$((i+1)); done",
            ]
        )

        #expect(result.succeeded)
        #expect(result.standardOutput.count == 20_000)
        #expect(result.standardError.count == 20_000)
    }
}
