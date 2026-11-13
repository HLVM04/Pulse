import AppKit

/// Draws the menubar item: a ring that fills with the quota pool, a solid
/// center while threads run, a count, and an orange badge when a thread waits.
/// Monochrome states are template images so they follow the menubar's look.
enum StatusIcon {
    static func image(
        fraction: Double?,
        poolUnits: Double?,
        activeCount: Int,
        waiting: Bool,
        low: Bool,
        stale: Bool
    ) -> NSImage {
        let height: CGFloat = 18
        let ring: CGFloat = 16
        let font = roundedFont(size: 12.5, weight: .semibold)
        let text: String = if low, let poolUnits { "\(Int(poolUnits.rounded()))%" } else if activeCount > 0 { "\(activeCount)" } else { "" }
        let textWidth = text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let badgeSpace: CGFloat = waiting ? 5 : 0
        let width = ring + (text.isEmpty ? 0 : 4 + textWidth) + badgeSpace
        let colored = waiting || low

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let ink: NSColor = colored ? (dark ? .white : .black) : .black
            let red = NSColor.systemRed
            let center = NSPoint(x: ring / 2, y: height / 2)
            let radius: CGFloat = 6

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.8
            ink.withAlphaComponent(fraction == nil || stale ? 0.25 : 0.32).setStroke()
            track.stroke()

            if let fraction, fraction > 0.004 {
                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: center, radius: radius,
                    startAngle: 90, endAngle: 90 - 360 * CGFloat(min(1, fraction)), clockwise: true
                )
                arc.lineWidth = 1.8
                arc.lineCapStyle = .round
                (low ? red : ink.withAlphaComponent(stale ? 0.5 : 1)).setStroke()
                arc.stroke()
            }

            if activeCount > 0 {
                ink.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 2.1, y: center.y - 2.1, width: 4.2, height: 4.2)).fill()
            }

            if !text.isEmpty {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: low ? red : ink]
                let size = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(at: NSPoint(x: ring + 4, y: (height - size.height) / 2), withAttributes: attributes)
            }

            if waiting {
                let dot = NSRect(x: width - 6, y: height - 7.5, width: 6, height: 6)
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = !colored
        image.accessibilityDescription = accessibility(fraction: fraction, activeCount: activeCount, waiting: waiting)
        return image
    }

    private static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private static func accessibility(fraction: Double?, activeCount: Int, waiting: Bool) -> String {
        var parts = ["Pulse"]
        if let fraction { parts.append("\(Int((fraction * 100).rounded())) percent of quota left") }
        if activeCount > 0 { parts.append("\(activeCount) threads running") }
        if waiting { parts.append("a thread is waiting for you") }
        return parts.joined(separator: ", ")
    }
}
