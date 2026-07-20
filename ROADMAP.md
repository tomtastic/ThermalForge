# ThermalForge Roadmap

This roadmap describes future work only. Implemented behavior and operating
details belong in the README and source documentation.

## Current State

ThermalForge currently includes:

- Five built-in profiles with distinct curves, trigger times, and ramp rates.
- Machine-specific Smart calibration with separate lid-open and lid-closed
  curves, adaptive workload discovery, convergence checks, and CSV diagnostics.
- Adaptive thermal polling, cached SMC reads, and coalesced daemon commands.
- A 95°C safety override, daemon heartbeat watchdog, clean startup/shutdown fan
  resets, serialized SMC access, and temperature anomaly logging.
- Research logging with temperature sensors, fan state, process snapshots, and
  session metadata.
- A persistent priority-based rule engine available from both the CLI and GUI.
- A menu bar app, standalone CLI, privileged daemon, one-click daemon install,
  and tag-based release artifacts.

## Next Feature: Calibration and Profile Visualization

Show how the available profiles differ after calibration so the user can judge
whether the machine-specific Smart curve is useful.

Planned first version:

- Plot Silent, Balanced, Performance, Max, default Smart, and calibrated Smart
  on a shared temperature-versus-fan-speed graph.
- Clearly distinguish theoretical built-in curves from measured calibration
  output.
- Display the active lid state and calibration date/mode.
- Show when Smart is using its fallback curve because calibration is missing or
  invalid.
- Keep the menu bar compact; open the graph in a dedicated detail window.
- Reuse the existing profile and calibration models rather than maintaining a
  second set of curve definitions for the graph.

Questions to resolve during design:

- Whether Silent should be shown as “Apple controlled” rather than as a numeric
  curve.
- How to represent sustained triggers, hysteresis, and ramp governors without
  making the graph misleading.
- Whether to include the raw fan-level equilibrium measurements as optional
  points alongside the generated Smart curve.

## Near-Term Maintenance

### Code Simplification Audit

Perform a focused codebase audit after this roadmap rewrite.

Initial targets:

- Split the large calibration implementation into workload discovery,
  convergence/sweep, curve construction, and persistence components.
- Split CLI command implementations out of the monolithic CLI entry file.
- Consolidate duplicated temperature-family and machine-state selection logic.
- Identify stale compatibility code and comments that describe superseded
  polling or calibration designs.
- Review error propagation and exit statuses for long-running CLI commands.
- Preserve behavior with tests before structural changes.

### Update Notifications

Add a lightweight, non-intrusive update check:

- Query the latest GitHub release after app launch.
- Compare it with `ThermalForgeVersion.current`.
- Show an “Update available” row in the menu without displaying a popup.
- Link to the release page and mention the Homebrew upgrade command.
- Cache checks and fail silently when offline.
- Do not add an automatic updater or Sparkle dependency at this stage.

## Deferred

These ideas remain potentially useful but are not active priorities.

### Runtime Learning

Smart could eventually learn thermal response during normal workloads instead
of relying entirely on synthetic calibration. Defer this until there is enough
real-world logging evidence to design safe, explainable, and reversible
adaptation.

### Enhanced Logging and Experiment Mode

Defer both the proposed logger expansion and the experiment/compare framework.
Possible future logging additions include thermal-pressure state, delta-T over
ambient, user markers, and statistical summaries. Experiment mode should not be
built until those primitives and a clear research need exist.

### Control Center Widget

Defer WidgetKit work. It requires an Xcode project and app-extension packaging,
which is not justified by the current feature priority.

## Not Pursuing

- Community thermal database and anonymous result uploads.
- Additional SEO/discoverability work, GitHub Discussions, blog posts, or a
  landing page.
- FORGE process auto-detection.
- Sparkle or another in-place automatic update framework.
