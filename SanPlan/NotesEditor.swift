import SwiftUI

/// One note, drawn in the canvas style of «Заметки». Notes with checklist lines open in reading mode,
/// so boxes tick with one tap; «Изменить» opens the text. Edits save as you type (encrypted on the phone).
struct NoteEditorView: View {
    @ObservedObject var store: NotesStore
    let noteID: String
    let onMakePlan: (String) -> Void
    let onMakeExpense: (String) -> Void

    @State private var text = ""
    @State private var isEditing = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sectionAccent) private var accent

    private var note: Note? { store.note(noteID) }

    var body: some View {
        ZStack(alignment: .top) {
            DS.Colors.canvas.ignoresSafeArea()
            NotesBackdrop()
            if isEditing { editing } else { reading }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isEditing {
                    Button { insertChecklistLine() } label: { Image(systemName: "checklist") }
                        .accessibilityLabel("Добавить пункт списка")
                    Button("Готово") { finishEditing() }.fontWeight(.semibold)
                } else {
                    Button("Изменить") { startEditing() }
                }
                actionsMenu
            }
        }
        .tint(accent)
        .safeAreaInset(edge: .bottom) { suggestions }
        .onAppear {
            text = note?.text ?? ""
            if note?.checklistProgress == nil { startEditing() }
        }
        .onChange(of: text) { _, value in
            // Emptied text deletes the note only on «Готово» or when leaving, not mid-edit.
            guard isEditing, note != nil, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            store.update(noteID, text: value)
        }
        .onChange(of: note == nil) { _, gone in if gone { dismiss() } }
        .onDisappear { if isEditing { store.update(noteID, text: text) } }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkewTag(note?.pinned == true ? "Закреплено" : "Заметка", color: accent)
            if let note {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 11, weight: .bold))
                    Text("Зашифрована · изменено \(NoteDates.short(note.updatedAt))")
                }
                .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                .foregroundColor(DS.Colors.textMuted)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Reading

    private var reading: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                    .padding(.bottom, 4)
                if let progress = note?.checklistProgress {
                    NoteChecklistProgress(done: progress.done, total: progress.total)
                        .padding(.bottom, 4)
                }
                readingLines
            }
            .padding(.horizontal, DS.Metrics.screenGutter)
            .padding(.top, 8)
            .padding(.bottom, DS.Metrics.spacing24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var readingLines: some View {
        let lines = (note?.text ?? "").components(separatedBy: "\n")
        let titleIndex = lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            if let done = NoteText.checkbox(line) {
                Button {
                    store.toggleChecklist(noteID, line: index)
                    text = store.note(noteID)?.text ?? text
                } label: {
                    HStack(spacing: DS.Metrics.spacing12) {
                        NoteCheckBox(done: done)
                        Text(NoteText.displayLine(line))
                            .font(DS.Fonts.text(17, .medium))
                            .strikethrough(done, color: DS.Colors.textMuted)
                            .foregroundColor(done ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(minHeight: 52)
                    .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityAddTraits(done ? .isSelected : [])
            } else if index == titleIndex {
                Text(line)
                    .font(DS.Fonts.text(26, .heavy, relativeTo: .title2))
                    .foregroundColor(DS.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 2)
            } else {
                Text(line.isEmpty ? " " : line)
                    .font(DS.Fonts.text(17, .medium))
                    .lineSpacing(3)
                    .foregroundColor(DS.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Editing

    private var editing: some View {
        VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
            header
            TextEditor(text: $text)
                .font(DS.Fonts.text(17, .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(focused ? accent : Color.clear, lineWidth: 2)
                )
                .accessibilityLabel("Текст заметки")
                .accessibilityIdentifier("note-text")
        }
        .padding(.horizontal, DS.Metrics.screenGutter)
        .padding(.top, 8)
        .padding(.bottom, DS.Metrics.spacing12)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    private var actionsMenu: some View {
        Menu {
            if let note {
                Button { store.togglePin(noteID) } label: {
                    Label(note.pinned ? "Открепить" : "Закрепить", systemImage: note.pinned ? "pin.slash" : "pin")
                }
                Button { onMakePlan(note.text) } label: { Label("Сделать планом", systemImage: "calendar.badge.plus") }
                Button { onMakeExpense(note.text) } label: { Label("Записать трату", systemImage: "creditcard") }
                ShareLink(item: note.text) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                Divider()
                Button(role: .destructive) {
                    isEditing = false
                    NotesActions.delete(noteID, in: store)
                } label: { Label("Удалить", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Действия с заметкой")
    }

    @ViewBuilder
    private var suggestions: some View {
        if !isEditing, let note {
            let hints = NoteText.hints(note.text)
            if hints.looksLikePlan || hints.looksLikeExpense {
                HStack(spacing: DS.Metrics.spacing8) {
                    if hints.looksLikePlan {
                        NoteActionChip(title: "Сделать планом", icon: "calendar.badge.plus") { onMakePlan(note.text) }
                    }
                    if hints.looksLikeExpense {
                        NoteActionChip(title: "Записать трату", icon: "creditcard") { onMakeExpense(note.text) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Metrics.screenGutter)
                .padding(.top, DS.Metrics.spacing8)
                .padding(.bottom, DS.Metrics.spacing12)
            }
        }
    }

    private func startEditing() {
        text = note?.text ?? text
        isEditing = true
        focused = true
    }

    private func finishEditing() {
        store.update(noteID, text: text)
        focused = false
        if store.note(noteID)?.checklistProgress != nil { isEditing = false }
    }

    private func insertChecklistLine() {
        let separator = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        text += separator + "- [ ] "
    }
}
