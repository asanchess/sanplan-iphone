import SwiftUI

extension WorkoutStore {
    /// План дня, собранный из прошедшей тренировки: те же упражнения, число подходов и повторов.
    /// Вес не задаётся: «в прошлый раз» и подсказка нагрузки берутся из истории при старте.
    /// Паузы — из настроек плана. Пустые упражнения (без подходов) пропускаются.
    nonisolated static func dayPlan(repeating record: WorkoutRecord, defaults: WorkoutDefaults, today: Int) -> WorkoutDayPlan? {
        let exercises = record.exercises.compactMap { exercise -> WorkoutExercisePlan? in
            guard !exercise.sets.isEmpty else { return nil }
            let doneReps = exercise.doneSets.compactMap(\.reps).filter { $0 > 0 }
            let reps = exercise.targetReps ?? doneReps.max() ?? 10
            return WorkoutExercisePlan(
                name: exercise.name,
                sets: min(exercise.sets.count, 100),
                reps: max(1, reps),
                perSide: exercise.perSide,
                restSeconds: defaults.restBetweenSets,
                id: exercise.exerciseId ?? UUID().uuidString,
                restAfterExercise: defaults.restBetweenExercises,
                bodyweight: exercise.bodyweight ? true : nil
            )
        }
        guard !exercises.isEmpty else { return nil }
        let weekday = record.weekday.flatMap { (1...7).contains($0) ? $0 : nil } ?? today
        return WorkoutDayPlan(weekday: weekday, exercises: exercises, title: record.title)
    }

    /// «Повторить»: новая тренировка из прошедшей. Идущую не заменяет.
    public func repeatWorkout(from record: WorkoutRecord, now: Int64 = WorkoutStore.nowMs()) {
        if let session = activeSession, session.phase != .complete {
            errorMessage = "Сначала заверши текущую тренировку"
            return
        }
        let defaults = WorkoutProgram.defaults(of: program)
        guard let day = Self.dayPlan(
            repeating: record,
            defaults: defaults,
            today: WorkoutProgram.weekday(of: Date())
        ) else {
            errorMessage = "В этой тренировке нет упражнений"
            return
        }
        startWorkout(day: day, now: now)
    }
}

/// Строка списка со свайпом влево: кнопки действий открываются под ней, каждая не уже 44 pt.
/// Обычный `swipeActions` работает только внутри `List`; история лежит в `ScrollView` с карточками.
struct WorkoutSwipeAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    let color: Color
    let run: () -> Void
}

struct WorkoutSwipeRow<Content: View>: View {
    let actions: [WorkoutSwipeAction]
    @ViewBuilder let content: Content

    @State private var offset: CGFloat = 0
    @State private var open = false

    private let actionWidth: CGFloat = 76
    private var total: CGFloat { actionWidth * CGFloat(actions.count) }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                ForEach(actions) { action in
                    Button {
                        close()
                        action.run()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: action.icon).font(.title3)
                            Text(action.title).font(.caption.weight(.semibold))
                        }
                        .foregroundColor(.white)
                        .frame(width: actionWidth)
                        .frame(maxHeight: .infinity)
                        .background(action.color)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(!open)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
            .opacity(offset < 0 ? 1 : 0)
            .allowsHitTesting(open)

            content
                .offset(x: offset)
                .overlay {
                    if open {
                        Color.clear
                            .contentShape(Rectangle())
                            .offset(x: offset)
                            .onTapGesture { close() }
                    }
                }
                .gesture(
                    HorizontalSwipe(
                        onChanged: { dx in
                            let base: CGFloat = open ? -total : 0
                            offset = min(0, max(-total, base + dx))
                        },
                        onEnded: { _, _ in
                            let shouldOpen = offset < -total / 2
                            withAnimation(.snappy) {
                                open = shouldOpen
                                offset = shouldOpen ? -total : 0
                            }
                        }
                    )
                )
        }
        .sensoryFeedback(.selection, trigger: open)
    }

    private func close() {
        withAnimation(.snappy) {
            open = false
            offset = 0
        }
    }
}
