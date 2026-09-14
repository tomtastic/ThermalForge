# Central backend and independent recovery

`thermalforge daemon` owns authoritative configuration, thermal policy, exclusive
calibration jobs, and every normal fan write. `thermalforge recovery` has a separate
launchd job and only performs recovery writes after confirming the failed backend's
exit. Both launch from a root-owned executable in
`/Library/PrivilegedHelperTools/com.thermalforge/thermalforge`.

## Control and sessions

`BackendCoordinator` serializes sensing, `RuntimeControlDecisionEngine`, and
`BackendActuating`. Request handling uses a short state lock, so status and renewal
remain available during long hardware operations. Requested intent and acknowledged
hardware state are separate in `BackendSnapshot`; sensor readings carry monotonic
freshness timestamps. Failed actuation discards the policy engine, restores Apple
ownership, and rebuilds rule latches and RPM assumptions before fresh evaluation.

`BackendClient` gives the app and CLI the same asynchronous protocol. Every controlling
session carries an ID, backend generation, authenticated UID/PID, and ten-second client
lease. Observers do not acquire or renew control. Only explicit CLI takeover can revoke
a GUI owner; a second CLI is busy. Release affects only the releasing client's session.
Explicit `auto` revokes control globally. Session-specific end records and persisted
recovery epochs stop automatic GUI reconnection from undoing takeover or `auto`.

Unix sockets use operating-system peer credentials and nonblocking I/O with a single
two-second deadline covering connection, write, and read. Frames are bounded to 1 MiB.
Legacy status and reset remain supported; legacy manual/heartbeat commands are rejected.
Long operations return accepted/pending, with their result in subsequent snapshots.

## Independent protection

`RecoveryCoordinator` binds one generation to a PID plus kernel process-start identity.
`FileRecoveryMarkerStore` fsyncs the marker and directory before permission for manual
writes is returned. Completed sensing/control advances a separate ten-second monotonic
lease; client traffic does not. The recovery timer checks every second. Unlock preparation
is cancellable and has an eight-second total budget.

Expiry revokes permission before SIGTERM. Recovery escalates after one second and waits
for positive process-exit evidence before SMC writes. An unknown or unkillable process
blocks restoration. Restart reads the durable marker and reconciles it before admitting
another backend. Backend loss of recovery communication cancels work, attempts cleanup,
and exits; a stalled call cannot leave the process running indefinitely.

`FanControl` validates capabilities, modes, targets, firmware results and reply sizes.
Unknown reads stay unknown. Handback attempts every fan and independently clears `Ftst`
where present, preserving failures. Targets are cleared only after the corresponding fan
is observed outside manual mode. Automatic/system modes and the diagnostic override must
be verified; actual RPM may lag. Recovery retries incomplete restoration.

## Configuration and calibration

Authoritative configuration lives under
`/Library/Application Support/ThermalForge/users/<uid>/configuration.json`. Atomic
versioned envelopes track edits, import completion and recovery revocation. Legacy
imports contain values only, retain source files, and cannot overwrite explicit edits.
Machine calibration stores separate lid states in one envelope, prefers valid root
legacy data, and rejects ambiguous lid metadata. Reset records a tombstone.

Calibration runs on the same hardware queue with injected sensing, gated actuation,
cancellation, storage and progress. Profile evaluation is suspended. The existing runner
retains convergence, temperature, coverage and intensity checks. Workloads must actually
stop before handback; a failed shutdown terminates the backend and leaves recovery to the
independent process. Cancellation or client loss never saves partial data or restarts jobs.

## Installation and verification

`ServiceInstallationCoordinator` fences old controllers, verifies handback, stages protected
files, starts recovery, then starts the backend. Uninstall retains recovery if handback
fails. Bundle creation requires both production executables and excludes the test fixture.

`ThermalForgeFixture` runs the real backend/recovery implementations against a parent-owned
SMC broker. Its operation journal survives subprocess crashes and verifies ordering across
SIGKILL, SIGSTOP, stalled sensing, lost sockets, recovery restart, partial handback and
calibration failures. All sockets and state are isolated from installed services.

Physical tests on direct-mode and `Ftst` machines remain required before release. Simulated
success establishes software behavior, not Apple firmware behavior.
