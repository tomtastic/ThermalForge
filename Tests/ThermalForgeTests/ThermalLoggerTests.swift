import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Thermal logger lifecycle")
struct ThermalLoggerTests {
    @Test("A cancelled logger still finalizes its session")
    func cancelledLoggerFinalizesSession() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let token = CancellationToken()
        token.cancel()
        let logger = try ThermalLogger(
            fanControl: FanControl(smc: FakeSMC()),
            outputDir: parent,
            cancellationToken: token
        )

        try logger.run()

        let thermalCSV = logger.outputPath.appendingPathComponent("thermal.csv")
        let processCSV = logger.outputPath.appendingPathComponent("processes.csv")
        let metadataURL = logger.outputPath.appendingPathComponent("metadata.json")
        let expiryMarker = logger.outputPath.appendingPathComponent(".expires")
        #expect(FileManager.default.fileExists(atPath: thermalCSV.path))
        #expect(FileManager.default.fileExists(atPath: processCSV.path))
        #expect(FileManager.default.fileExists(atPath: metadataURL.path))
        #expect(FileManager.default.fileExists(atPath: expiryMarker.path))

        let metadata = try JSONDecoder().decode(
            LogSessionMetadata.self,
            from: Data(contentsOf: metadataURL)
        )
        #expect(metadata.endedAt != nil)
        #expect(metadata.totalSamples == 0)
    }
}
