import Foundation
import HealthKit

/// What has to change in Apple Health after a history change: records to remove and records to write again.
/// Pure, so it is tested without HealthKit. An edited record is removed and written anew.
public enum WorkoutHealthPlan {
    public static func changes(previous: [WorkoutRecord], next: [WorkoutRecord]) -> (remove: [String], write: [WorkoutRecord]) {
        let before = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let after = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var remove: [String] = []
        var write: [WorkoutRecord] = []
        for record in previous where after[record.id] == nil {
            remove.append(record.id)
        }
        for record in next {
            guard let old = before[record.id] else {
                if exportable(record) { write.append(record) }
                continue
            }
            guard old != record, exported(old) != exported(record) else { continue }
            remove.append(record.id)
            if exportable(record) { write.append(record) }
        }
        return (remove, write)
    }

    /// Only workouts with a set done reach Health.
    public static func exportable(_ record: WorkoutRecord) -> Bool {
        record.doneSetCount > 0 && record.endedAt > record.startedAt
    }

    /// The part of a record Health sees: a note or a weight changes nothing there.
    private static func exported(_ record: WorkoutRecord) -> [Int64] {
        [record.startedAt, record.endedAt, exportable(record) ? 1 : 0]
    }
}

/// Writes workouts from the history to Apple Health as strength training, tagged with the record id,
/// so an edit or delete in the history finds and replaces the same workout there. Off until the user turns it on.
@MainActor
public final class WorkoutHealthExport: ObservableObject, WorkoutHealthSyncing {
    public static let shared = WorkoutHealthExport()

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var problem: String?
    @Published public private(set) var isWorking = false

    static let enabledKey = "arna.workout.healthExport"
    private let defaults: UserDefaults
    private lazy var healthStore = HKHealthStore()
    private var queue: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    public var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Turning it on asks for access and writes the whole history; turning it off leaves Health as it is.
    public func setEnabled(_ enabled: Bool, records: [WorkoutRecord]) {
        problem = nil
        guard enabled else {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            return
        }
        guard isAvailable else {
            problem = "«Здоровье» недоступно на этом устройстве."
            return
        }
        enqueue { [self] in
            try await healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [HKObjectType.workoutType()])
            guard healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else {
                throw WorkoutDomainError("Разрешите ARNA записывать тренировки: Настройки → Здоровье → Доступ к данным.")
            }
            isEnabled = true
            defaults.set(true, forKey: Self.enabledKey)
            try await delete(ids: records.map(\.id))
            for record in records where WorkoutHealthPlan.exportable(record) {
                try await save(record)
            }
        }
    }

    public func sync(previous: [WorkoutRecord], next: [WorkoutRecord]) {
        guard isEnabled, isAvailable else { return }
        let plan = WorkoutHealthPlan.changes(previous: previous, next: next)
        guard !plan.remove.isEmpty || !plan.write.isEmpty else { return }
        enqueue { [self] in
            try await delete(ids: plan.remove)
            for record in plan.write {
                try await save(record)
            }
        }
    }

    /// One change at a time, in order, so an edit right after a save cannot leave two copies.
    private func enqueue(_ work: @escaping @MainActor () async throws -> Void) {
        let previous = queue
        queue = Task { @MainActor [weak self] in
            await previous?.value
            self?.isWorking = true
            do {
                try await work()
            } catch {
                self?.problem = (error as? WorkoutDomainError)?.localizedDescription
                    ?? "Не удалось обновить «Здоровье»: \(error.localizedDescription)"
            }
            self?.isWorking = false
        }
    }

    private func save(_ record: WorkoutRecord) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: configuration, device: .local())
        let start = WorkoutHistory.date(record.startedAt)
        let end = WorkoutHistory.date(record.endedAt)
        try await builder.beginCollection(at: start)
        var metadata: [String: Any] = [
            HKMetadataKeyExternalUUID: record.id,
            HKMetadataKeyWasUserEntered: record.manual
        ]
        if let title = record.title { metadata[HKMetadataKeyWorkoutBrandName] = title }
        try await builder.addMetadata(metadata)
        try await builder.endCollection(at: end)
        _ = try await builder.finishWorkout()
    }

    private func delete(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: ids),
            HKQuery.predicateForObjects(from: HKSource.default())
        ])
        let store = healthStore
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.deleteObjects(of: HKObjectType.workoutType(), predicate: predicate) { _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
