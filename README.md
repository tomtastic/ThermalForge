# ThermalForge

Low-level fan control for Apple Silicon macOS (14+), implemented in Swift.

- Menu bar app (`ThermalForgeApp`)
- CLI (`thermalforge`)
- Privileged launchd daemon (`com.thermalforge.daemon`)

Original creator: **[ProducerGuy](https://github.com/ProducerGuy/ThermalForge)**.
This repository is an actively maintained fork.

### Fork History

The repository lineage is
**[ProducerGuy/ThermalForge](https://github.com/ProducerGuy/ThermalForge)** →
**[mileadev/ThermalForge](https://github.com/mileadev/ThermalForge)** →
**[tomtastic/ThermalForge](https://github.com/tomtastic/ThermalForge)** (this fork).

The main changes maintained by this fork are:

- persistent profile selection and a responsive, low-overhead menu bar app
- adaptive sensor polling, cached SMC reads, coalesced daemon commands, and reduced hidden-UI work, incorporating the performance work from [ProducerGuy/ThermalForge#16](https://github.com/ProducerGuy/ThermalForge/pull/16) by **[arttttt](https://github.com/arttttt)**
- hardened fan recovery on launch, profile changes, app exit, lost heartbeats, and sleep/wake
- machine-specific Smart-profile calibration with safe workload selection, three accuracy modes, CSV diagnostics, and separate lid-open and lid-closed curves
- calibration and daemon status in the menu bar, plus a bundled CLI and one-click daemon installation
- typed daemon transport, prioritized/latching rules, structured event logging, and expanded tests

## Architecture

`ThermalForgeCore` is split into explicit layers:

1. **Hardware**
- SMC adapter (`FanControl`)
- test seams: `FanController`, `SensorProvider`

2. **Control**
- `ThermalMonitor` runtime loop
- `ControlService`, `ControlStateMachine`
- `RuleEngine`, `RulePersistence`

3. **Transport**
- daemon socket: `/var/run/thermalforge.sock`
- protocol: `DaemonRequest`, `DaemonResponse`, `DaemonCodec`

4. **Observability**
- rotating text logs (`~/Library/Logs/ThermalForge`)
- structured events (`thermalforge-events-YYYY-MM-DD.jsonl`)
- research logger (`thermalforge log`)

## Safety Model

Execution precedence:

1. hard safety override (`>=95°C` → maximum fans)
2. the app's custom temperature override, when enabled
3. prioritized rule-engine decisions
4. profile curve logic

The hard override watches the hottest CPU or GPU sensor. It clears only below
`90°C`, providing a 5°C hysteresis band. Silent is hands-off during normal use,
but it remains monitored and is still subject to the hard override.

Daemon boundary:

- launchd system daemon (`root`)
- local Unix socket at `/var/run/thermalforge.sock` with mode `0600`; when an
  active console user is available, the socket is assigned to that user
- peer UID authorization restricted to root or the console user recorded when
  the daemon starts
- selecting a fan-controlling profile starts 5-second app heartbeats; selecting
  Silent stops them
- watchdog checks every 2 seconds and resets manually controlled fans to Apple
  auto after a heartbeat is more than 10 seconds stale (normally within about
  10–12 seconds)
- failed watchdog resets are retried; successful resets clear the saved manual
  command
- the app resets fans to Apple auto on launch, when selecting Silent, and on
  termination (with a 3-second client timeout)
- after wake, the daemon re-applies the last manual command after 2 seconds

Daemon calls have bounded socket send/receive timeouts and app-side fan commands
run off the UI thread through a serial coalescer. The menu bar warns when the
daemon is unavailable because manual fan commands cannot be applied without it.

## Calibration

Calibration measures the fan percentage needed to hold a set of temperatures on
the current machine. The Smart profile interpolates between those measurements
and adds a rate-of-temperature-rise adjustment. Without a valid calibration for
the current lid state, Smart uses its built-in S-curve.

Run the default Standard calibration with combined CPU and GPU stress:

```bash
sudo thermalforge calibrate
```

Available modes trade time for stabilization accuracy:

| Mode | Stabilization window | Maximum per fan level | Estimated total |
| --- | ---: | ---: | ---: |
| `quick` | 60s | 2.5 min | up to 17 min |
| `standard` | 90s | 4 min | up to 25 min |
| `optimized` | 120s | 6 min | up to 35 min |

Choose a mode or isolate the stress source when needed:

```bash
sudo thermalforge calibrate --mode optimized
sudo thermalforge calibrate --stress cpu
sudo thermalforge calibrate --stress gpu
```

Calibration stops the menu bar app and temporarily stops a running daemon to
avoid competing fan commands. It finds a safe workload, tests five fan levels,
and always stops the stress workload and returns fans to Apple auto when the run
ends. `Ctrl-C` also resets the fans and exits without saving calibration data.
An existing calibration cannot be replaced by a lower-ranked mode.

Lid-open and clamshell operation are calibrated independently. Run calibration
once in each configuration you use; the result is stored in:

- `~/Library/Application Support/ThermalForge/calibration_lid_open.json`
- `~/Library/Application Support/ThermalForge/calibration_lid_closed.json`

The embedded lid state must match the filename. A missing or mismatched file is
treated as uncalibrated rather than falling back to the legacy
`calibration.json`. The monitor checks for a lid-state change every 60 seconds
and reloads the matching curve. Calibration run as root also copies its result
to the active console user's application-support directory.

To delete all lid-specific and legacy calibration data:

```bash
thermalforge calibrate --reset
```

## Profiles

Built-in profiles:

| Profile | Behaviour |
| --- | --- |
| `silent` | Apple auto control; ThermalForge monitors only |
| `balanced` | 55–70°C ease-in curve, up to 60%, after an 8s sustained trigger |
| `performance` | 55–65°C linear curve, up to 85%, after a 4s sustained trigger |
| `max` | 100% at 65°C after a 5s sustained trigger |
| `smart` | 53–85°C rate-aware curve, using matching machine/lid calibration when available, after a 6s sustained trigger |

Active profiles return to Apple auto at or below `50°C`; the 50–start-temperature
band preserves the current fan state to prevent rapid start/stop cycling.

Control loop:

- thermal/control polling starts at 1 second while ramping, engaging, in a
  safety override, or at/above `85°C`
- after 8 consecutive non-busy ticks, steady fan-controlling profiles relax to
  2 seconds and hands-off Silent relaxes to 5 seconds; activity returns the loop
  to 1 second immediately
- full status and UI callbacks target 500ms, but cannot run faster than the
  current thermal poll (therefore 1s, 2s, or 5s with the default app cadence)
- process capture, anomaly detection, and Smart temperature-history sampling
  target 2 seconds but, like UI updates, cannot run faster than the current
  thermal poll; process capture is skipped below `50°C`
- timer leeway is 20% of the active interval to allow macOS to coalesce wakeups

## Rules (IF/THEN)

Rules are persisted at:
- `~/Library/Application Support/ThermalForge/rules.json`

CLI:
```bash
thermalforge rules list
thermalforge rules add --trigger 55 --until 65 --max
thermalforge rules enable <rule-id>
thermalforge rules disable <rule-id>
thermalforge rules remove <rule-id>
thermalforge rules test --cpu 70 --gpu 62 --profile balanced
```

## Install

### Homebrew
```bash
brew install ProducerGuy/tap/thermalforge
sudo thermalforge install
```

### Source
```bash
git clone https://github.com/tomtastic/ThermalForge.git
cd ThermalForge
./setup.sh
```

Open app:
```bash
open /Applications/ThermalForge.app
```

## Build / Test

```bash
swift build
swift test
./Scripts/ci-smoke.sh
```

Release build scripts:
- `Scripts/version.sh`
- `Scripts/build-app-bundle.sh`
- `Scripts/ci-smoke.sh`

CI workflows:
- `.github/workflows/ci.yml` (build + test + package smoke)
- `.github/workflows/release.yml` (tag-based artifact release)

## CLI Quick Reference

```bash
thermalforge status
thermalforge max
thermalforge auto
thermalforge set 4000
thermalforge watch --profile smart
thermalforge discover
thermalforge log --rate 10 --duration 1h --no-expire
```

## Troubleshooting

If macOS blocks the app after download:
```bash
xattr -dr com.apple.quarantine /Applications/ThermalForge.app
codesign --force --deep --sign - /Applications/ThermalForge.app
open /Applications/ThermalForge.app
```

Reset fans immediately:
```bash
thermalforge auto
```

## License

MIT
