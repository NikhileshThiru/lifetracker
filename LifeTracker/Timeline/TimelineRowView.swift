import SwiftUI
import UIKit
import LifeTrackerCore

struct TimelineRowView: View {
    let item: TimelineItem
    let tz: TimeZone
    /// Commits a drag-edge retime: (event, newStart?, newEnd?) — one is non-nil.
    var onAdjust: ((Event, Int64?, Int64?) -> Void)? = nil

    var body: some View {
        switch item {
        case .event(let layout):
            EventRow(layout: layout, tz: tz, onAdjust: onAdjust)
        case .gap(let gap):
            GapRow(gap: gap, tz: tz)
        case .nowMarker(let ms):
            NowMarkerRow(ms: ms, tz: tz)
        }
    }
}

private struct NowMarkerRow: View {
    let ms: Int64
    let tz: TimeZone

    var body: some View {
        HStack(spacing: 12) {
            Text(TimeFormat.clock(ms, tz: tz))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.now)
                .frame(width: Theme.timeColumnWidth, alignment: .trailing)
            Circle().fill(Theme.now).frame(width: 7, height: 7)
            Rectangle().fill(Theme.now.opacity(0.5)).frame(height: 1)
        }
        .padding(.vertical, 2)
        .accessibilityHidden(true)
    }
}

private struct EventRow: View {
    let layout: EventLayout
    let tz: TimeZone
    var onAdjust: ((Event, Int64?, Int64?) -> Void)? = nil

    private enum DragEdge { case start, end }
    @State private var dragEdge: DragEdge?
    @State private var dragMinutes = 0

    private var event: Event { layout.event }
    private var category: LifeTrackerCore.Category? { layout.category }
    private var isPlanned: Bool { event.state == EventState.planned.rawValue }
    private var isOpen: Bool { event.endAt == nil && !isPlanned }
    private var color: Color { .category(category?.colorHex) }

    // Drag-the-edges (spec §4): long-press an edge, then drag in 5-min steps.
    // Edges clipped by the day boundary aren't draggable from this day's view.
    private var canDragStart: Bool {
        onAdjust != nil && event.startAt != nil && !layout.continuesBefore
    }
    private var canDragEnd: Bool {
        onAdjust != nil && event.endAt != nil && !layout.continuesAfter
    }

    /// Reconciliation marks blocks whose boundaries were inferred (not stated)
    /// with confidence < 1 — surface that as an "≈" so the times read as editable.
    private var isApproximate: Bool { !isPlanned && event.confidence < 1.0 }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(layout.displayStart.map { (isApproximate ? "≈" : "") + TimeFormat.clock($0, tz: tz) } ?? "—")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Theme.timeColumnWidth, alignment: .trailing)

            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 4)
                .opacity(isPlanned ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 4) {
                if layout.continuesBefore {
                    ContinuationLabel(system: "arrow.up", text: "from yesterday")
                }
                Text(event.title ?? category?.name ?? "Untitled")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                if layout.continuesAfter {
                    ContinuationLabel(system: "arrow.down", text: "continues")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.surface))
        .overlay {
            if isPlanned {
                RoundedRectangle(cornerRadius: Theme.corner)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(Theme.hairline)
            }
        }
        .overlay(alignment: .top) { if canDragStart { dragHandle(.start) } }
        .overlay(alignment: .bottom) { if canDragEnd { dragHandle(.end) } }
        .overlay(alignment: dragEdge == .start ? .topTrailing : .bottomTrailing) {
            if dragEdge != nil { dragLabel }
        }
        .opacity(isPlanned ? 0.9 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
    }

    // MARK: Drag-edge editing

    private func dragHandle(_ edge: DragEdge) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 16)
            .frame(maxWidth: .infinity)
            .overlay(alignment: edge == .start ? .top : .bottom) {
                Capsule()
                    .fill(Theme.textSecondary.opacity(dragEdge == edge ? 0.9 : 0.25))
                    .frame(width: 28, height: 3)
                    .padding(edge == .start ? .top : .bottom, 4)
            }
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.25)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        guard case .second(true, let drag) = value else { return }
                        if dragEdge != edge {
                            dragEdge = edge
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                        guard let drag else { return }
                        // ~1.5pt per minute, snapped to 5-minute steps.
                        let raw = Int((drag.translation.height / 1.5).rounded())
                        let snapped = (raw / 5) * 5
                        if snapped != dragMinutes {
                            dragMinutes = snapped
                            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
                        }
                    }
                    .onEnded { _ in
                        commitDrag(edge)
                        dragEdge = nil
                        dragMinutes = 0
                    }
            )
            .accessibilityHidden(true)   // VoiceOver retimes via the edit sheet
    }

    private var dragLabel: some View {
        Text(draggedTimeText)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.accent))
            .padding(6)
            .allowsHitTesting(false)
    }

    private var draggedTimeText: String {
        let delta = Int64(dragMinutes) * 60_000
        switch dragEdge {
        case .start:
            let base = event.startAt ?? 0
            return "starts \(TimeFormat.clock(clampedStart(base + delta), tz: tz))"
        case .end:
            let base = event.endAt ?? 0
            return "ends \(TimeFormat.clock(clampedEnd(base + delta), tz: tz))"
        case nil:
            return ""
        }
    }

    private func clampedStart(_ proposed: Int64) -> Int64 {
        guard let end = event.endAt else { return proposed }
        return min(proposed, end - 5 * 60_000)   // keep at least 5 minutes
    }

    private func clampedEnd(_ proposed: Int64) -> Int64 {
        guard let start = event.startAt else { return proposed }
        return max(proposed, start + 5 * 60_000)
    }

    private func commitDrag(_ edge: DragEdge) {
        guard dragMinutes != 0, let onAdjust else { return }
        let delta = Int64(dragMinutes) * 60_000
        switch edge {
        case .start:
            guard let s = event.startAt else { return }
            onAdjust(event, clampedStart(s + delta), nil)
        case .end:
            guard let e = event.endAt else { return }
            onAdjust(event, nil, clampedEnd(e + delta))
        }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    private var subtitle: String {
        var parts: [String] = []
        // Don't repeat the category when the title already is it ("Sleep · Sleep").
        if let name = category?.name,
           name.localizedCaseInsensitiveCompare(event.title ?? "") != .orderedSame {
            parts.append(name)
        }
        if let dur = durationText { parts.append(dur) }
        if isPlanned { parts.append("planned") }
        if isOpen { parts.append("in progress") }
        return parts.joined(separator: " · ")
    }

    /// Duration of this day's slice (clipped), so an overnight block reads "6h" today, not 11h.
    private var durationText: String? {
        guard let start = layout.displayStart, let end = layout.displayEnd, end > start else { return nil }
        return TimeFormat.duration(end - start)
    }

    private var a11yLabel: String {
        var parts = [event.title ?? category?.name ?? "Untitled"]
        if layout.continuesBefore { parts.append("continued from yesterday") }
        if let start = layout.displayStart {
            parts.append("from \(isApproximate ? "about " : "")\(TimeFormat.clock(start, tz: tz))")
        }
        if let dur = durationText { parts.append(dur) }
        if isPlanned { parts.append("planned") }
        if isOpen { parts.append("in progress") }
        if layout.continuesAfter { parts.append("continues into tomorrow") }
        return parts.joined(separator: ", ")
    }
}

/// Small dim marker showing an activity spills across a day boundary.
private struct ContinuationLabel: View {
    let system: String
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: system).font(.system(size: 9, weight: .semibold))
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(Theme.textSecondary)
        .accessibilityHidden(true)
    }
}

private struct GapRow: View {
    let gap: Gap
    let tz: TimeZone

    private var isSleep: Bool { gap.kind == .sleepCandidate }

    var body: some View {
        HStack(spacing: 12) {
            Text(TimeFormat.clock(gap.startAt, tz: tz))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Theme.timeColumnWidth, alignment: .trailing)

            Image(systemName: isSleep ? "moon.zzz.fill" : "plus.circle")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(isSleep ? "Asleep?" : "Free time")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(TimeFormat.duration(gap.endAt - gap.startAt)) · tap to \(isSleep ? "confirm" : "fill")")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.corner)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                .foregroundStyle(Theme.hairline)
        }
        .accessibilityElement(children: .combine)
    }
}
