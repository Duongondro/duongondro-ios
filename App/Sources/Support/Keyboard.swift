import SwiftUI
import UIKit

/// A number pad has no return key, so a screen with a number field gets a Done button
/// above the keyboard, and dragging its content closes the keyboard too. Attach once per
/// screen, not per field: SwiftUI shows one button for every keyboard toolbar in view.
private struct NumberPadDone: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
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

extension View {
    func numberPadDone() -> some View { modifier(NumberPadDone()) }
}
