import SwiftUI
import UIKit

// Arcs and mascot skins (owner decisions 17.11.2026, docs/design/ARCS-R6.md).
//
// - An arc lasts 6 counted weeks. A week counts with 3 workouts or 5 days with closed plans
//   (the same rule as «Прогресс»); a missed week resets nothing.
// - Passing an arc opens the next one: its scene and its skin(s). «Никто» and the `base` skin are open from the start.
// - Opened skins can be worn in «Профиль → Маскот» whatever the current arc is.
// - Every arc holds a LIST of skins (one each for now; more per arc later).
//
// Assets (a missing one shows a placeholder, never a broken image):
// - skin pose: `mascot-<skin>-<pose>`, pose = cheer / point / rest / shrug / think / yawn;
//   the `base` skin keeps the existing PetCheer, PetPoint, PetRest, PetShrug, PetThink, PetYawn;
// - arc scene: `arc-<arc id>`.
//
// Reading from other screens (e.g. Progress):
//     MascotArcs.all                         // the catalogue, in order
//     MascotArcs.current(countedWeeks: n)    // the arc the person is in
//     MascotWardrobe.shared.update(countedWeeks: n)  // opens what n weeks have earned
//     MascotArcs.countedWeeks(plans:records:)        // total counted weeks from the person's data

struct MascotSkin: Identifiable, Equatable {
    let id: String
    let title: String
}

struct MascotArc: Identifiable, Equatable {
    let id: String
    let title: String
    let skins: [MascotSkin]

    /// Asset of the arc scene; nil until it is drawn.
    @MainActor var sceneAsset: String? { MascotAssets.exists("arc-\(id)") ? "arc-\(id)" : nil }
}

enum MascotArcs {
    /// Weeks one arc lasts.
    static let weeksPerArc = 6

    static let all: [MascotArc] = [
        MascotArc(id: "nobody", title: "Никто", skins: [MascotSkin(id: "base", title: "Обычный")]),
        MascotArc(id: "shinobi", title: "Шиноби", skins: [MascotSkin(id: "naruto", title: "Наруто")]),
        MascotArc(id: "pirate", title: "Пират", skins: [MascotSkin(id: "luffy", title: "Луффи")]),
        MascotArc(id: "reaper", title: "Жнец душ", skins: [MascotSkin(id: "ichigo", title: "Ичиго")]),
        MascotArc(id: "hunter", title: "Охотник", skins: [MascotSkin(id: "killua", title: "Киллуа")]),
    ]

    static let baseSkin = "base"

    /// Index of the arc the person is in after `countedWeeks` counted weeks.
    static func currentIndex(countedWeeks: Int) -> Int {
        min(max(countedWeeks, 0) / weeksPerArc, all.count - 1)
    }

    static func current(countedWeeks: Int) -> MascotArc { all[currentIndex(countedWeeks: countedWeeks)] }

    /// Counted weeks inside the current arc (0...6); the last arc keeps counting up to 6.
    static func weeksInCurrent(countedWeeks: Int) -> Int {
        let index = currentIndex(countedWeeks: countedWeeks)
        return min(max(countedWeeks, 0) - index * weeksPerArc, weeksPerArc)
    }

    /// The arc that owns a skin.
    static func arc(ofSkin skin: String) -> MascotArc? { all.first { $0.skins.contains { $0.id == skin } } }

    static func skin(_ id: String) -> MascotSkin? { all.lazy.flatMap(\.skins).first { $0.id == id } }

    /// Skins open after this many counted weeks: every skin of every arc reached so far.
    static func openSkins(countedWeeks: Int) -> Set<String> {
        let index = currentIndex(countedWeeks: countedWeeks)
        return Set(all.prefix(index + 1).flatMap { $0.skins.map(\.id) })
    }

    /// Total counted weeks (Mon–Sun, finished weeks only, as in «Прогресс»), looking back at most `maxWeeks`.
    @MainActor
    static func countedWeeks(plans: PlanStore, records: [WorkoutRecord], today: String, maxWeeks: Int = 104) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = WorkoutSummary.zone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let now = formatter.date(from: today),
              let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return 0 }
        var counted = 0
        for back in 1...max(maxWeeks, 1) {
            guard let start = calendar.date(byAdding: .day, value: -7 * back, to: weekStart) else { continue }
            let from = formatter.string(from: start)
            let to = PlanDomain.addDays(dateStr: from, days: 6)
            let trainings = WorkoutSummary.period(records, from: from, to: to).completed
            var closedDays = 0
            var day = from
            while day <= to {
                if plans.daySummary(for: day).done > 0 { closedDays += 1 }
                day = PlanDomain.addDays(dateStr: day, days: 1)
            }
            if trainings >= 3 || closedDays >= 5 { counted += 1 }
        }
        return counted
    }
}

enum MascotPoseKey: String, CaseIterable {
    case cheer, point, rest, shrug, think, yawn
}

/// Asset lookups with a cache: `UIImage(named:)` is not free and the walking hero asks every frame.
@MainActor
enum MascotAssets {
    private static var cache: [String: Bool] = [:]

    static func exists(_ name: String) -> Bool {
        if let known = cache[name] { return known }
        let found = UIImage(named: name) != nil
        cache[name] = found
        return found
    }

    /// The image of a skin in a pose, or nil when it is not drawn yet.
    static func pose(_ pose: MascotPoseKey, skin: String) -> String? {
        if skin == MascotArcs.baseSkin { return "Pet" + pose.rawValue.capitalized }
        let name = "mascot-\(skin)-\(pose.rawValue)"
        return exists(name) ? name : nil
    }
}

/// Which skins are open and which one the mascot wears. Kept on the device.
@MainActor
final class MascotWardrobe: ObservableObject {
    static let shared = MascotWardrobe()

    static let skinKey = "mascot.skin.v1"
    static let weeksKey = "mascot.countedWeeks.v1"

    @Published private(set) var skinID: String
    /// Total counted weeks last reported by a screen that can count them (Profile, Progress).
    @Published private(set) var countedWeeks: Int
    /// False until some screen has counted the weeks at least once: then the profile shows no week numbers.
    @Published private(set) var isCounted: Bool

    private let defaults: UserDefaults
    /// Screenshot demo data lives in memory only.
    private let persists: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if ScreenshotRoute.demoData {
            persists = false
            countedWeeks = 15
            isCounted = true
            skinID = "naruto"
        } else {
            persists = true
            countedWeeks = defaults.integer(forKey: Self.weeksKey)
            isCounted = defaults.object(forKey: Self.weeksKey) != nil
            skinID = defaults.string(forKey: Self.skinKey) ?? MascotArcs.baseSkin
        }
        if !openSkins.contains(skinID) { skinID = MascotArcs.baseSkin }
    }

    var openSkins: Set<String> { MascotArcs.openSkins(countedWeeks: countedWeeks) }
    var currentArc: MascotArc { MascotArcs.current(countedWeeks: countedWeeks) }
    var weeksInCurrentArc: Int { MascotArcs.weeksInCurrent(countedWeeks: countedWeeks) }
    var nextArc: MascotArc? {
        let index = MascotArcs.currentIndex(countedWeeks: countedWeeks)
        return index + 1 < MascotArcs.all.count ? MascotArcs.all[index + 1] : nil
    }

    func isOpen(_ skin: String) -> Bool { openSkins.contains(skin) }

    func wear(_ skin: String) {
        guard isOpen(skin), skin != skinID else { return }
        skinID = skin
        if persists { defaults.set(skin, forKey: Self.skinKey) }
    }

    /// A screen that counted the weeks reports them; arcs never close again once open.
    func update(countedWeeks weeks: Int) {
        guard persists else { return }
        isCounted = true
        guard weeks > countedWeeks else {
            if defaults.object(forKey: Self.weeksKey) == nil { defaults.set(countedWeeks, forKey: Self.weeksKey) }
            return
        }
        countedWeeks = weeks
        defaults.set(weeks, forKey: Self.weeksKey)
    }

    /// The image the walking hero shows in this pose: the worn skin, or the base mascot while that skin is not drawn.
    func heroImage(_ pose: MascotPoseKey) -> String {
        MascotAssets.pose(pose, skin: skinID) ?? MascotAssets.pose(pose, skin: MascotArcs.baseSkin) ?? "PetThink"
    }
}

/// A skin's picture in a pose, or a dashed placeholder while it is not drawn.
struct MascotSkinImage: View {
    let skin: String
    var pose: MascotPoseKey = .cheer
    var height: CGFloat

    var body: some View {
        if let name = MascotAssets.pose(pose, skin: skin) {
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(height: height)
                .accessibilityHidden(true)
        } else {
            MascotPlaceholder(height: height)
        }
    }
}

struct MascotPlaceholder: View {
    var height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(DS.Colors.textMuted, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
            .overlay {
                Image(systemName: "tshirt")
                    .font(.system(size: min(height * 0.3, 28), weight: .semibold))
                    .foregroundColor(DS.Colors.textMuted)
            }
            .frame(width: height * 0.72, height: height)
            .accessibilityLabel("Картинки пока нет")
    }
}
