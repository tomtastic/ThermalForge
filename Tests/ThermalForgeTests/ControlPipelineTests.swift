import Foundation
import IOKit
import Testing
@testable import ThermalForgeCore

/// Inject at the IOKit boundary, below the real SMCConnection and FanControl.
/// Firmware values, target acceptance, target readback and ownership are independent.
/// These are adversarial models, not recordings or proof of physical firmware behavior.
private final class PipelineFirmware {
    enum Fault: String, CaseIterable {
        case transport, firmware, ignored, delayed, clamped, lostMode, unreadable, secondFan
    }
    var fault: Fault?
    var targetOffset: Float = 0
    var table: [String: [UInt8]] = [:]
    var delayed: [String: [UInt8]] = [:]
    var journal: [String] = []
    var permission = false
    var unsafeWrites: [String] = []
    var now: TimeInterval = 0

    init() {
        table["FNum"] = [2]
        // Deliberately encode independently of the production conversion helper.
        for index in 0..<2 {
            table["F\(index)md"] = [0]
            table["F\(index)Ac"] = bytes(2500)
            table["F\(index)Tg"] = bytes(2500)
            table["F\(index)Mn"] = bytes(2317)
            table["F\(index)Mx"] = bytes(7826)
        }
        table["Tp01"] = bytes(96) // exercises Smart's immediate thermal override
    }
    func bytes(_ value: Float) -> [UInt8] {
        let bits = value.bitPattern
        return (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
    }
    func rpm(_ bytes: [UInt8]) -> Float {
        Float(bitPattern: bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) })
    }
    func exchange(_ input: inout SMCParamStruct, _ output: inout SMCParamStruct, _ size: inout Int) -> kern_return_t {
        let key = String(bytes: (0..<4).map { UInt8(truncatingIfNeeded: input.key >> ((3 - $0) * 8)) }, encoding: .ascii)!
        guard let value = table[key] else { output.result = 0x84; return kIOReturnSuccess }
        if input.data8 == 9 { output.keyInfo.dataSize = UInt32(value.count); return kIOReturnSuccess }
        if input.data8 == 5 {
            if fault == .unreadable, key == "F0Tg", table["F0md"] == [1] {
                output.result = 0x85
            } else {
                withUnsafeMutableBytes(of: &output.bytes) { $0.copyBytes(from: value) }
            }
            return kIOReturnSuccess
        }
        guard input.data8 == 6 else { output.result = 0x85; return kIOReturnSuccess }
        let payload = withUnsafeBytes(of: input.bytes) { Array($0.prefix(Int(input.keyInfo.dataSize))) }
        let target = key.hasSuffix("Tg") && payload.count == 4 && rpm(payload) > 0
        let manual = key.hasSuffix("md") && payload == [1]
        journal.append("write:\(key):\(target ? "target" : String(describing: payload))")
        if (target || manual) && !permission { unsafeWrites.append(key) }
        if target {
            switch fault {
            case .transport: return kIOReturnNotPrivileged
            case .firmware: output.result = 0x85; return kIOReturnSuccess
            case .ignored: return kIOReturnSuccess
            case .delayed: delayed[key] = payload; return kIOReturnSuccess
            case .clamped: table[key] = bytes(4000); return kIOReturnSuccess
            case .lostMode: table[String(key.prefix(2)) + "md"] = [0]
            case .secondFan where key == "F1Tg": output.result = 0x85; return kIOReturnSuccess
            default: break
            }
            table[key] = bytes(rpm(payload) + targetOffset)
        } else { table[key] = payload }
        return kIOReturnSuccess
    }
    var automatic: Bool { table["F0md"] == [0] && table["F1md"] == [0] }
    var targetWrites: Int { journal.filter { $0.hasSuffix(":target") }.count }
    func completeDelayedWrites() {
        for (key, value) in delayed { table[key] = value }
        delayed = [:]
    }
}

private final class PipelineProtection: RecoveryProtecting {
    let firmware: PipelineFirmware
    init(_ firmware: PipelineFirmware) { self.firmware = firmware }
    func authorizeManual() throws { firmware.journal.append("authorize"); firmware.permission = true }
    func completedWork() throws { firmware.journal.append("progress") }
    func restored() throws {
        #expect(firmware.automatic, "Recovery permission must outlive manual ownership")
        firmware.journal.append("handback"); firmware.permission = false
    }
}

private final class PipelineHarness {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let firmware = PipelineFirmware()
    let backend: BackendCoordinator
    let client: BackendClient
    init() {
        let firmware = firmware
        let smc = SMCConnection(transport: firmware.exchange)
        let fan = FanControl(smc: smc, wait: { firmware.now += $0 }, now: { firmware.now })
        let backend = BackendCoordinator(sensorProvider: fan, actuator: fan, recovery: PipelineProtection(firmware),
            configurationStore: BackendConfigurationStore(directory: directory.appendingPathComponent("users")),
            calibrationStore: BackendCalibrationStore(directory: directory.appendingPathComponent("calibration"), legacyRoot: nil),
            lidStateProvider: FixedCalibrationLid(isLidClosed: false), generation: "pipeline",
            now: { firmware.now }, configurationUID: { $0.uid })
        self.backend = backend
        client = BackendClient(kind: .gui, transport: { data in
            let request = try JSONDecoder().decode(BackendRequest.self, from: data)
            let response = backend.handle(request, peer: .init(uid: 501, pid: 123))
            return try JSONEncoder().encode(response)
        })
        backend.start(interval: 3600)
        settle()
    }
    // One turn can queue the durable revocation that completes handback.
    func settle() { backend.drainWork(); backend.drainWork() }
    func tick() { backend.requestTick(); settle() }
    func close() {
        backend.shutdown(); settle()
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("SMC to GUI failure interactions")
struct ControlPipelineTests {
    @Test("Partial, rejected, altered and delayed writes pause the GUI after verified handback",
          arguments: PipelineFirmware.Fault.allCases)
    fileprivate func hardwareFailureDoesNotRetry(_ fault: PipelineFirmware.Fault) async throws {
        let h = PipelineHarness(); defer { h.close() }
        h.firmware.fault = fault
        _ = try await h.client.acquire(.profile("smart")); h.settle()
        var failed = try await h.client.maintain()
        let message = try #require(failed.controlError)
        #expect(message.contains(fault == .secondFan ? "F1Tg" : (fault == .lostMode ? "fan 0" : "F0Tg")))
        #expect(!message.contains("operation couldn’t be completed"))
        #expect(failed.acknowledgedControl == .apple)
        #expect(failed.restoration == .verified)
        #expect(h.firmware.automatic)
        #expect(await h.client.ownsControl == false)
        let writes = h.firmware.targetWrites
        // A late target completion can change a target, but must never reclaim
        // manual mode or authorize a renewed GUI session after handback.
        h.firmware.completeDelayedWrites()
        for _ in 0..<5 {
            h.tick()
            failed = try await h.client.maintain()
            #expect(failed.controlError == message)
            #expect(failed.acknowledgedControl == .apple)
        }
        #expect(h.firmware.targetWrites == writes)
        #expect(h.firmware.automatic)
        #expect(h.firmware.unsafeWrites.isEmpty)
        if fault == .secondFan { #expect(writes == 2) }
    }

    @Test("Accepted fractional target readback remains accepted on later sensing cycles",
          arguments: [Float(-0.75), Float(0.75)])
    func acknowledgementIsConsistentAcrossLayers(_ offset: Float) async throws {
        let h = PipelineHarness(); defer { h.close() }
        h.firmware.targetOffset = offset
        _ = try await h.client.acquire(.profile("smart")); h.settle()
        #expect(try await h.client.status().acknowledgedControl == .maximum)
        let writes = h.firmware.targetWrites
        let handbacks = h.firmware.journal.filter { $0 == "handback" }.count
        for _ in 0..<5 { h.tick(); _ = try await h.client.maintain() }
        #expect(h.firmware.targetWrites == writes, "A target accepted by FanControl must not cause a backend restore/rewrite loop")
        #expect(h.firmware.journal.filter { $0 == "handback" }.count == handbacks)
        #expect(await h.client.ownsControl)
        #expect(h.firmware.unsafeWrites.isEmpty)
    }

    @Test("Drift beyond the accepted tolerance still restores and reapplies the policy")
    func significantDriftIsReconciled() async throws {
        let h = PipelineHarness(); defer { h.close() }
        _ = try await h.client.acquire(.profile("smart")); h.settle()
        let writes = h.firmware.targetWrites
        h.firmware.table["F0Tg"] = h.firmware.bytes(7800)
        h.tick()
        #expect(h.firmware.targetWrites == writes + 2)
        #expect(h.firmware.rpm(h.firmware.table["F0Tg"]!) == 7826)
        #expect(try await h.client.status().acknowledgedControl == .maximum)
        #expect(h.firmware.unsafeWrites.isEmpty)
    }

    @Test("Sensor loss pauses the session even after readings return")
    func missingSensorsDoNotRestartTheGUI() async throws {
        let h = PipelineHarness(); defer { h.close() }
        _ = try await h.client.acquire(.profile("smart")); h.settle()
        h.firmware.table["Tp01"] = h.firmware.bytes(0)
        h.tick()
        let failed = try await h.client.maintain()
        #expect(failed.controlError?.contains("Fresh control sensors") == true)
        #expect(await h.client.ownsControl == false)
        let writes = h.firmware.targetWrites
        h.firmware.table["Tp01"] = h.firmware.bytes(96)
        for _ in 0..<3 { h.tick(); _ = try await h.client.maintain() }
        #expect(h.firmware.targetWrites == writes)
        #expect(h.firmware.automatic)
        _ = try await h.client.acquire(.profile("smart")); h.settle()
        #expect(try await h.client.status().acknowledgedControl == .maximum)
    }

    @Test("Unreadable policy data cannot cause repeated GUI acquisition and handback")
    func invalidCalibrationPausesControl() async throws {
        let h = PipelineHarness(); defer { h.close() }
        _ = try await h.client.acquire(.profile("smart")); h.settle()
        let path = h.directory.appendingPathComponent("calibration/machine-calibration-v2.json")
        let original = try Data(contentsOf: path)
        try Data(#"{"version":999,"reset":false,"checkedRoot":true}"#.utf8).write(to: path)
        h.tick()
        let failed = try await h.client.maintain()
        #expect(failed.controlError?.contains("Unsupported calibration storage version") == true)
        #expect(await h.client.ownsControl == false)
        let writes = h.firmware.targetWrites
        try original.write(to: path)
        for _ in 0..<3 { h.tick(); _ = try await h.client.maintain() }
        #expect(h.firmware.targetWrites == writes)
        #expect(h.firmware.automatic)
        _ = try await h.client.acquire(.profile("smart")); h.settle()
        #expect(try await h.client.status().acknowledgedControl == .maximum)
    }
}
