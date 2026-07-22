# Code Simplification Audit

The July 2026 code-simplification audit is complete. Individual fixes and
structural moves are recorded as separate commits in git history; this file
records the final verification baseline.

Current verified baseline:

- 140 tests pass across 29 suites.
- A production build succeeds.
- Calibration persistence, temperature classification, monitor timing, daemon
  client transport, cancellation cleanup, uninstall ownership, lid detection,
  CPU/GPU stress workloads, calibration cooldown, equilibrium sweep, curve
  construction, rule persistence mutations, runtime anomaly observation,
  runtime control decisions, and fan unlock/write paths have dedicated
  components or test seams. Daemon requests and responses use bounded,
  newline-delimited framing with complete writes. The CLI entry file now only
  registers commands.

## Completion Verification

- Only one rule model and one authoritative rule store remain.
- Calibration phases are independently testable without SMC hardware, Metal,
  launchd, real waiting, or attached displays.
- The CLI entry file only registers commands.
- `ThermalMonitor` scheduling, observation, and decision logic have clear test
  boundaries.
- Privileged operations consistently report failures and target both root and
  console-user state where appropriate.
- No tracked generated app bundle or superseded design document remains.
- The final full test suite and production build pass.
