import SwiftUI

/// The current platform look on each iOS version, degrading to iOS 16
/// (design: Look › Modern on every iOS version). One layout per screen: every
/// `#available` lives in a helper here, never in a forked screen.
///
/// - iOS 26: Liquid Glass on floating controls and the main buttons.
/// - iOS 17–18: sensory feedback, symbol effects, scroll transitions.
/// - iOS 16: the same layouts with plain fills and UIKit haptics.
extension View {
    /// A light tap per count added.
    @ViewBuilder
    func countTapFeedback<T: Equatable>(trigger: T) -> some View {
        if #available(iOS 17.0, *) {
            sensoryFeedback(.increase, trigger: trigger)
        } else {
            onChange(of: trigger) { _ in UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
    }

    /// A success tap when `trigger` turns true, e.g. a day's first practice.
    @ViewBuilder
    func successFeedback(trigger: Bool) -> some View {
        if #available(iOS 17.0, *) {
            sensoryFeedback(.success, trigger: trigger) { old, new in !old && new }
        } else {
            onChange(of: trigger) { done in if done { UINotificationFeedbackGenerator().notificationOccurred(.success) } }
        }
    }

    /// A bounce on an SF Symbol whenever `value` changes (iOS 17+; still on 16).
    @ViewBuilder
    func symbolBounce<T: Equatable>(value: T) -> some View {
        if #available(iOS 17.0, *) {
            symbolEffect(.bounce, value: value)
        } else {
            self
        }
    }

    /// Rows ease in and out at the edges of a scroll view (iOS 17+).
    @ViewBuilder
    func edgeScrollTransition() -> some View {
        if #available(iOS 17.0, *) {
            scrollTransition(.animated) { content, phase in
                content
                    .opacity(phase.isIdentity ? 1 : 0.6)
                    .scaleEffect(phase.isIdentity ? 1 : 0.97)
            }
        } else {
            self
        }
    }

    /// A control that floats above content, such as the Undo bar: glass on
    /// iOS 26, the card fill before it.
    @ViewBuilder
    func floatingBar() -> some View {
        if #available(iOS 26.0, *) {
            padding(Theme.Space.l)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        } else {
            cardStyle()
        }
    }

    /// The filled main action: tinted glass on iOS 26, a bordered prominent
    /// button before it. Corner radius `radius` either way.
    @ViewBuilder
    func primaryButtonStyle(radius: CGFloat = Theme.Radius.card) -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
                .buttonBorderShape(.roundedRectangle(radius: radius))
        } else {
            buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: radius))
        }
    }

    /// The secondary action beside a primary one: glass on iOS 26, bordered before.
    @ViewBuilder
    func secondaryButtonStyle(radius: CGFloat = Theme.Radius.card) -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: radius))
        } else {
            buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: radius))
        }
    }
}

extension View {
    /// Keeps iOS 26's scroll-edge blur off a button pinned under a scroll view.
    @ViewBuilder
    func plainBottomEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: .bottom)
        } else {
            self
        }
    }
}

extension View {
    /// A sheet's own background colour (iOS 16.4+); earlier, the content's.
    @ViewBuilder
    func sheetBackground(_ color: Color) -> some View {
        if #available(iOS 16.4, *) {
            presentationBackground(color)
        } else {
            background(color.ignoresSafeArea())
        }
    }
}
