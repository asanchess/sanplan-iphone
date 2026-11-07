import Foundation
import Combine

@MainActor
public final class WorkoutStore: ObservableObject {
    @Published public var training: WorkoutTrainingPlan?
    @Published public var activeSession: WorkoutSessionState?
    @Published public var errorMessage: String?

    public let restAlarm: RestAlarmCoordinator
    private let fileName = "arna_workout_training_v1.json"
    private let fileManager = FileManager.default
    private var alarmWork: Task<Void, Never>?
    private var restAlarmObservation: AnyCancellable?

    public init(restAlarm: RestAlarmCoordinator? = nil) {
        self.restAlarm = restAlarm ?? RestAlarmCoordinator()
        // The workout screen reads the alarm warning through this store, so redraw it when the warning changes.
        restAlarmObservation = self.restAlarm.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        loadFromDisk()
    }

    private var storageURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("ARNA", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
        return directory.appendingPathComponent(fileName)
    }

    public func loadFromDisk() {
        let url = storageURL
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        // Unreadable before the first unlock after a restart: not corruption, so keep the file.
        guard let data = try? Data(contentsOf: url) else {
            self.errorMessage = "Тренировка недоступна, пока телефон не разблокирован."
            return
        }

        do {
            let decoded = WorkoutProgram.migrated(try JSONDecoder().decode(WorkoutTrainingPlan.self, from: data))
            if let session = decoded.session {
                try WorkoutDomain.validateState(session)
            }
            self.training = decoded
            self.activeSession = decoded.session
            reconcileClock()
        } catch {
            let corruptURL = url.deletingLastPathComponent().appendingPathComponent("arna_workout_corrupt_\(Int(Date().timeIntervalSince1970)).json")
            try? fileManager.moveItem(at: url, to: corruptURL)
            self.training = nil
            self.activeSession = nil
            self.errorMessage = "Предыдущие поврежденные данные тренировки перемещены в архив."
        }
    }

    public func saveToDisk() {
        let url = storageURL
        var toSave = training ?? WorkoutProgram.empty()
        toSave.session = activeSession

        do {
            let data = try JSONEncoder().encode(toSave)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            self.training = toSave
        } catch {
            self.errorMessage = "Не удалось сохранить тренировку: \(error.localizedDescription)"
        }
    }

    /// The weekly program as the builder sees it; empty before the first exercise is added.
    public var program: WorkoutTrainingPlan {
        training ?? WorkoutProgram.empty()
    }

    /// One builder edit. A running workout is never touched; errors show as a banner.
    public func updateProgram(_ edit: (WorkoutTrainingPlan) throws -> WorkoutTrainingPlan) {
        do {
            var next = try edit(program)
            next.session = activeSession
            training = next
            saveToDisk()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func setTrainingPlan(_ plan: WorkoutTrainingPlan) {
        self.training = plan
        self.activeSession = plan.session
        saveToDisk()
    }

    public func startWorkout(day: WorkoutDayPlan, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        do {
            let exercises = try WorkoutDomain.sessionExercises(from: day)
            let session = try WorkoutDomain.createWorkout(exercises: exercises, now: now)
            self.activeSession = session
            saveToDisk()
            syncRestAlarm(now: now)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    public func dispatch(command: WorkoutCommand, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        guard let current = activeSession else { return }
        let at = command.type == "recoverClock" ? now : WorkoutDomain.userCommandTime(now, state: current)
        do {
            let next = try WorkoutDomain.workoutCommand(state: current, command: command, now: at)
            self.activeSession = next
            saveToDisk()
            syncRestAlarm(now: at)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    public func reconcileClock(now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        guard let session = activeSession else { return }
        if now < session.lastNow {
            dispatch(command: .recoverClock(), now: now)
            return
        }
        if session.phase == .preparing || session.phase == .resting {
            if let deadline = session.deadline, now >= deadline {
                dispatch(command: .tick(), now: now)
            }
        }
    }

    public func discardWorkout() {
        self.activeSession = nil
        saveToDisk()
        syncRestAlarm(now: 0)
    }

    private func syncRestAlarm(now: Int64) {
        var fire: (date: Date, name: String)?
        if let session = activeSession, session.phase == .resting, let deadline = session.deadline {
            fire = (Date(timeIntervalSince1970: Double(deadline) / 1000.0), session.exercises[session.exerciseIndex].name)
        }
        // Chained so a quick pause and resume cannot apply out of order and leave the wrong alarm.
        let previous = alarmWork
        let alarm = restAlarm
        alarmWork = Task {
            await previous?.value
            if let fire {
                await alarm.schedule(at: fire.date, exerciseName: fire.name)
            } else {
                await alarm.cancel()
            }
        }
    }
}
