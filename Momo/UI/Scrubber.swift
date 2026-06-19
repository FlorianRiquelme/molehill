//
//  Scrubber.swift
//  The scrub-back timeline control (U10, R8 / OQ4 / OQ5). A distinct timeline below the chart
//  that maps a horizontal drag to a `ViewTime.at(Date)`; an explicit "Live" jump-to-now button
//  appears whenever the scrub position is off the trailing edge and returns the panel to
//  `.live` (OQ4). Recorded gaps are dimmed/hatched on the track and are draggable THROUGH, not
//  blocked (OQ5) — the panel body shows the "device was asleep" state when the cursor parks in
//  a gap (handled by the panel, driven by `ScrubFrame.cursorInGap`).
//
//  This control is purely presentational: it owns no history reads. It is handed a `ScrubFrame`
//  (the resolved window + gap segments, computed by the panel's `.at` resolution) and reports
//  drag positions back as `Date`s via callbacks. Keeping the read out of the control keeps the
//  governor/ingest path untouched (the historical read is independent of live collection).
//
import SwiftUI

// MARK: - Timeline model

/// A normalized gap segment on the scrub track, in 0...1 of the visible window (OQ5).
struct ScrubGap: Equatable {
    /// Fractional start/end of the gap across the track (0 = window start, 1 = window end).
    let startFraction: Double
    let endFraction: Double
}

/// Everything the scrubber needs to draw one window: the time bounds it spans, the gap
/// segments to hatch, and whether the oldest edge is the truncation boundary (no older data,
/// `HistorySeries.truncatedToOldest`). Computed by the panel from a `HistorySeries`.
struct ScrubFrame: Equatable {
    /// Earliest time the track represents (left edge).
    let windowStart: Date
    /// Latest time the track represents (right edge = "now" / live edge).
    let windowEnd: Date
    /// Dimmed/hatched gap regions (OQ5).
    let gaps: [ScrubGap]
    /// True when `windowStart` is the oldest retained data — scrubbing left of here is clamped.
    let truncatedToOldest: Bool

    /// Whether `date` falls inside a recorded gap (drives the panel's "device was asleep" body).
    func cursorInGap(_ date: Date) -> Bool {
        let f = fraction(for: date)
        return gaps.contains { f >= $0.startFraction && f <= $0.endFraction }
    }

    /// Map a date in `[windowStart, windowEnd]` to a 0...1 track fraction.
    func fraction(for date: Date) -> Double {
        let span = windowEnd.timeIntervalSince(windowStart)
        guard span > 0 else { return 1 }
        let f = date.timeIntervalSince(windowStart) / span
        return min(max(f, 0), 1)
    }

    /// Map a 0...1 track fraction to a date in `[windowStart, windowEnd]`.
    func date(forFraction f: Double) -> Date {
        let span = windowEnd.timeIntervalSince(windowStart)
        return windowStart.addingTimeInterval(span * min(max(f, 0), 1))
    }
}

// MARK: - Scrubber control

/// The timeline + cursor. Dragging anywhere on the track sets `viewTime = .at(date)`; the
/// "Live" button (shown only when scrubbed off the trailing edge) returns to `.live` (OQ4).
struct Scrubber: View {
    let frame: ScrubFrame
    /// The current view time; `.live` parks the cursor at the trailing edge.
    let viewTime: ViewTime
    /// Called as the cursor moves (drag) — the panel sets `viewTime = .at(date)`.
    let onScrub: (Date) -> Void
    /// Called by the "Live" button — the panel sets `viewTime = .live`.
    let onReturnToLive: () -> Void

    /// Cursor fraction across the track for the current view time.
    private var cursorFraction: Double {
        switch viewTime {
        case .live: return 1
        case .at(let date): return frame.fraction(for: date)
        }
    }

    private var isScrubbed: Bool {
        if case .at = viewTime { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    // Track.
                    Capsule().fill(.quaternary.opacity(0.4))

                    // Gap segments — dimmed + hatched, draggable through (OQ5).
                    ForEach(Array(frame.gaps.enumerated()), id: \.offset) { _, gap in
                        let x = gap.startFraction * width
                        let w = max(2, (gap.endFraction - gap.startFraction) * width)
                        GapHatch()
                            .frame(width: w)
                            .offset(x: x)
                    }

                    // Cursor.
                    Circle()
                        .fill(isScrubbed ? Color.accentColor : .secondary)
                        .frame(width: 11, height: 11)
                        .offset(x: cursorFraction * width - 5.5)
                }
                .frame(height: 14)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let f = width > 0 ? value.location.x / width : 1
                            onScrub(frame.date(forFraction: f))
                        }
                )
            }
            .frame(height: 14)

            HStack {
                Text(timeLabel).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                if frame.truncatedToOldest {
                    Text("· oldest recorded").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                // OQ4: explicit jump-to-now, only when off the trailing edge.
                if isScrubbed {
                    Button("Live") { onReturnToLive() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .font(.caption2.bold())
                }
            }
        }
    }

    private var timeLabel: String {
        switch viewTime {
        case .live: return "Live"
        case .at(let date): return Self.formatter.string(from: date)
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm:ss"
        return f
    }()
}

/// Diagonal-hatch fill for a recorded gap region (OQ5 "dimmed/hatched").
private struct GapHatch: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.gray.opacity(0.18))
            GeometryReader { geo in
                Path { p in
                    let step: CGFloat = 5
                    var x: CGFloat = -geo.size.height
                    while x < geo.size.width {
                        p.move(to: CGPoint(x: x, y: geo.size.height))
                        p.addLine(to: CGPoint(x: x + geo.size.height, y: 0))
                        x += step
                    }
                }
                .stroke(.gray.opacity(0.35), lineWidth: 0.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
