import Observation
import ServiceManagement
import SwiftUI
@preconcurrency import ThermalForgeCore

@MainActor
@Observable
final class AppState {
    static let client = BackendClient(kind: .gui)
    private static weak var current: AppState?
    var latestStatus: ThermalStatus?
    var activeProfile: FanProfile = .silent
    var profiles: [FanProfile] = FanProfile.builtIn
    var monitorState: MonitorState = .idle
    var calibrationState: CalibrationState = .none
    var calibrationMessage: String?
    var maxTemp: Float?
    var daemonAvailable = false
    var ownershipDescription = "Fan ownership unknown"
    var sensorDescription = "Sensors unavailable"
    var lastError: String?
    var useFahrenheit = UserDefaults.standard.bool(forKey: "useFahrenheit") {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }
    var launchAtLogin = false { didSet { updateLoginItem() } }
    var rulesEnabled = true {
        didSet {
            guard !applyingConfiguration else { return }
            let enabled = rulesEnabled
            editConfiguration { $0.rulesEnabled = enabled }
        }
    }
    var rules: [ThermalRule] = []
    var quickRuleTriggerTempC: Double {
        get { Double(quickTemperatureRule?.condition.valueCelsius ?? 55) }
        set { updateQuickTemperatureRule { $0.condition = ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: Float(newValue)) } }
    }
    var quickRuleReleaseTempC: Double {
        get { Double(quickTemperatureRule?.untilTempBelowC ?? 50) }
        set { updateQuickTemperatureRule { $0.untilTempBelowC = Float(newValue) } }
    }
    var quickRuleFanPercent: Double {
        get {
            guard case let .setFanPercent(percent) = quickTemperatureRule?.action else { return 100 }
            return Double(percent * 100)
        }
        set { updateQuickTemperatureRule { $0.action = .setFanPercent(Float(newValue / 100)) } }
    }
    var hasQuickTemperatureRule: Bool { quickTemperatureRule != nil }
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var configuration = BackendConfiguration()
    @ObservationIgnored private var applyingConfiguration = false
    @ObservationIgnored private var menuOpen = false
    @ObservationIgnored private var lastStatus: ThermalStatus?

    init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        let legacy = LegacyConfigurationReader.read()
        ThermalLogger.cleanExpired()
        pollingTask = Task { [weak self] in
            var initialized = false
            var startupProfile: String?
            while !Task.isCancelled {
                do {
                    var importError: String?
                    if !initialized {
                        do {
                            let configuration = try await Self.client.importLegacy(legacy)
                            self?.applyConfiguration(configuration)
                            startupProfile = configuration.selectedProfileID
                            initialized = true
                        } catch let error as DaemonError {
                            // A busy calibration can postpone migration while status
                            // remains available to this observing application.
                            if case .commandFailed = error { importError = String(describing: error) }
                            else { throw error }
                        }
                    }
                    if Task.isCancelled { break }
                    var state = try await Self.client.maintain()
                    if Task.isCancelled { break }
                    if let profile = startupProfile {
                        // Wait for startup reconciliation; joining another owner or an
                        // explicit Apple restoration leaves the app observing.
                        if state.owner != nil || state.lastSessionEndReason == .explicitAuto || state.lastSessionEndReason == .takeover {
                            startupProfile = nil
                        } else if state.restoration == .verified {
                            startupProfile = nil
                            state = try await Self.client.acquire(.profile(profile))
                        }
                    }
                    self?.publish(state)
                    if let importError { self?.lastError = importError }
                    if self?.configuration.revision != state.configurationRevision {
                        let configuration = try await Self.client.configuration()
                        self?.applyConfiguration(configuration)
                    }
                } catch {
                    self?.daemonAvailable = false
                    self?.ownershipDescription = "Fan ownership unknown"
                    self?.monitorState = .idle
                    self?.lastError = String(describing: error)
                    let status = await Self.readLocalSensors()
                    self?.publishSensors(status, description: status == nil ? "Sensors unavailable" : "Live local sensors · fan ownership unknown")
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        Self.current = self
    }

    deinit { pollingTask?.cancel() }

    static func releaseForTermination() async throws {
        current?.pollingTask?.cancel()
        _ = try await client.release()
    }

    private func publish(_ state: BackendSnapshot) {
        daemonAvailable = true
        lastError = state.restorationErrors.isEmpty ? nil : state.restorationErrors.joined(separator: "; ")
        if let profile = profiles.first(where: { $0.id == state.activeProfileID }) { activeProfile = profile }
        switch state.acknowledgedControl {
        case .unknown: ownershipDescription = "Fan ownership unknown"; monitorState = .idle
        case .apple: ownershipDescription = "Apple fan control"; monitorState = .idle
        case let .manualRPM(rpm): ownershipDescription = "Backend control · \(rpm) RPM acknowledged"; monitorState = .active(profileName: activeProfile.name)
        case .maximum: ownershipDescription = "Backend control · maximum acknowledged"; monitorState = .active(profileName: activeProfile.name)
        }
        if state.restoration == .pending { ownershipDescription = "Restoring Apple control…" }
        if state.restoration == .failed { ownershipDescription = "Apple restoration unverified" }
        if state.ownerKind == .cli { ownershipDescription += " · CLI session (observing)" }
        calibrationState = state.calibrationLidClosed.map { CalibrationState(active: true, lidClosed: $0) } ?? .none
        calibrationMessage = state.calibration?.message
        let fresh = state.sampledAt.map { BackendTiming.monotonicNow - $0 < BackendTiming.clientLease } ?? false
        publishSensors(fresh ? state.sensors : nil, description: fresh ? "Live backend sensors" : "Backend sensors stale or unavailable")
    }

    private func publishSensors(_ status: ThermalStatus?, description: String) {
        lastStatus = status
        sensorDescription = description
        if menuOpen { latestStatus = status }
        maxTemp = status.flatMap { TemperatureSummary($0.temperatures).controlPeak?.rounded() }
    }

    private static func readLocalSensors() async -> ThermalStatus? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: try? FanControl().status())
            }
        }
    }

    private func applyConfiguration(_ value: BackendConfiguration) {
        applyingConfiguration = true
        configuration = value
        profiles = value.profiles
        rules = value.rules
        rulesEnabled = value.rulesEnabled
        if let selected = profiles.first(where: { $0.id == value.selectedProfileID }) { activeProfile = selected }
        applyingConfiguration = false
    }

    private func editConfiguration(_ mutation: @escaping (inout BackendConfiguration) -> Void) {
        var proposed = configuration
        mutation(&proposed)
        Task {
            do { applyConfiguration(try await Self.client.updateConfiguration(proposed)) }
            catch {
                lastError = String(describing: error)
                if let latest = try? await Self.client.configuration() { applyConfiguration(latest) }
            }
        }
    }

    func menuDidOpen() { menuOpen = true; latestStatus = lastStatus }
    func menuDidClose() { menuOpen = false }
    func setSmart() { selectProfile(.smart) }
    func resetAuto() {
        Task {
            do { publish(try await Self.client.restoreApple()) }
            catch { lastError = String(describing: error) }
        }
    }
    func selectProfile(_ profile: FanProfile) {
        Task {
            do {
                publish(try await Self.client.acquire(.profile(profile.id)))
                applyConfiguration(try await Self.client.configuration())
            } catch { lastError = String(describing: error) }
        }
    }
    func addQuickRule() { updateQuickTemperatureRule { $0.enabled = true } }
    func removeRule(_ id: String) { editConfiguration { $0.rules.removeAll { $0.id == id } } }
    func toggleRule(_ id: String, enabled: Bool) {
        editConfiguration { value in
            if let index = value.rules.firstIndex(where: { $0.id == id }) { value.rules[index].enabled = enabled }
        }
    }
    func moveRule(_ id: String, toPriority priority: Int) {
        editConfiguration { value in
            if let index = value.rules.firstIndex(where: { $0.id == id }) { value.rules[index].priority = priority }
        }
    }
    private func updateLoginItem() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { lastError = String(describing: error) }
    }

    func installDaemon() {
        // Locate the bundled CLI binary
        guard let bundledURL = Bundle.main.url(forResource: "thermalforge", withExtension: nil) else {
            TFLogger.shared.error("Install failed: bundled CLI not found")
            return
        }

        // Run the bundled installer directly. Copying it over an existing,
        // previously executed binary before launch can make taskgated reject
        // the new image as having an invalid code signature.
        let script = DaemonInstallationCommand.administratorAppleScript(
            executablePath: bundledURL.path
        )
        // Run the blocking Process on a background queue to avoid
        // "semaphore.wait unavailable from async contexts" warning.
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            let errorPipe = Pipe()
            task.standardError = errorPipe
            let semaphore = DispatchSemaphore(value: 0)
            task.terminationHandler = { _ in semaphore.signal() }
            do {
                try task.run()
                semaphore.wait()

                if task.terminationStatus == 0 {
                    TFLogger.shared.info("Daemon installed successfully")
                    DispatchQueue.main.async {
                        self.lastError = nil
                    }
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let detail = String(decoding: errorData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let suffix = detail.isEmpty ? "" : ": \(detail)"
                    TFLogger.shared.error("Install failed with code \(task.terminationStatus)\(suffix)")
                }
            } catch {
                TFLogger.shared.error("Install failed: \(error)")
            }
        }
    }

    private var quickTemperatureRule: ThermalRule? {
        rules.first(where: { $0.id == LegacyTemperatureRuleMigration.ruleID })
    }

    private func updateQuickTemperatureRule(_ update: (inout ThermalRule) -> Void) {
        var rule = quickTemperatureRule ?? Self.defaultQuickTemperatureRule
        update(&rule)

        let trigger = min(max(rule.condition.valueCelsius, 40), 95)
        let release = min(max(rule.untilTempBelowC ?? 50, 35), trigger - 1)
        let fanPercent: Float
        if case let .setFanPercent(value) = rule.action {
            fanPercent = min(max(value, 0.2), 1)
        } else {
            fanPercent = 1
        }
        rule.condition = ThermalRuleCondition(
            metric: .maxTemp,
            comparator: .greaterThanOrEqual,
            valueCelsius: trigger
        )
        rule.action = .setFanPercent(fanPercent)
        rule.untilTempBelowC = release
        rule.name = "IF temp ≥ \(Int(trigger))°C THEN \(Int(fanPercent * 100))% until ≤ \(Int(release))°C"

        let updated = rule
        editConfiguration { configuration in
            configuration.rules.removeAll { $0.id == updated.id }
            configuration.rules.append(updated)
        }
    }

    private static let defaultQuickTemperatureRule = ThermalRule(
        id: LegacyTemperatureRuleMigration.ruleID,
        name: "IF temp ≥ 55°C THEN 100% until ≤ 50°C",
        enabled: true,
        priority: 1_000,
        condition: ThermalRuleCondition(
            metric: .maxTemp,
            comparator: .greaterThanOrEqual,
            valueCelsius: 55
        ),
        action: .setFanPercent(1),
        untilTempBelowC: 50
    )

}
