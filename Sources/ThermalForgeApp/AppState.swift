//
//  AppState.swift
//  ThermalForge
//
//  Observable bridge between ThermalMonitor and SwiftUI.
//

import Observation
import ServiceManagement
import SwiftUI
@preconcurrency import ThermalForgeCore

@MainActor
@Observable
final class AppState {
    var latestStatus: ThermalStatus?
    var activeProfile: FanProfile = .silent
    var monitorState: MonitorState = .idle
    var calibrationState: CalibrationState = .none
    var maxTemp: Float?

    var useFahrenheit: Bool = UserDefaults.standard.bool(forKey: "useFahrenheit") {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }

    var launchAtLogin: Bool = false {
        didSet { updateLoginItem() }
    }
    var customRuleEnabled: Bool = UserDefaults.standard.bool(forKey: "customRuleEnabled") {
        didSet { syncTemperatureRuleFromSettings() }
    }
    var customRuleTriggerTempC: Double = {
        let value = UserDefaults.standard.object(forKey: "customRuleTriggerTempC") as? Double
        return value ?? 55
    }() {
        didSet { syncTemperatureRuleFromSettings() }
    }
    var customRuleReleaseTempC: Double = {
        let value = UserDefaults.standard.object(forKey: "customRuleReleaseTempC") as? Double
        return value ?? 50
    }() {
        didSet { syncTemperatureRuleFromSettings() }
    }
    var customRuleFanPercent: Double = {
        let value = UserDefaults.standard.object(forKey: "customRuleFanPercent") as? Double
        return value ?? 100
    }() {
        didSet { syncTemperatureRuleFromSettings() }
    }

    var rulesEnabled: Bool = UserDefaults.standard.object(forKey: "rulesEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(rulesEnabled, forKey: "rulesEnabled")
            pushRulesToMonitor()
        }
    }

    var rules: [ThermalRule] = [] {
        didSet {
            persistRules()
            pushRulesToMonitor()
        }
    }

    @ObservationIgnored private var monitor: ThermalMonitor?
    @ObservationIgnored private let executor = PrivilegedExecutor()
    @ObservationIgnored private let daemonQueue = DispatchQueue(label: "com.thermalforge.app.daemon", qos: .utility)
    @ObservationIgnored private var heartbeatTimer: Timer?
    /// Whether the dropdown panel is currently shown. The panel's hosting view
    /// stays alive while hidden and re-renders on any observed change, so we
    /// only feed it the per-tick `latestStatus` while it's actually visible.
    /// Whether the privileged daemon is running. Without it, fan commands fail.
    var daemonAvailable: Bool = ThermalForgeDaemon.isRunning
    @ObservationIgnored private var menuOpen = false
    @ObservationIgnored private var lastStatus: ThermalStatus?
    @ObservationIgnored private var syncingRuleSettings = false
    @ObservationIgnored private var daemonCheckTimer: Timer?

    init() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)

        // Load all available profiles (built-in + custom)
        let allProfiles = FanProfile.loadAll()

        // Attempt to restore the last used profile ID from UserDefaults
        let lastProfileID = UserDefaults.standard.string(forKey: "lastProfileID")

        // Find the profile in the loaded list, or fallback to .silent if not found/invalid
        if let lastID = lastProfileID, let savedProfile = allProfiles.first(where: { $0.id == lastID }) {
            activeProfile = savedProfile
            TFLogger.shared.info("Restored profile: \(savedProfile.name)")
        } else {
            activeProfile = .silent
            if let lastProfileID {
                TFLogger.shared.info("Stored profile ID '\(lastProfileID)' was invalid. Falling back to .silent")
            }
        }

        runDaemonTask(
            action: { [executor] in try executor.execute(.resetAuto) },
            successMessage: "App launched — fans reset to auto",
            failureContext: "Startup reset failed"
        )

        // Clean expired logs.
        ThermalLogger.cleanExpired()

        do {
            try LegacyTemperatureRuleMigration.migrate()
        } catch {
            TFLogger.shared.error("Legacy temperature-rule migration failed: \(error)")
        }
        rules = RulePersistence.load()

        startMonitoring()
        // A restored fan-controlling profile can issue its first command without
        // passing through selectProfile(). Start its heartbeat immediately so
        // the daemon watchdog does not mistake the live app for an abandoned
        // controller and reset the fans every ten seconds.
        syncHeartbeat(for: activeProfile)

        // Periodically check if daemon became available or went away
        startDaemonCheck()
    }

    deinit {
        heartbeatTimer?.invalidate()
        daemonCheckTimer?.invalidate()
    }

    // MARK: - Heartbeat

    /// The daemon watchdog ignores heartbeats unless a manual fan command was
    /// sent, so hands-off (Silent) needs no heartbeat — running it there is a
    /// pure 5s wake on both processes for nothing. Run it only for fan-
    /// controlling profiles.
    private func syncHeartbeat(for profile: FanProfile) {
        if profile.requiresDaemonHeartbeat {
            startHeartbeat()
        } else {
            stopHeartbeat()
        }
    }

    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            // Off the main thread — a blocking daemon round-trip must never stall the UI.
            DispatchQueue.global(qos: .utility).async {
                _ = try? DaemonClient().send("heartbeat")
            }
        }
        timer.tolerance = 1.0 // let the OS coalesce the wakeup
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - Daemon Availability

    private func startDaemonCheck() {
        // Check immediately, then poll every 30s to detect if daemon starts/stops
        checkDaemonAvailability()
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in
                self.checkDaemonAvailability()
            }
        }
        timer.tolerance = 5
        daemonCheckTimer = timer
    }

    private func checkDaemonAvailability() {
        let wasAvailable = daemonAvailable
        daemonAvailable = ThermalForgeDaemon.isRunning
        if daemonAvailable != wasAvailable {
            if daemonAvailable {
                TFLogger.shared.info("Daemon became available")
            } else {
                TFLogger.shared.info("Daemon not running — fan control unavailable")
            }
        }
    }

    // MARK: - Install Daemon

    func installDaemon() {
        // Locate the bundled CLI binary
        guard let bundledURL = Bundle.main.url(forResource: "thermalforge", withExtension: nil) else {
            TFLogger.shared.error("Install failed: bundled CLI not found")
            return
        }

        let targetPath = "/usr/local/bin/thermalforge"

        // Use osascript to request elevation and copy the binary, then install the daemon
        let script = """
do shell script "cp '\(bundledURL.path)' '\(targetPath)' && chmod +x '\(targetPath)' && '\(targetPath)' install" with administrator privileges
"""
        // Run the blocking Process on a background queue to avoid
        // "semaphore.wait unavailable from async contexts" warning.
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            let semaphore = DispatchSemaphore(value: 0)
            task.terminationHandler = { _ in semaphore.signal() }
            do {
                try task.run()
                semaphore.wait()

                if task.terminationStatus == 0 {
                    TFLogger.shared.info("Daemon installed successfully")
                    DispatchQueue.main.async {
                        self.checkDaemonAvailability()
                    }
                } else {
                    TFLogger.shared.error("Install failed with code \(task.terminationStatus)")
                }
            } catch {
                TFLogger.shared.error("Install failed: \(error)")
            }
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard let fc = try? FanControl() else { return }

        let ruleEngine = RuleEngine(rules: rules, isEnabled: rulesEnabled)
        let controlService = ControlService(ruleEngine: ruleEngine)
        let monitor = ThermalMonitor(fanControl: fc, profile: activeProfile, controlService: controlService)

        monitor.onUpdate = { [weak self] status, profile, state, calState in
            Task { @MainActor in
                guard let self else { return }
                self.lastStatus = status
                // Publish-on-change, AND only while the panel is visible. The
                // dropdown's hosting view stays alive when hidden and re-renders
                // on every latestStatus change — so feeding it per-tick updates
                // while closed drives full SwiftUI layout for nothing.
                if self.menuOpen, self.latestStatus != status { self.latestStatus = status }
                if self.activeProfile != profile { self.activeProfile = profile }
                if self.monitorState != state { self.monitorState = state }
                if self.calibrationState != calState { self.calibrationState = calState }
                // Peak across all displayed CPU and GPU sensors for the menu bar.
                // Quantize to whole degrees: the label shows an integer, so a
                // jittering 0.1° fraction would otherwise force a relayout (CA
                // transaction) every update for a number that never changes.
                let newMax = TemperatureSummary(status.temperatures)
                    .controlPeak
                    .map { $0.rounded() }
                if self.maxTemp != newMax { self.maxTemp = newMax }
            }
        }

        // Fan commands run off the main thread, coalesced. Each daemon
        // round-trip can exceed 0.5s; routing this
        // through the main actor (as before) starved the UI run loop and froze
        // the app on profile switch.
        let executor = self.executor
        monitor.onFanCommand = { command in
            executor.submit(command)
        }

        monitor.start()
        self.monitor = monitor
        syncTemperatureRuleFromSettings()
    }

    private func pushRulesToMonitor() {
        monitor?.updateRules(rules, enabled: rulesEnabled)
    }

    private func persistRules() {
        do {
            try RulePersistence.save(rules)
        } catch {
            TFLogger.shared.error("Failed to persist rules: \(error)")
        }
    }

    // MARK: - Menu visibility

    /// Called when the dropdown panel becomes visible: resume live updates and
    /// push the latest snapshot immediately so it isn't stale on open.
    func menuDidOpen() {
        menuOpen = true
        if let status = lastStatus, latestStatus != status { latestStatus = status }
    }

    /// Called when the panel is dismissed: stop feeding the hidden hosting view.
    func menuDidClose() {
        menuOpen = false
    }

    // MARK: - Actions

    func setSmart() {
        selectProfile(.smart)
    }

    func resetAuto() {
        selectProfile(.silent)
        runDaemonTask(
            action: { [executor] in try executor.execute(.resetAuto) },
            successMessage: "Reset to Default (Silent (Apple Default))",
            failureContext: "Reset to Default failed"
        )
    }

    func selectProfile(_ profile: FanProfile) {
        activeProfile = profile
        monitor?.switchProfile(profile)
        syncHeartbeat(for: profile)
        TFLogger.shared.profile("Selected: \(profile.name)")

        // Persist the selection to UserDefaults
        UserDefaults.standard.set(profile.id, forKey: "lastProfileID")

        // All profiles use proportional curves — tick() handles fan engagement.
        if profile.curve.handsOff || profile.id == "silent" {
            runDaemonTask(
                action: { [executor] in try executor.execute(.resetAuto) },
                failureContext: "Profile \(profile.name) failed"
            )
        }
    }

    func addQuickRule() {
        let rule = ThermalRule(
            name: "IF temp ≥ 55°C THEN 100% until ≤ 65°C",
            enabled: true,
            priority: 900,
            condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: 55),
            action: .setMax,
            untilTempBelowC: 65
        )
        rules.append(rule)
    }

    func removeRule(_ id: String) {
        rules.removeAll(where: { $0.id == id })
    }

    func toggleRule(_ id: String, enabled: Bool) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].enabled = enabled
    }

    func moveRule(_ id: String, toPriority priority: Int) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].priority = priority
    }

    // MARK: - Launch at Login

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            TFLogger.shared.error("Launch at login toggle failed: \(error)")
            launchAtLogin = !launchAtLogin
        }
    }

    // MARK: - Custom IF/THEN Rule

    private func syncTemperatureRuleFromSettings() {
        guard !syncingRuleSettings else { return }
        syncingRuleSettings = true
        defer { syncingRuleSettings = false }

        customRuleTriggerTempC = min(max(customRuleTriggerTempC, 40), 95)
        customRuleReleaseTempC = min(max(customRuleReleaseTempC, 35), customRuleTriggerTempC - 1)
        customRuleFanPercent = min(max(customRuleFanPercent, 20), 100)

        UserDefaults.standard.set(customRuleEnabled, forKey: "customRuleEnabled")
        UserDefaults.standard.set(customRuleTriggerTempC, forKey: "customRuleTriggerTempC")
        UserDefaults.standard.set(customRuleReleaseTempC, forKey: "customRuleReleaseTempC")
        UserDefaults.standard.set(customRuleFanPercent, forKey: "customRuleFanPercent")

        let rule: TemperatureRule? = customRuleEnabled
            ? TemperatureRule(
                triggerTempC: Float(customRuleTriggerTempC),
                releaseTempC: Float(customRuleReleaseTempC),
                fanPercent: Float(customRuleFanPercent / 100)
            )
            : nil
        monitor?.setTemperatureRule(rule)
    }

    // MARK: - Daemon Calls

    private func runDaemonTask(
        action: @escaping () throws -> Void,
        successMessage: String? = nil,
        failureContext: String
    ) {
        daemonQueue.async {
            do {
                try action()
                if let successMessage {
                    TFLogger.shared.info(successMessage)
                }
            } catch {
                TFLogger.shared.error("\(failureContext): \(error)")
            }
        }
    }
}
