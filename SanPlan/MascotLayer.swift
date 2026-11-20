import SwiftUI
import UIKit

// The walking mascot no longer explains the interface: the tour (MascotTour.swift) does that.
// On a tap it says a summary of the section and reminders from the person's own data (MascotReminders.swift),
// reacts to events, and rarely speaks on its own (plan 20.11 §1).

/// One reaction line queued by `MascotEventWatcher`.
struct MascotReaction: Equatable {
    let id = UUID()
    let text: String
    let event: MascotEvent?
}

/// Shared mascot state: where the tab bar starts and the latest reaction.
@MainActor
final class MascotCenter: ObservableObject {
    static let shared = MascotCenter()
    /// Top edge of the tab bar in global coordinates; the lane is right above it.
    @Published var barTop: CGFloat?
    @Published private(set) var reaction: MascotReaction?

    func react(_ text: String, event: MascotEvent? = nil) {
        reaction = MascotReaction(text: text, event: event)
    }
}

/// The screen edge the hero hides behind; kept in AppStorage so it survives a relaunch.
enum MascotEdge: String {
    case left, right, top, bottom

    /// The edge the drop or fling points past most; nil when the predicted centre stays inside `bounds`.
    static func pick(predicted: CGPoint, bounds: CGRect) -> MascotEdge? {
        let over: [(MascotEdge, CGFloat)] = [
            (.left, bounds.minX - predicted.x), (.right, predicted.x - bounds.maxX),
            (.top, bounds.minY - predicted.y), (.bottom, predicted.y - bounds.maxY),
        ]
        guard let best = over.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return best.0
    }

    var image: String {
        switch self {
        case .left: return "PetPeekLeft"
        case .right: return "PetPeekRight"
        case .top: return "PetPeekTop"
        case .bottom: return "PetPeekBottom"
        }
    }

    var vertical: Bool { self == .left || self == .right }
}

/// Night hours: the hero sleeps.
enum MascotClock {
    static func isNight(hour: Int) -> Bool { hour >= 23 || hour < 7 }
}

// MARK: - Walking mascot

private struct PetMove {
    var from: CGPoint
    var to: CGPoint
    var start: Date
    var duration: Double
    var walking: Bool
}

private enum PetEffect {
    case jump, wave, hop

    var duration: Double {
        switch self {
        case .jump: return 1.2
        case .wave: return 0.9
        case .hop: return 0.5
        }
    }
}

/// The canvas hero: walks along the lane right above the tab bar, follows the finger exactly when dragged,
/// hides behind the edge it is thrown to, and on a tap says a summary from the person's data.
/// User activity elsewhere never cuts a line or a walk; only a drag of the hero or hiding does.
struct PetLayer: View {
    let area: CGSize
    let tab: MainTab
    /// Read at the moment of the tap, so the line is about the data as it is now.
    let reminders: @MainActor () -> [String]
    /// A rare line of its own; nil when nothing is worth saying.
    let selfTalk: @MainActor () -> String?

    @AppStorage("pet.visible") private var visible = true
    @AppStorage("pet.hiddenEdge") private var hiddenRaw = ""
    /// Where along the hidden edge it peeks, 0…1.
    @AppStorage("pet.hiddenAlong") private var hiddenAlong = 0.5
    @ObservedObject private var center: MascotCenter
    @ObservedObject private var wardrobe: MascotWardrobe
    @ObservedObject private var tour: TourCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private let size = CGSize(width: 64, height: 84)
    private let peek: CGFloat = 56
    private static let space = "mascot-layer"
    /// UI tests tap buttons near the bottom: the walking hero would be in the way there.
    private static let offForTests = ProcessInfo.processInfo.arguments.contains("--no-pet")

    @State private var spot = CGPoint(x: 14, y: 0)
    @State private var onLane = true
    @State private var move: PetMove?
    @State private var pose: MascotPoseKey = .think
    @State private var facingLeft = false
    @State private var bubble: String?
    @State private var bubbleSize: CGSize = .zero
    /// One waiting line, newest wins; said when the current one ends.
    @State private var pending: (text: String, event: MascotEvent?)?
    @State private var grab: CGSize?
    @State private var generation = 0
    @State private var speech = 0
    @State private var effect: PetEffect?
    @State private var effectStart = Date()
    @State private var keyboardUp = false
    @State private var layerFrame: CGRect = .zero
    @State private var safeTop: CGFloat = 0
    @State private var idleStep = 0
    @State private var lastTalk = Date()
    /// Which reminder line the next tap shows; back to the first one on a tab change.
    @State private var lineIndex = 0
    @State private var liveArea: CGSize = .zero

    init(area: CGSize, tab: MainTab, reminders: @escaping @MainActor () -> [String],
         selfTalk: @escaping @MainActor () -> String? = { nil }) {
        self.area = area
        self.tab = tab
        self.reminders = reminders
        self.selfTalk = selfTalk
        _center = ObservedObject(wrappedValue: MascotCenter.shared)
        _wardrobe = ObservedObject(wrappedValue: MascotWardrobe.shared)
        _tour = ObservedObject(wrappedValue: TourCenter.shared)
    }

    // MARK: Geometry

    private var hiddenEdge: MascotEdge? { MascotEdge(rawValue: hiddenRaw) }
    private var width: CGFloat { liveArea.width > 0 ? liveArea.width : area.width }
    private var height: CGFloat { liveArea.height > 0 ? liveArea.height : area.height }
    private var topY: CGFloat { max(safeTop, 0) }

    /// Bottom of the usable area: the tab bar's top edge in this layer's coordinates.
    private var floorY: CGFloat {
        guard let bar = center.barTop, layerFrame.height > 0 else { return height }
        let local = bar - layerFrame.minY
        return local > 200 ? min(local, height) : height
    }

    private var laneY: CGFloat { max(floorY - size.height - 8, topY) }

    /// The right end of the lane stays free for the «+».
    private var laneMaxX: CGFloat { max(8, width - size.width - 8 - 72) }

    private func laneX(_ x: CGFloat) -> CGFloat { min(max(x, 8), laneMaxX) }

    private var night: Bool { MascotClock.isNight(hour: Calendar.current.component(.hour, from: Date())) }

    /// The tour has its own mascot in the card, so the walking one steps aside while it runs.
    private var heroShown: Bool { visible && !Self.offForTests && !keyboardUp && !tour.isActive && area.height > 200 }

    private func position(at date: Date) -> CGPoint {
        if let move {
            let t = move.duration > 0 ? min(max(date.timeIntervalSince(move.start) / move.duration, 0), 1) : 1
            let e = move.walking ? t : 1 - pow(1 - t, 3)
            return CGPoint(x: move.from.x + (move.to.x - move.from.x) * e, y: move.from.y + (move.to.y - move.from.y) * e)
        }
        return CGPoint(x: spot.x, y: onLane ? laneY : spot.y)
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            if heroShown {
                if hiddenEdge == nil || move != nil {
                    TimelineView(.animation(minimumInterval: nil, paused: move == nil && effect == nil)) { context in
                        let p = position(at: context.date)
                        ZStack(alignment: .topLeading) {
                            hero(walking: move?.walking == true, date: context.date)
                                .offset(x: p.x, y: p.y)
                            if let bubble {
                                bubbleView(bubble, hero: p)
                            } else if night && hiddenEdge == nil {
                                Text("z")
                                    .font(DS.Fonts.text(16, .bold, relativeTo: .subheadline))
                                    .foregroundColor(DS.Colors.textPrimary)
                                    .offset(x: p.x + size.width - 10, y: p.y - 6)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
                if let edge = hiddenEdge, move == nil { peekView(edge) }
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .coordinateSpace(NamedCoordinateSpace.named(Self.space))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { layerFrame = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { safeTop = $0 }
        .onChange(of: area, initial: true) { _, new in liveArea = new }
        .onChange(of: tab) { _, _ in lineIndex = 0 }
        .onChange(of: visible) { _, _ in reset() }
        .onChange(of: tour.isActive) { _, _ in reset() }
        .onChange(of: center.reaction) { _, new in
            guard let new else { return }
            react(new)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { play(.wave) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .task {
            play(.wave)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6.5))
                wander()
            }
        }
    }

    private func hero(walking: Bool, date: Date) -> some View {
        let phase = walking && !reduceMotion ? sin(date.timeIntervalSinceReferenceDate * 2 * .pi / 0.62) : 0
        let fx = effectOffset(at: date)
        return Image(wardrobe.heroImage(pose))
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.height, alignment: .bottom)
            .rotationEffect(.degrees(phase * 4 + fx.angle), anchor: .bottom)
            .offset(y: -abs(phase) * 3 - fx.lift)
            .scaleEffect(x: facingLeft ? -1 : 1, y: 1)
            .shadow(color: .black.opacity(0.45), radius: 4, y: 4)
            .contentShape(Rectangle())
            .gesture(drag)
            .onTapGesture { tapped() }
            .accessibilityElement()
            .accessibilityLabel("Маскот")
            .accessibilityHint("Нажмите — расскажет про этот раздел. Перетащите к краю, чтобы спрятать")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tapped() }
            .accessibilityIdentifier("pet")
    }

    /// Jump/dance on wins, a wave on open, a surprised hop on a big expense; nothing with Reduce Motion.
    private func effectOffset(at date: Date) -> (lift: CGFloat, angle: Double) {
        guard let effect, !reduceMotion else { return (0, 0) }
        let t = date.timeIntervalSince(effectStart)
        guard t >= 0, t < effect.duration else { return (0, 0) }
        switch effect {
        case .jump: return (CGFloat(abs(sin(t * 2 * .pi / 0.8))) * 14, sin(t * 2 * .pi / 0.6) * 8)
        case .wave: return (0, sin(t * 2 * .pi / 0.3) * 10)
        case .hop: return (CGFloat(sin(t * .pi / effect.duration)) * 18, 0)
        }
    }

    private func play(_ newEffect: PetEffect) {
        guard !reduceMotion else { return }
        effect = newEffect
        effectStart = Date()
        let started = effectStart
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(newEffect.duration))
            if effectStart == started { effect = nil }
        }
    }

    /// The canvas speech bubble, kept fully inside the visible area, above the hero when there is room.
    private func bubbleView(_ text: String, hero p: CGPoint) -> some View {
        let bubbleWidth = min(220, max(width - 16, 120))
        let origin = bubbleOrigin(hero: p, width: bubbleWidth)
        return Text(text)
            .font(DS.Fonts.text(14, .semibold, relativeTo: .subheadline))
            .lineSpacing(2)
            .foregroundColor(DS.Colors.hex(0x1B1430))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: bubbleWidth, alignment: .leading)
            .background(DS.Colors.textPrimary, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(DS.Colors.ink, lineWidth: 2))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 8)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { bubbleSize = $0 }
            .offset(x: origin.x, y: origin.y)
            .opacity(bubbleSize.height > 0 ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
    }

    private func bubbleOrigin(hero p: CGPoint, width bubbleWidth: CGFloat) -> CGPoint {
        let h = max(bubbleSize.height, 44)
        let minY = topY + 8
        let maxY = max(floorY - 8 - h, minY)
        let x = min(max(p.x + size.width / 2 - bubbleWidth / 2, 8), max(width - bubbleWidth - 8, 8))
        let candidates = [p.y - 8 - h, p.y + size.height + 8]
        let y = candidates.first { $0 >= minY && $0 <= maxY } ?? min(max(candidates[0], minY), maxY)
        return CGPoint(x: x, y: y)
    }

    // MARK: Hidden

    /// Top-left of the visible peek square for an edge.
    private func peekOrigin(_ edge: MascotEdge) -> CGPoint {
        let along = CGFloat(min(max(hiddenAlong, 0), 1))
        let y = topY + 8 + along * max(floorY - peek - 8 - topY - 8, 0)
        let x = 8 + along * max(width - peek - 16, 0)
        switch edge {
        case .left: return CGPoint(x: 0, y: y)
        case .right: return CGPoint(x: width - peek, y: y)
        case .top: return CGPoint(x: x, y: topY)
        case .bottom: return CGPoint(x: x, y: floorY - peek)
        }
    }

    /// The peeking hero: the edge's image when the asset exists, otherwise the old tab shape.
    private func peekView(_ edge: MascotEdge) -> some View {
        let origin = peekOrigin(edge)
        return Button { recall() } label: {
            Group {
                if MascotAssets.exists(edge.image) {
                    Image(edge.image).resizable().scaledToFit()
                } else {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 10, height: 10)
                        .frame(width: edge.vertical ? 34 : peek, height: edge.vertical ? peek : 34)
                        .background(
                            UnevenRoundedRectangle(
                                topLeadingRadius: edge == .right || edge == .bottom ? 22 : 0,
                                bottomLeadingRadius: edge == .right || edge == .top ? 22 : 0,
                                bottomTrailingRadius: edge == .left || edge == .top ? 22 : 0,
                                topTrailingRadius: edge == .left || edge == .bottom ? 22 : 0
                            )
                            .fill(DS.Colors.accentDeep)
                        )
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 6)
                        .frame(width: peek, height: peek, alignment: alignment(edge))
                }
            }
            .frame(width: peek, height: peek)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .offset(x: origin.x, y: origin.y)
        .accessibilityLabel("Позвать маскота")
        .accessibilityIdentifier("pet-call")
    }

    private func alignment(_ edge: MascotEdge) -> Alignment {
        switch edge {
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }

    /// Where the hero stands fully behind the edge.
    private func offscreen(_ edge: MascotEdge) -> CGPoint {
        let o = peekOrigin(edge)
        switch edge {
        case .left: return CGPoint(x: -size.width - 16, y: o.y)
        case .right: return CGPoint(x: width + 16, y: o.y)
        case .top: return CGPoint(x: o.x, y: -size.height - 16)
        case .bottom: return CGPoint(x: o.x, y: height + 16)
        }
    }

    // MARK: Drag

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: NamedCoordinateSpace.named(Self.space))
            .onChanged { value in
                let offset: CGSize
                if let current = grab {
                    offset = current
                } else {
                    // A direct grab is the one thing that cuts a walk and a line.
                    let now = position(at: Date())
                    generation += 1
                    speech += 1
                    move = nil
                    bubble = nil
                    pending = nil
                    onLane = false
                    offset = CGSize(width: value.startLocation.x - now.x, height: value.startLocation.y - now.y)
                    grab = offset
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    spot = CGPoint(
                        x: min(max(value.location.x - offset.width, -size.width), width),
                        y: min(max(value.location.y - offset.height, -size.height / 2), floorY - size.height / 2)
                    )
                }
            }
            .onEnded { value in
                guard let offset = grab else { return }
                grab = nil
                let predicted = CGPoint(
                    x: value.predictedEndLocation.x - offset.width + size.width / 2,
                    y: value.predictedEndLocation.y - offset.height + size.height / 2
                )
                let bounds = CGRect(x: size.width * 0.15, y: topY, width: max(width - size.width * 0.3, 1),
                                    height: max(floorY - 8 - topY, 1))
                if let edge = MascotEdge.pick(predicted: predicted, bounds: bounds) {
                    hide(edge)
                } else {
                    later(0.6, generation) { returnToLane() }
                }
            }
    }

    private func hide(_ edge: MascotEdge) {
        speech += 1
        bubble = nil
        pending = nil
        let here = position(at: Date())
        hiddenAlong = edge.vertical
            ? Double((here.y - topY) / max(floorY - topY - size.height, 1))
            : Double(here.x / max(width - size.width, 1))
        hiddenAlong = min(max(hiddenAlong, 0), 1)
        hiddenRaw = edge.rawValue
        onLane = false
        go(to: offscreen(edge), duration: 0.22, walking: false, lane: false) { pose = .rest }
    }

    private func recall() {
        guard let edge = hiddenEdge else { return }
        generation += 1
        move = nil
        spot = offscreen(edge)
        onLane = false
        hiddenRaw = ""
        pose = .shrug
        let x: CGFloat
        switch edge {
        case .left: x = 12
        case .right: x = laneMaxX
        case .top, .bottom: x = peekOrigin(edge).x
        }
        go(to: CGPoint(x: laneX(x), y: laneY), duration: 0.45, walking: false, lane: true) { pose = .think }
    }

    // MARK: Tap → summary and reminders

    private func tapped() {
        if hiddenEdge != nil { recall(); return }
        guard grab == nil else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let lines = reminders()
        guard !lines.isEmpty else {
            say("На сегодня напомнить нечего.", pose: .shrug)
            return
        }
        let line = lines[lineIndex % lines.count]
        lineIndex += 1
        say(line, pose: .point)
    }

    /// While a line is up the newest reaction waits its turn; hidden or grabbed, it is dropped.
    private func react(_ reaction: MascotReaction) {
        guard heroShown, hiddenEdge == nil, grab == nil else { return }
        if bubble != nil {
            pending = (reaction.text, reaction.event)
            return
        }
        perform(reaction.text, event: reaction.event)
    }

    private func perform(_ text: String, event: MascotEvent?) {
        if event == .bigExpense {
            say(text, pose: .shrug)
            play(.hop)
        } else if event != nil {
            say(text, pose: .cheer)
            if event?.important == true { play(.jump) }
        } else {
            say(text, pose: .think)
        }
    }

    /// Shows the line over the hero wherever it is; a walk in progress goes on.
    private func say(_ text: String, pose newPose: MascotPoseKey) {
        speech += 1
        let token = speech
        pose = newPose
        bubbleSize = .zero
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { bubble = text }
        UIAccessibility.post(notification: .announcement, argument: text)
        let hold = min(max(3.5, Double(text.count) * 0.06), 6)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(hold))
            guard token == speech else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { bubble = nil }
            if let next = pending {
                pending = nil
                perform(next.text, event: next.event)
            } else if move == nil {
                pose = night ? .rest : .think
            }
        }
    }

    private func returnToLane() {
        let from = position(at: Date())
        go(to: CGPoint(x: laneX(from.x), y: laneY), duration: 0.8, walking: false, lane: true) {
            pose = night ? .rest : .think
        }
    }

    // MARK: Idle

    /// Strolls along the lane; at night slower and asleep. Speaks on its own rarely.
    private func wander() {
        guard heroShown, move == nil, grab == nil, hiddenEdge == nil, bubble == nil else { return }
        if !onLane { returnToLane(); return }
        if !night, SectionPrefs.mascotLines(), Date().timeIntervalSince(lastTalk) >= MascotSelfTalk.gap,
           let line = selfTalk() {
            lastTalk = Date()
            say(line, pose: .point)
            return
        }
        idleStep += 1
        if night {
            pose = .rest
            guard idleStep % 4 == 1 else { return }
        }
        if idleStep % 2 == 1 || night {
            let x = CGFloat.random(in: 8...laneMaxX)
            let from = position(at: Date())
            let speed = night ? 0.03 : 0.016
            if !night { pose = .think }
            go(to: CGPoint(x: x, y: laneY), duration: max(0.9, Double(abs(x - from.x)) * speed), walking: true, lane: true)
        } else {
            pose = [MascotPoseKey.think, .yawn, .shrug][idleStep % 3]
        }
    }

    /// Only for the hero going away (switched off, the tour): drops the line and the walk.
    private func reset() {
        let now = position(at: Date())
        generation += 1
        speech += 1
        move = nil
        grab = nil
        bubble = nil
        pending = nil
        if hiddenEdge == nil {
            spot = CGPoint(x: laneX(now.x), y: laneY)
            onLane = true
            pose = .think
        }
    }

    // MARK: Motion

    /// Moves the hero; a later move, drag or reset cancels the pending `done`.
    private func go(to target: CGPoint, duration: Double, walking: Bool, lane: Bool, then done: @escaping () -> Void = {}) {
        generation += 1
        let gen = generation
        let from = position(at: Date())
        if abs(target.x - from.x) > 1 { facingLeft = target.x < from.x }
        let time = reduceMotion ? 0 : duration
        guard time > 0.01, hypot(target.x - from.x, target.y - from.y) > 1 else {
            move = nil
            spot = target
            onLane = lane
            done()
            return
        }
        move = PetMove(from: from, to: target, start: Date(), duration: time, walking: walking)
        later(time, gen) {
            move = nil
            spot = target
            onLane = lane
            done()
        }
    }

    private func later(_ seconds: Double, _ gen: Int, _ action: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard gen == generation else { return }
            action()
        }
    }
}
