import SwiftUI

/// Right after «Что ведём?»: one card with a first step for each kept section. Shown once per device.
enum SectionStarter {
    static let shownKey = "asan.sections.starter.shown"

    struct Suggestion: Equatable {
        let title: String
        let tab: MainTab
        /// The exact place; nil opens the section as is (Тренировка has no deeper link yet).
        let link: DeepLink?
    }

    static func suggestions(keep: Set<MainTab>) -> [Suggestion] {
        SectionSettings.optional.filter { keep.contains($0) }.flatMap { tab -> [Suggestion] in
            switch tab {
            case .money: return [
                Suggestion(title: "Поставить лимит на день", tab: tab, link: .moneyPlan),
                Suggestion(title: "Начать копить (конверт)", tab: tab, link: .moneyPlan),
                Suggestion(title: "Загрузить выписку", tab: tab, link: .moneyOperations),
            ]
            case .plans: return [Suggestion(title: "Добавить первый план", tab: tab, link: .plansAll)]
            case .workout: return [Suggestion(title: "Выбрать программу", tab: tab, link: nil)]
            case .notes: return [Suggestion(title: "Первая заметка", tab: tab, link: .notes)]
            case .today: return []
            }
        }
    }
}

struct SectionStarterCard: View {
    let suggestions: [SectionStarter.Suggestion]
    let onPick: (SectionStarter.Suggestion) -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("С чего начать")
                .font(DS.Fonts.text(17, .bold))
                .foregroundColor(DS.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            ForEach(suggestions, id: \.title) { s in
                Button { onPick(s) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: s.tab.barIcon)
                            .foregroundColor(s.tab.accent)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        Text(s.title)
                            .font(DS.Fonts.text(16, .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .foregroundColor(DS.Colors.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScaleStyle())
            }
            Button("Пропустить", action: onSkip)
                .font(DS.Fonts.text(15, .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("sections-starter-skip")
        }
        .padding(16)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, DS.Metrics.screenGutter)
        .padding(.bottom, 12)
        .frame(maxWidth: 640)
        .accessibilityIdentifier("sections-starter")
    }
}
