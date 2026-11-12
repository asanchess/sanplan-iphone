import SwiftUI

/// «Заметки»: list and editor. On iPhone the editor pushes over the list; on iPad they sit side by side.
struct NotesScreen: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var vault: VaultKeySession
    @Binding var showSettings: Bool
    let onMakePlan: (String) -> Void
    let onMakeExpense: (String) -> Void
    /// Opens the shared «+» composer.
    let onCapture: () -> Void

    @State private var selection: String?
    @State private var query = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if vault.phase == .ready {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    list
                        .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 420)
                        .toolbar(.hidden, for: .navigationBar)
                } detail: {
                    if let id = selection, store.note(id) != nil {
                        NoteEditorView(store: store, noteID: id, onMakePlan: onMakePlan, onMakeExpense: onMakeExpense)
                            .id(id)
                    } else {
                        ZStack {
                            DS.Colors.canvas.ignoresSafeArea()
                            EmptyState(title: "Выберите заметку", icon: "note.text")
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack {
                    VaultGateView(vault: vault, showSettings: $showSettings)
                        .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
        .task(id: vault.phase) {
            if vault.phase == .idle { await vault.check() }
        }
        .onChange(of: store.recentlyDeleted?.id) { _, deleted in
            if let deleted, deleted == selection { selection = nil }
        }
    }

    private var visible: [Note] { store.notes.filter { $0.matches(query) } }

    private var list: some View {
        ZStack(alignment: .bottom) {
            DS.Colors.canvas.ignoresSafeArea()
            List(selection: $selection) {
                Section {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                        ScreenHeader("Заметки") {
                            CircleIconButton(icon: "person.crop.circle", accessibilityLabel: "Настройки") { showSettings = true }
                        }
                        searchField
                        syncLine
                    }
                    .listRowInsets(EdgeInsets(top: DS.Metrics.spacing16, leading: DS.Metrics.screenGutter, bottom: DS.Metrics.spacing8, trailing: DS.Metrics.screenGutter))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                }

                if visible.isEmpty {
                    EmptyState(
                        title: query.isEmpty ? "Заметок пока нет" : "Ничего не найдено",
                        message: query.isEmpty ? "Нажмите «+», чтобы записать мысль, идею или список." : nil,
                        icon: query.isEmpty ? "note.text" : "magnifyingglass"
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                }

                ForEach(visible) { note in
                    NoteRow(note: note)
                        .tag(note.id)
                        .listRowBackground(selection == note.id ? DS.Colors.surfaceRaised : Color.clear)
                        .listRowSeparatorTint(DS.Colors.hairline)
                        .listRowInsets(EdgeInsets(top: 10, leading: DS.Metrics.screenGutter, bottom: 10, trailing: DS.Metrics.screenGutter))
                        .swipeActions(edge: .leading) {
                            Button { store.togglePin(note.id) } label: {
                                Label(note.pinned ? "Открепить" : "Закрепить", systemImage: note.pinned ? "pin.slash" : "pin")
                            }
                            .tint(DS.Colors.accent)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { store.delete(note.id) } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button { store.togglePin(note.id) } label: {
                                Label(note.pinned ? "Открепить" : "Закрепить", systemImage: note.pinned ? "pin.slash" : "pin")
                            }
                            Button(role: .destructive) { store.delete(note.id) } label: { Label("Удалить", systemImage: "trash") }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await store.sync() }
            .captureButton(action: onCapture)

            if let deleted = store.recentlyDeleted {
                UndoBar(text: "Заметка «\(deleted.title)» удалена", onUndo: { store.undoDelete() }, onClose: { store.dismissUndo() })
                    .padding(.horizontal, DS.Metrics.screenGutter)
                    .padding(.bottom, DS.Metrics.spacing12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: DS.Metrics.spacing8) {
            Image(systemName: "magnifyingglass").foregroundColor(DS.Colors.textSecondary)
            TextField("Поиск по заметкам", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundColor(DS.Colors.textPrimary)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(DS.Colors.textSecondary)
                }
                .accessibilityLabel("Очистить поиск")
            }
        }
        .padding(.horizontal, DS.Metrics.spacing12)
        .frame(minHeight: DS.Metrics.minHitTarget)
        .background(DS.Colors.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DS.Colors.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private var syncLine: some View {
        switch store.syncState {
        case .offline(let message):
            Label(message, systemImage: "icloud.slash")
                .font(.footnote)
                .foregroundColor(DS.Colors.textSecondary)
        default:
            if store.unreadableCount > 0 {
                Label("\(store.unreadableCount) записей не открылось этим ключом.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundColor(DS.Colors.warning)
            }
        }
    }
}

private struct NoteRow: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if note.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundColor(DS.Colors.accent)
                        .accessibilityLabel("Закреплена")
                }
                Text(note.title)
                    .font(.body.weight(.semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)
            }
            if !note.preview.isEmpty {
                Text(note.preview)
                    .font(.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
            HStack(spacing: DS.Metrics.spacing8) {
                Text(NoteDates.short(note.updatedAt))
                if let progress = note.checklistProgress {
                    Label("\(progress.done) из \(progress.total)", systemImage: "checklist")
                }
            }
            .font(.footnote.monospacedDigit())
            .foregroundColor(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

enum NoteDates {
    static func short(_ ms: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'вчера', HH:mm"
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            formatter.dateFormat = "d MMMM"
        } else {
            formatter.dateFormat = "d MMMM yyyy"
        }
        return formatter.string(from: date)
    }
}

struct UndoBar: View {
    let text: String
    let onUndo: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: DS.Metrics.spacing12) {
            Text(text)
                .font(.subheadline)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Отменить", action: onUndo)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(DS.Colors.accent)
                .frame(minHeight: DS.Metrics.minHitTarget)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 32, height: DS.Metrics.minHitTarget)
            }
            .accessibilityLabel("Скрыть")
        }
        .padding(.horizontal, DS.Metrics.spacing16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DS.Colors.hairline, lineWidth: 1))
    }
}

/// One note. Notes with checklist lines open in reading mode, so boxes tick with one tap; «Изменить» opens the text.
struct NoteEditorView: View {
    @ObservedObject var store: NotesStore
    let noteID: String
    let onMakePlan: (String) -> Void
    let onMakeExpense: (String) -> Void

    @State private var text = ""
    @State private var isEditing = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var note: Note? { store.note(noteID) }

    var body: some View {
        ZStack {
            DS.Colors.canvas.ignoresSafeArea()
            if isEditing {
                TextEditor(text: $text)
                    .font(.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, DS.Metrics.screenGutter - 5)
                    .focused($focused)
                    .frame(maxWidth: 720)
                    .accessibilityLabel("Текст заметки")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                        readingLines
                        if let note {
                            Text("Изменено \(NoteDates.short(note.updatedAt))")
                                .font(.footnote)
                                .foregroundColor(DS.Colors.textSecondary)
                                .padding(.top, DS.Metrics.spacing16)
                        }
                    }
                    .padding(DS.Metrics.screenGutter)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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

    @ViewBuilder
    private var readingLines: some View {
        let lines = (note?.text ?? "").components(separatedBy: "\n")
        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            if let done = NoteText.checkbox(line) {
                Button { store.toggleChecklist(noteID, line: index); text = store.note(noteID)?.text ?? text } label: {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Metrics.spacing12) {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(done ? DS.Colors.accent : DS.Colors.textSecondary)
                        Text(NoteText.displayLine(line))
                            .strikethrough(done)
                            .foregroundColor(done ? DS.Colors.textSecondary : DS.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.body)
                    .frame(minHeight: DS.Metrics.minHitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(done ? .isSelected : [])
            } else {
                Text(line.isEmpty ? " " : line)
                    .font(index == 0 ? .title3.weight(.semibold) : .body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

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
                Button(role: .destructive) { isEditing = false; store.delete(noteID) } label: { Label("Удалить", systemImage: "trash") }
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
                        HeaderTextButton("Сделать планом", icon: "calendar.badge.plus") { onMakePlan(note.text) }
                    }
                    if hints.looksLikeExpense {
                        HeaderTextButton("Записать трату", icon: "creditcard") { onMakeExpense(note.text) }
                    }
                    Spacer()
                }
                .padding(.horizontal, DS.Metrics.screenGutter)
                .padding(.vertical, DS.Metrics.spacing8)
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
