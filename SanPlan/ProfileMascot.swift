import SwiftUI

/// «Профиль → Маскот»: on/off switch, the outfits grid (any opened outfit can be worn whatever the arc)
/// and the arcs with their scenes. Missing pictures show a placeholder.
struct ProfileMascotScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var wardrobe = MascotWardrobe.shared
    @AppStorage("pet.visible") private var petVisible = true

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProfileHeader(kicker: "Профиль", title: "Маскот", backLabel: "Назад") { dismiss() }
                ProfileGroup(nil) {
                    ProfileToggleRow(name: "Показывать героя", note: "Гуляет внизу экрана и молчит, пока не спросите", isOn: $petVisible)
                        .accessibilityIdentifier("pet-toggle")
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Образы")
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(MascotArcs.all.flatMap(\.skins)) { skin in
                            SkinTile(skin: skin,
                                     arcTitle: MascotArcs.arc(ofSkin: skin.id)?.title ?? "",
                                     open: wardrobe.isOpen(skin.id),
                                     worn: wardrobe.skinID == skin.id) {
                                wardrobe.wear(skin.id)
                            }
                        }
                    }
                    Text("Образ открывается, когда пройдена прошлая арка: \(MascotArcs.weeksPerArc) засчитанных недель.")
                        .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Арки")
                    ForEach(Array(MascotArcs.all.enumerated()), id: \.element.id) { index, arc in
                        ArcRow(arc: arc, status: status(of: index))
                    }
                }
            }
            .padding(.horizontal, DS.Metrics.screenGutter)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .background(DS.Colors.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func status(of index: Int) -> String {
        let current = MascotArcs.currentIndex(countedWeeks: wardrobe.countedWeeks)
        if index < current { return "Пройдена" }
        if index == current {
            return wardrobe.isCounted ? "Сейчас · \(wardrobe.weeksInCurrentArc) из \(MascotArcs.weeksPerArc) недель" : "Сейчас"
        }
        return "Закрыта"
    }
}

private struct SkinTile: View {
    let skin: MascotSkin
    let arcTitle: String
    let open: Bool
    let worn: Bool
    let wear: () -> Void

    var body: some View {
        Button(action: wear) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    MascotSkinImage(skin: skin.id, pose: .cheer, height: 72)
                        .frame(maxWidth: .infinity)
                        .opacity(open ? 1 : 0.35)
                    if !open {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
                Text(skin.title)
                    .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                    .foregroundColor(open ? DS.Colors.textPrimary : DS.Colors.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(worn ? "Надет" : (open ? arcTitle : "Закрыт"))
                    .font(DS.Fonts.text(13, .semibold, relativeTo: .caption))
                    .foregroundColor(worn ? DS.Colors.today : DS.Colors.textMuted)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 140)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                if worn { RoundedRectangle(cornerRadius: 16).strokeBorder(DS.Colors.today, lineWidth: 2) }
            }
            .background {
                if worn { RoundedRectangle(cornerRadius: 16).fill(DS.Colors.ink).offset(x: 3, y: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!open)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Образ «\(skin.title)», арка «\(arcTitle)»")
        .accessibilityValue(worn ? "Надет" : (open ? "Открыт" : "Закрыт"))
        .accessibilityAddTraits(worn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("skin-\(skin.id)")
    }
}

private struct ArcRow: View {
    let arc: MascotArc
    let status: String

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let scene = arc.sceneAsset {
                    Image(scene).resizable().scaledToFill().accessibilityHidden(true)
                } else {
                    MascotPlaceholder(height: 56)
                }
            }
            .frame(width: 72, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(arc.title)
                    .font(DS.Fonts.text(17, .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(status)
                    .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(minHeight: 64)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
