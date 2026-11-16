import SwiftUI

// «Тушь»: редактор прошедшей тренировки (DESIGN-INK 11.8-5). Данные и сохранение не менялись.

/// Everything about one workout in the history: when it started and ended, its exercises and sets, a note.
/// Also used to add a workout afterwards. Saved only with «Сохранить»; deleting asks first and can be undone.
struct WorkoutRecordEditor: View {
    @ObservedObject var store: WorkoutStore
    let original: WorkoutRecord
    let isNew: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorkoutRecord
    @State private var problem: String?
    @State private var isConfirmingDelete = false
    @State private var isAddingExercise = false

    init(store: WorkoutStore, original: WorkoutRecord, isNew: Bool) {
        self.store = store
        self.original = original
        self.isNew = isNew
        self._draft = State(initialValue: original)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .inkText(.body)
                            .foregroundColor(Ink.Colors.fg)
                    }
                }
                Section("Когда") {
                    DatePicker("Начало", selection: startBinding, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("Конец", selection: endBinding, displayedComponents: [.date, .hourAndMinute])
                    LabeledContent("Длительность", value: WorkoutFormat.duration(draft.durationSeconds))
                }
                Section("Название") {
                    TextField("Например, «Ноги»", text: Binding(
                        get: { draft.title ?? "" },
                        set: { draft.title = $0.isEmpty ? nil : $0 }
                    ))
                }
                ForEach(draft.exercises.indices, id: \.self) { index in
                    exerciseSection(index)
                }
                Section {
                    InkButton(title: "Добавить упражнение", icon: "plus", kind: .text) {
                        isAddingExercise = true
                    }
                }
                Section("Заметка") {
                    TextField("Как прошло", text: Binding(
                        get: { draft.note ?? "" },
                        set: { draft.note = $0.isEmpty ? nil : $0 }
                    ), axis: .vertical)
                    .lineLimit(2...6)
                }
                if !isNew {
                    Section {
                        InkButton(title: "Удалить тренировку", kind: .destructive) {
                            isConfirmingDelete = true
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Ink.Colors.bg.ignoresSafeArea())
            .listRowBackground(Ink.Colors.bg)
            .navigationTitle(isNew ? "Новая тренировка" : "Тренировка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .disabled(draft == original && !isNew)
                }
            }
            .confirmationDialog("Удалить тренировку?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    store.deleteRecord(id: original.id)
                    dismiss()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Её можно будет вернуть кнопкой «Отменить» в течение нескольких секунд.")
            }
            .sheet(isPresented: $isAddingExercise) {
                ExerciseLibrarySheet { name in addExercise(name) }
            }
        }
        .tint(Ink.Colors.accentText)
    }

    private func exerciseSection(_ index: Int) -> some View {
        Section {
            TextField("Упражнение", text: Binding(
                get: { draft.exercises.indices.contains(index) ? draft.exercises[index].name : "" },
                set: { if draft.exercises.indices.contains(index) { draft.exercises[index].name = $0 } }
            ))
            .inkText(.headline, weight: .bold)
            Toggle("Свой вес", isOn: Binding(
                get: { draft.exercises.indices.contains(index) && draft.exercises[index].bodyweight },
                set: { if draft.exercises.indices.contains(index) { draft.exercises[index].bodyweight = $0 } }
            ))
            .tint(Ink.Colors.accent)
            if draft.exercises.indices.contains(index) {
                ForEach(draft.exercises[index].sets.indices, id: \.self) { set in
                    setRow(index, set)
                }
                .onDelete { offsets in
                    guard draft.exercises.indices.contains(index) else { return }
                    draft.exercises[index].sets.remove(atOffsets: offsets)
                }
            }
            InkButton(title: "Подход", icon: "plus", kind: .text) {
                guard draft.exercises.indices.contains(index) else { return }
                let last = draft.exercises[index].sets.last
                draft.exercises[index].sets.append(WorkoutRecordSet(done: true, weightKg: last?.weightKg, reps: last?.reps))
            }
            InkButton(title: "Удалить упражнение", kind: .destructive) {
                guard draft.exercises.indices.contains(index) else { return }
                draft.exercises.remove(at: index)
            }
        }
    }

    private func setRow(_ exercise: Int, _ set: Int) -> some View {
        let current = value(exercise, set)
        let done = current?.done == true
        let bodyweight = draft.exercises.indices.contains(exercise) && draft.exercises[exercise].bodyweight
        let weight = current?.weightKg
        let reps = current?.reps ?? 0
        let step = WorkoutSessionEdit.defaultStepKg
        return VStack(alignment: .leading, spacing: Ink.Metrics.gutter) {
            Button {
                update(exercise, set) { $0.done.toggle() }
            } label: {
                Label("Подход \(set + 1)", systemImage: done ? "checkmark.square.fill" : "square")
                    .inkText(.headline, weight: .bold)
                    .foregroundColor(Ink.Colors.fg)
                    .frame(minHeight: Ink.Metrics.minHit, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "Сделан" : "Не сделан")
            InkStepper(
                title: bodyweight ? "Доп. вес" : "Вес",
                value: WorkoutFormat.weight(weight, bodyweight: bodyweight),
                canDecrease: (weight ?? 0) > 0,
                canIncrease: (weight ?? 0) < WorkoutSessionEdit.weightRange.upperBound,
                onDecrease: { setWeight(exercise, set, max(0, (weight ?? 0) - step)) },
                onIncrease: { setWeight(exercise, set, min(WorkoutSessionEdit.weightRange.upperBound, (weight ?? 0) + step)) },
                onEnter: { text in
                    guard let number = ValueStepperRow.number(text), WorkoutSessionEdit.weightRange.contains(number) else { return false }
                    setWeight(exercise, set, number)
                    return true
                },
                allowsDecimal: true
            )
            InkStepper(
                title: "Повторы",
                value: "\(reps)",
                canDecrease: reps > 0,
                canIncrease: reps < WorkoutSessionEdit.repsRange.upperBound,
                onDecrease: { update(exercise, set) { $0.reps = reps - 1 } },
                onIncrease: { update(exercise, set) { $0.reps = reps + 1 } },
                onEnter: { text in
                    guard let number = Int(text.trimmingCharacters(in: .whitespaces)), WorkoutSessionEdit.repsRange.contains(number) else { return false }
                    update(exercise, set) { $0.reps = number }
                    return true
                }
            )
        }
        .padding(.vertical, 4)
    }

    private func setWeight(_ exercise: Int, _ set: Int, _ value: Double) {
        update(exercise, set) { $0.weightKg = value > 0 ? WorkoutSessionEdit.roundWeight(value) : nil }
    }

    private func value(_ exercise: Int, _ set: Int) -> WorkoutRecordSet? {
        guard draft.exercises.indices.contains(exercise), draft.exercises[exercise].sets.indices.contains(set) else { return nil }
        return draft.exercises[exercise].sets[set]
    }

    private func update(_ exercise: Int, _ set: Int, _ change: (inout WorkoutRecordSet) -> Void) {
        guard draft.exercises.indices.contains(exercise), draft.exercises[exercise].sets.indices.contains(set) else { return }
        change(&draft.exercises[exercise].sets[set])
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: { WorkoutHistory.date(draft.startedAt) },
            set: { date in
                // Moving the start keeps the length, so changing the day moves the whole workout.
                let length = max(0, draft.endedAt - draft.startedAt)
                draft.startedAt = Int64(date.timeIntervalSince1970 * 1000)
                draft.endedAt = draft.startedAt + length
            }
        )
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { WorkoutHistory.date(draft.endedAt) },
            set: { draft.endedAt = Int64($0.timeIntervalSince1970 * 1000) }
        )
    }

    /// A plan exercise of the same name lends its id, so the history and «В прошлый раз» stay together.
    private func addExercise(_ name: String) {
        let planned = store.program.days.flatMap(\.exercises).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        let reps = planned?.reps ?? WorkoutProgram.defaultReps
        let sets = planned?.sets ?? WorkoutProgram.defaults(of: store.program).sets
        draft.exercises.append(WorkoutRecordExercise(
            exerciseId: planned?.id,
            name: name,
            bodyweight: planned?.bodyweight ?? false,
            targetReps: reps,
            perSide: planned?.perSide ?? false,
            sets: Array(repeating: WorkoutRecordSet(done: true, weightKg: planned?.weightKg, reps: reps), count: sets)
        ))
    }

    private func save() {
        do {
            guard !draft.exercises.isEmpty else { throw WorkoutDomainError("Добавьте хотя бы одно упражнение") }
            _ = try WorkoutHistory.validated(draft)
            store.saveRecord(draft)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
