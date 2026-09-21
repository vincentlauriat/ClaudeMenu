import SwiftUI

/// Native look, à la Juicy: the MenuBarExtra window already provides the translucent
/// material; cards are subtle tinted rounded rectangles that follow light/dark mode.
enum Theme {
    static let panelWidth: CGFloat = 340
    static let cardRadius: CGFloat = 14
    static let cardFill = Color.primary.opacity(0.07)
    static let cardStroke = Color.primary.opacity(0.06)
    static let track = Color.primary.opacity(0.12)

    /// Green while comfortable, orange when it gets tight, red when over.
    static func tone(used: Double) -> Color {
        used >= 100 ? .red : (used >= 80 ? .orange : .green)
    }
    /// Only a meaningful projection may darken the tone; otherwise judge on usage alone.
    static func tone(used: Double, landing: Double?) -> Color {
        guard let landing, landing > 100 else { return tone(used: used) }
        return used >= 80 ? .red : .orange
    }
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .stroke(Theme.cardStroke, lineWidth: 0.5))
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// Juicy-style segmented bar: a rounded track with quarter ticks.
struct SegmentedBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
                HStack(spacing: 0) {
                    ForEach(1..<4) { i in
                        Spacer()
                        Rectangle().fill(Color.black.opacity(0.25)).frame(width: 1)
                            .opacity(Double(i) / 4 < fraction ? 1 : 0)
                    }
                    Spacer()
                }
            }
        }
        .frame(height: 8)
    }
}

/// A collapsible section header with a chevron, like Juicy's "Informations sur la batterie".
/// Named `DisclosureCard` so it never shadows `SwiftUI.Section`.
struct DisclosureCard<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    @Binding var expanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 22)
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(spacing: 0) { content }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .card()
    }
}

/// "Libellé ……… valeur" row inside a section.
struct InfoRow: View {
    let label: String
    let value: String
    var tint: Color? = nil
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint ?? .primary)
                    .multilineTextAlignment(.trailing)
            }
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Settings-list row with a leading SF Symbol, like Juicy's bottom list.
struct ActionRow<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .medium))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
    }
}

extension ActionRow where Trailing == EmptyView {
    init(icon: String, iconColor: Color, title: String, subtitle: String? = nil) {
        self.init(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle) { EmptyView() }
    }
}
