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

    /// «Сегодня» is always shown; the others can be hidden in «Профиль».
    var visibilityKey: String { "section.visible.\(rawValue)" }
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
            .transformPreference(PetTipKey.self) { if !isActive { $0 = [] } }
            .environment(\.tabIsActive, isActive)
            .zIndex(isActive ? 1 : 0)
    }
}

private struct TabIsActiveKey: EnvironmentKey { static let defaultValue = true }
private struct ShellBarInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    /// Height of the shared bottom bar. UIKit-backed containers (NavigationSplitView) do not receive
    /// the shell's safe-area inset, so they reserve this space themselves via `clearOfShellBar()`.
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

private struct ClearOfShellBar: ViewModifier {
    @Environment(\.shellBarInset) private var inset

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: inset).accessibilityHidden(true)
        }
    }
}

extension View {
    /// Keeps content (and its «+») above the shared bottom bar inside a NavigationSplitView column.
    func clearOfShellBar() -> some View { modifier(ClearOfShellBar()) }
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
    static let keepDays = 30
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

    func purge(_ item: DeletedItem) {
        objectWillChange.send()
        sources.values.first { source in source.deletedItems.contains { $0.id == item.id } }?.purgeDeleted(id: item.id)
    }
}

struct RecentlyDeletedScreen: View {
    @ObservedObject var store = RecentlyDeleted.shared
    @State private var purgeTarget: DeletedItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Здесь лежит удалённое за последние \(RecentlyDeleted.keepDays) дней. Потом оно стирается само.")
                    .font(DS.Fonts.text(15, relativeTo: .subheadline))
                    .foregroundColor(DS.Colors.textSecondary)
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
                        Button("Удалить навсегда", systemImage: "trash", role: .destructive) { purgeTarget = item }
                    }
                }
            }
            .padding(DS.Metrics.screenGutter)
        }
        .background(DS.Colors.canvas.ignoresSafeArea())
        .navigationTitle("Недавно удалённые")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Удалить навсегда?", isPresented: Binding(get: { purgeTarget != nil }, set: { if !$0 { purgeTarget = nil } }), titleVisibility: .visible) {
            Button("Удалить навсегда", role: .destructive) { if let item = purgeTarget { store.purge(item) } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это нельзя вернуть.")
        }
    }
}

// MARK: - Mascot

/// A screen element the hero can walk to and point at: `.petTip("…")`.
struct PetTip {
    let text: String
    let anchor: Anchor<CGRect>
}

struct PetTipKey: PreferenceKey {
    static var defaultValue: [PetTip] = []
    static func reduce(value: inout [PetTip], nextValue: () -> [PetTip]) { value.append(contentsOf: nextValue()) }
}

extension View {
    /// Marks this element as something the hero shows when tapped. Order on screen is the order of tips.
    func petTip(_ text: String) -> some View {
        anchorPreference(key: PetTipKey.self, value: .bounds) { [PetTip(text: text, anchor: $0)] }
    }
}

enum PetPose: String, CaseIterable {
    case think = "PetThink", cheer = "PetCheer", rest = "PetRest", shrug = "PetShrug", point = "PetPoint", yawn = "PetYawn"
}

struct PetResolvedTip: Equatable {
    let text: String
    let rect: CGRect
}

/// The walking hero from the canvas: wanders along the bottom, can be dragged or tucked behind an edge,
/// and on a tap walks to the next important element of the screen, points at it and says what it is.
struct PetLayer: View {
    let tips: [PetResolvedTip]
    let area: CGSize
    let idleLine: String
    @AppStorage("pet.visible") private var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let size = CGSize(width: 64, height: 84)
    @State private var pos: CGPoint = CGPoint(x: 24, y: -1)
    @State private var pose: PetPose = .think
    @State private var walking = false
    @State private var hiddenSide: Int = 0 // -1 left, 1 right
    @State private var bubble: String?
    @State private var highlight: CGRect?
    @State private var dragStart: CGPoint?
    @State private var busy = false
    @State private var tipIndex = 0
    @State private var keyboardUp = false
    @State private var step = 0

    /// UI tests tap buttons near the bottom: the walking hero would be in the way there.
    private static let offForTests = ProcessInfo.processInfo.arguments.contains("--no-pet")

    private var laneY: CGFloat { max(area.height - size.height - 4, 0) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let highlight {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(DS.Colors.today, lineWidth: 3)
                    .frame(width: highlight.width + 12, height: highlight.height + 12)
                    .offset(x: highlight.minX - 6, y: highlight.minY - 6)
                    .opacity(0.9)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if visible && !Self.offForTests && !keyboardUp && area.height > 200 {
                hero
                    .offset(x: shownX, y: pos.y < 0 ? laneY : pos.y)
                if let bubble {
                    bubbleView(bubble)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .onReceive(Timer.publish(every: 6.5, on: .main, in: .common).autoconnect()) { _ in wander() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .onChange(of: idleLine) { _, _ in reset() }
    }

    private var shownX: CGFloat {
        switch hiddenSide {
        case -1: return -size.width + 14
        case 1: return area.width - 14
        default: return min(max(pos.x, 0), max(area.width - size.width, 0))
        }
    }

    private var hero: some View {
        Image(pose.rawValue)
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.height, alignment: .bottom)
            .rotationEffect(.degrees(walking && !reduceMotion ? (step % 2 == 0 ? -4 : 4) : 0), anchor: .bottom)
            .scaleEffect(x: facingLeft ? -1 : 1, y: 1)
            .shadow(color: .black.opacity(0.45), radius: 4, y: 4)
            .contentShape(Rectangle())
            .gesture(drag)
            .onTapGesture { tapped() }
            .accessibilityElement()
            .accessibilityLabel("Герой")
            .accessibilityHint("Нажмите, и он покажет главное на экране")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tapped() }
            .accessibilityIdentifier("pet")
    }

    @State private var facingLeft = false

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = CGPoint(x: shownX, y: pos.y < 0 ? laneY : pos.y)
                    hiddenSide = 0
                    bubble = nil
                    highlight = nil
                    busy = true
                }
                guard let start = dragStart else { return }
                pose = .shrug
                pos = CGPoint(x: start.x + value.translation.width,
                              y: min(max(start.y + value.translation.height, 0), laneY))
            }
            .onEnded { _ in
                dragStart = nil
                busy = false
                if pos.x < -8 { hide(-1) } else if pos.x > area.width - size.width + 8 { hide(1) } else { pose = .think }
            }
    }

    private func hide(_ side: Int) {
        withAnimation(.easeOut(duration: 0.45)) { hiddenSide = side }
        pose = .rest
    }

    private func tapped() {
        if hiddenSide != 0 {
            let x: CGFloat = hiddenSide < 0 ? 8 : area.width - size.width - 8
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                hiddenSide = 0
                pos.x = x
            }
            pose = .cheer
            return
        }
        guard !busy else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let count = tips.count + 1
        let index = tipIndex % count
        tipIndex += 1
        if index < tips.count {
            point(at: tips[index])
        } else {
            say(idleLine, pose: .cheer)
        }
    }

    private func point(at tip: PetResolvedTip) {
        busy = true
        let target = CGPoint(
            x: min(max(tip.rect.maxX - size.width + 10, 0), area.width - size.width),
            y: min(max(tip.rect.maxY - size.height + 24, 0), laneY)
        )
        walk(to: target) {
            pose = .point
            withAnimation(.easeOut(duration: 0.2)) { highlight = tip.rect }
            say(tip.text, pose: .point, keepBusy: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) {
                withAnimation(.easeOut(duration: 0.2)) {
                    highlight = nil
                    bubble = nil
                }
                walk(to: CGPoint(x: target.x, y: laneY)) { busy = false; pose = .think }
            }
        }
    }

    private func say(_ text: String, pose newPose: PetPose, keepBusy: Bool = false) {
        pose = newPose
        withAnimation(.easeOut(duration: 0.18)) { bubble = text }
        UIAccessibility.post(notification: .announcement, argument: text)
        guard !keepBusy else { return }
        let current = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.8) {
            if bubble == current { withAnimation(.easeOut(duration: 0.2)) { bubble = nil } }
            pose = .think
        }
    }

    private func walk(to target: CGPoint, then done: @escaping () -> Void) {
        let from = CGPoint(x: shownX, y: pos.y < 0 ? laneY : pos.y)
        facingLeft = target.x < from.x
        let distance = hypot(target.x - from.x, target.y - from.y)
        if reduceMotion || distance < 2 {
            pos = target
            done()
            return
        }
        let duration = min(max(Double(distance) / 140, 0.35), 2.2)
        walking = true
        let steps = Int(duration / 0.18)
        for i in 0..<steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.18) { step = i }
        }
        withAnimation(.linear(duration: duration)) { pos = target }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            walking = false
            done()
        }
    }

    private func wander() {
        guard visible, !busy, hiddenSide == 0, dragStart == nil, bubble == nil, area.width > size.width * 2 else { return }
        let x = CGFloat.random(in: 8...(area.width - size.width - 8))
        pose = [.think, .yawn, .cheer].randomElement() ?? .think
        walk(to: CGPoint(x: x, y: laneY)) { pose = .think }
    }

    private func reset() {
        tipIndex = 0
        highlight = nil
        bubble = nil
        busy = false
        if hiddenSide == 0 { pos.y = -1 }
    }

    private func bubbleView(_ text: String) -> some View {
        let heroY = pos.y < 0 ? laneY : pos.y
        let width: CGFloat = min(220, area.width - 16)
        let below = heroY < 140 || highlight != nil && heroY + size.height + 90 < area.height
        let x = min(max(shownX + size.width / 2 - width / 2, 8), area.width - width - 8)
        return Text(text)
            .font(DS.Fonts.text(15, .semibold, relativeTo: .subheadline))
            .foregroundColor(DS.Colors.canvas)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(width: width, alignment: .leading)
            .background(DS.Colors.textPrimary, in: RoundedRectangle(cornerRadius: 14))
            .background(RoundedRectangle(cornerRadius: 14).fill(DS.Colors.ink).offset(x: 3, y: 3))
            .alignmentGuide(.top) { d in below ? 0 : d.height }
            .offset(x: x, y: below ? heroY + size.height + 6 : heroY - 6)
    }
}
