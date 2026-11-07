import SwiftUI

/// One reminder of a plan, at the moment it rings.
public struct AlarmSignal: Equatable, Identifiable {
    public var id: Int { offset }
    public let offset: Int
    public let fireMs: Int64
    public let isPast: Bool
}

public struct AlarmRow: Equatable, Identifiable {
    public var id: String { plan.id }
    public let plan: PlanItem
    public let timeZone: String
    public let eventMs: Int64?
    public let signals: [AlarmSignal]
    public var nextSignal: AlarmSignal? { signals.first { !$0.isPast } }
}

/// The alarm list the web app shows, built from the same rules (`src/alarm-list.mjs`).
public enum AlarmRows {
    static func offsets(of plan: PlanItem) -> [Int]? {
        let schedule = plan.alarmSchedule ?? plan.googleSchedule
        if let list = schedule?.reminderOffsets ?? (schedule == nil ? plan.reminderOffsets : nil) { return list }
        if let scalar = schedule?.reminderMinutes ?? (schedule == nil ? plan.reminderMinutes : nil) {
            return scalar >= 0 ? [scalar] : []
        }
        return nil
    }

    static func hasAlarm(_ plan: PlanItem) -> Bool {
        if plan.alarmOnly == true || plan.alarmSchedule != nil { return true }
        return offsets(of: plan)?.isEmpty == false
    }

    public static func row(for plan: PlanItem, nowMs: Int64) -> AlarmRow {
        let schedule = plan.alarmSchedule ?? plan.googleSchedule
        let zone = schedule?.timeZone ?? plan.timeZone
        let eventMs = (schedule?.date ?? plan.date).flatMap { date in
            (schedule?.time ?? plan.time).flatMap { PlanDomain.zonedEpoch(dateStr: date, timeStr: $0, timeZone: zone) }
        }
        var signals: [AlarmSignal] = []
        if let eventMs, plan.completed != true, plan.alarmDeleted != true {
            signals = (offsets(of: plan) ?? [])
                .map { offset in
                    let fire = eventMs - Int64(offset) * 60_000
                    return AlarmSignal(offset: offset, fireMs: fire, isPast: fire <= nowMs)
                }
                .sorted { $0.fireMs < $1.fireMs }
        }
        return AlarmRow(plan: plan, timeZone: zone, eventMs: eventMs, signals: signals)
    }

    public static func build(plans: [PlanItem], nowMs: Int64, showAll: Bool) -> [AlarmRow] {
        let chosen = showAll ? plans : plans.filter { $0.completed != true && $0.alarmDeleted != true && hasAlarm($0) }
        let rows = chosen.map { row(for: $0, nowMs: nowMs) }
        if showAll {
            return rows.sorted { a, b in
                switch (a.eventMs, b.eventMs) {
                case let (x?, y?) where x != y: return x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.plan.id < b.plan.id
                }
            }
        }
        return rows.sorted { a, b in
            switch (a.nextSignal, b.nextSignal) {
            case let (x?, y?) where x.fireMs != y.fireMs: return x.fireMs < y.fireMs
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil):
                let x = a.signals.last?.fireMs ?? Int64.min
                let y = b.signals.last?.fireMs ?? Int64.min
                return x != y ? x > y : a.plan.id < b.plan.id
            default: return a.plan.id < b.plan.id
            }
        }
    }

    /// The word shown when a plan has nothing left to ring.
    public static func status(of row: AlarmRow) -> String {
        if row.plan.completed == true { return "Выполнено" }
        if row.plan.alarmDeleted == true { return "Отключено" }
        if row.eventMs == nil { return "Нужны дата и время" }
        if row.signals.isEmpty { return "Не выбрано" }
        return "Время прошло"
    }
}

/// Reads and writes `yyyy-MM-dd` and `HH:mm` as a single picker value in the plan's own zone.
enum PlanDateTime {
    static func formatter(_ format: String, timeZone: String, locale: String = "en_US_POSIX") -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: locale)
        formatter.timeZone = TimeZone(identifier: timeZone) ?? .current
        formatter.dateFormat = format
        return formatter
    }

    static func date(date: String?, time: String?, timeZone: String) -> Date {
        let text = "\(date ?? PlanDomain.today(timeZone: timeZone)) \(time ?? "09:00")"
        return formatter("yyyy-MM-dd HH:mm", timeZone: timeZone).date(from: text) ?? Date()
    }

    static func parts(_ value: Date, timeZone: String) -> (date: String, time: String) {
        (formatter("yyyy-MM-dd", timeZone: timeZone).string(from: value),
         formatter("HH:mm", timeZone: timeZone).string(from: value))
    }

    static func long(_ ms: Int64, timeZone: String) -> String {
        formatter("d MMMM yyyy, HH:mm", timeZone: timeZone, locale: "ru_RU")
            .string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func clock(_ ms: Int64, timeZone: String) -> String {
        formatter("HH:mm", timeZone: timeZone).string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

/// Up to five reminder intervals: presets, a custom interval, or none.
struct ReminderOffsetsPicker: View {
    @Binding var offsets: [Int]
    @State private var days = ""
    @State private var hours = ""
    @State private var minutes = ""
    @State private var notice: String? = nil

    private static let presets = [0, 10, 60, 1440]

    private var shown: [Int] {
        (Self.presets + offsets.filter { !Self.presets.contains($0) }).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
            Text("Напоминания")
                .font(.footnote.weight(.medium))
                .foregroundColor(DS.Colors.textSecondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: DS.Metrics.spacing8)], spacing: DS.Metrics.spacing8) {
                ForEach(shown, id: \.self) { offset in
                    chip(offset)
                }
            }

            DisclosureGroup("Свой интервал") {
                HStack(spacing: DS.Metrics.spacing8) {
                    numberField("Дни", text: $days)
                    numberField("Часы", text: $hours)
                    numberField("Мин", text: $minutes)
                    Button("Добавить", action: addCustom)
                        .font(.footnote.weight(.medium))
                        .foregroundColor(DS.Colors.accent)
                        .frame(minHeight: DS.Metrics.minHitTarget)
                }
                .padding(.top, DS.Metrics.spacing4)
            }
            .font(.footnote)
            .tint(DS.Colors.textSecondary)
            .foregroundColor(DS.Colors.textPrimary)

            Button(offsets.isEmpty ? "Без напоминаний" : "Убрать все напоминания") {
                offsets = []
                notice = nil
            }
            .font(.footnote)
            .foregroundColor(offsets.isEmpty ? DS.Colors.textSecondary : DS.Colors.accent)
            .disabled(offsets.isEmpty)
            .frame(minHeight: DS.Metrics.minHitTarget)

            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundColor(DS.Colors.warning)
            }
        }
    }

    private func chip(_ offset: Int) -> some View {
        let selected = offsets.contains(offset)
        return Button {
            toggle(offset)
        } label: {
            Text(PlanDomain.formatReminderOffset(offset))
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: DS.Metrics.minHitTarget)
                .foregroundColor(selected ? DS.Colors.onAccent : DS.Colors.textPrimary)
                .background(selected ? DS.Colors.accent : DS.Colors.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func numberField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .keyboardType(.numberPad)
            .font(.footnote.monospacedDigit())
            .padding(DS.Metrics.spacing8)
            .background(DS.Colors.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
    }

    private func toggle(_ offset: Int) {
        if offsets.contains(offset) {
            offsets.removeAll { $0 == offset }
            notice = nil
        } else {
            add(offset)
        }
    }

    private func add(_ offset: Int) {
        if offsets.contains(offset) {
            notice = "Такое напоминание уже добавлено."
        } else if offsets.count >= 5 {
            notice = "Можно выбрать до пяти напоминаний."
        } else {
            offsets = (offsets + [offset]).sorted(by: >)
            notice = nil
        }
    }

    private func addCustom() {
        let values = [days, hours, minutes].map { $0.isEmpty ? 0 : Int($0) }
        guard !(days.isEmpty && hours.isEmpty && minutes.isEmpty),
              let d = values[0], let h = values[1], let m = values[2], d >= 0, (0...23).contains(h), (0...59).contains(m) else {
            notice = "Укажи целые дни, часы от 0 до 23 и минуты от 0 до 59."
            return
        }
        let total = d * 1440 + h * 60 + m
        guard total <= 40320 else {
            notice = "Максимум — четыре недели заранее."
            return
        }
        add(total)
        days = ""
        hours = ""
        minutes = ""
    }
}

public struct AlarmsScreen: View {
    @ObservedObject var store: PlanStore
    @EnvironmentObject private var coordinator: AlarmCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var showAll = false
    @State private var editor: AlarmEditorTarget? = nil
    @State private var confirmDeleteOwn = false

    public var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.canvas.ignoresSafeArea()
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    let rows = AlarmRows.build(
                        plans: store.plans,
                        nowMs: Int64(context.date.timeIntervalSince1970 * 1000),
                        showAll: showAll
                    )
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                            accessCard
                            nearestCard(rows)
                            PillButton("Создать будильник", icon: "plus", style: .primary) {
                                editor = .new
                            }
                            Picker("Список будильников", selection: $showAll) {
                                Text("С сигналами").tag(false)
                                Text("Все планы").tag(true)
                            }
                            .pickerStyle(.segmented)

                            if rows.isEmpty {
                                EmptyState(
                                    title: "Будильников пока нет",
                                    message: "Создай отдельный или открой «Все планы», чтобы добавить сигнал к плану.",
                                    icon: "alarm"
                                )
                            } else {
                                ForEach(rows) { row in
                                    alarmRow(row)
                                }
                            }
                            deviceCard
                        }
                        .padding(.horizontal, DS.Metrics.screenGutter)
                        .padding(.vertical, DS.Metrics.spacing16)
                    }
                    .refreshable { await store.reload() }
                }
            }
            .navigationTitle("Будильники")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .sheet(item: $editor) { target in
                AlarmEditor(store: store, target: target).keyboardDismissBar()
            }
            .confirmationDialog("Удалить будильники с iPhone?", isPresented: $confirmDeleteOwn, titleVisibility: .visible) {
                Button("Удалить с iPhone", role: .destructive) {
                    Task { await coordinator.deleteAllOwnAlarms() }
                }
                Button("Оставить", role: .cancel) {}
            } message: {
                Text("Сигналы ARNA исчезнут с этого телефона. Расписание останется и вернётся при следующей синхронизации.")
            }
        }
        .task { await coordinator.reconcileWithSystem() }
    }

    @ViewBuilder
    private var accessCard: some View {
        if !coordinator.isAuthorized {
            Card {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing8) {
                    Text("Нет доступа к будильникам")
                        .font(.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Без доступа сигналы не прозвучат на заблокированном экране.")
                        .font(.footnote)
                        .foregroundColor(DS.Colors.textSecondary)
                    PillButton("Разрешить доступ", style: .secondary) {
                        Task {
                            await coordinator.requestAuthorization()
                            await coordinator.syncAlarms(plans: store.plans.map { $0.toNativePlan() })
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func nearestCard(_ rows: [AlarmRow]) -> some View {
        let nearest = rows
            .compactMap { row in row.nextSignal.map { (row, $0) } }
            .min { $0.1.fireMs < $1.1.fireMs }
        if let (row, signal) = nearest {
            Card {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing4) {
                    Text("Ближайший сигнал")
                        .font(.footnote)
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(PlanDateTime.clock(signal.fireMs, timeZone: row.timeZone))
                        .font(.system(size: 44, weight: .light).monospacedDigit())
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(row.plan.title)
                        .font(.body.weight(.medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(PlanDateTime.long(signal.fireMs, timeZone: row.timeZone))
                        .font(.footnote)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func alarmRow(_ row: AlarmRow) -> some View {
        Card {
            HStack(alignment: .top, spacing: DS.Metrics.spacing12) {
                VStack(alignment: .leading, spacing: DS.Metrics.spacing4) {
                    if let ms = row.nextSignal?.fireMs ?? row.eventMs {
                        Text(PlanDateTime.clock(ms, timeZone: row.timeZone))
                            .font(.title2.weight(.light).monospacedDigit())
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                    Text(row.plan.title)
                        .font(.body.weight(.medium))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(subtitle(row))
                        .font(.footnote)
                        .foregroundColor(DS.Colors.textSecondary)
                    ForEach(row.signals) { signal in
                        Text("\(PlanDomain.formatReminderOffset(signal.offset)) · \(PlanDateTime.long(signal.fireMs, timeZone: row.timeZone))")
                            .font(.caption)
                            .strikethrough(signal.isPast)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                Button("Изменить") { editor = .existing(row.plan) }
                    .font(.footnote.weight(.medium))
                    .foregroundColor(DS.Colors.accent)
                    .frame(minHeight: DS.Metrics.minHitTarget)
                    .accessibilityLabel("Изменить будильник: \(row.plan.title)")
            }
        }
    }

    private func subtitle(_ row: AlarmRow) -> String {
        let state: String
        if let next = row.nextSignal {
            state = PlanDateTime.formatter("d MMMM yyyy", timeZone: row.timeZone, locale: "ru_RU")
                .string(from: Date(timeIntervalSince1970: Double(next.fireMs) / 1000))
        } else {
            state = AlarmRows.status(of: row)
        }
        return "\(state) · \(row.plan.alarmOnly == true ? "Отдельный будильник" : "К плану")"
    }

    private var deviceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                Text("На этом iPhone")
                    .font(.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(coordinator.statusMessage)
                    .font(.footnote)
                    .foregroundColor(DS.Colors.textSecondary)
                ForEach(coordinator.syncErrors + coordinator.syncWarnings, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundColor(DS.Colors.warning)
                }
                Text("Активно сигналов: \(coordinator.activeRecords.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(DS.Colors.textPrimary)
                PillButton("Проверить: сигнал через минуту", icon: "alarm", style: .secondary) {
                    Task { await coordinator.scheduleTestAlarmInOneMinute() }
                }
                if !coordinator.activeRecords.isEmpty {
                    Button("Удалить сигналы с iPhone", role: .destructive) {
                        confirmDeleteOwn = true
                    }
                    .font(.footnote)
                    .foregroundColor(DS.Colors.destructive)
                    .frame(minHeight: DS.Metrics.minHitTarget)
                }
            }
        }
    }
}

enum AlarmEditorTarget: Identifiable {
    case new
    case existing(PlanItem)

    var id: String {
        switch self {
        case .new: return "new"
        case .existing(let plan): return plan.id
        }
    }
}

struct AlarmEditor: View {
    @ObservedObject var store: PlanStore
    let target: AlarmEditorTarget
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var moment = Date()
    @State private var offsets: [Int] = [0]
    @State private var pending = false
    @State private var error: String? = nil
    @State private var confirmDelete = false

    private let timeZone = PlanDomain.defaultTimeZone

    private var plan: PlanItem? {
        if case .existing(let plan) = target { return plan }
        return nil
    }

    private var standalone: Bool { plan == nil || plan?.alarmOnly == true }

    var body: some View {
        NavigationStack {
            ZStack {
                DS.Colors.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Metrics.spacing16) {
                        if let error {
                            ErrorBanner(message: error) { self.error = nil }
                        }
                        Card {
                            VStack(alignment: .leading, spacing: DS.Metrics.spacing12) {
                                if standalone {
                                    TextField("Название", text: $title)
                                        .font(.headline)
                                        .foregroundColor(DS.Colors.textPrimary)
                                        .padding(DS.Metrics.spacing8)
                                        .background(DS.Colors.surfaceRaised)
                                        .clipShape(RoundedRectangle(cornerRadius: DS.Metrics.innerRadius))
                                } else {
                                    Text(title)
                                        .font(.headline)
                                        .foregroundColor(DS.Colors.textPrimary)
                                    Text("Время самого плана при этом не меняется.")
                                        .font(.footnote)
                                        .foregroundColor(DS.Colors.textSecondary)
                                }
                                DatePicker("Время сигнала", selection: $moment)
                                    .font(.subheadline)
                                    .foregroundColor(DS.Colors.textPrimary)
                                    .tint(DS.Colors.controlTint)
                                    .environment(\.timeZone, TimeZone(identifier: timeZone) ?? .current)
                                    .environment(\.locale, Locale(identifier: "ru_RU"))
                                ReminderOffsetsPicker(offsets: $offsets)
                            }
                        }
                        PillButton("Сохранить", icon: "checkmark", style: .primary, isLoading: pending) {
                            Task { await save() }
                        }
                        if plan != nil {
                            Button("Удалить будильник", role: .destructive) { confirmDelete = true }
                                .font(.footnote)
                                .foregroundColor(DS.Colors.destructive)
                                .frame(maxWidth: .infinity, minHeight: DS.Metrics.minHitTarget)
                        }
                    }
                    .padding(DS.Metrics.screenGutter)
                }
            }
            .navigationTitle(plan == nil ? "Новый будильник" : "Изменить будильник")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .foregroundColor(DS.Colors.accent)
                        .disabled(pending)
                }
            }
            .confirmationDialog("Удалить будильник?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Удалить будильник", role: .destructive) {
                    Task { await remove() }
                }
                Button("Оставить", role: .cancel) {}
            } message: {
                Text(standalone ? "Отдельный будильник будет удалён." : "Сигналы этого плана будут отключены. Сам план останется.")
            }
        }
        .onAppear(perform: fill)
        .interactiveDismissDisabled(pending)
    }

    private func fill() {
        guard let plan else { return }
        title = plan.title
        let schedule = plan.alarmSchedule ?? plan.googleSchedule
        moment = PlanDateTime.date(
            date: schedule?.date ?? plan.date,
            time: schedule?.time ?? plan.time,
            timeZone: timeZone
        )
        offsets = AlarmRows.offsets(of: plan) ?? []
    }

    private func save() async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if standalone && trimmed.isEmpty {
            error = "Укажи название будильника."
            return
        }
        pending = true
        defer { pending = false }
        let parts = PlanDateTime.parts(moment, timeZone: timeZone)
        let schedule = AlarmSchedulePayload(date: parts.date, time: parts.time, timeZone: timeZone, reminderOffsets: offsets)
        let request = AlarmMutationRequest(
            action: plan == nil ? "create" : "update",
            id: plan?.id,
            title: standalone ? trimmed : nil,
            schedule: schedule
        )
        if let message = await store.mutateAlarm(request) {
            error = message
        } else {
            dismiss()
        }
    }

    private func remove() async {
        guard let plan else { return }
        pending = true
        defer { pending = false }
        if let message = await store.mutateAlarm(AlarmMutationRequest(action: "delete", id: plan.id)) {
            error = message
        } else {
            dismiss()
        }
    }
}
