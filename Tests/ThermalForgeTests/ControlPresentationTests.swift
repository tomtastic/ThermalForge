import Testing
import ThermalForgeCore
@testable import ThermalForgeApp

@Suite("Menu control presentation")
struct ControlPresentationTests {
    @Test("An in-flight fan write does not appear idle under verified Apple control")
    func applyingControl() {
        let state = BackendSnapshot(generation: "one", requestedIntent: .profile("smart"),
            acknowledgedControl: .unknown, owner: .init(generation: "one"), ownerKind: .gui)
        let menu = ControlPresentation(snapshot: state, profiles: FanProfile.builtIn)
        #expect(menu.selectedProfileID == "smart")
        #expect(menu.ownershipDescription == "Applying fan control…")
        #expect(!menu.paused)
    }

    @Test("An armed but idle Smart policy stays selected while Apple owns the fans")
    func armedSmartAtIdle() {
        let state = BackendSnapshot(generation: "one", requestedIntent: .profile("smart"),
            acknowledgedControl: .apple, owner: .init(generation: "one"), ownerKind: .gui,
            restoration: .verified, activeProfileID: "smart")
        let menu = ControlPresentation(snapshot: state, profiles: FanProfile.builtIn)
        #expect(menu.selectedProfileID == "smart")
        #expect(menu.ownershipDescription == "Smart · idle, Apple fan control")
        #expect(!menu.paused)
    }

    @Test("Explicit Apple control cannot leave a remembered Smart profile selected")
    func explicitAppleControl() {
        let state = BackendSnapshot(generation: "one", acknowledgedControl: .apple,
            restoration: .verified, lastSessionEndReason: .explicitAuto, activeProfileID: "smart")
        let menu = ControlPresentation(snapshot: state, profiles: FanProfile.builtIn)
        #expect(menu.selectedProfileID == "silent")
        #expect(menu.ownershipDescription == "Apple fan control")
    }

    @Test("A failed Smart session clears selection so clicking Smart can retry it")
    func pausedProfileCanBeSelectedAgain() {
        let state = BackendSnapshot(generation: "one", acknowledgedControl: .apple,
            restoration: .verified, controlError: "SMC write failed: F0Tg",
            lastSessionEndReason: .backendFailure, activeProfileID: "smart")
        let menu = ControlPresentation(snapshot: state, profiles: FanProfile.builtIn)
        #expect(menu.selectedProfileID == nil)
        #expect(menu.paused)
        #expect(menu.ownershipDescription == "Control paused · Apple fan control")
    }

    @Test("Observing a CLI session never selects a GUI profile")
    func observingCLI() {
        let state = BackendSnapshot(generation: "one", requestedIntent: .maximum,
            acknowledgedControl: .maximum, owner: .init(generation: "one"), ownerKind: .cli)
        let menu = ControlPresentation(snapshot: state, profiles: FanProfile.builtIn)
        #expect(menu.selectedProfileID == nil)
        #expect(menu.monitorState == .active(profileName: "CLI"))
        #expect(menu.ownershipDescription.contains("CLI session (observing)"))
    }

    @Test("Unverified restoration cannot select Apple default as an acknowledged state")
    func unverifiedRestoration() {
        let state = BackendSnapshot(generation: "one", restoration: .failed)
        let menu = ControlPresentation(snapshot: state, profiles: FanProfile.builtIn)
        #expect(menu.selectedProfileID == nil)
        #expect(menu.ownershipDescription == "Apple restoration unverified")
    }
}
