import SwiftUI
import UIKit

/// A number pad has no return key, so a screen with a number field gets a Done button
/// above the keyboard, and dragging its content closes the keyboard too. Attach once per
/// screen, not per field: SwiftUI shows one button for every keyboard toolbar in view.
/// The button is offered only while its screen is on top, so a screen pushed over one
/// that has it (Settings › practice settings) never shows two.
private struct NumberPadDone: ViewModifier {
    @State private var onTop = false

    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .onAppear { onTop = true }
            .onDisappear { onTop = false }
            .toolbar {
                if onTop {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
    }
}

extension View {
    func numberPadDone() -> some View { modifier(NumberPadDone()) }
}
