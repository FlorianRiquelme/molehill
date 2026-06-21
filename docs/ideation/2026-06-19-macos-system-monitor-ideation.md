---
date: 2026-06-19
topic: macos-system-monitor
focus: Clone iStat Menus — live CPU/mem/fans/disk/network/temp in the status bar, click to drill down, with history over time
mode: repo-grounded
---

# Ideation: macOS Menu-Bar System Monitor (iStat Menus clone)

## Grounding Context

Greenfield repo ("momo") — nothing built yet; only `.compound-engineering` config, `.gitignore`, `LICENSE`. Grounding came from external research (codebase scan and learnings search skipped — empty repo).

**Prior art & market:**
- **iStat Menus 7** (Bjango, closed, $14.99 / Setapp) — the benchmark. Modules: CPU/GPU (per-core, E/P cores, freq), Memory (pressure/swap), Disk (SMART, per-app I/O), Network (per-app bandwidth, ping, history), Sensors (SMC temps/voltages/power), Battery (+BT devices), Power, Weather, Time/world-clocks; "Combined mode" collapses items into one icon; per-module history graphs; configurable notification rules.
- **Stats** (exelban/stats, MIT, ~40k stars, free) — same module set, but **no history persistence beyond in-session ring buffers**, fan control legacy/Intel-only. Sensors+Bluetooth polling can consume up to 50% of the app's energy. Huge demand for a free alternative.
- **TG Pro** ($9.99), Macs Fan Control, Sensei, iGlance (abandoned), MenuMeters (dead).

**Top user complaints (2024–25):** fan control broken/fragile on M3+/macOS Sequoia & Tahoe (Stats deprecated it on Apple Silicon); rocky iStat v6→v7 upgrade; **menu-bar crowding on notched MacBooks** (items hide silently, no detection API; users buy Bartender/Ice); App Store variant is stripped (no weather/fan control/CPU freq).

**Technical reality:**
- Most reads need **no sudo**: CPU `host_processor_info`, memory `host_statistics64`, GPU `IOAccelerator`, energy/freq via `IOReport` (private API), temps via SMC (Intel) or `IOHIDEventSystem` (Apple Silicon, private), disk `statfs`/IOKit, network `getifaddrs`.
- Fan **control** needs a privileged root daemon (SMJobBless deprecated → SMAppService; broke on macOS 26.4.1).
- SMC keys change each SoC generation (M3 Ultra: only 3/99 temp keys via SMC); **macOS 26 removed `powermetrics --samplers smc`** and added a "System Settings → Menu Bar" permission gate.
- Full-featured monitors **cannot ship on the Mac App Store** (private APIs + privileged helper rejected) → direct + Setapp + notarization.
- Reference architectures: Vigil (per-monitor service + RingBuffer), MacSlowCooker (privileged root LaunchDaemon ↔ SwiftUI app over XPC; round-robin SQLite with cascading rollups), power-monitor (Rust zero-subprocess FFI). All share a collector→store→render shape. SwiftUI Charts is native (macOS 13+).

## Topic Axes

- Data collection — metrics plumbing, IOKit/SMC/IOReport, privilege boundaries, Apple Silicon quirks
- Menu-bar surface — glanceable live display, icon rendering, notch/real-estate, combined mode
- Drill-down panels — click-to-expand detail, live graphs, per-process attribution, inline controls
- History & retrospection — time-series storage, retention, visualization/playback, threshold alerts
- Distribution & architecture — privileged helper, signing/notarization, MAS-vs-direct, install/update/onboarding

## Ranked Ideas

### 1. Flight-recorder history (always-on, scrub-back playback)
**Description:** Record every metric continuously from first launch into a tiered-rollup store (1s last hour → 1m last day → 1h last month), surviving restarts. The drill-down gets a scrubber: drag to any past moment and the whole panel re-renders as it was then ("what pegged my CPU at 3am?"). Converged across 6 agents.
**Axis:** History & retrospection
**Basis:** `direct:` user explicitly wants history; Stats keeps nothing past a session, iStat's history is thin. `external:` MacSlowCooker cascading SQLite rollups, ~1MB/month @60s.
**Rationale:** The actually-useful question is almost always retrospective, which an in-session ring buffer structurally can't answer after a restart. Reframes the product from "live gauge" to "flight recorder for your Mac" — and a year of history is switching-cost lock-in a fresh competitor can't match.
**Downsides:** Persisting per-process attribution over time has real disk/privacy cost; retention defaults need a decision.
**Confidence:** 90%
**Complexity:** High
**Status:** Unexplored

### 2. Declarative per-SoC sensor capability manifest
**Description:** Don't hardcode SMC keys. Map each logical metric to an ordered fallback chain (SMC key → IOReport channel → IOHIDEventSystem path) shipped as *data*, not code. Probe at launch which sources actually return values on *this* Mac, cache the resolved map, and degrade visibly ("3 of 99 temps available on this Mac") instead of showing zeros. New chips / OS sampler removals become a data-file edit. Converged across 5 agents.
**Axis:** Data collection
**Basis:** `direct:` SMC keys change each SoC generation (M3 Ultra only 3/99 temp keys via SMC); macOS 26 removed `powermetrics --samplers smc`.
**Rationale:** Sensor breakage on new chips/OS is the single most recurring failure across iStat, Stats, and TG Pro. A data-driven, gracefully-degrading layer turns recurring engineering fires into routine data maintenance and makes the app correct on hardware that didn't exist when it shipped.
**Downsides:** Relying on a private IOHIDEventSystem API carries notarization risk and rules out the Mac App Store.
**Confidence:** 85%
**Complexity:** High
**Status:** Unexplored

### 3. Sensor-pod daemon + single time-series store as the only contract
**Description:** The architectural keystone. One privileged read-only LaunchDaemon (SMAppService) is the *only* component touching SMC/IOReport, writing samples over a versioned XPC contract into one append-only store. Every consumer — bar icon, drill-down, history, alerts — reads from the store, never directly from a collector. Self-healing helper lifecycle (detect/repair an unloaded daemon without reinstall). Converged across 6 agents.
**Axis:** Distribution & architecture
**Basis:** `external:` MacSlowCooker's privileged XPC daemon pattern; Kubernetes sidecar isolation. `reasoned:` decouples UI release cadence from the fragile privileged plumbing that breaks every macOS release; once the store is the universal interface, every new feature is additive.
**Rationale:** Get the privilege boundary wrong and you're either un-shippable or constantly broken on new hardware. This fork determines years of maintenance cost and makes #1, #4, #6, #7 mostly additive.
**Downsides:** The privileged-helper install/update/trust dance is where competitors' users churn; must be the engineering centerpiece.
**Confidence:** 85%
**Complexity:** High
**Status:** Unexplored

### 4. Causal drill-down: click a spike → the culprit, replayable
**Description:** Capture top-N process attribution + correlated state (thermal, power, foreground app) alongside each sample. Tap any point on a graph (live or historical) and get the responsible process(es) plus a one-line causal hypothesis ("Spotlight reindex after Xcode build kicked off mdworker storm"). Converged across 5 agents.
**Axis:** Drill-down panels
**Basis:** `reasoned:` every incumbent shows *that* a metric spiked but not *why*, forcing users into Activity Monitor; the whole job-to-be-done is "what caused it." `external:` OBD-II freeze-frame data.
**Rationale:** Numbers tell you something is wrong but not what to do. This is the layer incumbents structurally don't do — and the decision to persist attribution must be made *now*, since it can never be backfilled.
**Downsides:** Cross-subsystem process ranking needs a normalization model (how to rank a disk hog vs a CPU hog); storing process names is a privacy consideration.
**Confidence:** 80%
**Complexity:** Medium-High
**Status:** Unexplored

### 5. Pre-attentive menu-bar glyph (state/sparkline, not numbers)
**Description:** Numbers in a ~16px notch-constrained bar are unreadable and meaningless without context. Encode each metric as a tiny inline sparkline (trend/volatility) and/or a color-coded health state relative to a per-Mac baseline (green/amber/red). A single composite glyph also answers the notch-crowding complaint; precise numbers move to the drill-down. Converged across 4 agents.
**Axis:** Menu-bar surface
**Basis:** `external:` Edward Tufte's sparklines; Bloomberg inline trend glyphs; ICU patient-monitor IEC 60601-1-8 alarm palette. `reasoned:` the notch silently hides items, so information-per-pixel is the binding constraint; trend is often more decision-relevant than instantaneous value.
**Rationale:** Glanceability is the whole product, but the surface is shrinking each OS release. A pre-attentive signal carries more meaning per pixel than truncated digits and removes the "is 70°C bad?" cognitive load.
**Downsides:** Color-state needs a per-Mac baseline to be meaningful (depends on #1/#7); requires NSStatusItem + NSHostingView rather than plain MenuBarExtra.
**Confidence:** 75%
**Complexity:** Medium
**Status:** Unexplored

### 6. Energy-adaptive polling governor
**Description:** A central governor sets cadence for all collectors by context: 1Hz+ when a drill-down panel is open, 10–60s when only the menu bar is visible, near-paused on battery/low-power-mode or when no display is attached. Collectors subscribe to the governor's cadence rather than owning their own timers.
**Axis:** Data collection
**Basis:** `direct:` sensor polling can consume up to 50% of Stats' total app energy.
**Rationale:** A monitor that itself dominates the energy graph is self-defeating; one well-placed component fixes the app's biggest reputational risk for all metrics at once, and centralizing cadence makes sample spacing predictable for the rollup store (#1).
**Downsides:** Budget-vs-freshness tradeoff needs a default policy; over-throttling makes graphs feel laggy.
**Confidence:** 80%
**Complexity:** Medium
**Status:** Unexplored

### 7. Self-calibrating anomaly alerts (no manual thresholds)
**Description:** Kill the threshold form. Learn each metric's normal envelope per machine (by hour-of-day / day-of-week) and alert only on statistically unusual behavior, with a one-tap "this is normal, stop telling me" feedback loop. A build-time CPU spike at 3pm is normal; the same at 3am idle is an anomaly.
**Axis:** History & retrospection
**Basis:** `direct:` iStat makes users hand-configure notification rules and thresholds. `external:` Datadog anomaly monitors / Prometheus Holt-Winters seasonal bands.
**Rationale:** Static thresholds are wrong for every machine (a build server's "high CPU" is a laptop's idle) and are the most-skipped setup screen; per-machine baselines make alerts trustworthy. Naturally builds on the history store (#1).
**Downsides:** Cold-start period before baselines are meaningful; risk of missing genuinely novel-but-bad behavior.
**Confidence:** 70%
**Complexity:** Medium
**Status:** Unexplored

## Rejection Summary

| # | Idea | Reason Rejected |
|---|------|-----------------|
| 1 | Notch overflow guard / self-relocation | Duplicates #5 as the notch answer; occlusion inference unreliable (no API); Ice/Bartender already own this |
| 2 | Honest fan control (read-only default + capability probe) | Subsumed by #2 applied to the control axis; fan write adds fragile privileged complexity |
| 3 | Zero-config auto-surface bar | Overlaps #5 + #7; speculative learned-salience |
| 4 | Budget mode (renice enforcement) | Scope overrun (monitor → controller); better as a brainstorm variant |
| 5 | Fleet mode (1000 Macs) | Scope overrun for a v1 menu-bar clone; separate product tier (noted as a good future direction) |
| 6 | Headless daemon + CLI | Scope expansion; partly enabled by #3 anyway |
| 7 | Self-healing permission onboarding (macOS 26 gate) | Necessary reliability work, folds into #3; not a standalone differentiator |
| 8 | Infinite-canvas tear-off drill-down | Power-user nicety; brainstorm variant |
| 9 | Composable menu-bar slot renderer | Implementation detail of #5, not a user-facing idea |
| 10 | Zero-pixel sonification/haptics | Too speculative; annoyance/accessibility risk, low value |
| 11 | No-sudo purist | Strategic fork that drops fans/temps (the point of the clone); a positioning option, not an idea |
| 12 | Once-a-minute mode | A tier of #6, merged |
| 13 | OBD/SCADA/ICU/aviation analogies | Same ideas as #1/#4/#5 via different lenses, merged |
