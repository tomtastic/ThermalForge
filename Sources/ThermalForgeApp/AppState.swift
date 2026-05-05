//
//  AppState.swift
//  ThermalForge
//
//  Observable bridge between ThermalMonitor and SwiftUI.
//

import ServiceManagement
import SwiftUI
@preconcurrency import ThermalForgeCore

@MainActor
final class AppState: ObservableObject {
    @Published var latestStatus: ThermalStatus?
    @Published var activeProfile: FanProfile = .silent
    @Published var monitorState: MonitorState = .idle
    @Published var maxTemp: Float?
    @Published var useFahrenheit: Bool = UserDefaults.standard.bool(forKey: "useFahrenheit") {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }
    @Published var launchAtLogin: Bool = false {
        didSet { updateLoginItem() }
    }
    @Published var customRuleEnabled: Bool = UserDefaults.standard.bool(forKey: "customRuleEnabled") {
        didSet { syncTemperatureRuleFromSettings() }
    }
    @Published var customRuleTriggerTempC: Double = {
        let value = UserDefaults.standard.object(forKey: "customRuleTriggerTempC") as? Double
        return value ?? 55
    }() {
        didSet { syncTemperatureRuleFromSettings() }
    }
    @Published var customRuleReleaseTempC: Double = {
        let value = UserDefaults.standard.object(forKey: "customRuleReleaseTempC") as? Double
        return value ?? 50
    }() {
        didSet { syncTemperatureRuleFromSettings() }
    }
    @Published var customRuleFanPercent: Double = {
        let value = UserDefaults.standard.object(forKey: "customRuleFanPercent") as? Double
        return value ?? 100
    }() {
        didSet { syncTemperatureRuleFromSettings() }
    }

    private var monitor: ThermalMonitor?
    private let executor = PrivilegedExecutor()
    private var heartbeatTimer: Timer?
    private var syncingRuleSettings = false

    init() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)

        // Clean state: reset fans to auto on every launch.
        try? executor.execute(.resetAuto)
        TFLogger.shared.info("App launched — fans reset to auto")

        // Clean expired logs
        ThermalLogger.cleanExpired()

        startMonitoring()
        startHeartbeat()
    }

    deinit {
        heartbeatTimer?.invalidate()
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let client = DaemonClient()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            _ = try? client.send("heartbeat")
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard let fc = try? FanControl() else { return }

        let monitor = ThermalMonitor(fanControl: fc, profile: activeProfile)
        monitor.onUpdate = { [weak self] status, profile, state in
            Task { @MainActor [weak self] in
                self?.latestStatus = status
                self?.activeProfile = profile
                self?.monitorState = state
                // Max of only the displayed sensors
                // Peak across all CPU and GPU sensors for menu bar display
                let displayPrefixes = ["TC", "Tp", "TG", "Tg"]
                self?.maxTemp = status.temperatures
                    .filter { key, _ in displayPrefixes.contains(where: { key.hasPrefix($0) }) }
                    .values.max()
            }
        }
        monitor.onFanCommand = { [weak self] command in
            Task { @MainActor [weak self] in
                try self?.executor.execute(command)
            }
        }
        monitor.start()
        self.monitor = monitor
        syncTemperatureRuleFromSettings()
    }

    // MARK: - Actions

    func setSmart() {
        activeProfile = .smart
        monitor?.switchProfile(.smart)
        TFLogger.shared.profile("Smart activated")
    }

    func resetAuto() {
        do {
            try executor.execute(.resetAuto)
            activeProfile = .silent
            monitor?.switchProfile(.silent)
            TFLogger.shared.profile("Reset to Default (Silent (Apple Default))")
        } catch {
            TFLogger.shared.error("Reset to Default failed: \(error)")
        }
    }

    func selectProfile(_ profile: FanProfile) {
        activeProfile = profile
        monitor?.switchProfile(profile)
        TFLogger.shared.profile("Selected: \(profile.name)")

        // All profiles use proportional curves — tick() handles fan engagement.
        // Reset to auto on profile change so tick() starts from a clean state.
        do {
            if profile.curve.handsOff || profile.id == "smart" || profile.id == "silent" {
                try executor.execute(.resetAuto)
            }
            // Balanced/Performance/Max: tick() will ramp proportionally
            // based on current temperature after sustained trigger is met
        } catch {
            TFLogger.shared.error("Profile \(profile.name) failed: \(error)")
        }
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
            launchAtLogin = !launchAtLogin // revert toggle
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
}
