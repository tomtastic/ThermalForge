//
//  ThermalMonitor.swift
//  ThermalForge
//
//  Polling engine that reads temperatures and applies fan profiles.
//
//  Dual-cadence design:
//  - Thermal tick (adaptive): read temps, calculate curve, apply ramp governor, write fan speed
//  - Monitor tick (2s): process capture, anomaly detection, history logging
//

import Foundation

// MARK: - Fan Commands

public enum FanCommand: Equatable {
    case setMax
    case setRPM(Float)
    case resetAuto
}

// MARK: - Monitor State

public enum MonitorState: Equatable {
    case idle
    case active(profileName: String)
    case safetyOverride
}

// MARK: - Calibration State

/// Lightweight snapshot of calibration status reported to the UI.
public struct CalibrationState: Equatable {
    /// Whether a calibration curve is loaded for the current lid state.
    public let active: Bool
    /// True if the calibration was generated in clamshell (lid-closed) mode.
    public let lidClosed: Bool

    public static let none = CalibrationState(active: false, lidClosed: false)

    public init(active: Bool, lidClosed: Bool) {
        self.active = active
        self.lidClosed = lidClosed
    }
}

struct ElapsedCadence {
    static func isDue(lastRun: TimeInterval?, now: TimeInterval, interval: TimeInterval) -> Bool {
        guard let lastRun else { return true }
        return now - lastRun >= interval
    }
}

// MARK: - Thermal Monitor

public final class ThermalMonitor {
    private let sensorProvider: SensorProvider
    private let decisionEngine: RuntimeControlDecisionEngine
    private let lidStateProvider: any LidStateProvider
    private let now: () -> TimeInterval
    private let calibrationLoader: (Bool) -> CalibrationData?
    private let anomalyObserver: any ThermalAnomalyObserving
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.thermalforge.monitor", qos: .utility)

    public var activeProfile: FanProfile { decisionEngine.activeProfile }
    public var state: MonitorState { decisionEngine.state }
    public private(set) var latestStatus: ThermalStatus?

    // MARK: - Tick Timing

    /// Thermal tick interval in seconds. Fan control runs at this rate.
    /// Set from `start(interval:)` so the ramp / sustained-trigger math (which
    /// divides by it) always matches the real timer rate.
    private var tickInterval: Float = 1.0
    var currentTickInterval: Float { tickInterval }

    private static let fullStatusInterval: TimeInterval = 0.5
    private static let monitorInterval: TimeInterval = 2.0
    private var lastFullStatusAt: TimeInterval?
    private var lastMonitorTickAt: TimeInterval?

    // MARK: - Adaptive cadence

    /// Fast poll rate, from `start(interval:)`. Used while warm or active.
    private var activeInterval: Float = 1.0
    /// Slow poll rate while idle. Idle CPU is dominated by SMC reads, so fewer
    /// ticks ≈ proportionally less idle CPU.
    private static let idleInterval: Float = 2.0
    /// Hands-off profiles (Silent) never control fans — Apple's thermald does —
    /// so we only poll for the menu-bar readout and the 95°C safety backup.
    /// Both tolerate a much slower idle poll, which is the single biggest idle
    /// CPU lever for the default profile.
    private static let handsOffIdleInterval: Float = 5.0
    /// Stay fast at/above this temp regardless of profile, so the 95°C safety
    /// override reacts promptly. Apple Silicon idles ~45–60°C — overlapping the
    /// profile start temps — so a plain temp threshold can never relax. The real
    /// "can slow down" signal is state-based: fans off, idle, and below this
    /// profile's start temp (sustainedAboveCount == 0).
    private static let safetyWatchTemp: Float = 85.0
    /// Require this many consecutive idle ticks before relaxing, so hovering at a
    /// start temp doesn't flap the timer. Returns to fast immediately on activity.
    private static let idleConfirmTicks = 8
    private var consecutiveIdleTicks = 0

    // MARK: - Anomaly Detection

    private var isCalibrating = false

    /// Call this to suppress anomaly logging during calibration.
    public func setCalibrating(_ value: Bool) {
        queue.async { self.isCalibrating = value }
    }

    private var calibration: CalibrationData?

    /// Track which lid state the current calibration was loaded for,
    /// so we can reload when the lid state flips.
    private var calibrationLidClosed: Bool

    /// Snapshot of calibration status for the UI.
    private var calibrationState: CalibrationState {
        if let cal = calibration {
            return CalibrationState(active: true, lidClosed: cal.lidClosed)
        }
        return .none
    }

    /// How often (in seconds) to recheck lid state. Lid changes are rare —
    /// checking every 60s is plenty and avoids hardware queries on every tick.
    private let lidCheckInterval: Int = 60
    private var lastLidCheckTimestamp: UInt64 = 0

    /// Reload calibration data if the lid state has changed.
    /// Throttled to `lidCheckInterval` seconds to avoid frequent lid-state queries.
    private func syncCalibration() {
        let now = UInt64(now())
        guard now - lastLidCheckTimestamp >= lidCheckInterval else { return }
        lastLidCheckTimestamp = now
        let currentLidClosed = lidStateProvider.isLidClosed
        guard currentLidClosed != calibrationLidClosed else { return }

        TFLogger.shared.info("Lid state changed (clamshell: \(currentLidClosed)) — reloading calibration")
        calibrationLidClosed = currentLidClosed

        guard let data = calibrationLoader(currentLidClosed) else {
            calibration = nil
            TFLogger.shared.info("No calibration data for current lid state — using fallback curve")
            return
        }
        if let error = data.validationError {
            TFLogger.shared.error("Calibration data rejected on lid-state reload: \(error)")
            calibration = nil
            return
        }
        calibration = data
    }

    /// Called on the UI cadence, targeting 500ms but bounded by the thermal poll.
    public var onUpdate: ((ThermalStatus, FanProfile, MonitorState, CalibrationState) -> Void)?
    /// Called when a fan command needs to be executed (may require privilege).
    public var onFanCommand: ((FanCommand) throws -> Void)?

    public convenience init(
        sensorProvider: SensorProvider,
        profile: FanProfile = .silent,
        controlService: ControlService = ControlService(),
        lidStateProvider: any LidStateProvider = MacLidStateProvider()
    ) {
        self.init(
            sensorProvider: sensorProvider,
            profile: profile,
            controlService: controlService,
            lidStateProvider: lidStateProvider,
            now: {
                TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
            },
            calibrationLoader: { CalibrationData.load(forLidClosed: $0) },
            anomalyObserver: ThermalAnomalyObserver()
        )
    }

    init(
        sensorProvider: SensorProvider,
        profile: FanProfile,
        controlService: ControlService,
        lidStateProvider: any LidStateProvider,
        now: @escaping () -> TimeInterval,
        calibrationLoader: @escaping (Bool) -> CalibrationData?,
        anomalyObserver: any ThermalAnomalyObserving
    ) {
        self.sensorProvider = sensorProvider
        decisionEngine = RuntimeControlDecisionEngine(
            profile: profile,
            controlService: controlService
        )
        self.lidStateProvider = lidStateProvider
        self.now = now
        self.calibrationLoader = calibrationLoader
        self.anomalyObserver = anomalyObserver
        calibrationLidClosed = lidStateProvider.isLidClosed

        let loaded = calibrationLoader(calibrationLidClosed)
        if let error = loaded?.validationError {
            TFLogger.shared.error("Calibration data rejected: \(error)")
            calibration = nil
        } else {
            calibration = loaded
        }
    }

    public convenience init(
        fanControl: FanControl,
        profile: FanProfile = .silent,
        controlService: ControlService = ControlService(),
        lidStateProvider: any LidStateProvider = MacLidStateProvider()
    ) {
        self.init(
            sensorProvider: fanControl,
            profile: profile,
            controlService: controlService,
            lidStateProvider: lidStateProvider
        )
    }

    public func updateRules(_ rules: [ThermalRule], enabled: Bool) {
        queue.async { [self] in
            decisionEngine.replaceRules(rules, enabled: enabled)
        }
    }

    // MARK: - Lifecycle

    public func start(interval: TimeInterval = 1.0) {
        stop()

        activeInterval = Float(interval)
        tickInterval = activeInterval
        consecutiveIdleTicks = 0
        lastFullStatusAt = nil
        lastMonitorTickAt = nil

        let timer = DispatchSource.makeTimerSource(queue: queue)
        scheduleTimer(timer, interval: tickInterval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Stop polling and wait for any monitor callback already queued to finish.
    /// Callers can safely perform final fan cleanup after this returns.
    public func stopAndWait() {
        stop()
        queue.sync {}
    }

    /// (Re)schedule the repeating timer. Leeway lets the OS coalesce wakeups —
    /// a big idle-CPU win for a low-frequency poll; ±20% is invisible to fans.
    private func scheduleTimer(_ timer: DispatchSourceTimer, interval: Float) {
        timer.schedule(
            deadline: .now() + Double(interval),
            repeating: Double(interval),
            leeway: .milliseconds(Int(interval * 200))
        )
    }

    /// Adjust the poll rate to match thermal activity. Fast while warm/active so
    /// fan control and the 95°C override stay responsive; slow while cool & idle
    /// to keep idle CPU near zero. Reschedules the timer only on a real change.
    private func applyCadence(maxTemp: Float, fanChanged: Bool) {
        // Fast polling is only useful when something is *moving*: the fan speed
        // just changed (ramping), we're counting toward turning fans on, or
        // we're near the safety ceiling. Fans merely running at a STEADY speed
        // doesn't need 4–10 Hz — so a warm idle on Performance (fans holding at
        // minimum at ~56°C) relaxes to the slow rate instead of polling fast.
        let busy = fanChanged
            || decisionEngine.isEngaging
            || state == .safetyOverride
            || maxTemp >= Self.safetyWatchTemp

        if busy {
            consecutiveIdleTicks = 0
        } else if consecutiveIdleTicks < Self.idleConfirmTicks {
            consecutiveIdleTicks += 1
        }

        // handsOff profiles never adjust fans → slowest idle rate; fan-controlling
        // profiles holding steady use the medium rate so they still catch a rise.
        let idleRate = activeProfile.curve.handsOff ? Self.handsOffIdleInterval : Self.idleInterval
        let wantFast = busy || consecutiveIdleTicks < Self.idleConfirmTicks
        let desired = wantFast ? activeInterval : max(idleRate, activeInterval)
        guard desired != tickInterval else { return }
        tickInterval = desired
        if let timer {
            scheduleTimer(timer, interval: desired)
        }
    }

    /// Update the active profile.
    public func switchProfile(_ profile: FanProfile) {
        queue.async { [self] in
            decisionEngine.switchProfile(profile)
            lastFullStatusAt = nil
            lastMonitorTickAt = nil

            if profile.id == "smart" {
                // Reload calibration data for current lid state.
                calibrationLidClosed = lidStateProvider.isLidClosed
                let loaded = calibrationLoader(calibrationLidClosed)
                if let error = loaded?.validationError {
                    TFLogger.shared.error("Calibration data rejected on reload: \(error)")
                    calibration = nil
                } else {
                    calibration = loaded
                }
            }
        }
    }

    // MARK: - Polling

    func tick() {
        // Check if lid state changed and reload calibration accordingly.
        syncCalibration()

        let now = now()
        let monitorDue = ElapsedCadence.isDue(
            lastRun: lastMonitorTickAt,
            now: now,
            interval: Self.monitorInterval
        )
        let fullStatusDue = monitorDue || ElapsedCadence.isDue(
            lastRun: lastFullStatusAt,
            now: now,
            interval: Self.fullStatusInterval
        )

        // Build the full sensor snapshot only when UI or monitor work is due.
        // On those ticks, derive the control
        // peak from it instead of re-reading the CPU/GPU sensors; on the other
        // (control-only) ticks do the cheap CPU/GPU-only read.
        let status: ThermalStatus?
        let maxTemp: Float
        if fullStatusDue, let fullStatus = try? sensorProvider.status() {
            status = fullStatus
            latestStatus = fullStatus
            lastFullStatusAt = now
            maxTemp = TemperatureSummary(fullStatus.temperatures).controlPeak ?? 0
        } else if let fc = sensorProvider as? FanControl, let temps = fc.controlTemps() {
            status = nil
            maxTemp = max(temps.cpu, temps.gpu)
        } else {
            return
        }

        // Monitor cadence: process capture + anomaly detection (target ~2 seconds)
        if monitorDue, let status {
            monitorTick(status: status, maxTemp: maxTemp)
            lastMonitorTickAt = now
        }

        let limits = (sensorProvider as? FanControl)?.primaryFanLimits() ?? (2317, 7826)
        let output = decisionEngine.evaluate(RuntimeControlInput(
            status: status,
            maxTemp: maxTemp,
            fanLimits: RuntimeFanLimits(minRPM: limits.0, maxRPM: limits.1),
            now: now,
            tickInterval: tickInterval,
            recordTemperatureRate: monitorDue && status != nil,
            calibration: calibration
        ))

        if let command = output.command {
            applyCommand(command)
        }
        for notice in output.notices {
            logControlNotice(notice)
        }

        // Publish whenever this tick produced the full UI status snapshot.
        if let status { onUpdate?(status, activeProfile, state, calibrationState) }

        if output.shouldApplyCadence {
            applyCadence(maxTemp: maxTemp, fanChanged: output.fanChanged)
        }
    }

    // MARK: - Monitor Cadence (target ~2 seconds)

    /// Heavy operations: process capture + anomaly detection.
    /// Targets 2-second intervals, bounded by the adaptive thermal poll.
    private func monitorTick(status: ThermalStatus, maxTemp: Float) {
        anomalyObserver.observe(
            status: status,
            maxTemp: maxTemp,
            profileName: activeProfile.name,
            isCalibrating: isCalibrating
        )
    }

    // MARK: - Helpers

    private func logControlNotice(_ notice: RuntimeControlNotice) {
        switch notice {
        case let .safetyTriggered(maxTemp):
            TFLogger.shared.safety("Override triggered: \(String(format: "%.1f", maxTemp))°C — fans maxed")
            TFLogger.shared.event(ThermalEvent(
                type: .safetyOverrideTriggered,
                details: "maxTemp=\(String(format: "%.1f", maxTemp))"
            ))
        case let .safetyCleared(maxTemp):
            TFLogger.shared.event(ThermalEvent(
                type: .safetyOverrideCleared,
                details: "maxTemp=\(String(format: "%.1f", maxTemp))"
            ))
        case let .ruleTriggered(id, name):
            TFLogger.shared.event(ThermalEvent(
                type: .ruleTriggered,
                details: "rule=\(id) name=\(name)"
            ))
        case let .fan(message):
            TFLogger.shared.fan(message)
        }
    }

    private func applyCommand(_ command: FanCommand) {
        do {
            try onFanCommand?(command)
        } catch {
            TFLogger.shared.error("Fan command failed: \(command) — \(error)")
        }
    }
}
