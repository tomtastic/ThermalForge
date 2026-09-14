import Testing
@testable import ThermalForgeCore

@Suite struct ServiceInstallationTests {
    @Test func replacementStartsRecoveryBeforeBackend() throws {
        var journal: [String] = []
        let coordinator = ServiceInstallationCoordinator(
            stopControllers: { journal.append("controllers-exited") },
            restore: { journal.append("verified-auto"); return .init(verified: true) },
            stopRecovery: { journal.append("stop-recovery") },
            stageFiles: { journal.append("stage-protected-files") },
            startRecovery: { journal.append("recovery-ready") },
            startBackend: { journal.append("backend-ready") })
        try coordinator.install()
        #expect(journal == ["controllers-exited", "verified-auto", "stop-recovery", "stage-protected-files", "recovery-ready", "backend-ready"])
    }

    @Test func failedUninstallRetainsRecoveryAndFiles() {
        var journal: [String] = []
        let coordinator = ServiceInstallationCoordinator(
            stopControllers: { journal.append("controllers-exited") },
            restore: { journal.append("failed-auto"); return .init(verified: false, errors: ["fan1 unreadable"]) },
            stopRecovery: { journal.append("stop-recovery") }, stageFiles: {}, startRecovery: {}, startBackend: {},
            removeFiles: { journal.append("remove") })
        #expect(throws: ServiceInstallationError.self) { try coordinator.uninstall() }
        #expect(journal == ["controllers-exited", "failed-auto"])
    }

    @Test func failedFencingPreventsEveryRestorationWrite() {
        enum Failure: Error { case alive }
        var wrote = false
        let coordinator = ServiceInstallationCoordinator(
            stopControllers: { throw Failure.alive }, restore: { wrote = true; return .init(verified: true) },
            stopRecovery: {}, stageFiles: {}, startRecovery: {}, startBackend: {})
        #expect(throws: Failure.alive) { try coordinator.install() }
        #expect(!wrote)
    }

    @Test func failedRecoveryStartNeverStartsBackend() {
        var backendStarted = false
        let coordinator = ServiceInstallationCoordinator(
            stopControllers: {}, restore: { .init(verified: true) }, stopRecovery: {}, stageFiles: {},
            startRecovery: { throw ServiceInstallationError.serviceUnavailable("recovery") },
            startBackend: { backendStarted = true })
        #expect(throws: ServiceInstallationError.self) { try coordinator.install() }
        #expect(!backendStarted)
    }
}
