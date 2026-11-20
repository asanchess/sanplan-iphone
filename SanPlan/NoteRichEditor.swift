import SwiftUI
import UIKit

/// Commands from the keyboard bar to the live note editor.
@MainActor
final class NoteRichController: ObservableObject {
    fileprivate weak var coordinator: NoteRichEditor.Coordinator?

    func apply(_ tool: NoteListTool) { coordinator?.apply(tool) }
    func focus() { coordinator?.textView?.becomeFirstResponder() }
    func insertPhoto(_ id: String) { coordinator?.insertPhoto(id) }
    /// The note text as stored (plain text with list markers).
    var currentText: String? { coordinator?.storage }
}

extension NSAttributedString.Key {
    /// On the circle (U+FFFC) of a checklist line: whether it is ticked.
    static let noteCheck = NSAttributedString.Key("asan.noteCheck")
    /// On every character of a heading line.
    static let noteHeading = NSAttributedString.Key("asan.noteHeading")
    /// On the frame (U+FFFC) of a photo line: the photo id.
    static let notePhoto = NSAttributedString.Key("asan.notePhoto")
}

/// A photo frame as wide as the line it sits on (the width is known only at layout).
final class NotePhotoAttachment: NSTextAttachment {
    var photo: UIImage?
    var border: UIColor = .separator
    private var drawn: UIImage?

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        CGRect(x: 0, y: 0, width: max(lineFrag.width - 2, 40), height: 120)
    }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        if drawn?.size.width != imageBounds.width {
            drawn = NotePhotos.frame(photo, width: imageBounds.width, border: border)
        }
        return drawn
    }
}

/// The note text the iPhone way: circles that tick with a tap, dots and numbers, a big heading, and Return
/// carries a list on. Underneath the text stays plain («- [ ] », «• », «1. », «# ») for the web and sync.
struct NoteRichEditor: UIViewRepresentable {
    @Binding var text: String
    let accent: Color
    let controller: NoteRichController
    var onFocusChange: (Bool) -> Void = { _ in }
    /// The decrypted picture for a photo id (nil draws an empty frame).
    var photo: (String) -> UIImage? = { _ in nil }
    var onOpenPhoto: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 28, right: 8)
        view.adjustsFontForContentSizeCategory = true
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.autocapitalizationType = .sentences
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "note-text"
        view.accessibilityLabel = "Текст заметки"
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        let coordinator = context.coordinator
        coordinator.textView = view
        coordinator.accent = UIColor(accent)
        controller.coordinator = coordinator
        coordinator.load(text)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        controller.coordinator = coordinator
        // Only a change from elsewhere (sync, another device) reloads; our own typing already matches.
        if text != coordinator.storage { coordinator.load(text) }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: NoteRichEditor
        weak var textView: UITextView?
        var accent: UIColor = .systemYellow
        private(set) var storage = ""
        private var isApplying = false
        /// The circle under the finger when the current touch began.
        private var touchedCheck: Int?
        /// The photo frame under the finger when the current touch began.
        private var touchedPhoto: String?
        private var touchedAt = Date.distantPast

        init(_ parent: NoteRichEditor) { self.parent = parent }

        // MARK: Look

        private static func font(_ size: CGFloat, _ weight: UIFont.Weight, _ style: UIFont.TextStyle) -> UIFont {
            let descriptor = UIFontDescriptor(fontAttributes: [
                .family: "Golos Text",
                .traits: [UIFontDescriptor.TraitKey.weight: weight.rawValue]
            ])
            return UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont(descriptor: descriptor, size: size))
        }

        private var bodyFont: UIFont { Self.font(17, .medium, .body) }
        private var headingFont: UIFont { Self.font(24, .heavy, .title2) }
        private var primary: UIColor { UIColor(DS.Colors.textPrimary) }
        private var secondary: UIColor { UIColor(DS.Colors.textSecondary) }
        private var muted: UIColor { UIColor(DS.Colors.textMuted) }

        private var baseAttributes: [NSAttributedString.Key: Any] {
            [.font: bodyFont, .foregroundColor: primary]
        }

        private var headingAttributes: [NSAttributedString.Key: Any] {
            [.font: headingFont, .foregroundColor: primary, .noteHeading: true]
        }

        private func checkCircle(_ done: Bool) -> NSAttributedString {
            let font = bodyFont
            let config = UIImage.SymbolConfiguration(pointSize: font.pointSize + 3, weight: .semibold)
            let name = done ? "checkmark.circle.fill" : "circle"
            let color = done ? accent : muted
            let image = UIImage(systemName: name, withConfiguration: config)?.withTintColor(color, renderingMode: .alwaysOriginal)
            let attachment = NSTextAttachment()
            attachment.image = image
            let size = image?.size ?? CGSize(width: 22, height: 22)
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
            let circle = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
            circle.addAttributes([.noteCheck: done, .font: font], range: NSRange(location: 0, length: circle.length))
            return circle
        }

        private func photoFrame(_ id: String) -> NSAttributedString {
            let attachment = NotePhotoAttachment()
            attachment.photo = parent.photo(id)
            attachment.border = UIColor(DS.Colors.textMuted).withAlphaComponent(0.3)
            let frame = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
            frame.addAttributes([.notePhoto: id, .font: bodyFont], range: NSRange(location: 0, length: frame.length))
            return frame
        }

        // MARK: Text ↔ screen

        private func attributed(_ lines: [NoteLine]) -> NSAttributedString {
            let out = NSMutableAttributedString()
            for (index, line) in lines.enumerated() {
                if index > 0 { out.append(NSAttributedString(string: "\n", attributes: baseAttributes)) }
                switch line.style {
                case .check(let done):
                    out.append(checkCircle(done))
                    out.append(NSAttributedString(string: " " + line.body, attributes: baseAttributes))
                case .heading:
                    out.append(NSAttributedString(string: line.body, attributes: headingAttributes))
                case .plain where NotePhotos.id(in: line.body) != nil:
                    out.append(photoFrame(NotePhotos.id(in: line.body) ?? ""))
                default:
                    out.append(NSAttributedString(string: NoteLists.marker(line.style) + line.body, attributes: baseAttributes))
                }
            }
            return out
        }

        private static func displayPrefix(_ style: NoteLineStyle) -> Int {
            switch style {
            case .plain, .heading: return 0
            case .check: return 2
            case .bullet, .number: return (NoteLists.marker(style) as NSString).length
            }
        }

        private struct ScreenLine {
            var line: NoteLine
            var range: NSRange
            /// How many characters before the body on screen right now.
            var prefix: Int
        }

        private func screenLines() -> [ScreenLine] {
            guard let storage = textView?.textStorage else { return [] }
            let string = storage.string as NSString
            var result: [ScreenLine] = []
            var start = 0
            while true {
                let found = string.range(of: "\n", options: .literal, range: NSRange(location: start, length: string.length - start))
                let end = found.location == NSNotFound ? string.length : found.location
                result.append(read(NSRange(location: start, length: end - start), in: storage))
                if found.location == NSNotFound { break }
                start = end + 1
            }
            return result
        }

        private func read(_ range: NSRange, in storage: NSAttributedString) -> ScreenLine {
            let string = storage.string as NSString
            let text = string.substring(with: range)
            if range.length > 0, string.character(at: range.location) == 0xFFFC {
                let rest = (text as NSString).substring(from: 1)
                if let id = storage.attribute(.notePhoto, at: range.location, effectiveRange: nil) as? String {
                    // Text typed right after a frame keeps the token visible rather than losing the text.
                    return ScreenLine(line: NoteLine(.plain, NotePhotos.token(id) + rest), range: range, prefix: 0)
                }
                if let done = storage.attribute(.noteCheck, at: range.location, effectiveRange: nil) as? Bool {
                    if rest.hasPrefix(" ") {
                        return ScreenLine(line: NoteLine(.check(done), String(rest.dropFirst())), range: range, prefix: 2)
                    }
                    // Backspace ate the space after the circle: the circle goes too, like the iPhone.
                    return ScreenLine(line: NoteLine(.plain, rest), range: range, prefix: 1)
                }
                return ScreenLine(line: NoteLine(.plain, rest.replacingOccurrences(of: "\u{FFFC}", with: "")), range: range, prefix: 1)
            }
            if range.length > 0, storage.attribute(.noteHeading, at: range.location, effectiveRange: nil) as? Bool == true {
                return ScreenLine(line: NoteLine(.heading, text), range: range, prefix: 0)
            }
            let clean = text.replacingOccurrences(of: "\u{FFFC}", with: "")
            if clean.hasPrefix("•"), !clean.hasPrefix("• ") {
                // Backspace ate the space after the dot: the dot goes too.
                return ScreenLine(line: NoteLine(.plain, String(clean.dropFirst())), range: range, prefix: 1)
            }
            let parsed = NoteLists.parseLine(clean)
            let prefix = max(0, (clean as NSString).length - (parsed.body as NSString).length)
            return ScreenLine(line: parsed, range: range, prefix: parsed.style == .plain ? 0 : prefix)
        }

        private func cursor(at location: Int, in lines: [ScreenLine]) -> NoteCursor {
            for (index, line) in lines.enumerated() where location <= NSMaxRange(line.range) {
                return NoteCursor(line: index, column: max(0, location - line.range.location - line.prefix))
            }
            let last = max(lines.count - 1, 0)
            return NoteCursor(line: last, column: Int.max / 2)
        }

        private func offset(of cursor: NoteCursor, in lines: [NoteLine]) -> Int {
            var location = 0
            for (index, line) in lines.enumerated() {
                let prefix = Self.displayPrefix(line.style)
                let body = NotePhotos.id(in: line.body) != nil && line.style == .plain ? 1 : (line.body as NSString).length
                if index == cursor.line { return location + prefix + min(max(cursor.column, 0), body) }
                location += prefix + body + 1
            }
            return max(location - 1, 0)
        }

        /// Draws the lines anew and puts the cursor at `cursor`.
        private func render(_ lines: [NoteLine], cursor: NoteCursor?) {
            guard let view = textView else { return }
            isApplying = true
            defer { isApplying = false }
            view.textStorage.setAttributedString(attributed(lines))
            restyle()
            if let cursor {
                let location = min(offset(of: cursor, in: lines), view.textStorage.length)
                view.selectedRange = NSRange(location: location, length: 0)
                let style = lines.indices.contains(cursor.line) ? lines[cursor.line].style : .plain
                view.typingAttributes = style == .heading ? headingAttributes : baseAttributes
                if view.isFirstResponder { view.scrollRangeToVisible(view.selectedRange) }
            }
            view.undoManager?.removeAllActions()
        }

        /// Fonts, colours and indents per line; the characters stay as they are.
        private func restyle() {
            guard let storage = textView?.textStorage else { return }
            let lines = screenLines()
            storage.beginEditing()
            defer { storage.endEditing() }
            for item in lines where item.range.length > 0 {
                let range = item.range
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 3
                paragraph.paragraphSpacing = 4
                storage.removeAttribute(.strikethroughStyle, range: range)
                if item.line.style == .heading {
                    storage.addAttributes([.font: headingFont, .foregroundColor: primary, .noteHeading: true], range: range)
                    paragraph.paragraphSpacingBefore = 6
                } else {
                    storage.addAttributes([.font: bodyFont, .foregroundColor: primary], range: range)
                    storage.removeAttribute(.noteHeading, range: range)
                    let prefix = NSRange(location: range.location, length: min(item.prefix, range.length))
                    let body = NSRange(location: NSMaxRange(prefix), length: range.length - prefix.length)
                    switch item.line.style {
                    case .bullet, .number:
                        storage.addAttributes([.foregroundColor: secondary, .font: Self.font(17, .bold, .body)], range: prefix)
                        paragraph.headIndent = storage.attributedSubstring(from: prefix).size().width
                    case .check(let done):
                        paragraph.headIndent = storage.attributedSubstring(from: prefix).size().width
                        if done, body.length > 0 {
                            storage.addAttributes([.foregroundColor: secondary,
                                                   .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                                   .strikethroughColor: muted], range: body)
                        }
                    case .plain, .heading:
                        break
                    }
                }
                storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }
        }

        func load(_ text: String) {
            storage = text
            let lines = NoteLists.parse(text)
            let keep = textView.map { $0.textStorage.length - NSMaxRange($0.selectedRange) }
            render(lines, cursor: nil)
            if let view = textView, let keep {
                // Keep the cursor the same distance from the end (an edit from sync usually lands elsewhere).
                view.selectedRange = NSRange(location: max(0, view.textStorage.length - keep), length: 0)
            }
        }

        private func publish(_ lines: [NoteLine]) {
            storage = NoteLists.text(lines)
            if parent.text != storage { parent.text = storage }
        }

        // MARK: Keyboard bar

        func apply(_ tool: NoteListTool) {
            guard let view = textView else { return }
            let screen = screenLines()
            let selection = view.selectedRange
            let first = cursor(at: selection.location, in: screen)
            var endLocation = NSMaxRange(selection)
            if selection.length > 0, endLocation > 0,
               (view.textStorage.string as NSString).character(at: endLocation - 1) == 0x0A { endLocation -= 1 }
            let last = cursor(at: endLocation, in: screen)
            let lines = NoteLists.apply(tool, to: screen.map(\.line), range: first.line...max(first.line, last.line))
            render(lines, cursor: NoteCursor(line: last.line, column: last.column))
            publish(lines)
            UISelectionFeedbackGenerator().selectionChanged()
        }

        /// Puts the photo on its own line: on the cursor line when it is empty, else right after it.
        func insertPhoto(_ id: String) {
            guard let view = textView else { return }
            let screen = screenLines()
            var lines = screen.map(\.line)
            let at = cursor(at: view.selectedRange.location, in: screen)
            let photo = NoteLine(.plain, NotePhotos.token(id))
            var index = min(at.line, max(lines.count - 1, 0))
            if lines.indices.contains(index), lines[index].body.isEmpty, lines[index].style == .plain {
                lines[index] = photo
            } else {
                index += 1
                lines.insert(photo, at: min(index, lines.count))
            }
            if index + 1 >= lines.count { lines.append(NoteLine(.plain, "")) }
            render(lines, cursor: NoteCursor(line: index + 1, column: 0))
            publish(lines)
        }

        // MARK: UITextViewDelegate

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard textView.markedTextRange == nil, text.contains("\n") else { return true }
            var screen = screenLines()
            if range.length > 0 {
                // Typing over a selection: remove it first, then insert like a plain cursor.
                isApplying = true
                textView.textStorage.replaceCharacters(in: range, with: "")
                isApplying = false
                screen = screenLines()
            }
            let at = cursor(at: range.location, in: screen)
            let lines = screen.map(\.line)
            if text == "\n" {
                if range.length == 0, lines.indices.contains(at.line), lines[at.line].style == .plain { return true }
                let result = NoteLists.pressReturn(lines, at: at)
                render(result.lines, cursor: result.cursor)
                publish(result.lines)
                return false
            }
            // Pasted lines: their own markers become lists; the first joins the current line.
            let pasted = NoteLists.parse(text)
            guard lines.indices.contains(at.line), let lastPasted = pasted.last else { return true }
            let current = lines[at.line]
            let body = current.body as NSString
            let cut = min(at.column, body.length)
            var merged = Array(lines[..<at.line])
            merged.append(NoteLine(current.style, body.substring(to: cut) + pasted[0].body))
            if pasted.count > 2 { merged.append(contentsOf: pasted[1..<(pasted.count - 1)]) }
            merged.append(NoteLine(lastPasted.style, lastPasted.body + body.substring(from: cut)))
            merged.append(contentsOf: lines[(at.line + 1)...])
            let next = NoteLists.renumbered(merged)
            render(next, cursor: NoteCursor(line: at.line + pasted.count - 1, column: (lastPasted.body as NSString).length))
            publish(next)
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplying, textView.markedTextRange == nil else { return }
            let screen = screenLines()
            let lines = screen.map(\.line)
            if attributed(lines).string != textView.textStorage.string {
                // A marker typed by hand («# », «- [ ] ») turns into a heading or a circle.
                render(lines, cursor: cursor(at: textView.selectedRange.location, in: screen))
            } else {
                restyle()
            }
            publish(lines)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplying, textView.markedTextRange == nil else { return }
            let screen = screenLines()
            let at = cursor(at: textView.selectedRange.location, in: screen)
            guard screen.indices.contains(at.line), screen[at.line].range.length > 0 else { return }
            textView.typingAttributes = screen[at.line].line.style == .heading ? headingAttributes : baseAttributes
        }

        func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
            // A tap on a circle ticks it without opening the keyboard.
            (touchedCheck == nil && touchedPhoto == nil) || Date().timeIntervalSince(touchedAt) > 1
        }

        func textViewDidBeginEditing(_ textView: UITextView) { parent.onFocusChange(true) }
        func textViewDidEndEditing(_ textView: UITextView) { parent.onFocusChange(false) }

        // MARK: Ticking circles

        private func checkIndex(at point: CGPoint, key: NSAttributedString.Key = .noteCheck) -> Int? {
            guard let view = textView, view.textStorage.length > 0 else { return nil }
            let manager = view.layoutManager
            let container = view.textContainer
            let inner = CGPoint(x: point.x - view.textContainerInset.left, y: point.y - view.textContainerInset.top)
            let glyph = manager.glyphIndex(for: inner, in: container, fractionOfDistanceThroughGlyph: nil)
            let character = manager.characterIndexForGlyph(at: glyph)
            let string = view.textStorage.string as NSString
            for candidate in [character, character - 1] where candidate >= 0 && candidate < string.length {
                guard string.character(at: candidate) == 0xFFFC,
                      view.textStorage.attribute(key, at: candidate, effectiveRange: nil) != nil else { continue }
                let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: candidate, length: 1), actualCharacterRange: nil)
                let rect = manager.boundingRect(forGlyphRange: glyphs, in: container).insetBy(dx: -12, dy: -8)
                if rect.contains(inner) { return candidate }
            }
            return nil
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended, let id = touchedPhoto {
                parent.onOpenPhoto(id)
                return
            }
            guard gesture.state == .ended, let index = touchedCheck, let view = textView else { return }
            let screen = screenLines()
            guard let line = screen.firstIndex(where: { NSLocationInRange(index, $0.range) }) else { return }
            let selection = view.selectedRange
            let lines = NoteLists.toggleCheck(screen.map(\.line), line: line)
            render(lines, cursor: nil)
            view.selectedRange = selection
            publish(lines)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchedCheck = textView.flatMap { checkIndex(at: touch.location(in: $0)) }
            touchedPhoto = textView.flatMap { view in
                checkIndex(at: touch.location(in: view), key: .notePhoto).flatMap {
                    view.textStorage.attribute(.notePhoto, at: $0, effectiveRange: nil) as? String
                }
            }
            touchedAt = Date()
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            touchedCheck != nil || touchedPhoto != nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
