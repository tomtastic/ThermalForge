# Migration to the central backend

Build from `nextgen`, then run `./setup.sh`. Installation stops and confirms exit of
legacy controllers before verifying Apple handback. It installs one protected binary
and two launchd services; recovery must become ready before the backend starts.

The GUI imports profiles, rules, selected profile and rule preferences on first
connection. Imports are validated values, never privileged file paths. Original files
are preserved. Backend edits made before import win and repeated imports are idempotent.
Fahrenheit and launch at login remain local.

Valid state-specific root calibration takes precedence over user imports. Both lid states
are stored once in `/Library/Application Support/ThermalForge/machine-calibration-v2.json`.
Legacy files without explicit matching lid state are ignored. Calibration reset records a
tombstone so legacy data cannot reappear; interrupted jobs are never restarted or saved.

`set`, `max`, and `watch` now hold a foreground session. Use `--takeover` to revoke GUI
ownership; a second controlling CLI is rejected. Interrupting a CLI releases only that
session. The GUI remains an observer after takeover or explicit `auto` until a fresh profile
selection. An observing app cannot reset another client's fans when it quits. Calibration
also remains foreground and runs inside the backend without stopping either service.

`thermalforge status --json` preserves the sensor JSON shape. Legacy status/reset socket
requests work; legacy manual commands without sessions do not. `set --fan` is rejected
because central sessions currently control all fans.

Verification commands (read-only):

```sh
thermalforge status --json
thermalforge rules list
launchctl list com.thermalforge.daemon
launchctl list com.thermalforge.recovery
```

Uninstall with `sudo thermalforge uninstall` or `./uninstall.sh`. Failed Apple restoration
retains recovery and reports an error. Do not delete recovery manually to work around
unverified restoration. Physical handback tests on each supported mode-key/diagnostic
hardware family remain a release gate.
