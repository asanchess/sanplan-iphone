import SwiftUI

/// «Заметки» (canvas `docs/design/canvas-r5/Notes.html`): the list, and the editor pushed over it.
/// Encrypted: until the account's key is on this device, the vault gate (recovery-key transfer) is shown instead.
struct NotesScreen: View {
    @ObservedObject var store: NotesStore
    @ObservedObject var vault: VaultKeySession
    @Binding var showSettings: Bool
    let onMakePlan: (String) -> Void
    let onMakeExpense: (String) -> Void
    /// Opens the shared «+» composer (voice or text).
    let onCapture: () -> Void

    @State private var path: [String] = []
    @State private var query = ""
    @State private var routed = false
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if vault.phase == .ready {
                    NotesListView(store: store, query: $query, onCapture: onCapture)
                } else {
                    NotesVaultGateView(vault: vault)
                }
            }
            .navigationTitle("Заметки")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                NoteEditorView(store: store, noteID: id, onMakePlan: onMakePlan, onMakeExpense: onMakeExpense)
                    .id(id)
                    .shellRoot()
            }
        }
        .tint(accent)
        .task(id: vault.phase) {
            if vault.phase == .idle { await vault.check() }
        }
        .task { applyScreenshotRoute() }
        .onAppear { RecentlyDeleted.shared.register(store) }
        // Round 6 deep link: «Заметки» opens on the list itself, not on a note left open earlier.
        .onReceive(DeepLinks.shared.$pending) { link in
            guard link == .notes else { return }
            path.removeAll()
            DeepLinks.shared.consume()
        }
    }

    /// Debug screenshots: `notes-list` is the default; `notes-editor` opens one demo note.
    private func applyScreenshotRoute() {
        #if DEBUG
        guard !routed else { return }
        routed = true
        if ScreenshotRoute.demoData { NotesDemo.apply(to: store) }
        if ScreenshotRoute.is("notes-editor") {
            let id = store.note(NotesDemo.editorNoteID) != nil ? NotesDemo.editorNoteID : store.notes.first?.id
            if let id { path = [id] }
        }
        #endif
    }
}

/// The canvas list: header, search, pinned yellow cards, then a two-column grid.
struct NotesListView: View {
    @ObservedObject var store: NotesStore
    @Binding var query: String
    let onCapture: () -> Void
    @Environment(\.sectionAccent) private var accent

    var body: some View {
        let all = store.notes
        let visible = all.filter { $0.matches(query) }
        let pinned = visible.filter(\.pinned)
        let rest = visible.filter { !$0.pinned }
        ZStack(alignment: .top) {
            DS.Colors.canvas.ignoresSafeArea()
            NotesBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ScreenHeader("Заметки", kicker: "\(ReviewFormat.plural(all.count, "заметка", "заметки", "заметок")) · зашифрованы") {
                    }
                    NotesSearchField(query: $query)
                        .tourTarget("notes.search")
                    syncLine
                    if visible.isEmpty {
                        emptyState(searching: !all.isEmpty)
                    }
                    ForEach(Array(pinned.enumerated()), id: \.element.id) { index, note in
                        if index == 0 {
                            pinnedCard(note).tourTarget("notes.pinned")
                        } else {
                            pinnedCard(note)
                        }
                    }
                    if !rest.isEmpty {
                        NotesMasonry(notes: rest) { note in
                            NoteGridCard(note: note) { store.togglePin(note.id) }
                                .contextMenu { menu(for: note) }
                        }
                        .tourTarget("notes.grid")
                    }
                }
                .padding(.horizontal, DS.Metrics.screenGutter)
                .padding(.top, 18)
                // Room for the «+», as on the canvas.
                .padding(.bottom, 90)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .tourScrollHost()
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await store.sync() }
        }
        .notesCaptureButton(action: onCapture)
        .shellRoot()
    }

    private func pinnedCard(_ note: Note) -> some View {
        NotePinnedCard(note: note) { store.togglePin(note.id) }
            .contextMenu { menu(for: note) }
    }

    @ViewBuilder
    private func menu(for note: Note) -> some View {
        Button { store.togglePin(note.id) } label: {
            Label(note.pinned ? "Открепить" : "Закрепить", systemImage: note.pinned ? "pin.slash" : "pin")
        }
        ShareLink(item: note.text) { Label("Поделиться", systemImage: "square.and.arrow.up") }
        Button(role: .destructive) { NotesActions.delete(note.id, in: store) } label: {
            Label("Удалить", systemImage: "trash")
        }
    }

    private func emptyState(searching: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: searching ? "magnifyingglass" : "doc.text")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(accent)
                .accessibilityHidden(true)
            Text(searching ? "Ничего не найдено" : "Заметок пока нет")
                .font(DS.Fonts.text(17, .bold))
                .foregroundColor(DS.Colors.textPrimary)
            if !searching {
                Text("Нажмите «+», чтобы записать мысль, идею или список.")
                    .font(DS.Fonts.text(15, .medium, relativeTo: .subheadline))
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var syncLine: some View {
        switch store.syncState {
        case .offline(let message):
            statusLine(message, icon: "icloud.slash", color: DS.Colors.textSecondary)
        default:
            if store.unreadableCount > 0 {
                statusLine("\(store.unreadableCount) записей не открылось этим ключом.", icon: "exclamationmark.triangle", color: DS.Colors.warning)
            }
        }
    }

    private func statusLine(_ text: String, icon: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold))
            Text(text)
        }
        .font(DS.Fonts.text(13, .bold, relativeTo: .footnote))
        .foregroundColor(color)
        .padding(.horizontal, 4)
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

    /// The card line from the canvas: «Сегодня, 09:12», «Вчера», «12 ноября».
    static func card(_ ms: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) { return "Вчера" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "'Сегодня', HH:mm"
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            formatter.dateFormat = "d MMMM"
        } else {
            formatter.dateFormat = "d MMMM yyyy"
        }
        return formatter.string(from: date)
    }
}
