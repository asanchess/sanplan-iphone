import SwiftUI

// «Тушь»: итог тренировки, плитка показателей и тост «Отменить» (DESIGN-INK 11.7, 7.8, 7.9).

// MARK: - Finished workout

/// What was done, how long it took, the sets for last corrections, and «Сохранить изменения в план» when it differed.
struct WorkoutSummaryView: View {
    @State private var confirmingPlanReplace = false
    @ObservedObject var store: WorkoutStore
    let session: WorkoutSessionState

    @State private var editingSet: WorkoutSetRef?
    @State private var editingExercise: WorkoutIndexRef?
    @State private var replacingExercise: WorkoutIndexRef?

    var body: some View {
        let done = session.exercises.reduce(0) { $0 + $1.doneCount }
        let planned = session.exercises.reduce(0) { $0 + $1.rests.count }
        let seconds = WorkoutDomain.totalElapsedSeconds(state: session, now: session.endedAt ?? session.lastNow) ?? 0
        let record = WorkoutHistory.record(from: session, now: session.endedAt ?? session.lastNow)

        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Metrics.stack) {
                if let error = store.errorMessage {
                    InkBanner(message: error) { store.errorMessage = nil }
                }

                titlePanel(done: done, planned: planned)

                InkStatRow(tiles: [
                    (title: "Время", value: WorkoutFormat.duration(seconds)),
                    (title: "Подходы", value: "\(done)/\(planned)"),
                    (title: "Тоннаж", value: WorkoutFormat.tonnage(record?.tonnageKg ?? 0)),
                ])

                if done == 0 {
                    InkPanel {
                        Text("Ни один подход не отмечен, поэтому в историю тренировка не попадёт. Отметьте сделанные подходы ниже или закройте её.")
                            .inkText(.body)
                            .foregroundColor(Ink.Colors.muted)
                    }
                }

                if store.pendingPlanChanges != nil {
                    InkPanel {
                        VStack(alignment: .leading, spacing: Ink.Metrics.gutter) {
                            Text("Тренировка отличалась от плана")
                                .inkText(.headline, weight: .bold)
                                .foregroundColor(Ink.Colors.fg)
                            Text("Упражнения, подходы, повторы, вес или отдых менялись по ходу. Без сохранения план останется прежним.")
                                .inkText(.body)
                                .foregroundColor(Ink.Colors.muted)
                            InkButton(title: "Сохранить изменения в план", icon: "square.and.arrow.down", kind: .secondary) {
                                // Разовая тренировка («Повторить») не заменяет день плана молча.
                                if store.planDayToReplace != nil { confirmingPlanReplace = true }
                                else { store.saveSessionChangesToPlan() }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Ink.Metrics.gutter) {
                    InkSectionHeader(text: "Упражнения")
                    ForEach(session.exercises.indices, id: \.self) { index in
                        ExerciseSetsCard(
                            store: store,
                            session: session,
                            index: index,
                            onEditSet: { editingSet = WorkoutSetRef(exercise: index, set: $0) },
                            onEditTarget: { editingExercise = WorkoutIndexRef(index: index) },
                            onReplace: { replacingExercise = WorkoutIndexRef(index: index) }
                        )
                    }
                }
            }
            .padding(.horizontal, Ink.Metrics.page)
            .padding(.vertical, Ink.Metrics.stack)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            InkButton(title: done == 0 ? "Закрыть без сохранения" : "Готово", icon: "checkmark") {
                store.discardWorkout()
            }
            .padding(.horizontal, Ink.Metrics.page)
            .padding(.vertical, Ink.Metrics.gutter)
            .background(Ink.Colors.bg)
            .overlay(alignment: .top) { InkRule() }
        }
        .confirmationDialog(
            "Заменить тренировку на \(store.planDayToReplace.map { $0.title ?? WorkoutFormat.weekdayNames[$0.weekday - 1] } ?? "этот день")?",
            isPresented: $confirmingPlanReplace,
            titleVisibility: .visible
        ) {
            Button("Заменить", role: .destructive) { store.saveSessionChangesToPlan() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("В плане уже есть другая тренировка на этот день недели. Она будет заменена этой.")
        }
        .sheet(item: $editingSet) { ref in
            SetEditorSheet(store: store, ref: ref)
                .presentationDetents([.medium])
        }
        .sheet(item: $editingExercise) { ref in
            ExerciseTargetSheet(store: store, index: ref.index)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $replacingExercise) { ref in
            ExerciseLibrarySheet { name in
                guard let exercise = try? WorkoutSessionEdit.newExercise(
                    name: name, sets: 1, reps: WorkoutProgram.defaultReps, restSeconds: 60, restAfterExercise: 60
                ) else { return }
                store.editSession("Упражнение заменено") { try WorkoutSessionEdit.replaceExercise($0, index: ref.index, with: exercise) }
            }
        }
    }

    /// Титульный кадр: название дня, заголовок и подпись; справа место под маскота «victory».
    /// Если сделаны все подходы — «ФУХ!» и звёздная пыль один раз; если ни одного — кадр без украшений.
    @ViewBuilder
    private func titlePanel(done: Int, planned: Int) -> some View {
        let allDone = done == planned && done > 0
        let dayName = session.planDay.map { $0.title ?? WorkoutFormat.weekdayNames[$0.weekday - 1] }
        InkPanel(done == 0 ? .plain : .tone) {
            VStack(alignment: .leading, spacing: Ink.Metrics.gutter) {
                if let dayName { InkFolio(text: dayName) }
                HStack(alignment: .top, spacing: Ink.Metrics.framePadding) {
                    VStack(alignment: .leading, spacing: Ink.Metrics.gutter) {
                        Text("Тренировка завершена")
                            .inkPoster(26)
                            .foregroundColor(Ink.Colors.fg)
                            .accessibilityAddTraits(.isHeader)
                        Text(done == planned ? "Все подходы сделаны." : "\(done) из \(planned) подходов.")
                            .inkText(.body)
                            .foregroundColor(Ink.Colors.fg)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    InkMascotSlot(pose: .victory, size: 120)
                }
            }
            .frame(minHeight: 180 - 2 * Ink.Metrics.framePadding, alignment: .topLeading)
        }
        .overlay(alignment: .topTrailing) {
            if allDone {
                ZStack {
                    InkStardust()
                    InkSfxFlash(word: "ФУХ!", size: 32, trigger: 0, onAppear: true)
                }
                .offset(x: -12, y: -26)
            }
        }
        // Запас сверху (после overlay, чтобы надпись ехала вместе с кадром): «ФУХ!» поднята на 26 pt и наклонена.
        .padding(.top, allDone ? 24 : 0)
    }
}

/// Показатель с подписью и необязательной строкой сравнения (история): кадр 2 pt, значение плакатным 20 pt.
struct WorkoutStatTile: View {
    let title: String
    let value: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .inkText(.subheadline, weight: .medium)
                .foregroundColor(Ink.Colors.muted)
            Text(value)
                .inkPoster(20, relativeTo: .headline)
                .foregroundColor(Ink.Colors.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .inkText(.subheadline, weight: .medium, numeric: true)
                    .foregroundColor(Ink.Colors.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Ink.Metrics.framePadding)
        .overlay(Rectangle().strokeBorder(Ink.Colors.fg, lineWidth: Ink.Metrics.cellLine))
        .accessibilityElement(children: .combine)
    }
}

/// «Отменить» for the last change, at the bottom of the workout section for five seconds.
struct WorkoutUndoToast: View {
    @ObservedObject var store: WorkoutStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let offer = store.undoOffer {
                InkToast(label: offer.label) { store.undoLast() }
                    .padding(.horizontal, Ink.Metrics.page)
                    .padding(.vertical, Ink.Metrics.gutter)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .task(id: offer.id) {
                        try? await Task.sleep(for: .seconds(5))
                        store.dismissUndo(offer.id)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isStaticText)
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.2), value: store.undoOffer)
    }
}
