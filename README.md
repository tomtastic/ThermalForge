# ThermalForge

Low-level fan control for Apple Silicon macOS (14+), implemented in Swift.

- Menu bar app (`ThermalForgeApp`)
- CLI (`thermalforge`)
- Privileged launchd daemon (`com.thermalforge.daemon`)

Original creator: **[ProducerGuy](https://github.com/ProducerGuy/ThermalForge)**.
This repository is an actively maintained fork.

### Fork History

This fork was created from **[mileadev/ThermalForge](https://github.com/mileadev/ThermalForge)** and includes:
- **Persistent fan profile** — selected profile survives app restarts
- **Performance improvements** from [ProducerGuy/ThermalForge#16](https://github.com/ProducerGuy/ThermalForge/pull/16) by **[arttttt](https://github.com/arttttt)** — adaptive polling cadence, command coalescing, SMC read caching, and menu visibility gating (idle CPU ~9% → ~0.3%)

## Release

Current fork release: **`v0.8.5`**

- Release page: <https://github.com/tomtastic/ThermalForge/releases/tag/v0.8.5>
- Artifacts:
  - `ThermalForge.app.zip`
  - `thermalforge-cli-macos-arm64.tar.gz`
  - `checksums.txt`

`v0.8.5` adds:
- reliable open/closed lid detection using Core Graphics display metadata
- exact calibration selection for the current lid state
- uncalibrated status when the matching lid-state calibration file is absent
- rejection of calibration files whose embedded lid state does not match their filename
- menubar warning and one-click installation when the daemon is unavailable
- bundled CLI/daemon binary inside the app release

`v0.3.1` added:
- hardened on-exit fan safety — explicit resetAuto with timeout on app quit
- reduced daemon watchdog gap from ~25s to ~12s for faster fan recovery

`v0.3.0` added:
- adaptive polling cadence (1s active, 2s idle, 5s hands-off) — cuts idle CPU from ~9% to ~0.3%
- command coalescing for daemon I/O — serializes and batches fan commands
- SMC read caching and live key filtering — avoids redundant SMC reads
- autoreleasepool fixes for daemon memory leak
- @Observable migration from ObservableObject/@Published
- menu visibility gating — prevents hidden SwiftUI re-renders
- cheap controlTemps read path for non-UI ticks
- scheduled timer with leeway for OS coalescing
- process capture floor — skip below 50°C
- persistent fan profile selection across app launches
- socket timeout on legacy daemon fallback path

`v0.2.1` added:
- fix for menu bar freeze path caused by high-frequency repeated rule command dispatch
- daemon client socket timeout hardening + non-blocking app-side daemon call path
- runtime performance optimization: deduped rule-trigger events and reduced UI update cadence

`v0.2.0` added:
- typed daemon protocol (`DaemonRequest` / `DaemonResponse`) with legacy command fallback
- rule engine (IF/THEN with priority + latch/until)
- extracted control state machine + service
- unified built-in profiles (Smart included)
- structured event logging + expanded tests
- hardened app bundle/release pipeline

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
1. hard safety override (`>=95°C` -> max fan)
2. rule engine decisions
3. profile curve logic

Daemon boundary:
- launchd system daemon (`root`)
- local Unix socket with restrictive permissions
- peer UID authorization (root or active console user)
- heartbeat watchdog resets fans if client disappears

## Profiles

Built-in:
- `silent`
- `balanced`
- `performance`
- `max`
- `smart`

Control loop:
- thermal cadence: 100ms
- monitor cadence: 2s
- UI cadence: 1s

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
