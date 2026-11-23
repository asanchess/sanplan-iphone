import SwiftUI

// Building blocks of «Профиль» from the canvas (docs/design/canvas-r5/Profile.html):
// a caps label over one rounded block of rows; rows 64 pt high with a name, a grey note and a value or switch.
// Values, switches and chips take `sectionAccent`; the profile itself stays violet (`DS.Colors.today`).

/// Top of every profile screen: a round back button, the skewed violet kicker and a Dela title.
struct ProfileHeader: View {
    let kicker: String
    let title: String
    let backLabel: String
    let back: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(DS.Colors.surface, in: Circle())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(backLabel)
            VStack(alignment: .leading, spacing: 5) {
                SkewTag(kicker, color: DS.Colors.today)
                Text(title)
                    .font(DS.Fonts.title)
                    .foregroundColor(DS.Colors.textPrimary)
                    .shadow(color: DS.Colors.drop, radius: 3, y: 2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
        }
    }
}

/// «МАСКОТ», «АККАУНТ»…: the label and one block of rows.
struct ProfileGroup<Content: View>: View {
    private let title: String?
    private let content: Content

    init(_ title: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { SectionHeader(title) }
            VStack(spacing: 0) { content }
                .background(DS.Colors.surface)
                .clipShape(RoundedRectangle(cornerRadius: 20))
        }
    }
}

/// One row: name and note on the left, anything on the right.
struct ProfileRow<Trailing: View>: View {
    private let name: String
    private let note: String?
    private let nameColor: Color
    private let trailing: Trailing

    init(_ name: String, note: String? = nil, nameColor: Color = DS.Colors.textPrimary, @ViewBuilder trailing: () -> Trailing) {
        self.name = name
        self.note = note
        self.nameColor = nameColor
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(DS.Fonts.text(17, .semibold))
                    .foregroundColor(nameColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let note, !note.isEmpty {
                    Text(note)
                        .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .overlay(alignment: .bottom) { ProfileDivider() }
    }
}

extension ProfileRow where Trailing == EmptyView {
    init(_ name: String, note: String? = nil, nameColor: Color = DS.Colors.textPrimary) {
        self.init(name, note: note, nameColor: nameColor) { EmptyView() }
    }
}

/// The 1 pt canvas line between rows.
struct ProfileDivider: View {
    var body: some View {
        Rectangle().fill(DS.Colors.canvas).frame(height: 1).accessibilityHidden(true)
    }
}

/// The value on the right of a row, in the section colour.
struct ProfileValue: View {
    private let text: String
    @Environment(\.sectionAccent) private var accent

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
            .foregroundColor(accent)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// A row that opens something: value (optional) and a chevron.
struct ProfileNavRow: View {
    let name: String
    var note: String? = nil
    var value: String? = nil
    var marker: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                if let marker {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(marker)
                        .frame(width: 12, height: 12)
                        .background(RoundedRectangle(cornerRadius: 3).fill(DS.Colors.drop).offset(y: 2))
                        .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.18, d: 1, tx: 2, ty: 0))
                        .padding(.leading, 16)
                        .accessibilityHidden(true)
                }
                ProfileRow(name, note: note) {
                    HStack(spacing: 8) {
                        if let value { ProfileValue(value) }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DS.Colors.textMuted)
                            .accessibilityHidden(true)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ProfileRowButtonStyle())
    }
}

/// Rows darken a little while pressed instead of scaling: they sit edge to edge inside a block.
struct ProfileRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? DS.Colors.surfaceRaised : Color.clear)
    }
}

/// A switch row: the canvas track (52×32, ink border, section colour when on).
struct ProfileToggleRow: View {
    let name: String
    var note: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(DS.Fonts.text(17, .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                if let note {
                    Text(note)
                        .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(ArnaSwitchStyle())
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .overlay(alignment: .bottom) { ProfileDivider() }
    }
}

struct ArnaSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ArnaSwitchBody(configuration: configuration)
    }
}

private struct ArnaSwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.sectionAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8)) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? accent : DS.Colors.hairline)
                    Circle()
                        .fill(configuration.isOn ? DS.Colors.canvas : DS.Colors.textSecondary)
                        .frame(width: 22, height: 22)
                        .padding(3)
                }
                .frame(width: 52, height: 32)
                .overlay(Capsule().stroke(DS.Colors.edge, lineWidth: 1))
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "Включено" : "Выключено")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Section chips of «Настройки»: the chosen one is filled with its colour, slanted, with an ink shadow.
struct ProfileChip: View {
    let title: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.Fonts.text(15, .bold, relativeTo: .subheadline))
                .foregroundColor(selected ? DS.Colors.canvas : DS.Colors.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(color)
                            .background(RoundedRectangle(cornerRadius: 14).fill(DS.Colors.drop).offset(y: 2))
                            .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.087, d: 1, tx: 2, ty: 0))
                    } else {
                        RoundedRectangle(cornerRadius: 14).fill(DS.Colors.surface)
                    }
                }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
