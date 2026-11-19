import SwiftUI

/// One note, drawn in the canvas style of «Заметки». One live editor, like the iPhone: circles tick with a tap
/// (no keyboard), the keyboard bar adds lists and a heading, its «Готово» saves and puts the keyboard away.
/// Edits also save as you type (encrypted on the phone); «<» leaves the note.
struct NoteEditorView: View {
    @ObservedObject var store: NotesStore
    let noteID: String
    let onMakePlan: (String) -> Void
    let onMakeExpense: (String) -> Void

    @State private var text = ""
    @State private var focused = false
    @State private var loaded = false
    @State private var barTools: KeyboardBarTools?
    @StateObject private var editor = NoteRichController()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sectionAccent) private var accent
    @Environment(\.keyboardBarChannel) private var keyboardBar

    private var note: Note? { store.note(noteID) }

    var body: some View {
        ZStack(alignment: .top) {
            DS.Colors.canvas.ignoresSafeArea()
            NotesBackdrop()
            VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                header
                if let progress = note?.checklistProgress {
                    NoteChecklistProgress(done: progress.done, total: progress.total)
                }
                if loaded {
                    NoteRichEditor(text: $text, accent: accent, controller: editor) { focused = $0 }
                        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(focused ? accent : Color.clear, lineWidth: 2)
                        )
                }
            }
            .padding(.horizontal, DS.Metrics.screenGutter)
            .padding(.top, 8)
            .padding(.bottom, DS.Metrics.spacing12)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) { actionsMenu }
        }
        .tint(accent)
        .safeAreaInset(edge: .bottom) { suggestions }
        .onAppear {
            text = note?.text ?? ""
            loaded = true
            let tools = barTools ?? makeBarTools()
            barTools = tools
            keyboardBar?.tools = tools
            // A new, empty note opens ready to type; a written one opens for reading and ticking.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { editor.focus() }
            }
        }
        .onChange(of: text) { _, value in
            // Emptied text deletes the note only on «Готово» or when leaving, not mid-edit.
            guard note != nil, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            store.update(noteID, text: value)
        }
        .onChange(of: note?.text) { _, value in
            // Sync from another device while the note is open and not being typed in.
            if let value, value != text, !focused { text = value }
        }
        .onChange(of: note == nil) { _, gone in if gone { dismiss() } }
        .onDisappear {
            if let barTools, keyboardBar?.tools === barTools { keyboardBar?.tools = nil }
            store.update(noteID, text: editor.currentText ?? text)
        }
    }

    /// Lists and heading on the keyboard bar; «Готово» saves.
    private func makeBarTools() -> KeyboardBarTools {
        let editor = editor, store = store, noteID = noteID
        return KeyboardBarTools(items: [
            .init(id: "check", icon: "checklist", label: "Список с галочками") { editor.apply(.check) },
            .init(id: "number", icon: "list.number", label: "Нумерованный список") { editor.apply(.number) },
            .init(id: "bullet", icon: "list.bullet", label: "Список с точками") { editor.apply(.bullet) },
            .init(id: "heading", icon: "textformat.size", label: "Заголовок") { editor.apply(.heading) }
        ], onDone: {
            if let text = editor.currentText { store.update(noteID, text: text) }
        })
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
        if !focused, let note {
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
}
