# CLAUDE.md — Momo

Momo is a self-run **macOS menu-bar system monitor** (Apple Silicon primary; Intel best-effort).
It reads CPU, memory, disk, network, temperatures, and fan speeds **in-process with no privileged
helper**, and records every metric continuously — with per-process attribution — into a persistent
tiered-rollup store, with live drill-down, scrub-back, and per-subsystem causal attribution.

## Build & test

The Xcode project is **generated from `project.yml` by XcodeGen** — `project.yml` is the source of
truth; `Momo.xcodeproj` is gitignored. After adding/removing/renaming source files, regenerate:

```bash
xcodegen generate
xcodebuild -scheme Momo -destination 'platform=macOS' -derivedDataPath build/DerivedData build
xcodebuild -scheme Momo -destination 'platform=macOS' -derivedDataPath build/DerivedData test
```

- Source files are glob-included from `Momo/`, so new files appear in the target on
  `xcodegen generate` — you do **not** edit the `.xcodeproj`.
- Bundle id `com.florianriquelme.momo`; accessory app (`LSUIElement`); deployment floor macOS 14.
- Local ad-hoc signing ("Sign to Run Locally") — private APIs make it App-Store-ineligible by design.
- Tests are a hosted bundle; the live pipeline is guarded off under the XCTest host so tests don't
  spin the governor/DB.

## Hard rules

- **Swift 6 strict concurrency = `complete` is ON.** Keep it green. The concurrency contract
  (KTD11): collectors are reference types confined to the governor's single serial queue
  (non-`Sendable`, own their delta-math state); exactly one immutable `Sendable` `Sample` crosses
  a single main-actor hop into the UI. `@unchecked Sendable` types (governor, store, ring buffer,
  power context) uphold confinement manually — don't add cross-thread access.
- **No privileged helper.** Every metric reads via public C APIs + read-only private sensor APIs.
  Don't introduce a LaunchDaemon/XPC/SMAppService path.
- **The store schema is irreversible** (`Momo/Store/Schema.swift`). Per-process attribution can't be
  backfilled. Think before changing tier tables, the proc side tables, or rollup denominators.
- **On-disk privacy (KTD4b):** leaf process name only (never full paths); DB files `0o600`,
  `secure_delete=ON`, excluded from backup; per-process + foreground-app names age out at the 1h tier.

## Layout (one-way dependencies, KTD12)

```
Momo/
  Core/        # layer-neutral Sendable domain (Sample, SampleSink fan-out) — depended on by all
  Collectors/  # CPU/memory/disk/network + per-process attribution (delta-of-cumulative math)
  Sensors/     # SMC (Intel) + HID (Apple Silicon) readers + capability probe; catalog-driven
  Governor/    # single DispatchSourceTimer cadence state machine + PowerContext
  Store/       # GRDB DatabasePool (WAL) ingest, tiered schema, rollup/retention, clock guard
  History/     # tier-selecting historical query layer (reader pool)
  UI/          # MenuBarExtra readout, drill-down panels, live Swift Charts, scrub, culprit view
  App/         # MomoServices composition root, AppDelegate lifecycle
  Support/     # hand-authored private-API bridging header + module map
```

Collectors and the store both depend *down* onto `Core/Sample`; GRDB row types live in `Store/` and
own the only knowledge of the on-disk schema. The governor depends only on the `SampleSink` — never
on the store or ring buffer directly.

## Gotchas

- **Private HID bridging on macOS 26** changed — see
  `docs/solutions/build-errors/iohideventsystemclient-bridging-header-collision.md` before touching
  `Momo/Support/Momo-Bridging-Header.h` or the sensor readers.
- **Per-process CPU ticks need a `mach_timebase_info` conversion on Apple Silicon** (KTD10).
- **Energy (R11) is a continuous constraint:** one coalesced wakeup, background QoS, detail
  collection paused when no panel is open. Verify with Activity Monitor "Idle Wake Ups" on battery.

## Knowledge & decision records

- `docs/plans/` — decision artifacts (the plan + its Key Technical Decisions, KTD1–KTD12). Progress
  lives in git, not in plan bodies.
- `docs/solutions/` — documented solutions to past problems (bugs, best practices, patterns),
  organized by category with YAML frontmatter (`module`, `tags`, `problem_type`). Relevant when
  implementing or debugging in a documented area.
- `docs/residual-review-findings/` — accepted-but-deferred code-review findings (with proper-fix
  notes) — check before assuming an edge case is unhandled.
