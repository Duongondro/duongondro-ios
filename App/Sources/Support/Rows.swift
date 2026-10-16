import SwiftUI

/// A label and its value or control: side by side when each fits on one line,
/// otherwise the control goes under the label. Longer languages (French, German),
/// larger text and narrower phones get a stacked row instead of a label squeezed
/// into a narrow column beside a picker, a field or a long value.
struct FittingRow<Label: View, Control: View>: View {
    var spacing: CGFloat = Theme.Space.s
    /// Where the control sits when stacked under the label.
    var stackedAlignment: HorizontalAlignment = .leading
    @ViewBuilder var label: () -> Label
    @ViewBuilder var control: () -> Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // The label keeps its one-line width here, so this branch is taken only
            // when it really fits: a greedy control can never squeeze it to nothing.
            HStack(spacing: spacing) {
                label()
                    .fixedSize()
                Spacer(minLength: spacing)
                control()
            }
            VStack(alignment: stackedAlignment, spacing: Theme.Space.xs) {
                label()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                control()
            }
        }
    }
}

/// Buttons or other pieces in a row when they fit on one line each, otherwise one
/// under the other, leading.
struct FittingStack<Content: View>: View {
    var spacing: CGFloat = Theme.Space.m
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { content() }
            VStack(alignment: .leading, spacing: spacing) { content() }
        }
    }
}
