# Known Residuals — Tier 2 code review (feat/momo-system-monitor)

Source: 6-persona `ce-code-review` (correctness, swift-ios, adversarial, performance,
reliability, maintainability) over the full ~8,600-line feature diff vs `main`.
Verdict: no P0s; correctness verified the schema, delta math, tier selection, gap
detection, and rollup denominators as sound.

The **safe, high-value findings were applied** (commit `fix(review): apply Tier 2
code-review findings`) and the **irreversible per-process `value` deflation was fixed**
(commit `fix(store): per-process value denominator = recorded attribution-sample count`).

The findings below were **deliberately deferred** (accepted by the author at the Residual
Work Gate). None block shipping; they are refinements, niche edge cases, test hygiene, or
items requiring hardware/observation Momo doesn't have. Severity is the reviewer's.

## Deferred findings

### P1
- **First 48h prune commits as one transaction (WAL spike).** `Rollup.prune` batches DELETEs
  by ts-range, but all batches run inside the enclosing `dbPool.write`, so the WAL holds every
  freed page until commit (amplified by `secure_delete=ON`). The first prune after 48h of
  recording is a one-time, bounded, transient spike — not data loss. *Proper fix:* commit each
  prune batch in its own `dbPool.write` (or checkpoint between batches), which means decoupling
  `prune` from the cascade transaction. `Momo/Store/Rollup.swift` `prune`.
- **`try!` on `ProcessAttributionCollector` init crashes the app on libproc struct-stride drift.**
  Intentional ("refuse to record corrupt attribution", KTD5), but a macOS update that shifts
  `proc_taskinfo`/`rusage_info_current` layout would crash-on-launch forever. *Proper fix:*
  catch, log, and run with attribution disabled (governor accepts an optional attribution
  collector; `tick()` already guards `attribution` with `try?`). Very low-probability trigger
  (ABI-stable structs). `Momo/App/MomoServices.swift`.
- **Three parallel `ScalarRow` scalar-extractors.** `DrillTarget.historicalScalar`,
  `Subsystem.recordedScalar` (CulpritView), and `PanelData.scalarValue` implement the same
  per-metric projection from three starting points and could silently diverge. Currently
  consistent. *Proper fix:* one canonical `scalarProjection(_:metric:)` on `ScalarRow`.
- **SMCKeyData Intel stride unverified vs the C ABI (OQ9).** Swift packs to 76 bytes; the live
  IOKit struct method may expect the 80-byte C layout. Intel is fixture-tested only and
  best-effort by design — no Intel hardware to validate. Needs a live Intel run before trusting
  Intel temperature reads. `Momo/Sensors/SMCReader.swift`.
- **`coarseBucketStarts` `SELECT DISTINCT ts` scan.** Flagged as scanning the full sealed 1s
  tier each cascade. *Mitigated:* `ts` is the PRIMARY KEY, so it's a fast index-only scan, and
  the cascade is now minute-gated (runs once/minute). Actual cost is low; a lower-bound
  optimization was declined because a too-aggressive bound risks missing a bucket (coarser-tier
  data loss) — worse than the marginal gain. `Momo/Store/Rollup.swift`.
- **`FakeTimer.fire()` runs `tick()` on the test thread** (test-only). Violates the governor's
  queue-confinement contract; passes today (single-threaded tests + the `gov.plan` barrier) but
  would trip TSan. *Proper fix:* a `tickSync()` on the governor (`queue.sync { tick() }`) that
  tests call instead of `timer.fire()`. `MomoTests/PollingGovernorTests.swift`.

### P2
- **authoritativeReset leaves orphan future-dated rows.** A sustained backward clock correction
  (stale RTC) seals the future-dated tail but never deletes/overwrites the non-colliding future
  rows; they age-prune against their own future ts and persist, so a history query over that
  future range renders phantom data. Rare path. *Proper fix:* on authoritative reset, delete
  finer-tier rows with `ts > corrected sampleTs`. `Momo/Store/RecordingStore.swift`.
- **`RingBuffer.removeFirst` is O(n) per tick at capacity.** A ~1800-element array memmove every
  1–2s. Microseconds in absolute terms. *Proper fix:* a head-index ring. `Momo/UI/LiveModel.swift`.
- **`PanelData.sample(.at)` / `.series(.at)` are permanently-nil dead branches** (historical
  resolution moved to `HistoricalResolver`). *Proper fix:* drop the `ViewTime` param from those
  live-path-only helpers. `Momo/UI/DrillDownPanel.swift`.
- **`MetricFormat` lives in `MenuBarReadout.swift`** but is consumed by four UI files. *Proper
  fix:* move to `Momo/UI/MetricFormat.swift`.
- **Store-open failure produces a nil store with no UI indicator.** Best-effort recording is
  intentional, and the failure is now logged; a "Recording unavailable" UI affordance (and
  surfacing `StoreError.databaseTooNew`) is deferred. `Momo/App/MomoServices.swift`.
- **`flushPending()` runs `queue.sync` + a write on the main thread at terminate.** With a large
  buffer on a loaded system this could approach the OS graceful-termination watchdog. Buffer is
  ≤1s of data, so low risk. `Momo/Store/RecordingStore.swift`.

### P3
- **`CulpritResolver.live` binds a selection to an arbitrarily-far ring sample** with no
  proximity bound — a selection over missing live data can mis-attribute from a distant sample.
  *Proper fix:* reject matches beyond one detail-cadence interval → degrade to "no data".
  `Momo/UI/CulpritView.swift`.
- **`SensorProbe.init` does blocking IOKit service enumeration on `@MainActor` at launch**,
  delaying the menu-bar icon. The governor already tolerates a nil probe (probe-gated ingest),
  so the probe can be built in a background `Task` and assigned async. `Momo/App/MomoServices.swift`.
- **`HistoryQuery.observe` pins the tier at observation-creation time.** A scrubber observation
  left open until its 1s window ages past 48h keeps querying the pruned 1s tier and renders a
  blank chart until reopened. `Momo/History/HistoryQuery.swift`.

## Accepted residual risks (no action)
- SIGKILL/power-loss loses ≤1 finest bucket by design (KTD2 durability bound).
- WAL can grow under a perpetually-open reader until the next successful checkpoint (correct
  SQLite behavior; checkpoint is best-effort).
- Hot-unplugged USB sensors keep their slot in the fixed `availableTemperatureKeys` for the
  session; the "N of M available" count is stale until relaunch (correct "absent" value behavior).
