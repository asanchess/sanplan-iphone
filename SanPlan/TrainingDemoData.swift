import Foundation

#if DEBUG
/// Screenshots only (`--screenshot-demo-data`): a made-up five-exercise day and about six weeks of workouts.
/// Lives in memory; nothing here is written to disk, the vault or the cloud, and nothing is real.
enum TrainingDemoData {
    private static let exercises: [(name: String, sets: Int, reps: Int, weight: Double)] = [
        ("Жим лёжа", 4, 8, 60),
        ("Жим гантелей под углом", 3, 10, 22),
        ("Разводка гантелей", 3, 12, 12),
        ("Французский жим", 3, 10, 25),
        ("Разгибания на блоке", 3, 12, 20),
    ]

    /// «Грудь + трицепс» today, «Спина» and «Ноги» on two other days.
    static func program(now: Date) -> WorkoutTrainingPlan {
        let today = WorkoutProgram.weekday(of: now)
        let chest = WorkoutDayPlan(
            weekday: today,
            exercises: exercises.enumerated().map { index, item in
                WorkoutExercisePlan(name: item.name, sets: item.sets, reps: item.reps, restSeconds: 90,
                                    id: "demo-chest-\(index)", restAfterExercise: 120, weightKg: item.weight)
            },
            title: "Грудь + трицепс"
        )
        let back = WorkoutDayPlan(
            weekday: (today + 1) % 7 + 1,
            exercises: [
                WorkoutExercisePlan(name: "Тяга в наклоне", sets: 4, reps: 8, restSeconds: 90, id: "demo-back-0", weightKg: 50),
                WorkoutExercisePlan(name: "Подтягивания", sets: 3, reps: 8, restSeconds: 90, id: "demo-back-1", bodyweight: true),
                WorkoutExercisePlan(name: "Тяга блока к груди", sets: 3, reps: 12, restSeconds: 75, id: "demo-back-2", weightKg: 45),
            ],
            title: "Спина"
        )
        let legs = WorkoutDayPlan(
            weekday: (today + 3) % 7 + 1,
            exercises: [
                WorkoutExercisePlan(name: "Присед", sets: 4, reps: 6, restSeconds: 120, id: "demo-legs-0", weightKg: 80),
                WorkoutExercisePlan(name: "Выпады", sets: 3, reps: 10, perSide: true, restSeconds: 90, id: "demo-legs-1", weightKg: 16),
            ],
            title: "Ноги"
        )
        let days = [chest, back, legs].sorted { $0.weekday < $1.weekday }
        return WorkoutTrainingPlan(version: WorkoutProgram.currentVersion, days: days)
    }

    /// About three workouts a week for six weeks, newest first, with a slow climb in weight.
    static func history(now: Date) -> [WorkoutRecord] {
        let day: Int64 = 86_400_000
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let offsets = [2, 4, 7, 9, 11, 14, 16, 19, 21, 23, 26, 28, 30, 33, 35, 38, 41]
        return offsets.enumerated().map { number, offset in
            let start = nowMs - Int64(offset) * day - 2 * 3_600_000
            let climb = Double(6 - offset / 7) * 1.25
            let parts = exercises.enumerated().map { index, item in
                WorkoutRecordExercise(
                    id: "demo-ex-\(number)-\(index)",
                    name: item.name,
                    targetReps: item.reps,
                    sets: (0..<item.sets).map { set in
                        WorkoutRecordSet(done: !(offset % 3 == 0 && set == item.sets - 1), weightKg: item.weight + climb, reps: item.reps)
                    }
                )
            }
            return WorkoutRecord(
                id: "demo-workout-\(number)",
                startedAt: start,
                endedAt: start + Int64(44 + offset % 4 * 3) * 60_000,
                weekday: WorkoutProgram.weekday(of: Date(timeIntervalSince1970: Double(start) / 1000)),
                title: "Грудь + трицепс",
                exercises: parts
            )
        }
    }
}
#endif
