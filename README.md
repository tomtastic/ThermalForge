# ThermalForge

[![CI](https://github.com/tomtastic/ThermalForge/actions/workflows/ci.yml/badge.svg)](https://github.com/tomtastic/ThermalForge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%E2%80%93M5-orange)](https://support.apple.com/en-us/116943)

Low-level fan control for Apple Silicon macOS (14+), implemented in Swift.

- Menu bar app (`ThermalForgeApp`)
- CLI (`thermalforge`)
- Privileged control backend (`com.thermalforge.daemon`)
- Independent recovery service (`com.thermalforge.recovery`)

Original creator: **[ProducerGuy](https://github.com/ProducerGuy/ThermalForge)**.
This repository is an actively maintained fork.

### Fork History

The repository lineage is
**[ProducerGuy/ThermalForge](https://github.com/ProducerGuy/ThermalForge)** →
**[mileadev/ThermalForge](https://github.com/mileadev/ThermalForge)** →
**[tomtastic/ThermalForge](https://github.com/tomtastic/ThermalForge)** (this fork).

The main changes maintained by this fork are:

- persistent profile selection and a responsive, low-overhead menu bar app
- centralized policy evaluation, cached SMC reads, and reduced hidden-UI work, building on earlier performance work from [ProducerGuy/ThermalForge#16](https://github.com/ProducerGuy/ThermalForge/pull/16) by **[arttttt](https://github.com/arttttt)**
- hardened fan recovery on launch, profile changes, app exit, expired client or completed-work leases, and sleep/wake
- machine-specific Smart calibration with safe workload selection, three accuracy modes, CSV diagnostics, and separate lid-open and lid-closed curves
- calibration and daemon status in the menu bar, plus a bundled CLI and one-click daemon installation
- typed daemon transport, runtime control decision extraction, anomaly observation, fan unlock/write consolidation, framed socket handling, and expanded tests

## Architecture

The app and CLI are clients of one serialized control backend. It owns profiles,
rules, calibration, and normal fan writes. An independent process owns recovery
from a stopped or failed backend. Both processes use one root-owned executable
under `/Library/PrivilegedHelperTools/com.thermalforge/`.

The version 2 socket protocol distinguishes requested intent, acknowledged fan
control, measured sensors, session ownership, and verified Apple handback. See
[architecture-v2.md](docs/architecture-v2.md) for the protocol and process model.

## Safety Model

The hottest CPU/GPU temperature drives the 95°C maximum-fan override, which
clears below 90°C. Rules run before profile curves. Even the Silent profile needs
a live client session for its temperature override; observers cannot cause writes.

- Client ownership expires after ten seconds without renewal. CLI `set`, `max`,
  `watch`, and calibration remain in the foreground and release their own session
  on interruption.
- Recovery uses a separate ten-second monotonic lease. Only completed sensing and
  control advances it; responsive status requests cannot conceal a stalled controller.
- Recovery durably records its obligation before the first manual write. On
  failure it revokes permission, sends SIGTERM, escalates after one second, and
  positively confirms controller exit before touching SMC.
- Every fan and any diagnostic override must report verified system/automatic
  ownership. Partial failures remain unverified and are retried; new control is blocked.
- Sleep invalidates sessions. Wake verifies Apple handback before fresh evaluation.
- Requests use an absolute two-second socket deadline. Root and the current console
  user are authorized using credentials supplied by the operating system.
- `--takeover` allows a CLI to revoke the GUI's session. The GUI remains open as an
  observer; it requires a fresh profile selection after takeover or explicit `auto`.
  A second controlling CLI receives a busy response.

The app can display local read-only sensors during an outage and marks fan ownership
unknown. GUI profile recovery after communication/backend failures cannot override
an explicit restoration or takeover, including across backend restarts.

Physical handback verification on direct-mode and `Ftst` hardware is a separate
release gate. Simulated tests verify software ordering, not firmware behavior.
Permanent SMC failures or a controller that cannot be terminated leave restoration
unverified and new manual control blocked.

## Calibration

Calibration measures the fan percentage needed to hold a set of temperatures on
the current machine. The Smart profile interpolates between those measurements
and adds a rate-of-temperature-rise adjustment. Without a valid calibration for
the current lid state, Smart uses its built-in S-curve.

Run the default Standard calibration with combined CPU and GPU stress:

```bash
thermalforge calibrate
```

Available modes use the same 60-second minimum evidence window but increasingly
strict convergence limits. A level finishes as soon as its trend, half-window
movement, and detrended uncertainty pass; uncertain levels can continue up to
the mode-specific limit:

| Mode | Minimum evidence | Maximum per fan level | Convergence |
| --- | ---: | ---: | --- |
| `quick` | 60s | 2.5 min | Fastest |
| `standard` | 60s | 4 min | Balanced |
| `optimized` | 60s | 6 min | Tightest |

Choose a mode or isolate the stress source when needed:

```bash
thermalforge calibrate --mode optimized
thermalforge calibrate --mode optimized --intensity 0.00221
thermalforge calibrate --mode optimized --rediscover-intensity
thermalforge calibrate --stress cpu
thermalforge calibrate --stress gpu
```

Calibration runs as an exclusive backend job. The app and other clients can
observe progress; cancellation and explicit Apple restoration remain available.
Use `--takeover` when the GUI owns control. It begins workload discovery at 5%, adjusts the
intensity geometrically, and makes early decisions when the result is clearly
safe or unsafe. Low CPU intensities use fractional duty cycling instead of
jumping directly to one fully loaded core. CPU, GPU, and combined runs use their
matching temperature sensors.

The sweep tests five fan levels. Unstable timeouts are excluded rather than
saved as equilibrium measurements, at least three converged points are required,
and the generated curve cannot reduce fan speed as temperature rises. The CSV
records selected, CPU, and GPU temperatures plus convergence diagnostics in the
console output. Completion and cancellation require confirmed workload termination
before verified Apple handback. Interrupted runs never save partial results or restart
automatically. `--force` is required to replace a higher-ranked calibration.

The selected stress type, workload intensity, and ambient temperature are saved
with the result. Later calibrations using the same stress type reuse that
known-safe intensity and skip Phase 1 automatically when ambient is within 3°C.
Use `--intensity` to supply a previously verified value explicitly; the 100% fan
stage still validates it against the temperature ceiling before the curve is
saved. Workload intensity is machine- and environment-specific; do not copy a
value from another Mac. Use `--rediscover-intensity` to ignore a saved workload
and rerun Phase 1.

A calibration is saved only when its converged sweep reaches at least 80°C,
providing measured coverage for the Smart control range. Underpowered sweeps and
all-maximum curves are rejected, leaving the previous calibration untouched.

Lid-open and clamshell operation are calibrated independently. The backend stores
both curves in `/Library/Application Support/ThermalForge/machine-calibration-v2.json`.
It prefers valid state-specific legacy root data, then authenticated user imports.
Lid-ambiguous data is never imported. Original files remain intact.

```bash
thermalforge calibrate --reset
```

Reset clears both machine curves and records a tombstone so a later legacy import
cannot resurrect them. A new completed calibration can still be saved.

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

The backend samples and evaluates control every second. Client display and lease
maintenance are independent; a slow CLI display interval does not expire its session.
Only acknowledged hardware operations update the published control state. Failures
return to Apple control and rebuild policy state before another evaluation.

## Rules (IF/THEN)

Profiles, rules, selected profile, and rule preferences are authoritative in
`/Library/Application Support/ThermalForge/users/<console-uid>/configuration.json`.
The first GUI connection imports validated legacy values atomically and preserves
the original files; explicit backend edits take precedence. Fahrenheit and launch
at login remain local preferences.

CLI:
```bash
thermalforge rules list
thermalforge rules add --trigger 55 --until 65 --max
thermalforge rules enable <rule-id>
thermalforge rules disable <rule-id>
thermalforge rules remove <rule-id>
thermalforge rules test --cpu 70 --gpu 62
```

## Install

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
thermalforge max --takeover  # foreground; Ctrl-C releases this session
thermalforge auto             # explicit verified Apple restoration
thermalforge set 4000 --takeover
thermalforge watch --profile smart --takeover
thermalforge discover
thermalforge log --rate 10 --duration 1h --no-expire
```

`set` controls all fans; per-fan `--fan` commands are rejected. Legacy status/reset
requests remain supported, while manual requests without protected sessions are rejected.

Installation fences old controllers and verifies handback before enabling either new
service. Recovery starts successfully before the backend. Failed uninstall restoration
retains recovery and reports the failure. Automated tests do not replace installed services.

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
