import PulseCore
import SwiftUI

/// The pool burn-down chart: recorded level (solid) up to now, projection
/// (dashed) after, reset jumps labeled "+N%". Drawn with paths rather than
/// Swift Charts so jumps stay vertical and labels can be placed exactly.
struct PoolChart: View {
    let pool: PoolSummary
    var detailed = false

    private var color: Color { .provider(pool.provider) }

    var body: some View {
        GeometryReader { geometry in
            let frame = ChartFrame(pool: pool, size: geometry.size, detailed: detailed)
            ZStack(alignment: .topLeading) {
                grid(frame)
                fill(frame, points: pool.projected, opacity: 0.12)
                fill(frame, points: pool.recorded, opacity: 0.32)
                frame.path(pool.projected)
                    .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.4, dash: [3.5, 3]))
                frame.path(pool.recorded)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.7, lineJoin: .round))
                nowMarker(frame)
                resetLabels(frame)
                xLabels(frame)
            }
        }
        .frame(height: detailed ? 176 : 78)
        .accessibilityElement()
        .accessibilityLabel("\(pool.displayName) quota pool, \(Format.percent(pool.remainingNow)) of \(Format.percent(pool.capacity)) left")
    }

    private func fill(_ frame: ChartFrame, points: [SeriesPoint], opacity: Double) -> some View {
        frame.area(points).fill(
            LinearGradient(colors: [color.opacity(opacity), color.opacity(0.02)], startPoint: .top, endPoint: .bottom)
        )
    }

    @ViewBuilder private func grid(_ frame: ChartFrame) -> some View {
        if detailed {
            ForEach([1.0, 0.5, 0.0], id: \.self) { share in
                let y = frame.y(pool.capacity * share)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: frame.plotWidth, y: y))
                }
                .stroke(.primary.opacity(share == 0 ? 0.14 : 0.07), lineWidth: 0.5)
                Text(Format.percent(pool.capacity * share))
                    .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.tertiary)
                    .position(x: frame.size.width - 14, y: y)
            }
            ForEach(1..<14, id: \.self) { day in
                let x = frame.x(pool.rangeFromMs + Double(day) * PoolMath.dayMs)
                Path { path in
                    path.move(to: CGPoint(x: x, y: frame.top))
                    path.addLine(to: CGPoint(x: x, y: frame.bottom))
                }
                .stroke(.primary.opacity(0.035), lineWidth: 0.5)
            }
        } else {
            Path { path in
                path.move(to: CGPoint(x: 0, y: frame.bottom))
                path.addLine(to: CGPoint(x: frame.plotWidth, y: frame.bottom))
            }
            .stroke(.primary.opacity(0.14), lineWidth: 0.5)
        }
    }

    @ViewBuilder private func nowMarker(_ frame: ChartFrame) -> some View {
        let x = frame.x(pool.nowMs)
        Path { path in
            path.move(to: CGPoint(x: x, y: frame.top - 6))
            path.addLine(to: CGPoint(x: x, y: frame.bottom))
        }
        .stroke(.primary.opacity(0.3), lineWidth: 0.75)
        Circle()
            .fill(color)
            .overlay(Circle().stroke(.background, lineWidth: 1.5))
            .frame(width: 7, height: 7)
            .position(x: x, y: frame.y(pool.remainingNow))
    }

    @ViewBuilder private func resetLabels(_ frame: ChartFrame) -> some View {
        let labels = resetLabelLayout(frame)
        ForEach(labels.indices, id: \.self) { index in
            let label = labels[index]
            Text("+\(Format.percent(label.amount))")
                .font(.system(size: 9.5, weight: label.isNext ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(label.isNext ? AnyShapeStyle(color) : AnyShapeStyle(.secondary))
                .fixedSize()
                .position(x: label.x, y: frame.top - 8 - label.lift)
        }
    }

    private struct ResetLabel {
        var x: CGFloat
        var amount: Double
        var isNext: Bool
        var lift: CGFloat
    }

    private func resetLabelLayout(_ frame: ChartFrame) -> [ResetLabel] {
        let nextT = pool.nextReset?.t
        var resets = pool.projectedResets.map { (t: $0.t, amount: $0.amount, isNext: $0.t == nextT) }
        if detailed {
            resets = pool.recordedResets.map { (t: $0.t, amount: $0.amount, isNext: false) } + resets
        } else {
            resets = resets.filter(\.isNext)
        }
        var out: [ResetLabel] = []
        var lastX: CGFloat = -100
        var lift: CGFloat = 0
        for reset in resets.sorted(by: { $0.t < $1.t }) where reset.amount >= 0.5 {
            let x = min(max(frame.x(reset.t), 12), frame.plotWidth - 12)
            lift = x - lastX < 28 ? (lift == 0 ? 11 : 0) : 0
            lastX = x
            out.append(ResetLabel(x: x, amount: reset.amount, isNext: reset.isNext, lift: lift))
        }
        return out
    }

    @ViewBuilder private func xLabels(_ frame: ChartFrame) -> some View {
        let y = frame.bottom + 9
        if detailed {
            let todayIndex = Int(((pool.nowMs - pool.rangeFromMs) / PoolMath.dayMs).rounded(.down))
            ForEach([0, 3, 6, 9, 12], id: \.self) { day in
                let ms = pool.rangeFromMs + (Double(day) + 0.5) * PoolMath.dayMs
                Text(Format.dayLabel(ms))
                    .font(.system(size: 9.5, weight: day == todayIndex ? .semibold : .regular))
                    .foregroundStyle(day == todayIndex ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .fixedSize()
                    .position(x: frame.x(ms), y: y)
            }
        } else {
            Text(Format.date(pool.rangeFromMs)).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                .fixedSize().position(x: 18, y: y)
            Text("Now").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                .fixedSize().position(x: frame.x(pool.nowMs), y: y)
            Text(Format.date(pool.rangeToMs - 1)).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                .fixedSize().position(x: frame.plotWidth - 18, y: y)
        }
    }
}

/// Maps pool time and units to points in the chart.
private struct ChartFrame {
    let pool: PoolSummary
    let size: CGSize
    let top: CGFloat
    let bottom: CGFloat
    let plotWidth: CGFloat

    init(pool: PoolSummary, size: CGSize, detailed: Bool) {
        self.pool = pool
        self.size = size
        top = detailed ? 30 : 18
        bottom = size.height - 18
        plotWidth = size.width - (detailed ? 34 : 0)
    }

    func x(_ ms: Double) -> CGFloat {
        let span = pool.rangeToMs - pool.rangeFromMs
        guard span > 0 else { return 0 }
        return CGFloat((ms - pool.rangeFromMs) / span) * plotWidth
    }

    func y(_ units: Double) -> CGFloat {
        guard pool.capacity > 0 else { return bottom }
        let share = min(1, max(0, units / pool.capacity))
        return top + CGFloat(1 - share) * (bottom - top)
    }

    func path(_ points: [SeriesPoint]) -> Path {
        Path { path in
            for (index, point) in points.enumerated() {
                let location = CGPoint(x: x(point.t), y: y(point.v))
                if index == 0 { path.move(to: location) } else { path.addLine(to: location) }
            }
        }
    }

    func area(_ points: [SeriesPoint]) -> Path {
        guard let first = points.first, let last = points.last else { return Path() }
        var area = path(points)
        area.addLine(to: CGPoint(x: x(last.t), y: bottom))
        area.addLine(to: CGPoint(x: x(first.t), y: bottom))
        area.closeSubpath()
        return area
    }
}
