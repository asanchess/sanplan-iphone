import SwiftUI
import UIKit

// The walking mascot no longer explains the interface: the tour (MascotTour.swift) does that.
// On a tap it says one short reminder from the person's own data (MascotReminders.swift),
// and it reacts once, briefly, when a plan is done, a workout is finished or an expense is added.

/// One reaction line queued by `MascotEventWatcher`.
struct MascotReaction: Equatable {
    let id = UUID()
    let text: String
    let cheerful: Bool
}

/// Shared mascot state: where the tab bar starts and the latest reaction.
@MainActor
final class MascotCenter: ObservableObject {
    static let shared = MascotCenter()
    /// Top edge of the tab bar in global coordinates; the lane is right above it.
    @Published var barTop: CGFloat?
    @Published private(set) var reaction: MascotReaction?

    func react(_ text: String, cheerful: Bool) {
        reaction = MascotReaction(text: text, cheerful: cheerful)
    }
}

// MARK: - Walking mascot

private struct PetMove {
    var from: CGPoint
    var to: CGPoint
    var start: Date
    var duration: Double
    var walking: Bool
}

/// The canvas hero: walks along the lane right above the tab bar, follows the finger exactly when dragged,
/// hides behind an edge when thrown there, and on a tap says one reminder from the person's data.
/// Position is computed per frame from the current move (no implicit animation), so a grab mid-walk starts exactly
/// where the hero is drawn.
struct PetLayer: View {
    let area: CGSize
    let tab: MainTab
    /// Read at the moment of the tap, so the line is about the data as it is now.
    let reminders: @MainActor () -> [String]

    @AppStorage("pet.visible") private var visible = true
    @ObservedObject private var center: MascotCenter
    @ObservedObject private var wardrobe: MascotWardrobe
    @ObservedObject private var tour: TourCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let size = CGSize(width: 64, height: 84)
    private static let space = "mascot-layer"
    /// UI tests tap buttons near the bottom: the walking hero would be in the way there.
    private static let offForTests = ProcessInfo.processInfo.arguments.contains("--no-pet")

    @State private var spot = CGPoint(x: -32, y: 0)
    @State private var onLane = true
    @State private var move: PetMove?
    @State private var pose: MascotPoseKey = .think
    @State private var facingLeft = false
    @State private var hiddenSide = 0
    @State private var bubble: String?
    @State private var bubbleSize: CGSize = .zero
    @State private var grab: CGSize?
    @State private var generation = 0
    @State private var keyboardUp = false
    @State private var layerFrame: CGRect = .zero
    @State private var safeTop: CGFloat = 0
    @State private var idleStep = 0
    /// Which reminder line the next tap shows; back to the first one on a tab change.
    @State private var lineIndex = 0
    @State private var liveArea: CGSize = .zero

    init(area: CGSize, tab: MainTab, reminders: @escaping @MainActor () -> [String]) {
        self.area = area
        self.tab = tab
        self.reminders = reminders
        _center = ObservedObject(wrappedValue: MascotCenter.shared)
        _wardrobe = ObservedObject(wrappedValue: MascotWardrobe.shared)
        _tour = ObservedObject(wrappedValue: TourCenter.shared)
    }

    // MARK: Geometry

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

    private func laneX(_ x: CGFloat) -> CGFloat { min(max(x, 8), max(width - size.width - 8, 8)) }

    /// At rest the hero peeks from behind the left edge, so it does not cover content.
    private var peekX: CGFloat { -size.width / 2 }

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
                TimelineView(.animation(minimumInterval: nil, paused: move == nil)) { context in
                    let p = position(at: context.date)
                    ZStack(alignment: .topLeading) {
                        hero(walking: move?.walking == true, date: context.date)
                            .offset(x: p.x, y: p.y)
                        if let bubble {
                            bubbleView(bubble, hero: p)
                        }
                    }
                }
                if hiddenSide != 0 { edgeTab }
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .coordinateSpace(NamedCoordinateSpace.named(Self.space))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { layerFrame = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { safeTop = $0 }
        .onChange(of: area, initial: true) { _, new in liveArea = new }
        .onChange(of: tab) { _, _ in
            lineIndex = 0
            reset()
        }
        .onChange(of: visible) { _, _ in reset() }
        .onChange(of: tour.isActive) { _, _ in reset() }
        .onChange(of: center.reaction) { _, new in
            guard let new else { return }
            react(new)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardUp = true
            reset()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6.5))
                wander()
            }
        }
    }

    private func hero(walking: Bool, date: Date) -> some View {
        let phase = walking && !reduceMotion ? sin(date.timeIntervalSinceReferenceDate * 2 * .pi / 0.62) : 0
        return Image(wardrobe.heroImage(pose))
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.height, alignment: .bottom)
            .rotationEffect(.degrees(phase * 4), anchor: .bottom)
            .offset(y: -abs(phase) * 3)
            .scaleEffect(x: facingLeft ? -1 : 1, y: 1)
            .shadow(color: .black.opacity(0.45), radius: 4, y: 4)
            .contentShape(Rectangle())
            .gesture(drag)
            .onTapGesture { tapped() }
            .accessibilityElement()
            .accessibilityLabel("Маскот")
            .accessibilityHint("Нажмите — напомнит, что осталось на сегодня. Перетащите к краю, чтобы спрятать")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tapped() }
            .accessibilityIdentifier("pet")
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

    /// The canvas tab that calls the hero back from behind an edge.
    private var edgeTab: some View {
        let left = hiddenSide < 0
        let y = min(max(spot.y + 20, topY + 8), max(floorY - 56, topY + 8))
        return Button { recall() } label: {
            ZStack(alignment: left ? .leading : .trailing) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                    .frame(width: 28, height: 48)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: left ? 0 : 20,
                            bottomLeadingRadius: left ? 0 : 20,
                            bottomTrailingRadius: left ? 20 : 0,
                            topTrailingRadius: left ? 20 : 0
                        )
                        .fill(DS.Colors.accentDeep)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 6)
            }
            .frame(width: 44, height: 48, alignment: left ? .leading : .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .offset(x: left ? 0 : width - 44, y: y)
        .accessibilityLabel("Позвать маскота")
        .accessibilityIdentifier("pet-call")
    }

    // MARK: Drag

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: NamedCoordinateSpace.named(Self.space))
            .onChanged { value in
                let offset: CGSize
                if let current = grab {
                    offset = current
                } else {
                    // Grab where the hero is drawn right now, cancel whatever it was doing, keep the pose.
                    let now = position(at: Date())
                    generation += 1
                    move = nil
                    bubble = nil
                    hiddenSide = 0
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
                let flungX = value.predictedEndLocation.x - offset.width
                if spot.x < -size.width * 0.35 || flungX < -size.width * 0.8 {
                    hide(-1)
                } else if spot.x > width - size.width * 0.65 || flungX > width - size.width * 0.2 {
                    hide(1)
                } else {
                    later(0.6, generation) { returnToLane() }
                }
            }
    }

    private func hide(_ side: Int) {
        spot.y = min(max(spot.y, topY), laneY)
        onLane = false
        hiddenSide = side
        go(to: CGPoint(x: side < 0 ? -size.width - 16 : width + 16, y: spot.y), duration: 0.22, walking: false, lane: false) {
            pose = .rest
        }
    }

    private func recall() {
        let side = hiddenSide
        hiddenSide = 0
        pose = .shrug
        let x = side < 0 ? 12 : width - size.width - 12
        go(to: CGPoint(x: laneX(x), y: laneY), duration: 0.45, walking: false, lane: true) { pose = .think }
    }

    // MARK: Tap → reminder

    private func tapped() {
        if hiddenSide != 0 { recall(); return }
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

    /// A reaction is said once and only when the hero is out and free; otherwise it is dropped, not queued.
    private func react(_ reaction: MascotReaction) {
        guard heroShown, hiddenSide == 0, grab == nil, bubble == nil else { return }
        say(reaction.text, pose: reaction.cheerful ? .cheer : .think)
    }

    /// Stops where it stands, says the line, holds it long enough to read, then goes back to the lane.
    private func say(_ text: String, pose newPose: MascotPoseKey) {
        var here = position(at: Date())
        if here.x < 8 { here.x = 8 }  // steps out from behind the edge to speak
        generation += 1
        move = nil
        spot = here
        pose = newPose
        bubbleSize = .zero
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { bubble = text }
        UIAccessibility.post(notification: .announcement, argument: text)
        let hold = min(max(3.5, Double(text.count) * 0.06), 6)
        later(hold, generation) {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { bubble = nil }
            returnToLane()
        }
    }

    private func returnToLane() {
        let from = position(at: Date())
        go(to: CGPoint(x: peekX, y: laneY), duration: 0.8, walking: true, lane: true) {
            pose = .think
        }
    }

    // MARK: Idle

    /// Movement only: no words without a tap or an event.
    private func wander() {
        guard heroShown, move == nil, grab == nil, hiddenSide == 0, bubble == nil else { return }
        if !onLane { returnToLane(); return }
        idleStep += 1
        // No strolling over content: it stays peeking and only changes pose.
        if abs(position(at: Date()).x - peekX) > 1 { returnToLane(); return }
        pose = [MascotPoseKey.think, .yawn, .shrug][idleStep % 3]
    }

    private func reset() {
        generation += 1
        move = nil
        grab = nil
        bubble = nil
        if hiddenSide == 0 {
            spot = CGPoint(x: peekX, y: laneY)
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
