import SwiftUI

/// The mockups' flat buttons: a filled one for the main action, an outlined one
/// beside it, a soft-filled one for the least important. Small corners (6 pt),
/// full width unless the caller narrows them.
struct FilledButtonStyle: ButtonStyle {
    var fill: Color = Theme.accent
    var ink: Color = Theme.onAccent
    var height: CGFloat = Theme.Size.welcomeButton

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct OutlinedButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var height: CGFloat = Theme.Size.welcomeButton

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(tint, lineWidth: 2))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct SoftButtonStyle: ButtonStyle {
    var height: CGFloat = Theme.Size.secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(Theme.softFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// A two-way choice on a soft track, the selected side raised (or filled).
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var filled = false
    var height: CGFloat = 36

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Button { selection = value } label: {
                    Text(title)
                        .font(.subheadline.weight(on ? .bold : .semibold))
                        .foregroundStyle(on ? (filled ? Theme.onAccent : Theme.ink) : Theme.soft)
                        .frame(maxWidth: .infinity, minHeight: height)
                        .background(on ? (filled ? Theme.accent : Theme.card) : .clear,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(Theme.Space.xs)
        .background(Theme.softFill, in: RoundedRectangle(cornerRadius: filled ? Theme.Radius.card : Theme.Radius.small, style: .continuous))
    }
}

/// A thin progress bar in the accent colour.
struct Bar: View {
    let fraction: Double
    var height: CGFloat = Theme.Size.barThin

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(Theme.accent).frame(width: g.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Grouped rows on a white card, as in the mockups' lists: uppercase header,
/// hairlines between rows, an optional footnote.
struct CardSection<Content: View>: View {
    var header: LocalizedStringKey?
    var footer: LocalizedStringKey?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if let header {
                Text(header)
                    .font(.footnote.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, Theme.Space.l)
            }
            VStack(spacing: 0) {
                _VariadicView.Tree(DividedLayout()) { content }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, Theme.Space.l)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DividedLayout: _VariadicView_MultiViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
                .padding(.horizontal, Theme.Space.l)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.minTap, alignment: .leading)
            if child.id != last {
                Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, Theme.Space.l)
            }
        }
    }
}
