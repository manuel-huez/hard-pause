import SwiftUI

enum CaretTrackingTextFieldInputMode {
    case domain
    case name
}

// Reports the insertion point only. Typed content stays in the native binding.
#if os(iOS)
    import UIKit

    struct CaretTrackingTextField: UIViewRepresentable {
        let placeholder: String
        @Binding var text: String
        let accessibilityLabel: String
        let inputMode: CaretTrackingTextFieldInputMode
        let onSubmit: () -> Void
        let onCaretChange: (CGPoint?) -> Void

        init(
            _ placeholder: String, text: Binding<String>, accessibilityLabel: String = "Website domain",
            inputMode: CaretTrackingTextFieldInputMode = .domain,
            onSubmit: @escaping () -> Void,
            onCaretChange: @escaping (CGPoint?) -> Void
        ) {
            self.placeholder = placeholder
            _text = text
            self.accessibilityLabel = accessibilityLabel
            self.inputMode = inputMode
            self.onSubmit = onSubmit
            self.onCaretChange = onCaretChange
        }

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIView(context: Context) -> UITextField {
            let field = UITextField()
            field.delegate = context.coordinator
            field.placeholder = placeholder
            field.accessibilityLabel = accessibilityLabel
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.textColor = UIColor(PauseTheme.ink)
            field.tintColor = UIColor(PauseTheme.coral)
            switch inputMode {
            case .domain:
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
                field.spellCheckingType = .no
                field.keyboardType = .URL
            case .name:
                field.autocapitalizationType = .sentences
                field.autocorrectionType = .default
                field.spellCheckingType = .default
                field.keyboardType = .default
            }
            field.returnKeyType = .done
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
            return field
        }

        func updateUIView(_ field: UITextField, context: Context) {
            context.coordinator.parent = self
            if field.text != text {
                field.text = text
                context.coordinator.publishCaret(field)
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
            CGSize(width: proposal.width ?? 180, height: max(uiView.font?.lineHeight ?? 22, 24))
        }

        static func dismantleUIView(_ field: UITextField, coordinator: Coordinator) {
            coordinator.parent.onCaretChange(nil)
        }

        @MainActor final class Coordinator: NSObject, UITextFieldDelegate {
            var parent: CaretTrackingTextField
            init(_ parent: CaretTrackingTextField) { self.parent = parent }

            @objc func changed(_ field: UITextField) {
                parent.text = field.text ?? ""
                publishCaret(field)
            }

            func textFieldDidBeginEditing(_ field: UITextField) { publishCaret(field) }
            func textFieldDidEndEditing(_ field: UITextField) { parent.onCaretChange(nil) }
            func textFieldDidChangeSelection(_ field: UITextField) { publishCaret(field) }
            func textFieldShouldReturn(_ field: UITextField) -> Bool {
                parent.onSubmit()
                return true
            }

            fileprivate func publishCaret(_ field: UITextField) {
                guard field.isFirstResponder, let selection = field.selectedTextRange,
                    let window = field.window
                else { return }
                let rect = field.convert(field.caretRect(for: selection.end), to: window)
                parent.onCaretChange(CGPoint(x: rect.midX, y: rect.midY))
            }
        }
    }
#elseif os(macOS)
    import AppKit

    struct CaretTrackingTextField: View {
        let placeholder: String
        @Binding var text: String
        let accessibilityLabel: String
        let onSubmit: () -> Void
        let onCaretChange: (CGPoint?) -> Void
        @FocusState private var isFocused: Bool

        init(
            _ placeholder: String, text: Binding<String>, accessibilityLabel: String = "Website domain",
            inputMode: CaretTrackingTextFieldInputMode = .domain,
            onSubmit: @escaping () -> Void,
            onCaretChange: @escaping (CGPoint?) -> Void
        ) {
            self.placeholder = placeholder
            _text = text
            self.accessibilityLabel = accessibilityLabel
            self.onSubmit = onSubmit
            self.onCaretChange = onCaretChange
        }

        var body: some View {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(accessibilityLabel)
                .focused($isFocused)
                .onSubmit(onSubmit)
                .background(CaretObserver(isFocused: isFocused, onChange: onCaretChange))
        }
    }

    /// Observes the field editor without changing its text, selection, or delegate.
    private struct CaretObserver: NSViewRepresentable {
        let isFocused: Bool
        let onChange: (CGPoint?) -> Void

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            context.coordinator.view = view
            context.coordinator.observer = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main
            ) { [weak coordinator = context.coordinator] notification in
                MainActor.assumeIsolated {
                    guard let editor = notification.object as? NSTextView,
                        editor.window === coordinator?.view?.window
                    else { return }
                    coordinator?.scheduleUpdate()
                }
            }
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {
            context.coordinator.isFocused = isFocused
            context.coordinator.onChange = onChange
            context.coordinator.scheduleUpdate()
        }

        static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
            if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
            coordinator.view = nil
            coordinator.isFocused = false
            coordinator.onChange = nil
        }

        @MainActor final class Coordinator {
            weak var view: NSView?
            var observer: NSObjectProtocol?
            var isFocused = false
            var onChange: ((CGPoint?) -> Void)?
            private var pending = false
            private var lastPosition: CGPoint?

            func scheduleUpdate() {
                guard !pending else { return }
                pending = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pending = false
                    let position = self.caretPosition()
                    guard position != self.lastPosition else { return }
                    self.lastPosition = position
                    self.onChange?(position)
                }
            }

            private func caretPosition() -> CGPoint? {
                guard isFocused, let window = view?.window,
                    let editor = window.firstResponder as? NSTextView, editor.isFieldEditor
                else { return nil }
                let selection = editor.selectedRange()
                guard selection.location != NSNotFound else { return nil }
                let location = min(NSMaxRange(selection), (editor.string as NSString).length)
                let rect = editor.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
                let hostWindow = window.sheetParent ?? window
                guard let content = hostWindow.contentView else { return nil }
                let point = hostWindow.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY))
                return content.convert(point, from: nil)
            }
        }
    }

#endif

struct MascotFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

func mascotAttention(caret: CGPoint?, frame: CGRect) -> CGPoint? {
    guard let caret, !frame.isEmpty else { return nil }
    // atan preserves small caret movements even when the field is far below the face.
    return CGPoint(
        x: atan((caret.x - frame.midX) / 170) / (.pi / 2),
        y: atan((caret.y - frame.midY) / 220) / (.pi / 2)
    )
}
