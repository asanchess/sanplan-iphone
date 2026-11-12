import Foundation
import Combine

/// «Отменить» for the last change: shown for a few seconds after it.
public struct WorkoutUndoOffer: Equatable, Identifiable {
    public let id: UUID
    public let label: String
}

/// Writes finished workouts to Apple Health and keeps them in step with edits and deletes in the history.
@MainActor
public protocol WorkoutHealthSyncing: AnyObject {
    func sync(previous: [WorkoutRecord], next: [WorkoutRecord])
}

@MainActor
public final class WorkoutStore: ObservableObject {
    /// One store per process, so a lock-screen button launched in the background acts on the same session as the screen.
    /// It reopens the account that was signed in last, since the lock screen can act before sign-in is checked.
    public static let shared = WorkoutStore(rememberOwner: true)

    @Published public var training: WorkoutTrainingPlan?
    @Published public var activeSession: WorkoutSessionState?
    @Published public var errorMessage: String?
    @Published public private(set) var history = WorkoutHistoryFile()
    @Published public private(set) var undoOffer: WorkoutUndoOffer?

    public let restAlarm: RestAlarmCoordinator
    public var health: WorkoutHealthSyncing?

    /// Where the workouts are kept: nothing while signed out, the phone's shared folder, or one account's folder.
    enum Location: Equatable {
        case none
        case device
        case account(folder: String)
    }

    private struct Snapshot {
        var label: String
        var training: WorkoutTrainingPlan?
        var session: WorkoutSessionState?
        var history: WorkoutHistoryFile
    }

    static let trainingFile = "arna_workout_training_v1.json"
    static let historyFile = "arna_workout_history_v1.json"
    static let ownerKey = "arna.workout.ownerFolder"
    static let undoLimit = 30

    private(set) var location: Location
    private let fileManager = FileManager.default
    private let arnaDir: URL
    private let defaults: UserDefaults
    private let rememberOwner: Bool
    private var isUnavailable = false
    private var undoStack: [Snapshot] = []
    private var alarmWork: Task<Void, Never>?
    private var restAlarmObservation: AnyCancellable?

    /// - Parameters:
    ///   - baseDirectory: the folder holding `ARNA`; Application Support by default, a temporary folder in tests.
    ///   - owner: whose workouts to open; by default the remembered one for the shared store, else the phone's shared file.
    public init(
        restAlarm: RestAlarmCoordinator? = nil,
        baseDirectory: URL? = nil,
        owner: FinanceStore.Owner? = nil,
        defaults: UserDefaults = .standard,
        rememberOwner: Bool = false
    ) {
        self.restAlarm = restAlarm ?? RestAlarmCoordinator()
        let base = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.arnaDir = base.appendingPathComponent("ARNA", isDirectory: true)
        self.defaults = defaults
        self.rememberOwner = rememberOwner
        if let owner {
            self.location = Self.location(for: owner)
        } else if rememberOwner {
            self.location = Self.remembered(defaults.string(forKey: Self.ownerKey))
        } else {
            self.location = .device
        }
        // The workout screen reads the alarm warning through this store, so redraw it when the warning changes.
        restAlarmObservation = self.restAlarm.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        if case .account(let folder) = location { adoptSharedFiles(into: folder) }
        loadFromDisk()
    }

    static func location(for owner: FinanceStore.Owner) -> Location {
        switch owner {
        case .none: return .none
        case .device: return .device
        case .account(let email): return .account(folder: FinanceStore.accountFolderName(email))
        }
    }

    private static func remembered(_ value: String?) -> Location {
        switch value ?? "device" {
        case "device": return .device
        case "none": return .none
        case let folder: return .account(folder: folder)
        }
    }

    // MARK: - Accounts

    /// Opens the workouts of whoever is signed in now; the same owner again changes nothing, so a running workout stays.
    /// Signing out unloads them without deleting: the session, plan and history wait in that account's folder.
    /// The first account after the update takes over the phone's earlier shared files.
    public func switchOwner(to owner: FinanceStore.Owner, now: Int64 = WorkoutStore.nowMs()) {
        let next = Self.location(for: owner)
        guard next != location else { return }
        location = next
        if rememberOwner {
            switch next {
            case .none: defaults.set("none", forKey: Self.ownerKey)
            case .device: defaults.set("device", forKey: Self.ownerKey)
            case .account(let folder): defaults.set(folder, forKey: Self.ownerKey)
            }
        }
        undoStack = []
        undoOffer = nil
        errorMessage = nil
        training = nil
        activeSession = nil
        history = WorkoutHistoryFile()
        isUnavailable = false
        if case .account(let folder) = next { adoptSharedFiles(into: folder) }
        loadFromDisk(now: now)
        syncRestAlarm(now: now)
    }

    public var isSignedOut: Bool { location == .none }

    private var directory: URL? {
        switch location {
        case .none: return nil
        case .device: return arnaDir
        case .account(let folder):
            return arnaDir.appendingPathComponent("accounts", isDirectory: true).appendingPathComponent(folder, isDirectory: true)
        }
    }

    /// A move, not a copy: the next account to sign in starts empty instead of seeing these workouts.
    private func adoptSharedFiles(into folder: String) {
        guard let target = directory else { return }
        try? fileManager.createDirectory(at: target, withIntermediateDirectories: true, attributes: nil)
        for name in [Self.trainingFile, Self.historyFile] {
            let shared = arnaDir.appendingPathComponent(name)
            let own = target.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: own.path), fileManager.fileExists(atPath: shared.path) {
                try? fileManager.moveItem(at: shared, to: own)
            }
        }
    }

    // MARK: - Files

    public func loadFromDisk(now: Int64 = WorkoutStore.nowMs()) {
        guard let directory else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let trainingURL = directory.appendingPathComponent(Self.trainingFile)
        let historyURL = directory.appendingPathComponent(Self.historyFile)

        if fileManager.fileExists(atPath: trainingURL.path) {
            // Unreadable before the first unlock after a restart: not corruption, so keep the file.
            guard let data = try? Data(contentsOf: trainingURL) else {
                markUnavailable()
                return
            }
            do {
                let decoded = WorkoutProgram.migrated(try JSONDecoder().decode(WorkoutTrainingPlan.self, from: data))
                if let session = decoded.session {
                    try WorkoutDomain.validateState(session)
                }
                training = decoded
                activeSession = decoded.session
            } catch {
                moveAside(trainingURL)
                training = nil
                activeSession = nil
                errorMessage = "Предыдущие поврежденные данные тренировки перемещены в архив."
            }
        }

        if fileManager.fileExists(atPath: historyURL.path) {
            guard let data = try? Data(contentsOf: historyURL) else {
                markUnavailable()
                return
            }
            do {
                var decoded = try JSONDecoder().decode(WorkoutHistoryFile.self, from: data)
                decoded.records = WorkoutHistory.sorted(decoded.records)
                history = decoded
            } catch {
                moveAside(historyURL)
                history = WorkoutHistoryFile()
                errorMessage = "История тренировок была повреждена и перемещена в архив."
            }
        }
        reconcileClock(now: now)
    }

    /// Reads the files again once the phone is unlocked, if they could not be read before.
    public func reloadIfUnavailable() {
        guard isUnavailable else { return }
        isUnavailable = false
        errorMessage = nil
        loadFromDisk()
    }

    private func markUnavailable() {
        isUnavailable = true
        training = nil
        activeSession = nil
        history = WorkoutHistoryFile()
        errorMessage = "Тренировка недоступна, пока телефон не разблокирован."
    }

    private func moveAside(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let name = url.deletingPathExtension().lastPathComponent + "_corrupt_\(stamp).json"
        try? fileManager.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent(name))
    }

    public func saveToDisk() {
        saveTraining()
    }

    private func saveTraining() {
        guard let directory, !isUnavailable else { return }
        var toSave = training ?? WorkoutProgram.empty()
        toSave.session = activeSession
        write(toSave, to: directory.appendingPathComponent(Self.trainingFile), what: "тренировку")
    }

    private func saveHistory() {
        guard let directory, !isUnavailable else { return }
        write(history, to: directory.appendingPathComponent(Self.historyFile), what: "историю тренировок")
    }

    private func write<T: Encodable>(_ value: T, to url: URL, what: String) {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            errorMessage = "Не удалось сохранить \(what): \(error.localizedDescription)"
        }
    }

    // MARK: - Changes and «Отменить»

    /// Every change goes through here: it is checked, the finished workout is kept in the history, files are written,
    /// the rest alarm follows, and a change with a label can be undone.
    private func change(_ label: String?, now: Int64, _ body: () throws -> Void) {
        guard location != .none else {
            errorMessage = "Войдите в аккаунт, чтобы сохранять тренировки."
            return
        }
        reloadIfUnavailable()
        guard !isUnavailable else { return }
        let before = snapshot(label ?? "")
        do {
            try body()
        } catch {
            restore(before)
            errorMessage = error.localizedDescription
            return
        }
        if activeSession != before.session {
            archiveSession(now: now)
        }
        let changed = training != before.training || activeSession != before.session || history != before.history
        if let label, changed {
            undoStack.append(before)
            if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
            undoOffer = WorkoutUndoOffer(id: UUID(), label: label)
        }
        persist(since: before)
        syncRestAlarm(now: now)
    }

    /// Puts back the state before the last change that offered «Отменить». Each further call goes one step back.
    public func undoLast(now: Int64 = WorkoutStore.nowMs()) {
        guard let previous = undoStack.popLast() else { return }
        let before = snapshot("")
        restore(previous)
        undoOffer = nil
        persist(since: before)
        syncRestAlarm(now: now)
        // A rest that ran out in the meantime rings now, as it would have.
        reconcileClock(now: now)
    }

    public var canUndo: Bool { !undoStack.isEmpty }

    /// Hides the offer once its few seconds have passed; the change can still be undone from the stack.
    public func dismissUndo(_ id: UUID) {
        if undoOffer?.id == id { undoOffer = nil }
    }

    private func snapshot(_ label: String) -> Snapshot {
        Snapshot(label: label, training: training, session: activeSession, history: history)
    }

    private func restore(_ snapshot: Snapshot) {
        training = snapshot.training
        activeSession = snapshot.session
        history = snapshot.history
    }

    private func persist(since before: Snapshot) {
        if training != before.training || activeSession != before.session {
            saveTraining()
        }
        if history != before.history {
            saveHistory()
            health?.sync(previous: before.history.records, next: history.records)
        }
    }

    /// A finished workout is kept in the history and follows later edits on its summary. One with no set done is not kept.
    private func archiveSession(now: Int64) {
        guard var session = activeSession, session.phase == .complete else { return }
        if session.recordId == nil {
            session.recordId = UUID().uuidString
            activeSession = session
        }
        let id = session.recordId ?? UUID().uuidString
        let existing = history.records.first { $0.id == id }
        guard var record = WorkoutHistory.record(from: session, id: id, now: now) else {
            if existing != nil { history.records = WorkoutHistory.removing(history.records, id: id) }
            return
        }
        if record.endedAt - record.startedAt > WorkoutHistory.maxDurationMs {
            record.startedAt = record.endedAt - WorkoutHistory.maxDurationMs
        }
        if let existing {
            record.note = existing.note
            record.healthId = existing.healthId
        }
        if let next = try? WorkoutHistory.upsert(history.records, record) {
            history.records = next
        }
    }

    // MARK: - Plan

    /// The weekly program as the builder sees it; empty before the first exercise is added.
    public var program: WorkoutTrainingPlan {
        training ?? WorkoutProgram.empty()
    }

    /// One builder edit. A running workout is never touched; errors show as a banner.
    /// Pass a nil label for edits too small to offer «Отменить», like each typed letter of a title.
    public func updateProgram(label: String? = "План изменён", _ edit: (WorkoutTrainingPlan) throws -> WorkoutTrainingPlan) {
        change(label, now: Self.nowMs()) {
            training = try edit(program)
        }
    }

    public func setTrainingPlan(_ plan: WorkoutTrainingPlan) {
        change(nil, now: Self.nowMs()) {
            training = plan
            activeSession = plan.session
        }
    }

    // MARK: - Workout

    /// Starts a workout from a plan day with last time's results and today's targets filled in.
    public func startWorkout(day: WorkoutDayPlan, now: Int64 = WorkoutStore.nowMs()) {
        change("Тренировка начата", now: now) {
            let planned = try WorkoutDomain.sessionExercises(from: day)
            let exercises = WorkoutHistory.prepared(planned, history: history.records)
            var session = try WorkoutDomain.createWorkout(exercises: exercises, now: now)
            session.planDay = day
            session.recordId = UUID().uuidString
            activeSession = session
        }
    }

    public func dispatch(command: WorkoutCommand, now: Int64 = WorkoutStore.nowMs()) {
        guard let current = activeSession else { return }
        let at = command.type == "recoverClock" ? now : WorkoutDomain.userCommandTime(now, state: current)
        change(Self.undoLabel(for: command.type), now: at) {
            activeSession = try WorkoutDomain.workoutCommand(state: current, command: command, now: at)
        }
    }

    /// What «Отменить» says for a command; nil for clock steps and small adjustments that are not worth undoing.
    static func undoLabel(for type: String) -> String? {
        switch type {
        case "startRest": return "Подход отмечен"
        case "finishSet", "finish": return "Тренировка завершена"
        case "skipRest": return "Отдых пропущен"
        case "acknowledge": return "Следующий подход"
        case "startNow": return "Подход начат"
        case "setSets": return "Подходы изменены"
        default: return nil
        }
    }

    /// An edit of the running or just finished workout: logged sets, its exercises, or where the user is.
    /// Stepper adjustments pass a nil label: the opposite step undoes them, so they offer no toast.
    public func editSession(
        _ label: String?,
        now: Int64 = WorkoutStore.nowMs(),
        _ edit: (WorkoutSessionState) throws -> WorkoutSessionState
    ) {
        guard let current = activeSession else { return }
        change(label, now: now) {
            activeSession = try edit(current)
        }
    }

    /// The plan day as the workout ended up, when it differs from the plan.
    public var pendingPlanChanges: WorkoutDayPlan? {
        activeSession.flatMap(WorkoutHistory.planChanges)
    }

    /// «Сохранить изменения в план»: the workout's exercises, sets, reps, rests and weights become the plan of its day.
    public func saveSessionChangesToPlan(now: Int64 = WorkoutStore.nowMs()) {
        guard var session = activeSession, let day = WorkoutHistory.planChanges(session) else { return }
        change("План обновлён", now: now) {
            let next = try WorkoutProgram.replaceDay(program, with: day)
            training = next
            let saved = WorkoutProgram.day(next, weekday: day.weekday)
            if let saved {
                for i in session.exercises.indices where saved.exercises.indices.contains(i) {
                    session.exercises[i].exerciseId = saved.exercises[i].id
                }
            }
            session.planDay = saved
            activeSession = session
        }
    }

    public func reconcileClock(now: Int64 = WorkoutStore.nowMs()) {
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

    /// Closes the workout screen. A finished workout is already in the history; one in progress is dropped.
    public func discardWorkout(now: Int64 = WorkoutStore.nowMs()) {
        guard let session = activeSession else { return }
        change(session.phase == .complete ? nil : "Тренировка удалена", now: now) {
            activeSession = nil
        }
    }

    // MARK: - History

    public var records: [WorkoutRecord] { history.records }

    /// Saves an edited workout or one added by hand.
    public func saveRecord(_ record: WorkoutRecord, now: Int64 = WorkoutStore.nowMs()) {
        let exists = history.records.contains { $0.id == record.id }
        change(exists ? "Тренировка изменена" : "Тренировка добавлена", now: now) {
            history.records = try WorkoutHistory.upsert(history.records, record)
        }
    }

    public func deleteRecord(id: String, now: Int64 = WorkoutStore.nowMs()) {
        guard history.records.contains(where: { $0.id == id }) else { return }
        change("Тренировка удалена", now: now) {
            history.records = WorkoutHistory.removing(history.records, id: id)
            // The finished workout still on screen would otherwise bring the record back with its next edit.
            if let session = activeSession, session.phase == .complete, session.recordId == id {
                activeSession = nil
            }
        }
    }

    /// Workouts a week for the streak; nil goes back to one per training day of the plan.
    public func setWeeklyGoal(_ goal: Int?) {
        change(nil, now: Self.nowMs()) {
            if let goal, !WorkoutHistory.goalRange.contains(goal) {
                throw WorkoutDomainError("Цель — от 1 до 14 тренировок в неделю")
            }
            history.weeklyGoal = goal
        }
    }

    public var weeklyGoal: Int {
        WorkoutHistory.effectiveGoal(history.weeklyGoal, planDays: program.days.count)
    }

    // MARK: - Rest alarm

    private func syncRestAlarm(now: Int64) {
        var fire: (date: Date, name: String)?
        if let session = activeSession, session.phase == .resting, let deadline = session.deadline,
           session.exercises.indices.contains(session.exerciseIndex) {
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

    public nonisolated static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
