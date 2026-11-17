import SwiftUI
import UIKit

// Canvas pieces of «Заметки» (docs/design/canvas-r5/Notes.html): backdrop, search, pinned card, grid card, «+».

/// Dark brown-ink text on the yellow pinned card (canvas #2A1F0A).
let notesCardInk = DS.Colors.hex(0x2A1F0A)

/// The glow and dot pattern in the top-right corner, in the section colour.
struct NotesBackdrop: View {
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        let color = accent
        ZStack(alignment: .topTrailing) {
            Color.clear
            Circle()
                .fill(RadialGradient(colors: [color.opacity(0.22), color.opacity(0)], center: .center, startRadius: 0, endRadius: 154))
                .frame(width: 320, height: 320)
                .offset(x: 90, y: -110)
            Canvas { context, size in
                let step: CGFloat = 11
                var y = step / 2
                while y < size.height {
                    var x = step / 2
                    while x < size.width {
                        context.fill(Path(ellipseIn: CGRect(x: x - 1.9, y: y - 1.9, width: 3.8, height: 3.8)), with: .color(color))
                        x += step
                    }
                    y += step
                }
            }
            .frame(width: 230, height: 230)
            .mask {
                RadialGradient(colors: [.black, .clear], center: UnitPoint(x: 0.72, y: 0.28), startRadius: 0, endRadius: 159)
            }
            .opacity(0.3)
            .offset(x: 30, y: -30)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Canvas search: a 52 pt capsule on the surface colour; the section colour rings it while typing.
struct NotesSearchField: View {
    @Binding var query: String
    @FocusState private var focused: Bool
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .accessibilityHidden(true)
            TextField("Поиск по заметкам", text: $query, prompt: Text("Поиск").foregroundColor(DS.Colors.textSecondary))
                .font(DS.Fonts.text(17, .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .accessibilityIdentifier("notes-search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 36, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Очистить поиск")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, query.isEmpty ? 16 : 6)
        .frame(minHeight: 52)
        .background(DS.Colors.surface, in: Capsule())
        .overlay(Capsule().stroke(accent, lineWidth: focused ? 2 : 0))
        .animation(.easeOut(duration: 0.18), value: focused)
    }
}

/// What a card shows under the title, and its small bottom line.
enum NoteCardText {
    /// The lines after the title; checklist items run on one line, separated by commas, as on the canvas.
    static func body(_ note: Note) -> String {
        let lines = note.text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out = ""
        var previousWasItem = false
        for line in lines.dropFirst() {
            let isItem = NoteText.checkbox(line) != nil
            if !out.isEmpty { out += isItem && previousWasItem ? ", " : "\n" }
            out += NoteText.displayLine(line)
            previousWasItem = isItem
        }
        return out
    }

    /// «3 из 5» for a checklist, otherwise when it was last changed.
    static func meta(_ note: Note) -> String {
        if let progress = note.checklistProgress { return "\(progress.done) из \(progress.total)" }
        return NoteDates.card(note.updatedAt)
    }
}

/// The 44 pt pin control on a card.
struct NotePinButton: View {
    let note: Note
    let color: Color
    var size: CGFloat = 19
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: note.pinned ? "pin.fill" : "pin")
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel((note.pinned ? "Открепить: " : "Закрепить: ") + note.title)
    }
}

/// Canvas pinned note: the yellow card with an ink frame, a 6 pt ink shadow and a one-degree tilt.
struct NotePinnedCard: View {
    let note: Note
    let onPin: () -> Void
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        let preview = NoteCardText.body(note)
        ZStack(alignment: .topTrailing) {
            NavigationLink(value: note.id) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ЗАКРЕПЛЕНО")
                        .font(DS.Fonts.text(13, .heavy, relativeTo: .caption))
                        .tracking(0.8)
                        .accessibilityLabel("Закреплено")
                        .frame(minHeight: 24, alignment: .leading)
                        .padding(.trailing, 40)
                    Text(note.title)
                        .font(DS.Fonts.text(21, .heavy, relativeTo: .title3))
                        .lineSpacing(3)
                        .lineLimit(3)
                    if !preview.isEmpty {
                        Text(preview)
                            .font(DS.Fonts.text(16, .medium))
                            .lineSpacing(3)
                            .lineLimit(4)
                    }
                    Text(NoteCardText.meta(note))
                        .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                        .monospacedDigit()
                        .opacity(0.7)
                }
                .foregroundColor(notesCardInk)
                .multilineTextAlignment(.leading)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(accent, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityIdentifier("note-card-\(note.id)")

            NotePinButton(note: note, color: notesCardInk, size: 20, action: onPin)
                .padding(.top, 8)
                .padding(.trailing, 8)
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(DS.Colors.ink, lineWidth: 2))
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(DS.Colors.ink).offset(x: 6, y: 6))
        .rotationEffect(.degrees(-1))
        .padding(.leading, 2)
        .padding(.trailing, 8)
        .padding(.bottom, 4)
    }
}

/// Canvas grid note: a surface card, title, grey text, the date or checklist count in the section colour, and a pin.
struct NoteGridCard: View {
    let note: Note
    let onPin: () -> Void
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        let preview = NoteCardText.body(note)
        ZStack(alignment: .bottomTrailing) {
            NavigationLink(value: note.id) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(note.title)
                        .font(DS.Fonts.text(17, .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineSpacing(2)
                        .lineLimit(3)
                    if !preview.isEmpty {
                        Text(preview)
                            .font(DS.Fonts.text(15, .medium, relativeTo: .subheadline))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineSpacing(2)
                            .lineLimit(6)
                    }
                    Text(NoteCardText.meta(note))
                        .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                        .monospacedDigit()
                        .foregroundColor(accent)
                        .lineLimit(1)
                        .frame(minHeight: 30, alignment: .bottomLeading)
                        .padding(.trailing, 30)
                }
                .multilineTextAlignment(.leading)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityIdentifier("note-card-\(note.id)")

            NotePinButton(note: note, color: DS.Colors.textMuted, action: onPin)
                .padding(.trailing, 4)
                .padding(.bottom, 2)
        }
    }
}

/// Two columns like the canvas: notes alternate left and right in list order.
struct NotesMasonry<Card: View>: View {
    let notes: [Note]
    @ViewBuilder let card: (Note) -> Card

    var body: some View {
        let left = notes.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let right = notes.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 12) { ForEach(left) { card($0) } }
                .frame(maxWidth: .infinity, alignment: .top)
            VStack(spacing: 12) { ForEach(right) { card($0) } }
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

/// The round «+» of «Заметки» in the section colour (canvas: 58 pt, ink frame, 4 pt ink shadow, 14 pt above the bar).
/// Opens the shared composer, which records by voice or text. Hidden while the keyboard is up.
private struct NotesCaptureButton: ViewModifier {
    let action: () -> Void
    @State private var keyboardVisible = false
    @Environment(\.tabIsActive) private var tabIsActive
    @Environment(\.sectionAccent) private var accent

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if tabIsActive && !keyboardVisible {
                    Button(action: action) {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(DS.Colors.ink)
                            .frame(width: 58, height: 58)
                            .background(accent, in: Circle())
                            .overlay(Circle().stroke(DS.Colors.ink, lineWidth: 2))
                            .background(Circle().fill(DS.Colors.ink).offset(x: 4, y: 4))
                    }
                    .buttonStyle(PressScaleStyle())
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityLabel("Записать")
                    .accessibilityHint("Заметка, план или трата")
                    .accessibilityIdentifier("notes-capture")
                    .padding(.trailing, 16)
                    .padding(.bottom, 14)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardVisible = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardVisible = false }
    }
}

extension View {
    func notesCaptureButton(action: @escaping () -> Void) -> some View {
        modifier(NotesCaptureButton(action: action))
    }
}

/// A canvas-style chip for «Сделать планом» / «Записать трату».
struct NoteActionChip: View {
    let title: String
    let icon: String
    let action: () -> Void
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(accent)
                Text(title)
                    .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(DS.Colors.surfaceRaised, in: Capsule())
            .overlay(Capsule().stroke(DS.Colors.ink, lineWidth: 2))
            .background(Capsule().fill(DS.Colors.ink).offset(x: 3, y: 3))
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// A square checkbox: section colour with an ink tick when done.
struct NoteCheckBox: View {
    let done: Bool
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(done ? accent : Color.clear)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(done ? DS.Colors.ink : DS.Colors.textMuted, lineWidth: 2)
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(DS.Colors.ink)
            }
        }
        .frame(width: 26, height: 26)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(done ? DS.Colors.ink : Color.clear).offset(x: 2, y: 2))
        .accessibilityHidden(true)
    }
}

/// «3 из 5» with a bar in the section colour.
struct NoteChecklistProgress: View {
    let done: Int
    let total: Int
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        let ratio = total > 0 ? CGFloat(done) / CGFloat(total) : 0
        HStack(spacing: 12) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.Colors.surfaceRaised)
                    Capsule().fill(accent).frame(width: max(proxy.size.width * ratio, ratio > 0 ? 10 : 0))
                }
            }
            .frame(height: 10)
            Text("\(done) из \(total)")
                .font(DS.Fonts.text(13, .heavy, relativeTo: .caption))
                .monospacedDigit()
                .foregroundColor(accent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Отмечено \(done) из \(total)")
    }
}
