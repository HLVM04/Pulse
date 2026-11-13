import PulseCore
import SwiftUI

extension Color {
    static let claudeCoral = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.93, green: 0.55, blue: 0.42, alpha: 1)
            : NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    })

    static func provider(_ provider: String) -> Color {
        switch provider {
        case "claude": .claudeCoral
        case "codex": Color(nsColor: .systemTeal)
        case "gemini", "gemini-cli", "antigravity": Color(nsColor: .systemBlue)
        default: Color(nsColor: .systemIndigo)
        }
    }
}

struct ProviderGlyph: View {
    let provider: String
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: provider == "claude" ? "asterisk" : provider == "codex" ? "hexagon" : "sparkle")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(Color.provider(provider))
    }
}

/// Section title in the panel: small, secondary, with an optional trailing action.
struct SectionHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

/// A small glyph and text: how Pulse shows metadata instead of separators.
struct MetaLabel: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.tertiary)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }
}

/// A rounded app-icon-like tile holding one glyph.
struct IconTile: View {
    let symbol: String
    var tint: Color = .orange
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(.quaternary)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: size, height: size)
    }
}

/// Label above a value, with an optional third line.
struct StatCell: View {
    let label: String
    let value: String
    var detail: String? = nil
    var detailTint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit().lineLimit(1)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(detailTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A full-width row button with a soft hover highlight.
struct RowButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PanelSection<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
    }
}

struct PanelDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 14).opacity(0.6)
    }
}

/// A quiet card for "connect this" and "nothing here" states.
struct NoticeCard<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    var tint: Color = .secondary
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                IconTile(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 14, style: .continuous))
    }
}
