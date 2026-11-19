import SwiftUI
import UIKit

// MARK: - Mascot tour
//
// The mascot walks through the sections: for each step it switches to the step's tab, scrolls the target into
// view when needed, dims the rest of the screen with a cut-out around the target and says one or two sentences.
// Nothing advances on its own: «Дальше», «Назад», «Пропустить».
//
// Three ways in:
// - first launch after this update: the full tour, once per device (`TourLaunch.doneKey`);
// - «Профиль → Настройки → Общие → Краткий тур»: one step per section;
// - «?» in a section's header: the full tour of that section only.
//
// Targets: `someView.tourTarget("money.composer")` on the element itself. The element's live frame is tracked,
// so the cut-out follows it while the person scrolls. A screen's ScrollView gets `.tourScrollHost()` so the tour
// can scroll a target into view. Step texts live in MascotTourSteps.swift.

/// The tour's sections, in the order of the tab bar; `general` covers «+», «Прогресс», the profile and «?».
public enum TourSection: String, CaseIterable, Equatable {
    case today, plans, notes, money, workout, general

    var tab: MainTab {
        switch self {
        case .today, .general: return .today
        case .plans: return .plans
        case .notes: return .notes
        case .money: return .money
        case .workout: return .workout
        }
    }

    var title: String {
        switch self {
        case .general: return "Общее"
        default: return tab.title
        }
    }

    init(tab: MainTab) {
        switch tab {
        case .today: self = .today
        case .plans: self = .plans
        case .notes: self = .notes
        case .money: self = .money
        case .workout: self = .workout
        }
    }
}

public struct TourStep: Equatable, Identifiable {
    public let id: String
    public let section: TourSection
    /// The `tourTarget` id to highlight; nil: the mascot only talks.
    public let target: String?
    public let text: String
    /// The one step the short tour shows for this section.
    public let isKey: Bool

    public init(_ id: String, _ section: TourSection, target: String?, key: Bool = false, _ text: String) {
        self.id = id
        self.section = section
        self.target = target
        self.text = text
        self.isKey = key
    }
}

public enum TourKind: Equatable {
    case full
    case short
    case section(TourSection)
}

/// One run of the tour: the steps and where the person is. Pure, so the order rules are testable.
public struct TourRun: Equatable {
    public let kind: TourKind
    public let steps: [TourStep]
    public private(set) var index = 0
    /// +1 after «Дальше», −1 after «Назад»: a step whose target is not on screen is passed in that direction.
    public private(set) var direction = 1

    public init(kind: TourKind, steps: [TourStep]) {
        self.kind = kind
        self.steps = steps
    }

    public var step: TourStep? { steps.indices.contains(index) ? steps[index] : nil }
    public var isFirst: Bool { index == 0 }
    public var isLast: Bool { index >= steps.count - 1 }
    public var position: String { "\(index + 1) из \(steps.count)" }

    /// False when there is no next step: the run is over.
    public mutating func next() -> Bool {
        direction = 1
        guard index + 1 < steps.count else { return false }
        index += 1
        return true
    }

    public mutating func back() {
        guard index > 0 else { return }
        direction = -1
        index -= 1
    }

    /// The current step's target is not on screen: go on in the same direction. False when the run is over.
    public mutating func passMissing() -> Bool {
        if direction < 0, index > 0 {
            index -= 1
            return true
        }
        return next()
    }

    /// The short tour keeps its one step per section even without a target; the others pass missing ones.
    public var passesMissingTargets: Bool { kind != .short }
}

/// When the tour starts by itself. The flag is per device and versioned: everyone sees the new full tour once.
public enum TourLaunch {
    public static let doneKey = "asan.tour.full.v2.done"
    /// `--mascot-tour [full|short|today|plans|notes|money|workout|general]` starts a tour even in test modes.
    public static let forceArgument = "--mascot-tour"

    public struct Decision: Equatable {
        public let kind: TourKind
        /// Asked for by a launch argument: the device flag is neither checked nor set.
        public let forced: Bool
    }

    public static func isTestRun(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("--screenshot-signed-in")
            || arguments.contains("--no-pet")
            || environment["XCTestConfigurationFilePath"] != nil
    }

    public static func decide(arguments: [String], environment: [String: String], defaults: UserDefaults) -> Decision? {
        if let flag = arguments.firstIndex(of: forceArgument) {
            let value = flag + 1 < arguments.count ? arguments[flag + 1] : "full"
            let kind: TourKind
            if value == "short" {
                kind = .short
            } else if let section = TourSection(rawValue: value) {
                kind = .section(section)
            } else {
                kind = .full
            }
            return Decision(kind: kind, forced: true)
        }
        if isTestRun(arguments: arguments, environment: environment) { return nil }
        if defaults.bool(forKey: doneKey) { return nil }
        return Decision(kind: .full, forced: false)
    }

    public static func markDone(_ defaults: UserDefaults) {
        defaults.set(true, forKey: doneKey)
    }
}

// MARK: - Frames

/// Live global frames of the targets on the active tab, and the visible area the tour works in.
@MainActor
final class TourFrames: ObservableObject {
    static let shared = TourFrames()

    /// Bumped on a frame change while the tour runs, so only the overlay redraws.
    @Published private(set) var tick = 0
    var live = false {
        didSet { if live { tick &+= 1 } }
    }
    /// The area between the status bar and the tab bar, in global coordinates.
    var viewport: CGRect = .zero

    private struct Entry {
        let owner: UUID
        let frame: CGRect
    }

    /// Several views may carry one id (a header in a sheet over the tab's header): the latest one wins,
    /// and when it goes away the one under it is used again.
    private var entries: [String: [Entry]] = [:]

    func frame(_ id: String?) -> CGRect? {
        guard let id else { return nil }
        return entries[id]?.last?.frame
    }

    func set(_ id: String, frame: CGRect, owner: UUID) {
        guard frame.width >= 2, frame.height >= 2 else {
            remove(id, owner: owner)
            return
        }
        var list = entries[id, default: []]
        if let index = list.firstIndex(where: { $0.owner == owner }) {
            list[index] = Entry(owner: owner, frame: frame)
        } else {
            list.append(Entry(owner: owner, frame: frame))
        }
        entries[id] = list
        if live { tick &+= 1 }
    }

    func remove(_ id: String, owner: UUID) {
        guard let list = entries[id], list.contains(where: { $0.owner == owner }) else { return }
        let rest = list.filter { $0.owner != owner }
        entries[id] = rest.isEmpty ? nil : rest
        if live { tick &+= 1 }
    }

    func isFullyVisible(_ id: String) -> Bool {
        guard let frame = frame(id), viewport.height > 0 else { return false }
        return viewport.insetBy(dx: -1, dy: -1).contains(frame)
    }
}

struct TourScrollRequest: Equatable {
    let id: String
    let token: Int
}

// MARK: - Center

/// The running tour. RootView switches the tab to the step's section; targets scroll themselves on request.
@MainActor
final class TourCenter: ObservableObject {
    static let shared = TourCenter()

    @Published private(set) var run: TourRun?
    @Published private(set) var scrollRequest: TourScrollRequest?

    private var token = 0
    private var settle: Task<Void, Never>?

    var isActive: Bool { run != nil }
    var step: TourStep? { run?.step }

    func start(_ kind: TourKind) {
        // A section that is off has no tab to show: its steps are left out.
        let sections = SectionSettings.shared
        let steps = TourPlan.steps(kind).filter { sections.isOn($0.section.tab) }
        guard !steps.isEmpty else { return }
        run = TourRun(kind: kind, steps: steps)
        TourFrames.shared.live = true
        stepChanged(from: nil)
    }

    func next() {
        guard var current = run else { return }
        let previous = current.step
        if current.next() {
            run = current
            stepChanged(from: previous)
        } else {
            end()
        }
    }

    func back() {
        guard var current = run, !current.isFirst else { return }
        let previous = current.step
        current.back()
        run = current
        stepChanged(from: previous)
    }

    func end() {
        settle?.cancel()
        settle = nil
        run = nil
        scrollRequest = nil
        TourFrames.shared.live = false
    }

    private func requestScroll(_ id: String) {
        token += 1
        scrollRequest = TourScrollRequest(id: id, token: token)
    }

    /// After the tab has switched: scroll the target into view if it is not.
    /// The tour never moves on by itself: only the person's «Дальше» does. A step whose target is not on screen
    /// stays, with the card in the middle and nothing lit.
    private func stepChanged(from previous: TourStep?) {
        settle?.cancel()
        guard let step = run?.step else { return }
        // A note left open in «Заметки» would hide the list the steps point at.
        if step.section == .notes, previous?.section != .notes, SectionSettings.shared.isOn(.notes) { DeepLinks.shared.open(.notes) }
        guard let target = step.target else { return }
        let stepID = step.id
        settle = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled, self.run?.step?.id == stepID else { return }
            if !TourFrames.shared.isFullyVisible(target) { self.requestScroll(target) }
        }
    }
}

// MARK: - Placement

/// Where the card stands next to the lit element, and which way the mascot points at it.
/// The card goes into the larger free space beside the element, so the text and the element are read together.
public struct TourPlacement: Equatable {
    public enum Side: Equatable {
        /// The card is right above the element: the mascot points down.
        case above
        /// The card is right under the element: the mascot points up.
        case below
        /// No room beside the element, or nothing is lit: the card sits at the screen edge away from it.
        case edge(top: Bool)
    }

    public enum Pointer: String, Equatable {
        case up, down, upLeft, upRight, forward
    }

    public let side: Side
    /// The mascot stands on the card's leading side (true) or trailing side, whichever is nearer the element.
    public let mascotLeading: Bool
    public let pointer: Pointer

    /// The mascot's width plus the card's outer padding: where its hand is, horizontally.
    static let mascotReach: CGFloat = 52

    public static func decide(hole: CGRect?, area: CGSize, topInset: CGFloat, minSpace: CGFloat = 200) -> TourPlacement {
        guard let hole, hole.width > 0, hole.height > 0 else {
            return TourPlacement(side: .edge(top: false), mascotLeading: true, pointer: .forward)
        }
        let leading = hole.midX <= area.width / 2
        let handX = leading ? mascotReach : area.width - mascotReach
        let dx = hole.midX - handX
        let straight = abs(dx) < area.width * 0.22
        let upward: Pointer = straight ? .up : (dx < 0 ? .upLeft : .upRight)

        let spaceAbove = hole.minY - topInset
        let spaceBelow = area.height - hole.maxY
        if max(spaceAbove, spaceBelow) < minSpace {
            // The element fills the screen: the card covers the far end of it.
            let top = hole.midY > area.height / 2
            return TourPlacement(side: .edge(top: top), mascotLeading: leading, pointer: top ? .down : upward)
        }
        if spaceBelow >= spaceAbove {
            return TourPlacement(side: .below, mascotLeading: leading, pointer: upward)
        }
        return TourPlacement(side: .above, mascotLeading: leading, pointer: .down)
    }
}

// MARK: - Targets

private struct TourScrollProxyKey: EnvironmentKey {
    static var defaultValue: ScrollViewProxy? { nil }
}

extension EnvironmentValues {
    var tourScrollProxy: ScrollViewProxy? {
        get { self[TourScrollProxyKey.self] }
        set { self[TourScrollProxyKey.self] = newValue }
    }
}

private struct TourScrollHost: ViewModifier {
    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.environment(\.tourScrollProxy, proxy)
        }
    }
}

@MainActor
private struct TourTargetModifier: ViewModifier {
    let id: String
    @ObservedObject private var center = TourCenter.shared
    @Environment(\.tabIsActive) private var tabIsActive
    @Environment(\.tourScrollProxy) private var scrollProxy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var owner = UUID()
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .id(id)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { new in
                frame = new
                publish(new, active: tabIsActive)
            }
            .onChange(of: tabIsActive) { _, active in publish(frame, active: active) }
            .onDisappear { TourFrames.shared.remove(id, owner: owner) }
            .onChange(of: center.scrollRequest) { _, request in
                guard let request, request.id == id, tabIsActive, let scrollProxy else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) {
                    scrollProxy.scrollTo(id, anchor: .center)
                }
            }
    }

    private func publish(_ frame: CGRect, active: Bool) {
        if active {
            TourFrames.shared.set(id, frame: frame, owner: owner)
        } else {
            TourFrames.shared.remove(id, owner: owner)
        }
    }
}

extension View {
    /// Marks this element as a tour target. Ids are listed in MascotTourSteps.swift.
    func tourTarget(_ id: String) -> some View {
        modifier(TourTargetModifier(id: id))
    }

    /// Put on a screen's ScrollView, so the tour can scroll its targets into view.
    func tourScrollHost() -> some View {
        modifier(TourScrollHost())
    }
}

/// The small «?» in a section header: the full tour of that section.
struct SectionHelpButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 30, height: 30)
                .background(DS.Colors.surface, in: Circle())
                .frame(width: 34, height: DS.Metrics.minHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Как пользоваться разделом")
        .accessibilityIdentifier("section-help")
    }
}

// MARK: - Overlay

/// The cut-out: the whole area dimmed except a rounded hole around the target. The hole animates between steps.
private struct TourDimShape: Shape {
    var hole: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(hole.origin.x, hole.origin.y), AnimatablePair(hole.size.width, hole.size.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Reaches under the status bar too; nothing is clipped here.
        path.addRect(rect.insetBy(dx: -60, dy: -400))
        if hole.width > 0, hole.height > 0 {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: 18, height: 18), style: .continuous)
        }
        return path
    }
}

/// Drawn over the tabs; RootView switches the tab bar off while it runs.
/// Nothing under the dim takes touches, the lit element included: only the card's buttons work,
/// and only «Дальше» moves the tour on.
@MainActor
struct MascotTourOverlay: View {
    @ObservedObject private var center = TourCenter.shared
    @ObservedObject private var frames = TourFrames.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let area = proxy.frame(in: .global)
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                if let run = center.run, let step = run.step {
                    let hole = frames.frame(step.target).map { $0.offsetBy(dx: -area.minX, dy: -area.minY).insetBy(dx: -8, dy: -8) }
                    let holeKey = "\(step.id)|\(hole != nil)"
                    let accent = step.section.tab.accent
                    let place = TourPlacement.decide(hole: hole, area: proxy.size, topInset: proxy.safeAreaInsets.top)

                    // Swallows every touch, so nothing is pressed or scrolled by accident during the tour.
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0))
                        .accessibilityHidden(true)

                    Group {
                        if reduceMotion {
                            spotlight(hole, accent: accent, size: proxy.size)
                                .id(holeKey)
                                .transition(.opacity)
                        } else {
                            spotlight(hole, accent: accent, size: proxy.size)
                        }
                    }
                    .animation(reduceMotion ? .easeInOut(duration: 0.4) : .spring(duration: 0.6, bounce: 0.1), value: holeKey)
                    .transition(.opacity)

                    card(run, step, accent: accent, place: place)
                        .modifier(TourCardPosition(place: place, hole: hole, size: proxy.size, topInset: proxy.safeAreaInsets.top))
                        .id(reduceMotion ? "card-\(step.id)" : "card")
                        .transition(.opacity)
                        // The mascot walks with the card to the next element.
                        .animation(reduceMotion ? .easeInOut(duration: 0.4) : .spring(duration: 0.7, bounce: 0.18), value: holeKey)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.5), value: center.isActive)
            .onGeometryChange(for: CGRect.self) { geometry in
                let frame = geometry.frame(in: .global)
                let top = geometry.safeAreaInsets.top
                return CGRect(x: frame.minX, y: frame.minY + top, width: frame.width, height: max(frame.height - top, 0))
            } action: { frames.viewport = $0 }
        }
    }

    private func spotlight(_ hole: CGRect?, accent: Color, size: CGSize) -> some View {
        let rect = hole ?? CGRect(x: size.width / 2, y: size.height / 2, width: 0, height: 0)
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return ZStack(alignment: .topLeading) {
            TourDimShape(hole: rect)
                .fill(Color.black.opacity(hole == nil ? 0.45 : 0.6), style: FillStyle(eoFill: true))
            if hole != nil {
                ZStack {
                    shape.stroke(DS.Colors.ink, lineWidth: 6)
                    shape.stroke(accent, lineWidth: 3)
                }
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func mascot(_ place: TourPlacement) -> some View {
        let art = TourPointerArt.image(place.pointer)
        return Image(art.name)
            .resizable()
            .scaledToFit()
            .scaleEffect(x: art.mirrored ? -1 : 1, y: 1)
            .frame(width: 74, height: 100, alignment: place.side == .above ? .bottom : .top)
            .shadow(color: .black.opacity(0.45), radius: 4, y: 4)
            .id(art.name + (art.mirrored ? "-m" : ""))
            .transition(.opacity)
            .accessibilityHidden(true)
    }

    private func card(_ run: TourRun, _ step: TourStep, accent: Color, place: TourPlacement) -> some View {
        let ink = DS.Colors.hex(0x1B1430)
        return HStack(alignment: place.side == .above ? .bottom : .top, spacing: 4) {
            if place.mascotLeading { mascot(place) }
            bubble(run, step, accent: accent, ink: ink)
            if !place.mascotLeading { mascot(place) }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tour-card")
        .onChange(of: step.id, initial: true) { _, _ in
            UIAccessibility.post(notification: .announcement, argument: step.text)
        }
    }

    private func bubble(_ run: TourRun, _ step: TourStep, accent: Color, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
                Text("\(step.section.title) · \(run.position)".uppercased())
                    .font(DS.Fonts.text(11, .heavy, relativeTo: .caption))
                    .tracking(0.6)
                    .foregroundColor(ink.opacity(0.6))
                Text(step.text)
                    .font(DS.Fonts.text(15, .semibold, relativeTo: .subheadline))
                    .lineSpacing(2)
                    .foregroundColor(ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(step.id)
                    .transition(.opacity)
                HStack(spacing: 8) {
                    Button("Пропустить") { center.end() }
                        .font(DS.Fonts.text(14, .semibold, relativeTo: .subheadline))
                        .foregroundColor(ink.opacity(0.65))
                        .frame(minHeight: DS.Metrics.minHitTarget)
                        .accessibilityIdentifier("tour-skip")
                    Spacer(minLength: 0)
                    if !run.isFirst {
                        Button("Назад") { center.back() }
                            .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                            .foregroundColor(ink)
                            .padding(.horizontal, 12)
                            .frame(minHeight: DS.Metrics.minHitTarget)
                            .accessibilityIdentifier("tour-back")
                    }
                    Button {
                        center.next()
                    } label: {
                        Text(run.isLast ? "Готово" : "Дальше")
                            .font(DS.Fonts.text(15, .heavy, relativeTo: .subheadline))
                            .foregroundColor(DS.Colors.ink)
                            .padding(.horizontal, 16)
                            .frame(minHeight: DS.Metrics.minHitTarget)
                            .background(accent, in: Capsule())
                            .overlay(Capsule().stroke(DS.Colors.ink, lineWidth: 2))
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityIdentifier("tour-next")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(DS.Colors.textPrimary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(DS.Colors.ink, lineWidth: 2))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 8)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: step.id)
    }
}

/// Puts the card right above or right under the lit element, or at a screen edge when there is no room.
private struct TourCardPosition: ViewModifier {
    let place: TourPlacement
    let hole: CGRect?
    let size: CGSize
    let topInset: CGFloat

    func body(content: Content) -> some View {
        switch place.side {
        case .below:
            content
                .padding(.top, (hole?.maxY ?? 0) + 6)
                .frame(width: size.width, height: size.height, alignment: .top)
        case .above:
            content
                .frame(width: size.width, height: max((hole?.minY ?? size.height) - 6, 0), alignment: .bottom)
                .frame(width: size.width, height: size.height, alignment: .top)
        case .edge(let top):
            content
                .padding(.top, top ? topInset + 8 : 0)
                .padding(.bottom, top ? 0 : 10)
                .frame(width: size.width, height: size.height, alignment: top ? .top : .bottom)
        }
    }
}

/// The mascot's pointing picture for a direction. Only the base look has them; other looks point forward.
@MainActor
enum TourPointerArt {
    static func image(_ pointer: TourPlacement.Pointer) -> (name: String, mirrored: Bool) {
        let fallback = MascotWardrobe.shared.heroImage(.point)
        guard MascotWardrobe.shared.skinID == MascotArcs.baseSkin else { return (fallback, false) }
        let choice: (String, Bool)
        switch pointer {
        case .up: choice = ("PetPointUp", false)
        case .down: choice = ("PetPointDown", false)
        case .upLeft: choice = ("PetPointUpLeft", false)
        case .upRight: choice = ("PetPointUpLeft", true)
        case .forward: return (fallback, false)
        }
        return MascotAssets.exists(choice.0) ? (choice.0, choice.1) : (fallback, false)
    }
}
