import SwiftUI
import UIKit

/// A number pad has no return key. Every number-pad field in the app gets a bar with
/// Done attached to its keyboard, set as the field begins editing so it arrives with
/// the keyboard (SwiftUI's keyboard toolbar can show up a beat later, or not at all),
/// and a tap anywhere outside a text field closes any keyboard. Installed once, at
/// launch, for the whole app.
enum KeyboardDismissal {
    @MainActor private static var installed = false
    @MainActor private static let outsideTaps = OutsideTaps()

    @MainActor static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(forName: UITextField.textDidBeginEditingNotification,
                                               object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let field = note.object as? UITextField else { return }
                attachDone(to: field)
                outsideTaps.editing = field
                outsideTaps.attach(to: field.window)
            }
        }
        NotificationCenter.default.addObserver(forName: UITextView.textDidBeginEditingNotification,
                                               object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                outsideTaps.editing = note.object as? UIView
                outsideTaps.attach(to: (note.object as? UIView)?.window)
            }
        }
        // Only while a keyboard is up, so later taps (every +108) don't pass through it.
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillShowNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { outsideTaps.enabled = true }
        }
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidHideNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { outsideTaps.enabled = false }
        }
    }

    @MainActor private static func attachDone(to field: UITextField) {
        guard [.numberPad, .decimalPad, .phonePad, .asciiCapableNumberPad].contains(field.keyboardType),
              !(field.inputAccessoryView is DoneBar) else { return }
        field.inputAccessoryView = DoneBar()
        field.reloadInputViews()
    }

    @MainActor static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// The bar above a number pad: Done on the trailing side, in the app's language.
private final class DoneBar: UIToolbar {
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        let done = UIBarButtonItem(title: String(localized: "Done", bundle: .appLanguage, locale: .appLanguage),
                                   primaryAction: UIAction { _ in KeyboardDismissal.dismiss() })
        done.style = .done
        done.tintColor = UIColor(Theme.accent)
        items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
        sizeToFit()
    }

    required init?(coder: NSCoder) { nil }
}

/// One tap recogniser per window: a tap outside any text field closes the keyboard,
/// and still reaches whatever was tapped.
@MainActor private final class OutsideTaps: NSObject, UIGestureRecognizerDelegate {
    private var windows: [ObjectIdentifier: UITapGestureRecognizer] = [:]
    /// The field being edited: a tap just around it (a padded box that focuses it on
    /// tap) keeps the keyboard.
    weak var editing: UIView?
    var enabled = false {
        didSet { windows.values.forEach { $0.isEnabled = enabled } }
    }

    func attach(to window: UIWindow?) {
        guard let window, windows[ObjectIdentifier(window)] == nil else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        tap.isEnabled = enabled
        window.addGestureRecognizer(tap)
        windows[ObjectIdentifier(window)] = tap
    }

    @objc private func tapped() { KeyboardDismissal.dismiss() }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        MainActor.assumeIsolated {
            // The edit menu (Paste, Copy) may sit in this window or another one.
            guard let window = gestureRecognizer.view, touch.view?.window === window else { return false }
            var view = touch.view
            while let v = view {
                if v is UITextField || v is UITextView { return false }
                let name = String(describing: type(of: v))
                if name.contains("Menu") || name.contains("Callout") { return false }
                view = v.superview
            }
            if let field = editing, field.window === window,
               field.convert(field.bounds, to: window).insetBy(dx: -24, dy: -24)
                   .contains(touch.location(in: window)) {
                return false
            }
            return true
        }
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

extension View {
    /// Dragging the screen's content closes the keyboard too. The Done bar and the
    /// tap outside come from `KeyboardDismissal`, for every screen.
    func numberPadDone() -> some View { scrollDismissesKeyboard(.interactively) }
}
