import SwiftUI
import LifeTrackerCore

struct TimelineRowView: View {
    let item: TimelineItem
    let tz: TimeZone

    var body: some View {
        switch item {
        case .event(let layout):
            EventRow(layout: layout, tz: tz)
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

    private var event: Event { layout.event }
    private var category: LifeTrackerCore.Category? { layout.category }
    private var isPlanned: Bool { event.state == EventState.planned.rawValue }
    private var isOpen: Bool { event.endAt == nil && !isPlanned }
    private var color: Color { .category(category?.colorHex) }

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
        .opacity(isPlanned ? 0.9 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yLabel)
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
