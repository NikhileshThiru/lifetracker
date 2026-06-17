import SwiftUI
import LifeTrackerCore

struct TimelineRowView: View {
    let item: TimelineItem
    let tz: TimeZone

    var body: some View {
        switch item {
        case .event(let event, let category):
            EventRow(event: event, category: category, tz: tz)
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
    let event: Event
    let category: LifeTrackerCore.Category?
    let tz: TimeZone

    private var isPlanned: Bool { event.state == EventState.planned.rawValue }
    private var isOpen: Bool { event.endAt == nil && !isPlanned }
    private var color: Color { .category(category?.colorHex) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(event.startAt.map { TimeFormat.clock($0, tz: tz) } ?? "—")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Theme.timeColumnWidth, alignment: .trailing)

            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 4)
                .opacity(isPlanned ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title ?? category?.name ?? "Untitled")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 5) {
                    if let name = category?.name { Text(name) }
                    if let dur = durationText { Text("· \(dur)") }
                    if isPlanned { Text("· planned") }
                    if isOpen { Text("· in progress") }
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
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
    }

    private var durationText: String? {
        guard let start = event.startAt, let end = event.endAt, end > start else { return nil }
        return TimeFormat.duration(end - start)
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
