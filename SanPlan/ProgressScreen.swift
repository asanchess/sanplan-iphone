import SwiftUI

/// «Прогресс» from the canvas (docs/design/canvas-r5/Progress.html), in the «Сегодня» colour.
/// Four numbers for an explicit period, the arc, goals, notes and «Может, забыли?».
/// Every number opens exactly what it is about through `DeepLinks`; RootView switches the tab and closes this sheet.
struct ProgressScreen: View {
    @ObservedObject var plans: PlanStore
    @ObservedObject var finance: FinanceStore
    @ObservedObject var workouts: WorkoutStore
    @ObservedObject private var goalStore = GoalStore.shared
    private let notes: NotesStore?
    /// Kept so the existing call compiles; places are now opened through `DeepLinks.shared`, not by tab.
    let onOpen: (MainTab) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var period: DeepLink.Period = .week
    /// «Не сейчас» and finished items, hidden until the sheet is opened again.
    @State private var hidden: Set<String> = []

    init(
        plans: PlanStore,
        finance: FinanceStore,
        workouts: WorkoutStore,
        notes: NotesStore? = nil,
        onOpen: @escaping (MainTab) -> Void = { _ in }
    ) {
        _plans = ObservedObject(wrappedValue: plans)
        _finance = ObservedObject(wrappedValue: finance)
        _workouts = ObservedObject(wrappedValue: workouts)
        self.notes = notes
        self.onOpen = onOpen
    }

    private var today: String { PlanDomain.today(timeZone: plans.timeZone) }

    private var snapshot: ProgressSnapshot {
        let day = today
        if ScreenshotRoute.demoData { return ProgressSnapshot.demo(period, today: day) }
        let goalsBlock = GoalsSummary.make(
            goals: goalStore.goals,
            weekGoalId: goalStore.weekGoal(today: day)?.goal.id,
            progressOf: { goalStore.progress(for: $0, today: day) }
        )
        let overdue = goalStore.goals
            .filter { GoalEngine.isOverdue($0, today: day, progress: goalStore.progress(for: $0, today: day)) }
            .sorted { ($0.dueDay ?? "") < ($1.dueDay ?? "") }
            .map { (id: $0.id, title: $0.title, due: $0.dueDay ?? day) }
        let input = ProgressInputs(
            today: day,
            plans: plans.plans,
            finance: finance.state,
            workouts: workouts.records,
            weeklyGoal: workouts.weeklyGoal,
            goals: goalsBlock,
            overdueGoals: overdue,
            notes: notes?.notes ?? []
        )
        return ProgressBuilder.make(input, kind: period)
    }

    var body: some View {
        let snap = snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                ArnaSegmented("Период", selection: $period, options: [(.week, "Неделя"), (.month, "Месяц")])
                trendsBlock(snap)
                    .tourTarget("progress.numbers")
                arcCard(snap.arc)
                    .tourTarget("progress.arc")
                goalsSection(snap.goals)
                notesSection(snap.notes)
                forgottenSection(snap)
            }
            .padding(.horizontal, DS.Metrics.screenGutter)
            .padding(.top, 18)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background { ProgressBackdrop().ignoresSafeArea() }
        .environment(\.sectionAccent, DS.Colors.today)
    }

    private func open(_ link: DeepLink) {
        DeepLinks.shared.open(link)
        dismiss()
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(DS.Colors.surface, in: Circle())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Назад")
            VStack(alignment: .leading, spacing: 5) {
                SkewTag("Собрано из ваших данных", color: DS.Colors.today)
                Text("Прогресс")
                    .font(DS.Fonts.title)
                    .foregroundColor(DS.Colors.textPrimary)
                    .shadow(color: DS.Colors.ink, radius: 0, x: 3, y: 3)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Numbers

    private func trendsBlock(_ snap: ProgressSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(snap.period.caption.uppercased())
                .font(DS.Fonts.label)
                .tracking(0.8)
                .foregroundColor(DS.Colors.textSecondary)
                .accessibilityLabel(snap.period.caption)
            let trends = snap.trends
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(Array(stride(from: 0, to: trends.count, by: 2)), id: \.self) { start in
                    GridRow {
                        trendButton(trends[start], period: snap.period)
                        if start + 1 < trends.count {
                            trendButton(trends[start + 1], period: snap.period)
                        }
                    }
                }
            }
        }
    }

    private func trendButton(_ trend: ProgressTrend, period: ProgressPeriod) -> some View {
        Button { open(trend.link) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(trend.name)
                    .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                    .tracking(0.78)
                    .foregroundColor(kickColor(trend.kind))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(trend.value)
                    .font(DS.Fonts.display(26, relativeTo: .title2))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(trend.note)
                    .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(trend.name.lowercased()) \(period.label): \(trend.value), \(trend.note)")
        .accessibilityHint(trend.accessibilityHint)
    }

    private func kickColor(_ kind: ProgressTrend.Kind) -> Color {
        switch kind {
        case .money: return DS.Colors.money
        case .workouts, .gym: return DS.Colors.workout
        case .plans: return DS.Colors.plans
        }
    }

    // MARK: Arc

    private func arcCard(_ position: ProgressArcPosition) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("АРКА · \(position.arc.name.uppercased())")
                        .font(DS.Fonts.text(13, .bold, relativeTo: .caption))
                        .tracking(0.78)
                        .foregroundColor(DS.Colors.today)
                        .accessibilityLabel("Арка «\(position.arc.name)»")
                    Text(position.line)
                        .font(DS.Fonts.text(19, .bold, relativeTo: .headline))
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ProgressArcScene(arc: position.arc)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(DS.Colors.canvas)
                    RoundedRectangle(cornerRadius: 5).fill(DS.Colors.today)
                        .frame(width: proxy.size.width * position.fraction)
                }
            }
            .frame(height: 10)
            .accessibilityElement()
            .accessibilityLabel("Пройдено недель: \(position.done) из \(position.arc.weeks)")
            Text(ProgressArcs.rule)
                .font(DS.Fonts.text(15, .medium, relativeTo: .subheadline))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(DS.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: 22))
        .inked(cornerRadius: 22, shadow: 6)
        .padding(.trailing, 6)
    }

    // MARK: Goals

    private func goalsSection(_ block: GoalsSummaryBlock?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Цели")
            if let block {
                ForEach(block.rows) { row in
                    Button { open(.goals) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(row.title)
                                    .font(DS.Fonts.text(17, .semibold))
                                    .foregroundColor(DS.Colors.textPrimary)
                                    .lineLimit(2)
                                if !row.text.isEmpty {
                                    Text(row.isWeek ? "Цель недели · \(row.text)" : row.text)
                                        .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                                        .foregroundColor(DS.Colors.textSecondary)
                                }
                            }
                            if let fraction = row.fraction {
                                ProgressLineBar(fraction: fraction)
                            }
                        }
                        .rowCard()
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityHint("Откроет цели")
                }
                if block.more > 0 {
                    Button { open(.goals) } label: {
                        Text("Ещё \(ReviewFormat.plural(block.more, "цель", "цели", "целей"))")
                            .font(DS.Fonts.text(15, .bold))
                            .foregroundColor(DS.Colors.today)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(PressScaleStyle())
                }
            } else {
                Button { open(.goals) } label: {
                    Text("Целей нет.")
                        .font(DS.Fonts.text(16, .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Откроет цели")
            }
        }
    }

    // MARK: Notes

    private func notesSection(_ line: ProgressNotesLine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Заметки")
            Button { open(.notes) } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(line.headline)
                        .font(DS.Fonts.text(line.count > 0 ? 17 : 16, line.count > 0 ? .semibold : .medium))
                        .foregroundColor(line.count > 0 ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    if let detail = line.detail {
                        Text(detail)
                            .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(2)
                    }
                }
                .modifier(NotesRowStyle(card: line.count > 0))
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityHint("Откроет заметки")
        }
    }

    // MARK: May have forgotten

    private func forgottenSection(_ snap: ProgressSnapshot) -> some View {
        let items = snap.forgotten.filter { !hidden.contains($0.id) }
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Может, забыли?")
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 10) {
                    Button { open(item.link) } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.name)
                                .font(DS.Fonts.text(17, .semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(2)
                            Text(item.note)
                                .font(DS.Fonts.text(14, .medium, relativeTo: .footnote))
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    HStack(spacing: 8) {
                        Button { act(item, demo: snap.isDemo) } label: {
                            Text(item.yes)
                                .font(DS.Fonts.text(15, .bold))
                                .foregroundColor(DS.Colors.textPrimary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(ProgressPalette.softButton, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(PressScaleStyle())
                        Button { withAnimation(.easeOut(duration: 0.2)) { _ = hidden.insert(item.id) } } label: {
                            Text("Не сейчас")
                                .font(DS.Fonts.text(15, .bold))
                                .foregroundColor(DS.Colors.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Colors.hairline, lineWidth: 1.5))
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if items.isEmpty {
                Text("Хвостов нет.")
                    .font(DS.Fonts.text(16, .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
    }

    /// «Выполнен» closes the plan right here; «Открыть» goes to the place.
    private func act(_ item: ProgressForgotten, demo: Bool) {
        switch item.kind {
        case .plan:
            withAnimation(.easeOut(duration: 0.2)) { _ = hidden.insert(item.id) }
            guard !demo else { return }
            let planId = String(item.id.dropFirst("plan-".count))
            Task { await plans.toggleTaskCompletion(id: planId, completed: true) }
        case .goal, .note:
            open(item.link)
        }
    }
}

// MARK: - Pieces

private enum ProgressPalette {
    /// Canvas «#33295A»: the soft main button of «Может, забыли?».
    static let softButton = DS.Colors.hex(0x33295A)
}

/// A thin bar in the section colour, for goal progress.
private struct ProgressLineBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Colors.canvas)
                Capsule().fill(DS.Colors.today)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Выполнено \(Int((min(1, max(0, fraction)) * 100).rounded())) %")
    }
}

private extension View {
    /// The row card of the canvas lists: surface, radius 18, padding 14 × 16.
    func rowCard() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Notes with content sit in a row card; the honest empty line stays plain text, as on the canvas.
private struct NotesRowStyle: ViewModifier {
    let card: Bool

    func body(content: Content) -> some View {
        if card {
            content.rowCard()
        } else {
            content
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
    }
}

/// The canvas glow in the top right corner: a soft lilac circle and a fading dot pattern.
private struct ProgressBackdrop: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            DS.Colors.canvas
            Circle()
                .fill(RadialGradient(
                    colors: [DS.Colors.today.opacity(0.22), DS.Colors.today.opacity(0)],
                    center: .center, startRadius: 0, endRadius: 154
                ))
                .frame(width: 320, height: 320)
                .offset(x: 90, y: -110)
            Canvas { context, size in
                let step: CGFloat = 11
                var y: CGFloat = 0
                while y < size.height {
                    var x: CGFloat = 0
                    while x < size.width {
                        let rect = CGRect(x: x + step / 2 - 1.9, y: y + step / 2 - 1.9, width: 3.8, height: 3.8)
                        context.fill(Path(ellipseIn: rect), with: .color(DS.Colors.today))
                        x += step
                    }
                    y += step
                }
            }
            .frame(width: 230, height: 230)
            .opacity(0.3)
            .mask(RadialGradient(
                colors: [.black, .clear],
                center: UnitPoint(x: 0.72, y: 0.28), startRadius: 0, endRadius: 159
            ))
            .offset(x: 30, y: -30)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
