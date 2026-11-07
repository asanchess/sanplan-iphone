import Foundation

@MainActor
public final class PlanStore: ObservableObject {
    @Published public var plans: [PlanItem] = [] {
        didSet {
            plansRevision += 1
            reconcileDraftsWithSaved()
        }
    }
    @Published public var remoteEvents: [PlanItem] = []
    @Published public var upcomingEvents: [PlanItem] = []
    @Published public var selectedDate: String
    @Published public var timeZone: String = PlanDomain.defaultTimeZone
    @Published public var draftPlans: [PlanItem] = [] {
        didSet { saveDraftToDisk() }
    }
    @Published public var editingPlanId: String? = nil
    @Published public var isLoading: Bool = false
    @Published public var isParsing: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var pendingTaskIds: Set<String> = []
    @Published public var googlePendingId: String? = nil
    /// Drafts the server refused because they overlap something; saving them needs an explicit choice.
    @Published public var conflictedDraftIds: Set<String> = []

    /// The server takes 4 MB of JSON, and base64 inflates audio by a third.
    public static let maxAudioBytes = 2_900_000

    private let client: APIClient
    private let onUnauthorized: () -> Void
    private let onPlansChanged: ([PlanItem]) -> Void
    private let draftPersistenceKey = "arna.planner.draft.json"
    private var loadedRange: (start: String, end: String)? = nil
    /// Bumped at sign-out so a response still in flight cannot bring the old account's plans back.
    private var generation = 0
    /// Bumped on every write to `plans`, so a list fetched before a save cannot overwrite the save.
    private var plansRevision = 0
    private var reloadInFlight = false

    public init(
        client: APIClient,
        onUnauthorized: @escaping () -> Void,
        onPlansChanged: @escaping ([PlanItem]) -> Void = { _ in }
    ) {
        self.client = client
        self.onUnauthorized = onUnauthorized
        self.onPlansChanged = onPlansChanged
        self.selectedDate = PlanDomain.today()

        loadDraftFromDisk()
    }

    public var activeDraft: PlanItem? {
        get {
            if let editingId = editingPlanId {
                return draftPlans.first(where: { $0.id == editingId })
            }
            return draftPlans.first
        }
        set {
            if let val = newValue {
                updateDraft(val)
            }
        }
    }

    public var dayAgenda: [AgendaItem] {
        PlanDomain.getAgendaItems(
            plans: plans + draftPlans + remoteEvents,
            targetDate: selectedDate,
            targetTimeZone: timeZone
        )
    }

    public func agenda(for date: String) -> [AgendaItem] {
        PlanDomain.getAgendaItems(
            plans: plans + draftPlans + remoteEvents,
            targetDate: date,
            targetTimeZone: timeZone
        )
    }

    public var upcomingAgenda: [AgendaItem] {
        PlanDomain.getUpcomingItems(
            plans: plans + draftPlans + upcomingEvents,
            nowEpochMs: Int64(Date().timeIntervalSince1970 * 1000),
            timeZone: timeZone
        )
    }

    public func setDraftPlans(_ drafts: [PlanItem]) {
        self.draftPlans = drafts.map { PlanDomain.withDefaultReminders($0) }
        self.editingPlanId = self.draftPlans.first?.id
        self.conflictedDraftIds = []
    }

    public func updateDraft(_ draft: PlanItem) {
        if let idx = draftPlans.firstIndex(where: { $0.id == draft.id }) {
            draftPlans[idx] = draft
        } else {
            draftPlans.append(draft)
        }
    }

    public func removeDraft(id: String) {
        draftPlans.removeAll(where: { $0.id == id })
        conflictedDraftIds.remove(id)
        if editingPlanId == id {
            editingPlanId = draftPlans.first?.id
        }
    }

    public func clearAllDrafts() {
        draftPlans = []
        conflictedDraftIds = []
        editingPlanId = nil
    }

    /// Forgets everything that belongs to the signed-in account.
    public func resetForSignOut() {
        generation += 1
        reloadInFlight = false
        plans = []
        remoteEvents = []
        upcomingEvents = []
        loadedRange = nil
        errorMessage = nil
        pendingTaskIds = []
        googlePendingId = nil
        isLoading = false
        isParsing = false
        clearAllDrafts()
    }

    public func reload() async {
        // Launch, the Today tab and the Plans tab all ask at once; one request answers them all.
        guard !reloadInFlight else { return }
        reloadInFlight = true
        let started = generation
        let revisionAtStart = plansRevision
        isLoading = true
        errorMessage = nil
        defer {
            reloadInFlight = false
            if started == generation { isLoading = false }
        }

        do {
            let loaded = try await PlanAPI.getPlans(client: client)
            guard started == generation else { return }
            // A save or alarm change that landed meanwhile already holds the newer list.
            if revisionAtStart == plansRevision {
                plans = loaded
                onPlansChanged(loaded)
            }
        } catch let err as APIError {
            guard started == generation else { return }
            handleAPIError(err)
            return
        } catch {
            guard started == generation else { return }
            errorMessage = error.localizedDescription
            return
        }
        await loadCalendar()
    }

    /// The saved plans stay on screen when only the calendar fails.
    private func loadCalendar() async {
        let started = generation
        let start = PlanDomain.addDays(dateStr: selectedDate, days: -7)
        let end = PlanDomain.addDays(dateStr: selectedDate, days: 14)
        do {
            async let range = PlanAPI.getCalendarRange(client: client, start: start, end: end, timeZone: timeZone)
            async let upcoming = PlanAPI.getUpcoming(client: client, timeZone: timeZone)
            let (rangeEvents, upcomingList) = try await (range, upcoming)
            guard started == generation else { return }
            remoteEvents = rangeEvents
            upcomingEvents = upcomingList
            loadedRange = (start, end)
        } catch let err as APIError {
            guard started == generation else { return }
            if case .unauthorized = err {
                handleAPIError(err)
            } else {
                errorMessage = "Google Календарь сейчас недоступен. Показаны только планы ARNA."
            }
        } catch {
            guard started == generation else { return }
            errorMessage = "Google Календарь сейчас недоступен. Показаны только планы ARNA."
        }
    }

    /// Moving between weeks only reaches the network once the selected day leaves the loaded window.
    public func ensureRangeLoaded() async {
        if let range = loadedRange, selectedDate >= range.start, selectedDate < range.end { return }
        await loadCalendar()
    }

    public func parseText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let started = generation
        isParsing = true
        errorMessage = nil
        defer { if started == generation { isParsing = false } }

        do {
            let parsed = try await PlanAPI.parse(client: client, text: trimmed, timeZone: timeZone)
            guard started == generation else { return }
            if parsed.isEmpty {
                errorMessage = "Не удалось распознать планы в тексте."
            } else {
                setDraftPlans(parsed)
            }
        } catch let err as APIError {
            guard started == generation else { return }
            handleAPIError(err)
        } catch {
            guard started == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func transcribe(audio: Data, mimeType: String) async {
        guard audio.count <= Self.maxAudioBytes else {
            errorMessage = "Запись слишком длинная. Продиктуй короче, до 10 минут."
            return
        }
        let started = generation
        isParsing = true
        errorMessage = nil
        defer { if started == generation { isParsing = false } }

        do {
            let response = try await PlanAPI.transcribe(
                client: client,
                audioBase64: audio.base64EncodedString(),
                mimeType: mimeType,
                timeZone: timeZone,
                intent: "plans"
            )
            guard started == generation else { return }
            if response.plans?.isEmpty != false && response.transcript?.isEmpty != false {
                errorMessage = "Не удалось разобрать запись. Попробуй ещё раз."
                return
            }
            handleTranscribeResult(transcript: response.transcript, plans: response.plans, intent: "plans")
        } catch let err as APIError {
            guard started == generation else { return }
            handleAPIError(err)
        } catch {
            guard started == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func handleTranscribeResult(transcript: String?, plans: [PlanItem]?, intent: String) {
        if let plans = plans, !plans.isEmpty {
            setDraftPlans(plans)
        } else if let t = transcript, !t.isEmpty {
            if intent == "plans" {
                Task {
                    await parseText(t)
                }
            } else if var draft = activeDraft {
                let prev = draft.title
                draft.title = prev.isEmpty ? t : "\(prev) \(t)"
                updateDraft(draft)
            }
        }
    }

    /// Only drafts the server confirms leave the list; a refused draft stays for correction.
    @discardableResult
    public func saveDrafts(keepConflicts: Bool = false) async -> Bool {
        guard !draftPlans.isEmpty else { return true }
        for draft in draftPlans {
            let validationErrors = PlanDomain.validatePlan(draft)
            if !validationErrors.isEmpty {
                errorMessage = "«\(draft.title)»: " + validationErrors.joined(separator: " ")
                return false
            }
        }

        let started = generation
        isLoading = true
        errorMessage = nil
        defer { if started == generation { isLoading = false } }

        do {
            let response = try await PlanAPI.savePlans(
                client: client,
                plans: draftPlans,
                confirmed: true,
                keepConflicts: keepConflicts
            )
            guard started == generation else { return false }
            let results = response.results ?? []
            let savedIds = Set(results.filter { $0.status == "saved" }.compactMap(\.id))
            let refused = results.filter { $0.status != "saved" }

            draftPlans.removeAll { savedIds.contains($0.id) }
            editingPlanId = draftPlans.first?.id
            conflictedDraftIds = Set(refused.filter { $0.message == PlanAPI.conflictMessage }.compactMap(\.id))
            if let all = response.plans {
                plans = all
                onPlansChanged(all)
            }
            await loadCalendar()

            if !refused.isEmpty {
                errorMessage = refused.compactMap(\.message).joined(separator: " ")
                return false
            }
            return true
        } catch let err as APIError {
            guard started == generation else { return false }
            handleAPIError(err)
            return false
        } catch {
            guard started == generation else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func toggleTaskCompletion(id: String, completed: Bool) async {
        let started = generation
        pendingTaskIds.insert(id)
        plans = PlanDomain.setPlanCompletion(plans: plans, id: id, completed: completed)
        defer { pendingTaskIds.remove(id) }

        do {
            let updated = try await PlanAPI.completePlan(client: client, id: id, completed: completed)
            guard started == generation else { return }
            if let updated, let idx = plans.firstIndex(where: { $0.id == updated.id }) {
                plans[idx] = updated
            }
            onPlansChanged(plans)
        } catch let err as APIError {
            guard started == generation else { return }
            plans = PlanDomain.setPlanCompletion(plans: plans, id: id, completed: !completed)
            handleAPIError(err)
        } catch {
            guard started == generation else { return }
            plans = PlanDomain.setPlanCompletion(plans: plans, id: id, completed: !completed)
            errorMessage = error.localizedDescription
        }
    }

    public func exportPlanToGoogle(_ item: PlanItem) async {
        let started = generation
        googlePendingId = item.id
        defer { if started == generation { googlePendingId = nil } }

        do {
            let updated = try await PlanAPI.exportToGoogle(client: client, plan: item)
            guard started == generation else { return }
            if let updated, let idx = plans.firstIndex(where: { $0.id == updated.id }) {
                plans[idx] = updated
            }
            onPlansChanged(plans)
            await loadCalendar()
        } catch let err as APIError {
            guard started == generation else { return }
            handleAPIError(err)
        } catch {
            guard started == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Creates, changes or removes an alarm schedule. Returns a message when the server refuses.
    public func mutateAlarm(_ request: AlarmMutationRequest) async -> String? {
        let started = generation
        do {
            let updated = try await PlanAPI.mutateAlarm(client: client, request: request)
            guard started == generation else { return nil }
            plans = updated
            onPlansChanged(updated)
            return nil
        } catch let err as APIError {
            guard started == generation else { return nil }
            if case .unauthorized = err {
                handleAPIError(err)
                return nil
            }
            return err.localizedDescription
        } catch {
            guard started == generation else { return nil }
            return error.localizedDescription
        }
    }

    /// A save whose reply was lost may still have reached the server. An unchanged draft that is
    /// already stored leaves the list; an edited one gets a new id, because the server refuses a
    /// changed plan under an id it already holds.
    private func reconcileDraftsWithSaved() {
        guard !draftPlans.isEmpty else { return }
        let stored = Dictionary(plans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        var next: [PlanItem] = []
        for draft in draftPlans {
            guard let saved = stored[draft.id] else { next.append(draft); continue }
            changed = true
            if Self.sameContent(saved, draft) {
                conflictedDraftIds.remove(draft.id)
                continue
            }
            var renamed = draft
            renamed.id = UUID().uuidString
            if editingPlanId == draft.id { editingPlanId = renamed.id }
            if conflictedDraftIds.remove(draft.id) != nil { conflictedDraftIds.insert(renamed.id) }
            next.append(renamed)
        }
        guard changed else { return }
        draftPlans = next
        if let editing = editingPlanId, !next.contains(where: { $0.id == editing }) {
            editingPlanId = next.first?.id
        }
    }

    /// Mirrors the server's sameness check for the fields a person can edit.
    static func sameContent(_ a: PlanItem, _ b: PlanItem) -> Bool {
        func offsets(_ p: PlanItem) -> [Int] { ((try? PlanDomain.getReminderOffsets(plan: p)) ?? []).sorted() }
        return a.title == b.title && a.kind == b.kind && a.date == b.date && a.time == b.time
            && a.durationMinutes == b.durationMinutes && offsets(a) == offsets(b)
    }

    private func handleAPIError(_ err: APIError) {
        if case .unauthorized = err {
            onUnauthorized()
            return
        }
        errorMessage = err.localizedDescription
    }

    private func saveDraftToDisk() {
        guard let data = try? JSONEncoder().encode(draftPlans) else { return }
        UserDefaults.standard.set(data, forKey: draftPersistenceKey)
    }

    private func loadDraftFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: draftPersistenceKey),
              let loaded = try? JSONDecoder().decode([PlanItem].self, from: data) else { return }
        draftPlans = loaded
        editingPlanId = loaded.first?.id
    }
}
