import SwiftUI
import UIKit

// MARK: - Sections

extension MainTab {
    /// Bottom-bar order from the canvas.
    static let ordered: [MainTab] = [.today, .plans, .notes, .money, .workout]

    var accent: Color {
        switch self {
        case .today: return DS.Colors.today
        case .plans: return DS.Colors.plans
        case .notes: return DS.Colors.notes
        case .money: return DS.Colors.money
        case .workout: return DS.Colors.workout
        }
    }

    var barIcon: String {
        switch self {
        case .today: return "sun.max"
        case .plans: return "checklist"
        case .notes: return "doc.text"
        case .money: return "creditcard"
        case .workout: return "dumbbell"
        }
    }
}

// MARK: - Bottom bar

struct ArnaTabBar: View {
    @Binding var selection: MainTab
    let tabs: [MainTab]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let on = tab == selection
                Button {
                    guard tab != selection else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.22)) { selection = tab }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.barIcon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(on ? tab.accent : DS.Colors.textMuted)
                            .frame(width: 52, height: 30)
                            .background {
                                if on {
                                    RoundedRectangle(cornerRadius: 9)
                                        .fill(tab.accent.opacity(0.2))
                                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tab.accent, lineWidth: 2))
                                        .background(RoundedRectangle(cornerRadius: 9).fill(DS.Colors.ink).offset(x: 3, y: 3))
                                        .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.14, d: 1, tx: 2, ty: 0))
                                }
                            }
                        Text(tab.title)
                            .font(DS.Fonts.text(11, .bold, relativeTo: .caption2))
                            .foregroundColor(on ? DS.Colors.textPrimary : DS.Colors.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                .accessibilityIdentifier("tab-\(tab.rawValue)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("arna-tab-bar")
        // The mascot's lane sits right above this edge, wherever the bar ends up.
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { MascotCenter.shared.barTop = $0 }
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                .fill(DS.Colors.navBar)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// Keeps a tab's screen alive once opened (no reload on return) and lets the new one rise in.
struct TabStage<Content: View>: View {
    let isActive: Bool
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isActive: Bool, @ViewBuilder content: () -> Content) {
        self.isActive = isActive
        self.content = content()
    }

    var body: some View {
        content
            .opacity(isActive ? 1 : 0)
            .offset(y: isActive || reduceMotion ? 0 : 10)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .environment(\.tabIsActive, isActive)
            .zIndex(isActive ? 1 : 0)
    }
}

private struct TabIsActiveKey: EnvironmentKey { static let defaultValue = true }
private struct ShellBarInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    /// Height of the shared bottom bar. UIKit-backed containers (NavigationSplitView) do not receive
    /// the shell's safe-area inset, so they reserve this space themselves via `shellRoot()`.
    var shellBarInset: CGFloat {
        get { self[ShellBarInsetKey.self] }
        set { self[ShellBarInsetKey.self] = newValue }
    }

    /// False for a tab kept alive in the background: its «+» and shortcuts must not answer.
    var tabIsActive: Bool {
        get { self[TabIsActiveKey.self] }
        set { self[TabIsActiveKey.self] = newValue }
    }
}

private struct ShellRoot: ViewModifier {
    @Environment(\.shellBarInset) private var inset
    @Environment(\.tabIsActive) private var tabIsActive

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: inset).accessibilityHidden(true)
            }
            // Repeated here: TabStage's accessibilityHidden does not reach through UIKit-backed stacks,
            // so VoiceOver (and UI tests) found the hidden Today tab's buttons from other tabs.
            .accessibilityHidden(!tabIsActive)
    }
}

extension View {
    /// Apply at the root inside a NavigationStack / NavigationSplitView column: keeps content and its
    /// «+» above the shared bottom bar and hides the whole tab from accessibility while it is in the background.
    func shellRoot() -> some View { modifier(ShellRoot()) }
}

// MARK: - Undo

/// One «Отменить» bar for the whole app. Any action that can be taken back offers it here for 5 seconds.
@MainActor
final class UndoCenter: ObservableObject {
    static let shared = UndoCenter()

    struct Offer: Identifiable {
        let id = UUID()
        let message: String
        let undo: () -> Void
    }

    @Published private(set) var offer: Offer?
    private var timer: Task<Void, Never>?

    func show(_ message: String, undo: @escaping () -> Void) {
        let new = Offer(message: message, undo: undo)
        offer = new
        UIAccessibility.post(notification: .announcement, argument: message + ". Можно отменить")
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if self?.offer?.id == new.id { self?.offer = nil }
        }
    }

    func performUndo() {
        guard let current = offer else { return }
        offer = nil
        timer?.cancel()
        current.undo()
        UIAccessibility.post(notification: .announcement, argument: "Отменено")
    }

    func dismiss() {
        offer = nil
        timer?.cancel()
    }
}

struct UndoToast: View {
    @ObservedObject var center: UndoCenter

    var body: some View {
        if let offer = center.offer {
            HStack(spacing: 12) {
                Text(offer.message)
                    .font(DS.Fonts.text(15, .semibold, relativeTo: .subheadline))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Отменить") { center.performUndo() }
                    .font(DS.Fonts.text(15, .heavy, relativeTo: .subheadline))
                    .foregroundColor(DS.Colors.canvas)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(DS.Colors.today, in: Capsule())
                    .buttonStyle(PressScaleStyle())
                    .accessibilityIdentifier("undo-button")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .background(DS.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 16))
            .inked(cornerRadius: 16, shadow: 4)
            .padding(.horizontal, DS.Metrics.screenGutter)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(offer.id)
        }
    }
}

// MARK: - Recently deleted

/// Something deleted that can still come back for 30 days.
struct DeletedItem: Identifiable, Hashable {
    let id: String
    let title: String
    let section: MainTab
    let deletedAt: Date
}

/// Each section store that keeps deleted things for 30 days registers itself here.
@MainActor
protocol RecentlyDeletedSource: AnyObject {
    var deletedItems: [DeletedItem] { get }
    func restoreDeleted(id: String)
    func purgeDeleted(id: String)
}

@MainActor
final class RecentlyDeleted: ObservableObject {
    static let shared = RecentlyDeleted()
    /// «Настройки → Заметки → Хранить удалённое»: 7, 30 or 90 days; 30 when not set.
    nonisolated static var keepDays: Int { SectionPrefs.keepDays() }
    private var sources: [ObjectIdentifier: RecentlyDeletedSource] = [:]

    func register(_ source: RecentlyDeletedSource) {
        sources[ObjectIdentifier(source)] = source
        objectWillChange.send()
    }

    var items: [DeletedItem] {
        let limit = Date().addingTimeInterval(-Double(Self.keepDays) * 86_400)
        return sources.values.flatMap { $0.deletedItems }
            .filter { $0.deletedAt >= limit }
            .sorted { $0.deletedAt > $1.deletedAt }
    }

    func restore(_ item: DeletedItem) {
        objectWillChange.send()
        sources.values.first { source in source.deletedItems.contains { $0.id == item.id } }?.restoreDeleted(id: item.id)
    }

    /// «Удалить навсегда»: the owning store erases the item the same way the 30-day expiry does
    /// (goal and habit trash on this phone; a note keeps only its empty tombstone, so other devices drop it too).
    func purge(_ item: DeletedItem) {
        objectWillChange.send()
        sources.values.first { source in source.deletedItems.contains { $0.id == item.id } }?.purgeDeleted(id: item.id)
    }

    /// «Очистить всё»: every registered store erases everything it keeps as deleted.
    func purgeAll() {
        objectWillChange.send()
        for source in sources.values {
            for item in source.deletedItems { source.purgeDeleted(id: item.id) }
        }
    }
}

struct RecentlyDeletedScreen: View {
    /// What «Удалить навсегда» is about to erase: one item or everything.
    private enum PurgeRequest {
        case one(DeletedItem)
        case all
    }

    @ObservedObject var store = RecentlyDeleted.shared
    @State private var purgeRequest: PurgeRequest?
    @Environment(\.dismiss) private var dismiss

    private var purgeTitle: String {
        if case .all? = purgeRequest { return "Очистить всё?" }
        return "Удалить навсегда?"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ProfileHeader(kicker: "Профиль", title: "Недавно удалённые", backLabel: "Назад") { dismiss() }
                    .padding(.bottom, 8)
                Text("Здесь лежит удалённое за последние \(RecentlyDeleted.keepDays) дней. Потом оно стирается само.")
                    .font(DS.Fonts.text(15, relativeTo: .subheadline))
                    .foregroundColor(DS.Colors.textSecondary)
                if !store.items.isEmpty {
                    HStack {
                        Text("Удержите запись, чтобы удалить её навсегда.")
                            .font(DS.Fonts.text(13, relativeTo: .caption))
                            .foregroundColor(DS.Colors.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Очистить всё") { purgeRequest = .all }
                            .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                            .foregroundColor(DS.Colors.destructive)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("recently-deleted-clear")
                    }
                }
                if store.items.isEmpty {
                    EmptyState(title: "Пусто", message: "Удалённые записи появятся здесь", icon: "trash")
                }
                ForEach(store.items) { item in
                    HStack(spacing: 12) {
                        Circle().fill(item.section.accent).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(DS.Fonts.text(17, .semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(2)
                            Text("\(item.section.title) · \(item.deletedAt.formatted(.relative(presentation: .named)))")
                                .font(DS.Fonts.text(13, relativeTo: .caption))
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Button("Вернуть") { store.restore(item) }
                            .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                            .foregroundColor(item.section.accent)
                            .frame(minHeight: 44)
                    }
                    .padding(14)
                    .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18))
                    .contextMenu {
                        Button("Вернуть", systemImage: "arrow.uturn.backward") { store.restore(item) }
                        Button("Удалить навсегда", systemImage: "trash", role: .destructive) { purgeRequest = .one(item) }
                    }
                    .accessibilityAction(named: "Удалить навсегда") { purgeRequest = .one(item) }
                }
            }
            .padding(.horizontal, DS.Metrics.screenGutter)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(DS.Colors.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        // `presenting:` hands the request to the buttons even after the binding has been reset by the dismissal.
        .alert(purgeTitle, isPresented: Binding(get: { purgeRequest != nil }, set: { if !$0 { purgeRequest = nil } }),
               presenting: purgeRequest) { request in
            Button("Удалить навсегда", role: .destructive) {
                switch request {
                case .one(let item): store.purge(item)
                case .all: store.purgeAll()
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: { _ in
            Text("Восстановить будет нельзя.")
        }
    }
}

// The mascot (targets, walking hero, highlight) lives in MascotLayer.swift.
