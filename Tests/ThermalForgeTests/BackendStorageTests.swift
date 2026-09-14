import Foundation
import Testing
@testable import ThermalForgeCore

@Suite("Backend authoritative storage")
struct BackendStorageTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func calibration(lid: Bool, mode: String = "standard") -> CalibrationData {
        CalibrationData(machine: "TestMac", fans: 2, maxRPM: 6000, minRPM: 2000,
            calibratedAt: "2026-09-14", mode: mode, lidClosed: lid,
            measurements: [.init(targetTemp: 60, holdingRPMPercent: 0.4), .init(targetTemp: 80, holdingRPMPercent: 0.8)])
    }
    @Test("Configuration imports are atomic, idempotent, and scoped to authenticated UID")
    func idempotentImport() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = BackendConfigurationStore(directory: dir)
        var legacy = BackendConfiguration()
        legacy.selectedProfileID = "smart"
        let imported = try store.importLegacy(legacy, uid: 501)
        #expect(imported.importedLegacy)
        #expect(imported.selectedProfileID == "smart")
        legacy.selectedProfileID = "max"
        #expect(try store.importLegacy(legacy, uid: 501) == imported)
        #expect(try store.load(uid: 502).selectedProfileID == "silent")
        #expect(try BackendConfigurationStore(directory: dir).load(uid: 501) == imported)
    }
    @Test("Explicit edits take precedence while unedited fields migrate")
    func explicitEditPrecedence() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = BackendConfigurationStore(directory: dir)
        var explicit = try store.load(uid: 501)
        explicit.rulesEnabled = false
        explicit.selectedProfileID = "performance"
        _ = try store.update(explicit, uid: 501)
        let rule = ThermalRule(id: "legacy", name: "Legacy", condition: .init(metric: .maxTemp, comparator: .greaterThan, valueCelsius: 70), action: .setMax)
        var legacy = BackendConfiguration(rules: [rule])
        legacy.selectedProfileID = "smart"
        let merged = try store.importLegacy(legacy, uid: 501)
        #expect(!merged.rulesEnabled)
        #expect(merged.selectedProfileID == "performance")
        #expect(merged.rules == [rule])
        #expect(merged.revision == 2)
    }
    @Test("Optimistic revisions prevent concurrent stale edits from overwriting values")
    func concurrentRevision() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = BackendConfigurationStore(directory: dir)
        var first = try store.load(uid: 501), second = first
        first.rulesEnabled = false
        second.selectedProfileID = "smart"
        _ = try store.update(first, uid: 501)
        #expect(throws: BackendStorageError.self) { try store.update(second, uid: 501) }
        #expect(try !store.load(uid: 501).rulesEnabled)
    }
    @Test("Invalid import leaves no completion marker and never replaces valid configuration")
    func invalidImport() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = BackendConfigurationStore(directory: dir)
        var invalid = BackendConfiguration()
        invalid.selectedProfileID = "missing"
        #expect(throws: BackendStorageError.self) { try store.importLegacy(invalid, uid: 501) }
        #expect(try !store.load(uid: 501).importedLegacy)
        invalid = BackendConfiguration(profiles: [.init(id: "bad", name: "Bad", curve: .init(startTemp: .nan))], selectedProfileID: "bad")
        #expect(throws: BackendStorageError.self) { try store.importLegacy(invalid, uid: 501) }
        #expect(try store.importLegacy(BackendConfiguration(), uid: 501).importedLegacy)
    }
    @Test("Valid state-specific root calibration takes precedence over user imports")
    func rootCalibrationPrecedence() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = root.appendingPathComponent("calibration_lid_open.json")
        try JSONEncoder().encode(calibration(lid: false, mode: "optimized")).write(to: legacy)
        let store = BackendCalibrationStore(directory: dir.appendingPathComponent("machine"), legacyRoot: root)
        try store.importLegacy([calibration(lid: false, mode: "quick"), calibration(lid: true)])
        #expect(try store.load(lidClosed: false)?.mode == "optimized")
        #expect(try store.load(lidClosed: true)?.mode == "standard")
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }
    @Test("Lid-ambiguous or mismatched root calibration never migrates")
    func ambiguousRootCalibration() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(calibration(lid: false))
        try data.write(to: root.appendingPathComponent("calibration.json"))
        try data.write(to: root.appendingPathComponent("calibration_lid_closed.json"))
        let store = BackendCalibrationStore(directory: dir.appendingPathComponent("machine"), legacyRoot: root)
        #expect(try store.load(lidClosed: true) == nil)
        #expect(try store.load(lidClosed: false) == nil)
    }
    @Test("An explicit reset tombstone survives restart and blocks resurrection from every import")
    func resetTombstone() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(calibration(lid: false)).write(to: root.appendingPathComponent("calibration_lid_open.json"))
        let machine = dir.appendingPathComponent("machine")
        let store = BackendCalibrationStore(directory: machine, legacyRoot: root)
        try store.reset()
        let reopened = BackendCalibrationStore(directory: machine, legacyRoot: root)
        try reopened.importLegacy([calibration(lid: false), calibration(lid: true)])
        #expect(try reopened.load(lidClosed: false) == nil)
        #expect(try reopened.load(lidClosed: true) == nil)
        // A new completed job is still allowed after reset.
        try reopened.save(calibration(lid: false, mode: "optimized"))
        #expect(try reopened.load(lidClosed: false)?.mode == "optimized")
    }
    @Test("Corrupt authoritative storage fails closed instead of silently replacing values")
    func corruptStorage() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let userDir = dir.appendingPathComponent("501")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: userDir.appendingPathComponent("configuration.json"))
        let store = BackendConfigurationStore(directory: dir)
        #expect(throws: DecodingError.self) { try store.load(uid: 501) }
    }
    @Test("Automatic recovery epochs survive restart, edits, and legacy import")
    func epochOwnership() throws {
        let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = BackendConfigurationStore(directory: dir)
        let revoked = try store.invalidateAutomaticRecovery(uid: 501)
        #expect(revoked.recoveryEpoch != nil)
        var edit = revoked
        edit.recoveryEpoch = nil
        edit.rulesEnabled = false
        let updated = try store.update(edit, uid: 501)
        #expect(updated.recoveryEpoch == revoked.recoveryEpoch)
        let imported = try store.importLegacy(BackendConfiguration(), uid: 501)
        #expect(imported.recoveryEpoch == revoked.recoveryEpoch)
        #expect(try BackendConfigurationStore(directory: dir).load(uid: 501).recoveryEpoch == revoked.recoveryEpoch)
    }

}
