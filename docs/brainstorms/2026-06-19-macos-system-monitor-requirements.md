---
date: 2026-06-19
topic: macos-system-monitor
---

# macOS Menu-Bar System Monitor — Requirements

## Summary

A macOS menu-bar system monitor for the author's own daily use — good enough to replace iStat Menus — covering CPU, memory, disk, network, temperatures, and fan speeds, all read in-process with no privileged helper. From first launch it continuously records every metric (including which process is responsible) into a persistent store. The live view ships first; the flight-recorder UI — scrub back to any past moment, click a spike to see the culprit — layers on top of data already being captured.

## Problem Frame

The author currently uses iStat Menus but wants to own the tool. Free Stats keeps no history past a session (in-memory ring buffers only), and iStat's history is thin. The genuinely useful question about a Mac is almost always retrospective — "what pegged my CPU at 3am?" — and no incumbent answers it well after a restart, nor explains *why* a metric spiked without forcing a trip to Activity Monitor.

This is a learning/craft project as much as a utility: the point of building it (rather than just running Stats) is the time-series and data-visualization work — continuous recording, tiered rollups, scrub-back playback, and causal attribution. The daily-driver requirement keeps it honest (it has to actually be good enough to live in), and the flight-recorder is what makes it worth building.

## Key Decisions

- **In-process, no privileged helper.** Sensors and fans are read-only, so every metric reads without elevated privileges. This avoids the privileged root LaunchDaemon / XPC / SMAppService install-and-trust dance — the single most fragile, OS-version-coupled part of the space (it broke on macOS 26.4.1; Stats deprecated fan control on Apple Silicon). The whole product is one well-behaved menu-bar app.
- **Record from day one, with per-process attribution.** The store records continuously from first launch, and each sample carries top-N per-process attribution. This is irreversible by nature — attribution can never be backfilled — so the store schema is the one decision that must be right before any data is written, even though the history *UI* lands later.
- **Broad metrics live before deep history.** Full live metric coverage ships first so the app can replace iStat early; the recording store runs silently underneath from launch, and the flight-recorder visualization is pure additive payoff on data already collected. The two goals never compete for the same milestone.
- **Energy-adaptive polling is a v1 requirement, not a stretch.** A monitor that itself dominates the energy graph is self-defeating (sensor polling can consume up to 50% of Stats' app energy). Centralized, context-aware cadence is part of being a credible daily driver.
- **Sensor support is data-driven, not hardcoded.** SMC keys change every SoC generation (M3 Ultra exposes only 3 of 99 temp keys via SMC) and macOS 26 removed `powermetrics --samplers smc`. The app probes per-machine sensor availability at launch and degrades visibly instead of showing zeros.

## Requirements

**Metric coverage**

- R1. The app reads CPU (overall + per-core), memory (used / pressure / swap), disk (usage + I/O), network (throughput), temperatures, and fan RPM — all without elevated privileges, in-process.

**Menu-bar live display**

- R2. The menu bar shows a glanceable live readout for a user-selected subset of metrics, updating continuously.
- R3. Clicking a menu-bar item opens a drill-down panel for that metric.

**Drill-down detail**

- R4. Each drill-down panel shows current detail (e.g., per-core CPU, per-process attribution, the sensor list) plus a live graph of recent values.

**Recording & history (flight recorder)**

- R5. From first launch, all metrics are recorded continuously into a persistent store that survives app restarts and reboots.
- R6. Each recorded sample includes top-N per-process attribution and correlated state (e.g., foreground app, power state), captured at record time. This is captured from day one and cannot be backfilled.
- R7. Storage uses tiered retention / rollups so long-term history stays bounded in size as it ages.
- R8. The drill-down supports scrub-back: selecting any past moment re-renders the panel as it was at that time.

**Causal drill-down**

- R9. Selecting any point on a graph — live or historical — surfaces the responsible process(es) for that moment.

**Stability & resource behavior**

- R10. A central polling governor sets collection cadence by context: faster when a drill-down panel is open, slower when only the menu bar is visible, throttled on battery / low-power mode / no attached display.
- R11. The app's own CPU and energy footprint stays low enough to run continuously without being a notable consumer.

**Sensor robustness**

- R12. Sensor metrics resolve through a per-machine capability probe at launch; sensors with no available source degrade visibly ("3 of N temps available on this Mac") rather than showing zeros.

## Key Flows

- F1. First-launch recording
  - **Trigger:** App launches for the first time (or after an update).
  - **Steps:** Capability probe resolves which sensors this Mac exposes; collectors start; the store begins recording all metrics with per-process attribution.
  - **Outcome:** Recording is on from the first moment, before the user has configured anything.
  - **Covered by:** R5, R6, R12

- F2. Live glance and drill-down
  - **Trigger:** User looks at the menu bar, then clicks a metric.
  - **Steps:** Menu bar shows live readouts (R2); click opens the panel (R3) with current detail + a live graph (R4).
  - **Outcome:** The user gets the present-moment picture, the same job iStat does today.
  - **Covered by:** R2, R3, R4

- F3. Retrospective investigation ("what pegged my CPU at 3am?")
  - **Trigger:** User notices something was wrong earlier, or wants to inspect a past spike.
  - **Steps:** Open a panel, scrub back to the moment (R8); the panel re-renders as it was then; select the spike to see the responsible process(es) (R9).
  - **Outcome:** The user answers a retrospective, causal question no in-session ring buffer can answer after a restart.
  - **Covered by:** R8, R9, R6

## Acceptance Examples

- AE1. **Covers R8.** Given the app has been recording for several days, when the user drags the scrubber to a timestamp two days ago, then the panel's graphs and detail reflect the values that were recorded at that timestamp, not the current ones.
- AE2. **Covers R9.** Given a historical CPU spike, when the user selects that point on the graph, then the panel names the process(es) that were responsible at that moment (from the attribution captured at record time, R6).
- AE3. **Covers R10.** Given the machine is on battery in low-power mode with no drill-down open, when the governor evaluates cadence, then collection slows to its throttled rate; when a drill-down panel opens, then cadence increases for the visible metrics.
- AE4. **Covers R12.** Given a Mac whose SoC exposes only a subset of temperature sensors, when the app starts, then it shows the available sensors and indicates how many of the expected sensors are unavailable, rather than rendering zeros or blank values.

## Scope Boundaries

**Deferred for later**

- Anomaly / threshold alerts that learn a per-machine normal envelope (ideation idea #7) — useful, but not needed to replace iStat.
- Pre-attentive menu-bar glyphs / sparklines and color-coded health state (idea #5) — v1 menu bar is plain readouts; this is polish on top.
- Additional iStat modules: GPU, battery + Bluetooth devices, weather, world clocks, combined mode.

**Outside this product's identity**

- Fan control (setting fan speeds) and the privileged root daemon it requires (idea #3) — this is a read-only monitor, not a controller. Read-only was chosen deliberately over a "control as a stretch" path.
- Becoming a general-purpose controller (e.g., `renice` enforcement / budget mode).
- Mac App Store distribution — the private sensor APIs (IOHIDEventSystem) rule it out, and the tool is run by its author rather than shipped to strangers.
- Multi-Mac / fleet monitoring — a separate product tier, not this one.

## Dependencies / Assumptions

- **No-sudo metric sources exist for everything in R1.** Grounded in research: CPU via `host_processor_info`, memory via `host_statistics64`, disk via `statfs`/IOKit, network via `getifaddrs`, temps/fans via SMC (Intel) and `IOHIDEventSystem` (Apple Silicon, private API). The sensor sources are private APIs — acceptable for a self-run app, and the reason App Store distribution is out of scope.
- **Target OS supports native time-series charting** (SwiftUI Charts, macOS 13+). macOS 26 added a "System Settings → Menu Bar" permission gate and removed the `powermetrics` SMC sampler — the capability probe (R12) is partly there to absorb exactly these shifts.
- **Network throughput is in the v1 metric set** (confirmed in dialogue).
- Retention defaults (how long to keep each rollup tier) are not yet decided — see Outstanding Questions.

## Outstanding Questions

**Resolve before planning**

- Tiered retention policy: how long to keep data at each resolution (e.g., 1s recent → 1m → 1h), and the disk/privacy tradeoff of persisting per-process names over time.
- Cross-subsystem "culprit" ranking (R9): how to rank a disk hog vs. a CPU hog vs. a network hog into a single "responsible process" answer needs a normalization model.

**Deferred to planning**

- Store technology and on-disk format for the tiered rollups.
- Menu-bar rendering approach (whether plain `MenuBarExtra` suffices for v1 readouts, given the glyph work is deferred).

## Sources / Research

- `docs/ideation/2026-06-19-macos-system-monitor-ideation.md` — the ranked ideas this brainstorm scopes from (flight recorder #1, sensor capability manifest #2, sensor-pod daemon #3, causal drill-down #4, glyph #5, polling governor #6, anomaly alerts #7).
- Prior art: **Stats** (exelban/stats, MIT) — same module set, no history persistence beyond a session; **iStat Menus 7** (Bjango) — the benchmark, thin history. Both establish the gap this targets.
- Reference architectures noted in ideation: Vigil (per-monitor service + ring buffer), MacSlowCooker (round-robin SQLite with cascading rollups, ~1MB/month @60s), power-monitor (zero-subprocess FFI). All share the collector → store → render shape this adopts.
