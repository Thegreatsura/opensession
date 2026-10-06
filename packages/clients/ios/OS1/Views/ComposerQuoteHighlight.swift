import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Dims the composer's markdown quote lines (`ComposerQuoteLines`): the quoted
/// text takes the secondary label colour and its `>` the tertiary one, the
/// way a sent quote reads, so quoted context stands apart from the question.
///
/// It paints colour and nothing else, on the field's own text view, so the
/// draft string, glyph metrics, caret, selection, the IME's marked text and
/// the send key all stay the stock TextField's. On iOS it uses TextKit 2
/// rendering attributes, which never touch the text storage; the Mac's field
/// editor and resting cell take foreground-colour attributes only. It never
/// repaints while the IME is composing.
///
/// Install it as a `.background` on the TextField itself: it finds the field's
/// platform text view by frame.
struct ComposerQuoteHighlight: View {
    let text: String

    var body: some View {
        ComposerQuoteHighlightBridge(text: text)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#if os(iOS)
private struct ComposerQuoteHighlightBridge: UIViewRepresentable {
    let text: String

    func makeCoordinator() -> ComposerQuotePainter { ComposerQuotePainter() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.schedule(text: text, marker: view)
    }
}

@MainActor
final class ComposerQuotePainter {
    private weak var textView: UITextView?
    private var text = ""
    private var painted: [ComposerQuoteLines.Line] = []
    private var scheduled = false

    func schedule(text: String, marker: UIView) {
        self.text = text
        guard !scheduled else { return }
        scheduled = true
        // After SwiftUI has pushed the new string into the field.
        DispatchQueue.main.async { [weak self, weak marker] in
            guard let self else { return }
            self.scheduled = false
            guard let marker else { return }
            self.paint(marker: marker, retry: true)
        }
    }

    private func paint(marker: UIView, retry: Bool) {
        guard let textView = textView?.window != nil ? textView : find(from: marker) else { return }
        self.textView = textView
        // Mid-composition the marked range belongs to the IME.
        guard textView.markedTextRange == nil else { return }
        guard textView.text == text else {
            if retry {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak marker] in
                    guard let marker else { return }
                    self?.paint(marker: marker, retry: false)
                }
            }
            return
        }
        let lines = ComposerQuoteLines.lines(in: text)
        guard lines != painted || !lines.isEmpty else { return }
        painted = lines
        if let layout = textView.textLayoutManager,
           let content = layout.textContentManager {
            layout.removeRenderingAttribute(.foregroundColor, for: layout.documentRange)
            for line in lines {
                if let range = Self.textRange(line.line, in: content) {
                    layout.addRenderingAttribute(.foregroundColor, value: UIColor.secondaryLabel, for: range)
                }
                if let range = Self.textRange(line.marker, in: content) {
                    layout.addRenderingAttribute(.foregroundColor, value: UIColor.tertiaryLabel, for: range)
                }
            }
        } else {
            // TextKit 1 has no rendering-only colour on iOS: recolour the
            // storage. Attributes only, never characters, so the string the
            // binding reads back is unchanged.
            let storage = textView.textStorage
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: UIColor.label, range: full)
            for line in lines {
                storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: line.line)
                storage.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: line.marker)
            }
            storage.endEditing()
            textView.typingAttributes[.foregroundColor] = UIColor.label
        }
    }

    private static func textRange(_ range: NSRange, in content: NSTextContentManager) -> NSTextRange? {
        let start = content.documentRange.location
        guard let from = content.location(start, offsetBy: range.location),
              let to = content.location(from, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: from, end: to)
    }

    /// The editable text view under the marker: the composer field.
    private func find(from marker: UIView) -> UITextView? {
        guard let window = marker.window else { return nil }
        let center = marker.convert(CGPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
        var stack: [UIView] = [window]
        while let view = stack.popLast() {
            if let textView = view as? UITextView, textView.isEditable,
               textView.convert(textView.bounds, to: nil).contains(center) {
                return textView
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }
}
#else
private struct ComposerQuoteHighlightBridge: NSViewRepresentable {
    let text: String

    func makeCoordinator() -> ComposerQuotePainter { ComposerQuotePainter() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.schedule(text: text, marker: view)
    }
}

@MainActor
final class ComposerQuotePainter {
    private weak var field: NSView?
    private var text = ""
    private var scheduled = false
    private var observers: [NSObjectProtocol] = []

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func schedule(text: String, marker: NSView) {
        self.text = text
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self, weak marker] in
            guard let self else { return }
            self.scheduled = false
            guard let marker else { return }
            self.paint(marker: marker, attempts: [0.05, 0.25])
        }
    }

    /// SwiftUI pushes the string into the field, and may reset its
    /// attributes, on its own schedule: paint now and again shortly after.
    /// A pass that finds nothing to change does nothing.
    private func paint(marker: NSView, attempts: [Double]) {
        if let field = field?.window != nil ? field : find(from: marker) {
            if self.field !== field {
                self.field = field
                observe(field)
            }
            repaint()
        }
        guard let next = attempts.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + next) { [weak self, weak marker] in
            guard let self, let marker else { return }
            self.paint(marker: marker, attempts: Array(attempts.dropFirst()))
        }
    }

    /// Editing hands the text to the window's field editor, which draws its
    /// own copy: paint again whenever editing starts or ends.
    private func observe(_ field: NSView) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = [NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification]
            .map { name in
                NotificationCenter.default.addObserver(forName: name, object: field, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        DispatchQueue.main.async { self?.repaint() }
                    }
                }
            }
    }

    private func repaint() {
        guard let field else { return }
        let lines = ComposerQuoteLines.lines(in: text)
        if let textField = field as? NSTextField {
            if let editor = textField.currentEditor() as? NSTextView {
                paint(editor, lines: lines)
            } else if textField.stringValue == text {
                // At rest an NSTextField draws its cell's attributed string.
                let value = NSMutableAttributedString(attributedString: textField.attributedStringValue)
                let full = NSRange(location: 0, length: value.length)
                value.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
                for line in lines where NSMaxRange(line.line) <= value.length {
                    value.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: line.line)
                    value.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: line.marker)
                }
                if !value.isEqual(to: textField.attributedStringValue) {
                    textField.attributedStringValue = value
                }
            }
        } else if let textView = field as? NSTextView {
            paint(textView, lines: lines)
        }
    }

    /// The field editor recolours its own storage: an AppKit field editor
    /// draws past TextKit 2 rendering attributes. Attributes only, never
    /// characters, and never while the IME holds marked text, so the string
    /// the field hands back to SwiftUI, the caret and the selection are
    /// untouched.
    private func paint(_ textView: NSTextView, lines: [ComposerQuoteLines.Line]) {
        guard !textView.hasMarkedText(), textView.string == text,
              let storage = textView.textStorage
        else { return }
        let full = NSRange(location: 0, length: storage.length)
        var wanted: [(NSRange, NSColor)] = [(full, .labelColor)]
        for line in lines where NSMaxRange(line.line) <= storage.length {
            wanted.append((line.line, .secondaryLabelColor))
            wanted.append((line.marker, .tertiaryLabelColor))
        }
        // Skip the write when every run already has its colour.
        let target = NSMutableAttributedString(attributedString: storage)
        for (range, color) in wanted { target.addAttribute(.foregroundColor, value: color, range: range) }
        guard !target.isEqual(to: storage) else { return }
        // No selection write: an attribute edit leaves it where it was, and
        // setting it would post a selection change for SwiftUI to map
        // against a string it may be mid-way through replacing.
        storage.beginEditing()
        for (range, color) in wanted { storage.addAttribute(.foregroundColor, value: color, range: range) }
        storage.endEditing()
        textView.typingAttributes[.foregroundColor] = NSColor.labelColor
    }

    /// The editable text field (or text view) under the marker.
    private func find(from marker: NSView) -> NSView? {
        guard let root = marker.window?.contentView else { return nil }
        let center = marker.convert(NSPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            let editable = (view as? NSTextField)?.isEditable == true
                || ((view as? NSTextView)?.isEditable == true && !(view.superview is NSClipView && view.superview?.superview?.superview is NSTextField))
            if editable, view.convert(view.bounds, to: nil).contains(center) {
                return view
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }
}
#endif
