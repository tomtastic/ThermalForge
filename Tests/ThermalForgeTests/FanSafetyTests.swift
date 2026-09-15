import Foundation
import IOKit
import Testing
@testable import ThermalForgeCore

private final class SafetySMC: SMCReading {
    var table: [String: [UInt8]] = [:]
    var unreadable: Set<String> = []
    var unavailable: Set<String> = []
    var rejectedWrites: Set<String> = []
    var ignoredWrites: Set<String> = []
    var targetWriteRestoresManual = false
    var targetWriteRestoresAuto = false
    var onRead: ((String) -> Void)?
    var journal: [String] = []
    init(uppercase: Bool = false, ftst: Bool = false, fans: Int = 2) {
        table["FNum"] = [UInt8(fans)]
        if ftst { table["Ftst"] = [1] }
        for index in 0..<fans {
            table[uppercase ? "F\(index)Md" : "F\(index)md"] = [1]
            table["F\(index)Mn"] = floatToSMCBytes(2000)
            table["F\(index)Mx"] = floatToSMCBytes(7000)
            table["F\(index)Ac"] = floatToSMCBytes(3000)
            table["F\(index)Tg"] = floatToSMCBytes(3000)
        }
    }
    func keyAvailability(_ key: String) -> SMCKeyAvailability {
        if unavailable.contains(key) { return .unknown }
        return table[key].map { .present(size: UInt32($0.count)) } ?? .absent
    }
    func readKey(_ key: String) -> (success: Bool, bytes: [UInt8], size: UInt32) {
        onRead?(key)
        journal.append("read:\(key)")
        guard !unreadable.contains(key), let bytes = table[key] else { return (false, [], 0) }
        return (true, bytes, UInt32(bytes.count))
    }
    func writeKey(_ key: String, bytes: [UInt8]) -> Bool {
        journal.append("write:\(key):\(bytes)")
        guard table[key] != nil, !rejectedWrites.contains(key) else { return false }
        if !ignoredWrites.contains(key) { table[key] = bytes }
        if targetWriteRestoresManual, key.hasSuffix("Tg") {
            let modeKey = String(key.prefix(2)) + "md"
            table[modeKey] = [1]
        }
        if targetWriteRestoresAuto, key.hasSuffix("Tg") { table[String(key.prefix(2)) + "md"] = [0] }
        return true
    }
    func getKeyInfo(_ key: String) -> (size: UInt32, type: String)? {
        table[key].map { (UInt32($0.count), $0.count == 1 ? "ui8 " : "flt ") }
    }
    func getKeyCount() -> UInt32 { UInt32(table.count) }
    func getKeyAtIndex(_ index: UInt32) -> String? { nil }
}

@Suite("Verified SMC safety")
struct FanSafetyTests {
    @Test("A temporarily unreadable CPU is discovered even when another sensor works")
    func temporarySensorLoss() throws {
        let smc = SafetySMC()
        smc.table["Tp01"] = floatToSMCBytes(100)
        smc.table["Tg0f"] = floatToSMCBytes(55)
        smc.unreadable.insert("Tp01")
        smc.unavailable.insert("Tp01")
        var time: TimeInterval = 0
        let fan = FanControl(smc: smc, wait: { _ in }, now: { time })
        #expect(try fan.status().temperatures["Tp01"] == nil)
        smc.unreadable = []; smc.unavailable = []
        time = 2
        #expect(try fan.status().temperatures["Tp01"] == 100)
        smc.table["Tp01"] = [0, 0, 0, 0, 0, 0, 0, 0]
        #expect(try fan.status().temperatures["Tp01"] == nil)
    }

    @Test("Oversized firmware RPM values cannot trap integer conversion or authorize control")
    func oversizedRPM() throws {
        let smc = SafetySMC()
        smc.table["F0Ac"] = floatToSMCBytes(.greatestFiniteMagnitude)
        smc.table["F0Mx"] = floatToSMCBytes(.greatestFiniteMagnitude)
        let fan = FanControl(smc: smc)
        #expect(try fan.status().fans[0].actualRPM == 0)
        #expect(throws: ThermalForgeError.self) { try fan.setMax() }
        #expect(!smc.journal.contains { $0.hasPrefix("write:") })
    }

    @Test("Manual target acknowledgement also requires the fan to remain manual")
    func manualOwnershipReadback() {
        let smc = SafetySMC()
        smc.targetWriteRestoresAuto = true
        #expect(throws: ThermalForgeError.self) { try FanControl(smc: smc).setMax() }
    }

    @Test("Cancellation during mode discovery prevents the diagnostic override write")
    func cancellationDuringDiscovery() {
        let smc = SafetySMC(ftst: true)
        smc.table["F0md"] = [0]
        let token = CancellationToken()
        smc.onRead = { if $0 == "F0md" { token.cancel() } }
        #expect(throws: ThermalForgeError.self) { try FanControl(smc: smc).setMax(cancellation: token) }
        #expect(!smc.journal.contains { $0.hasPrefix("write:") })
    }

    @Test("Unreadable mode is unknown, never reported as Apple auto")
    func unknownMode() throws {
        let smc = SafetySMC()
        smc.unreadable.insert("F0md")
        let fan = FanControl(smc: smc)
        #expect(try fan.fanInfo(0).mode == "unknown")
        #expect(!fan.restoreApple().verified)
        #expect(smc.table["F0md"] == [0]) // attempt despite unreadable value
    }

    @Test("Unsupported fan modes prevent manual writes")
    func unsupportedMode() {
        let smc = SafetySMC()
        smc.table["F0md"] = [2]
        #expect(throws: ThermalForgeError.self) { try FanControl(smc: smc).setAllFans(rpm: 3500) }
        #expect(!smc.journal.contains { $0.hasPrefix("write:") })
    }

    @Test("Both hardware mode variants restore multiple fans and verify Ftst")
    func modeVariants() {
        for uppercase in [false, true] {
            for ftst in [false, true] {
                let smc = SafetySMC(uppercase: uppercase, ftst: ftst)
                let fan = FanControl(smc: smc)
                #expect(fan.restoreApple().verified)
                for index in 0..<2 {
                    #expect(smc.table[uppercase ? "F\(index)Md" : "F\(index)md"] == [0])
                    #expect(smc.table["F\(index)Tg"] == floatToSMCBytes(0))
                }
                if ftst { #expect(smc.table["Ftst"] == [0]) }
            }
        }
    }

    @Test("One fan failure does not prevent other fans or diagnostic override restoration")
    func partialRestore() {
        let smc = SafetySMC(uppercase: true, ftst: true)
        smc.rejectedWrites.insert("F0Md")
        let fan = FanControl(smc: smc)
        let result = fan.restoreApple()
        #expect(!result.verified)
        #expect(smc.table["F0Tg"] == floatToSMCBytes(3000))
        #expect(smc.table["F1Md"] == [0])
        #expect(smc.table["F1Tg"] == floatToSMCBytes(0))
        #expect(smc.table["Ftst"] == [0])
        smc.rejectedWrites = []
        #expect(fan.restoreApple().verified)
    }

    @Test("Unreadable fan count still attempts independent Ftst clear")
    func countFailureStillClearsOverride() {
        let smc = SafetySMC(ftst: true)
        smc.unreadable.insert("FNum")
        #expect(!FanControl(smc: smc).restoreApple().verified)
        #expect(smc.table["Ftst"] == [0])
    }

    @Test("Unreadable Ftst capability blocks control and cannot claim successful restoration")
    func unknownCapability() {
        let smc = SafetySMC()
        smc.unavailable.insert("Ftst")
        let fan = FanControl(smc: smc)
        #expect(throws: ThermalForgeError.self) { try fan.setAllFans(rpm: 3500) }
        #expect(!fan.restoreApple().verified)
        #expect(!smc.journal.contains { $0.hasPrefix("write:Ftst") })
    }

    @Test("Readable Ftst metadata with unreadable value keeps handback unverified")
    func unreadableOverride() {
        let smc = SafetySMC(ftst: true)
        smc.unreadable.insert("Ftst")
        let result = FanControl(smc: smc).restoreApple()
        #expect(!result.verified)
        #expect(result.errors.contains("Ftst restoration unverified"))
    }

    @Test("Successful transport without observed mode transition cannot clear the stale target")
    func ignoredModeWrite() {
        let smc = SafetySMC()
        smc.ignoredWrites.insert("F0md")
        #expect(!FanControl(smc: smc).restoreApple().verified)
        #expect(smc.table["F0Tg"] == floatToSMCBytes(3000))
    }

    @Test("Final ownership is reverified after target-clearing writes")
    func finalOwnershipVerification() {
        let smc = SafetySMC()
        smc.targetWriteRestoresManual = true
        let result = FanControl(smc: smc).restoreApple()
        #expect(!result.verified)
        #expect(result.errors.contains { $0.contains("final ownership unverified") })
    }

    @Test("Targets are cleared only after the corresponding mode read confirms handback")
    func targetOrdering() throws {
        let smc = SafetySMC(ftst: true)
        #expect(FanControl(smc: smc).restoreApple().verified)
        for index in 0..<2 {
            let clear = try #require(smc.journal.firstIndex { $0.hasPrefix("write:F\(index)Tg") })
            let read = try #require(smc.journal[..<clear].lastIndex(of: "read:F\(index)md"))
            let mode = try #require(smc.journal.firstIndex { $0.hasPrefix("write:F\(index)md") })
            #expect(read > mode)
        }
    }

    @Test("Whole preparation shares an eight-second monotonic budget")
    func unlockBudget() {
        let smc = SafetySMC(ftst: true)
        smc.table["F0md"] = [0]
        smc.table["F1md"] = [0]
        smc.rejectedWrites.insert("F1md")
        var time: TimeInterval = 0
        let fan = FanControl(smc: smc, wait: { time += $0 }, now: { time })
        #expect(throws: ThermalForgeError.self) { try fan.setAllFans(rpm: 3500) }
        #expect(time >= 8 && time < 8.2)
        #expect(!smc.journal.contains { $0.hasPrefix("write:F0Tg") })
        #expect(fan.restoreApple().verified == false) // rejected mode persists, never premature success
    }

    @Test("Cancellation interrupts unlock preparation before target writes")
    func unlockCancellation() {
        let smc = SafetySMC(ftst: true)
        smc.table["F0md"] = [0]
        let token = CancellationToken()
        var waits = 0
        let fan = FanControl(smc: smc, wait: { _ in waits += 1; token.cancel() })
        #expect(throws: ThermalForgeError.self) { try fan.apply(.setRPM(3500), cancellation: token) }
        #expect(waits == 1)
        #expect(!smc.journal.contains { $0.hasPrefix("write:F0Tg") })
        #expect(fan.restoreApple().verified)
    }

    @Test("Missing maximum RPM does not enable manual mode using a guessed limit")
    func missingMaximum() {
        let smc = SafetySMC()
        smc.unreadable.insert("F1Mx")
        let fan = FanControl(smc: smc)
        #expect(throws: ThermalForgeError.self) { try fan.setMax() }
        #expect(!smc.journal.contains { $0.hasPrefix("write:") })
    }

    @Test("Unreadable minimum is unknown rather than a zero-RPM capability")
    func missingMinimum() {
        let smc = SafetySMC()
        smc.unreadable.insert("F0Mn")
        let fan = FanControl(smc: smc)
        #expect(throws: ThermalForgeError.self) { try fan.setAllFans(rpm: 1000) }
        #expect(!smc.journal.contains { $0.hasPrefix("write:") })
        smc.unreadable = []
        #expect(throws: ThermalForgeError.self) { try fan.setAllFans(rpm: 1000) }
    }

    @Test("Target write requires firmware acknowledgement and readable matching readback")
    func targetAcknowledgement() {
        let smc = SafetySMC()
        smc.ignoredWrites.insert("F0Tg")
        #expect(throws: ThermalForgeError.self) { try FanControl(smc: smc).setAllFans(rpm: 3500) }
    }

    @Test("Actual SMC read path rejects firmware rejection and truncated replies")
    func transportReadFailures() {
        for malformed in [false, true] {
            let smc = SMCConnection { input, output, size in
                output.keyInfo.dataSize = 1
                if input.data8 == SMCCommand.readBytes.rawValue {
                    if malformed { size -= 1 } else { output.result = 0x85 }
                }
                return kIOReturnSuccess
            }
            #expect(!smc.readKey("FNum").success)
        }
    }

    @Test("Metadata overflow and incorrectly sized writes never reach firmware write")
    func transportSizeValidation() {
        var writes = 0
        let oversized = SMCConnection { input, output, _ in
            output.keyInfo.dataSize = 33
            if input.data8 == SMCCommand.writeBytes.rawValue { writes += 1 }
            return kIOReturnSuccess
        }
        #expect(!oversized.readKey("FNum").success)
        #expect(!oversized.writeKey("FNum", bytes: [0]))
        let smc = SMCConnection { input, output, _ in
            output.keyInfo.dataSize = 1
            if input.data8 == SMCCommand.writeBytes.rawValue { writes += 1 }
            return kIOReturnSuccess
        }
        #expect(!smc.writeKey("FNum", bytes: [0, 0]))
        #expect(writes == 0)
    }

    @Test("Only explicit firmware key-not-found establishes absence")
    func transportCapabilityClassification() {
        let missing = SMCConnection { _, output, _ in output.result = 0x84; return kIOReturnSuccess }
        let unreadable = SMCConnection { _, output, _ in output.result = 0x85; return kIOReturnSuccess }
        let disconnected = SMCConnection { _, _, _ in kIOReturnError }
        #expect(missing.keyAvailability("Ftst") == .absent)
        #expect(unreadable.keyAvailability("Ftst") == .unknown)
        #expect(disconnected.keyAvailability("Ftst") == .unknown)
    }
}
