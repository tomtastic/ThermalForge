//
//  MenuBarView.swift
//  ThermalForge
//
//  Menu bar dropdown content.
//

import SwiftUI
import ThermalForgeCore

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("ThermalForge")
                    .font(.headline)
                Text(ThermalForgeVersion.current)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                stateIndicator
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Daemon warning
            if !appState.daemonAvailable {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text("Fan control unavailable")
                            .font(.caption)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    Button("Install Daemon") {
                        appState.installDaemon()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }

            Divider()

            // Fan speeds
            if let status = appState.latestStatus {
                let temperatures = TemperatureSummary(status.temperatures)
                SectionHeader(title: "FANS")
                ForEach(status.fans, id: \.index) { fan in
                    HStack {
                        Text("Fan \(fan.index)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(fan.actualRPM) RPM")
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1)
                }

                Divider().padding(.vertical, 4)

                // Temperatures
                SectionHeader(title: "TEMPERATURES")
                TemperatureRow(label: "CPU", value: temperatures.cpu, fahrenheit: appState.useFahrenheit)
                TemperatureRow(label: "GPU", value: temperatures.gpu, fahrenheit: appState.useFahrenheit)
                TemperatureRow(label: "RAM", value: temperatures.ram, fahrenheit: appState.useFahrenheit)
                TemperatureRow(label: "SSD", value: temperatures.ssd, fahrenheit: appState.useFahrenheit)
                TemperatureRow(label: "Ambient", value: temperatures.ambient, fahrenheit: appState.useFahrenheit)
            } else {
                Text("Reading sensors...")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }

            Divider().padding(.vertical, 4)

            // Profile picker
            SectionHeader(title: "PROFILE")
            Picker("Profile", selection: Binding(
                get: { appState.activeProfile.id },
                set: { id in
                    if let profile = FanProfile.builtIn.first(where: { $0.id == id }) {
                        appState.selectProfile(profile)
                    }
                }
            )) {
                ForEach(FanProfile.builtIn) { profile in
                    HStack {
                        Text(profile.name)
                        Spacer()
                        if !profile.curve.handsOff {
                            let unit = appState.useFahrenheit ? "F" : "C"
                            if profile.curve.instantEngage {
                                let startC = profile.curve.startTemp
                                let startDisp = appState.useFahrenheit ? startC * 9 / 5 + 32 : startC
                                Text("\(Int(startDisp))°\(unit) instant")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                let startC = profile.curve.startTemp
                                let ceilC = profile.curve.ceilingTemp
                                let startDisp = appState.useFahrenheit ? startC * 9 / 5 + 32 : startC
                                let ceilDisp = appState.useFahrenheit ? ceilC * 9 / 5 + 32 : ceilC
                                Text("\(Int(startDisp))→\(Int(ceilDisp))°\(unit)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tag(profile.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .padding(.horizontal, 12)

            // Calibration indicator
            if appState.calibrationState.active {
                HStack(spacing: 4) {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(.orange)
                        .font(.caption2)
                    Text(appState.calibrationState.lidClosed ? "Calibrated (lid closed)" : "Calibrated (lid open)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
            }

            Divider().padding(.vertical, 4)

            SectionHeader(title: "RULES")
            Toggle("Enable Rule Engine", isOn: $appState.rulesEnabled)
                .padding(.horizontal, 12)

            if appState.rules.isEmpty {
                Text("No rules configured")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            } else {
                ForEach(appState.rules.sorted(by: { $0.priority > $1.priority })) { rule in
                    HStack {
                        Toggle(rule.name, isOn: ruleBinding(rule.id))
                        Button(action: { appState.removeRule(rule.id) }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1)
                }
            }

            Button(action: { appState.addQuickRule() }) {
                Label("Add IF/THEN Rule", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 2)

            Divider().padding(.vertical, 4)

            // Quick actions
            HStack(spacing: 8) {
                Button(action: { appState.setSmart() }) {
                    Label("Smart", systemImage: "fan.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)

                Button(action: { appState.resetAuto() }) {
                    Label("Default", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)

            Divider().padding(.vertical, 4)

            // Custom IF/THEN rule
            SectionHeader(title: "IF / THEN RULE")
            Toggle("Enable Custom Rule", isOn: $appState.customRuleEnabled)
                .padding(.horizontal, 12)

            if appState.customRuleEnabled {
                Stepper(
                    value: $appState.customRuleTriggerTempC,
                    in: 40 ... 95,
                    step: 1
                ) {
                    Text("IF temp ≥ \(Int(appState.customRuleTriggerTempC))°C")
                        .font(.caption)
                }
                .padding(.horizontal, 12)

                Stepper(
                    value: $appState.customRuleFanPercent,
                    in: 20 ... 100,
                    step: 5
                ) {
                    Text("THEN set fan \(Int(appState.customRuleFanPercent))%")
                        .font(.caption)
                }
                .padding(.horizontal, 12)

                Stepper(
                    value: $appState.customRuleReleaseTempC,
                    in: 35 ... 94,
                    step: 1
                ) {
                    Text("ELSE when temp ≤ \(Int(appState.customRuleReleaseTempC))°C")
                        .font(.caption)
                }
                .padding(.horizontal, 12)
            }

            Divider().padding(.vertical, 4)

            // Footer
            Toggle("°F / °C", isOn: $appState.useFahrenheit)
                .padding(.horizontal, 12)
            Toggle("Launch at Login", isOn: $appState.launchAtLogin)
                .padding(.horizontal, 12)

            Button(action: { NSApp.terminate(nil) }) {
                Text("Quit ThermalForge")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .frame(width: 320)
        .onAppear { appState.menuDidOpen() }
        .onDisappear { appState.menuDidClose() }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var stateIndicator: some View {
        switch appState.monitorState {
        case .safetyOverride:
            Label("SAFETY", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .active(let name):
            Label(name, systemImage: "fan.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .idle:
            Label("Idle", systemImage: "fan")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func ruleBinding(_ ruleID: String) -> Binding<Bool> {
        Binding(
            get: {
                appState.rules.first(where: { $0.id == ruleID })?.enabled ?? false
            },
            set: { enabled in
                appState.toggleRule(ruleID, enabled: enabled)
            }
        )
    }
}

// MARK: - Subviews

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
    }
}

private struct TemperatureRow: View {
    let label: String
    let value: Float?
    var fahrenheit: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            if let tempC = value {
                let display = fahrenheit ? tempC * 9 / 5 + 32 : tempC
                let unit = fahrenheit ? "F" : "C"
                Text("\(String(format: "%.1f", display))°\(unit)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(tempColor(tempC))
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
    }

    /// Color thresholds always based on °C
    private func tempColor(_ temp: Float) -> Color {
        if temp >= 90 { return .red }
        if temp >= 75 { return .orange }
        if temp >= 60 { return .yellow }
        return .primary
    }
}
