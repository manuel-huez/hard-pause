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

    struct CaretTrackingTextField: NSViewRepresentable {
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

        func makeNSView(context: Context) -> NSTextField {
            let field = NSTextField()
            field.delegate = context.coordinator
            field.placeholderString = placeholder
            field.setAccessibilityLabel(accessibilityLabel)
            field.font = .systemFont(ofSize: NSFont.systemFontSize)
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.focusRingType = .default
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            context.coordinator.field = field
            return field
        }

        func updateNSView(_ field: NSTextField, context: Context) {
            context.coordinator.parent = self
            if field.stringValue != text {
                field.stringValue = text
                context.coordinator.publishCaret()
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
            CGSize(width: proposal.width ?? 180, height: max(nsView.intrinsicContentSize.height, 22))
        }

        static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
            coordinator.stopObserving()
            coordinator.parent.onCaretChange(nil)
        }

        @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
            var parent: CaretTrackingTextField
            weak var field: NSTextField?
            private var selectionObserver: NSObjectProtocol?
            init(_ parent: CaretTrackingTextField) { self.parent = parent }

            func controlTextDidBeginEditing(_ notification: Notification) {
                stopObserving()
                if let editor = field?.currentEditor() as? NSTextView {
                    selectionObserver = NotificationCenter.default.addObserver(
                        forName: NSTextView.didChangeSelectionNotification, object: editor, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.publishCaret() }
                    }
                }
                publishCaret()
            }

            func controlTextDidChange(_ notification: Notification) {
                parent.text = field?.stringValue ?? ""
                publishCaret()
            }

            func controlTextDidEndEditing(_ notification: Notification) {
                stopObserving()
                parent.onCaretChange(nil)
            }

            func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
                guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
                parent.onSubmit()
                return true
            }

            func stopObserving() {
                if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
                selectionObserver = nil
            }

            fileprivate func publishCaret() {
                guard let field, let editor = field.currentEditor() as? NSTextView,
                    let window = field.window, let content = window.contentView
                else { return }
                let selection = editor.selectedRange()
                guard selection.location != NSNotFound else { return }
                let caretLocation = min(NSMaxRange(selection), (editor.string as NSString).length)
                let rect = editor.firstRect(
                    forCharacterRange: NSRange(location: caretLocation, length: 0), actualRange: nil)
                let pointInWindow = window.convertPoint(fromScreen: CGPoint(x: rect.midX, y: rect.midY))
                let pointInContent = content.convert(pointInWindow, from: nil)
                parent.onCaretChange(pointInContent)
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
