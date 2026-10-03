import SwiftUI
import WebKit

/// Встраивание системного WKWebView из предоставленного root шлюза PlanGateway.
/// Экземпляр WKWebView сохраняется постоянно смонтированным в памяти, предотвращая сброс сессии,
/// потерю черновиков и перезапуск микрофонной записи.
struct PlanWebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView.scrollView.keyboardDismissMode = .interactive
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Перечисление 4 нативных вкладок SanPlan.
enum SanPlanTab: String, CaseIterable {
    case calendar = "calendar"
    case record = "record"
    case alarms = "alarms"
    case settings = "settings"

    var title: String {
        switch self {
        case .calendar: return "Календарь"
        case .record: return "Запись"
        case .alarms: return "Будильники"
        case .settings: return "Настройки"
        }
    }

    var iconName: String {
        switch self {
        case .calendar: return "calendar"
        case .record: return "mic.fill"
        case .alarms: return "alarm.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// Главный пользовательский интерфейс компаньона SanPlan.
struct ContentView: View {
    @ObservedObject var gateway: PlanGateway
    @ObservedObject var coordinator: AlarmCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedTab: SanPlanTab = ProcessInfo.processInfo.arguments.contains("--show-alarms") ? .alarms : .record
    @State private var showingReportSheet: Bool = false
    @State private var showingDeleteConfirmation: Bool = false
    @State private var fetchInProgress = false
    @State private var fetchRequested = false

    // Палитра концепта: глубокий синий акцент, графитовый текст, сдержанные разделители
    private var accentBlue: Color { colorScheme == .dark ? Color(red: 0.50, green: 0.69, blue: 0.99) : Color(red: 0.10, green: 0.28, blue: 0.60) }
    private let inactiveSlate = Color(red: 0.45, green: 0.48, blue: 0.53)
    private let canvasBackground = Color(UIColor.systemGroupedBackground)

    var body: some View {
        VStack(spacing: 0) {
            // Центральная контентная область
            ZStack {
                // ЕДИНСТВЕННЫЙ постоянно смонтированный WKWebView для вкладок calendar / record / settings
                PlanWebViewContainer(webView: gateway.webView)
                    .opacity(selectedTab == .alarms ? 0 : 1)
                    .allowsHitTesting(selectedTab != .alarms)
                    .accessibilityHidden(selectedTab == .alarms)
                    .ignoresSafeArea(.keyboard, edges: .bottom)

                // Изолированный нативный экран будильников
                if selectedTab == .alarms {
                    AlarmsScreenView(
                        coordinator: coordinator,
                        isLoading: gateway.isLoadingPlans,
                        onRefresh: { await syncFromGateway() },
                        onShowReport: { showingReportSheet = true },
                        onConfirmDelete: { showingDeleteConfirmation = true }
                    )
                    .background(canvasBackground)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Единый нативный нижний док с 4 равноправными вкладками
            nativeBottomDock
        }
        .background(canvasBackground)
        .preferredColorScheme(gateway.themePreference == "dark" ? .dark : gateway.themePreference == "light" ? .light : nil)
        .confirmationDialog(
            "Удалить только будильники SanPlan?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Удалить будильники SanPlan", role: .destructive) {
                Task {
                    await coordinator.deleteAllOwnAlarms()
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Будут отменены только будильники, созданные приложением SanPlan. Личные будильники устройства затронуты не будут.")
        }
        .sheet(isPresented: $showingReportSheet) {
            WarningsReportSheet(
                warnings: coordinator.syncWarnings,
                errors: coordinator.syncErrors,
                activeCount: coordinator.activeAlarmCount
            )
        }
        .onAppear {
            setupBridgeCallbacks()
            if coordinator.hasUserOptedIn && coordinator.isAuthorized {
                Task { await syncFromGateway() }
            } else {
                Task { await coordinator.reconcileWithSystem() }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                Task {
                    if coordinator.hasUserOptedIn && coordinator.isAuthorized {
                        await syncFromGateway()
                    } else {
                        await coordinator.reconcileWithSystem()
                    }
                }
            }
        }
        .onChange(of: coordinator.isAuthorized) { authorized in
            if authorized && coordinator.hasUserOptedIn {
                Task { await syncFromGateway() }
            }
        }
    }

    private var nativeBottomDock: some View {
        HStack(spacing: 0) {
            ForEach(SanPlanTab.allCases, id: \.self) { tab in
                Button {
                    handleTabSelection(tab)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 20, weight: selectedTab == tab ? .semibold : .regular))
                        Text(tab.title)
                            .font(.system(size: 11, weight: selectedTab == tab ? .medium : .regular))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                    .foregroundColor(selectedTab == tab ? accentBlue : inactiveSlate)
                }
                .accessibilityLabel(Text(tab.title))
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .overlay(Divider(), alignment: .top)
    }

    private func handleTabSelection(_ tab: SanPlanTab) {
        selectedTab = tab
        if tab == .alarms {
            Task {
                if coordinator.hasUserOptedIn && coordinator.isAuthorized {
                    await syncFromGateway()
                } else {
                    await coordinator.reconcileWithSystem()
                }
            }
        } else {
            gateway.navigate(to: tab.rawValue)
        }
    }

    private func setupBridgeCallbacks() {
        gateway.onPlansChanged = { Task { await syncFromGateway() } }

        gateway.onAlarmTabRequested = {
            selectedTab = .alarms
            Task {
                if coordinator.hasUserOptedIn && coordinator.isAuthorized {
                    await syncFromGateway()
                } else {
                    await coordinator.reconcileWithSystem()
                }
            }
        }
    }

    private func syncFromGateway() async {
        guard !fetchInProgress else { fetchRequested = true; return }
        fetchInProgress = true
        defer { fetchInProgress = false }
        repeat {
            fetchRequested = false
            await coordinator.reconcileWithSystem()
            do {
                let plans = try await gateway.loadPlans()
                await coordinator.syncAlarms(plans: plans)
            } catch {
                coordinator.reportFetchError(error.localizedDescription)
            }
        } while fetchRequested
    }
}

/// Выделенный нативный экран будильников с визуальной иерархией концепта.
struct AlarmsScreenView: View {
    @ObservedObject var coordinator: AlarmCoordinator
    @Environment(\.colorScheme) private var colorScheme
    let isLoading: Bool
    let onRefresh: () async -> Void
    let onShowReport: () -> Void
    let onConfirmDelete: () -> Void

    @State private var isDiagnosticsExpanded: Bool = false

    private var accentBlue: Color { colorScheme == .dark ? Color(red: 0.50, green: 0.69, blue: 0.99) : Color(red: 0.10, green: 0.28, blue: 0.60) }
    private let cardBackground = Color(UIColor.secondarySystemGroupedBackground)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Баннер авторизации AlarmKit при необходимости
                    if !coordinator.isAuthorized {
                        authorizationCard
                    }

                    // Информационная панель статуса синхронизации
                    syncStatusSummaryCard

                    // Выделенный блок ближайшего сигнала (Next-Signal Prominent)
                    if let nextAlarm = coordinator.activeRecords.first {
                        nextSignalCard(record: nextAlarm)
                    }

                    // Основной список активных будильников, сгруппированных по планам
                    if !coordinator.activeRecords.isEmpty {
                        activeAlarmsGroupedSection
                    } else {
                        emptyStateCard
                    }

                    // Диагностика и проверка через 1 минуту только под свернутой плашкой
                    diagnosticsSection

                    // Кнопка удаления только собственных будильников SanPlan
                    if coordinator.activeAlarmCount > 0 {
                        Button(role: .destructive) {
                            onConfirmDelete()
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Удалить будильники SanPlan")
                            }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .refreshable {
                await onRefresh()
            }
            .navigationTitle("Будильники")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 6) {
                        Text("SanPlan")
                            .font(.subheadline)
                            .bold()
                            .foregroundColor(accentBlue)
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task { await onRefresh() }
                    } label: {
                        HStack(spacing: 4) {
                            if coordinator.isSyncing || isLoading {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundColor(accentBlue)
                    }
                    .disabled(coordinator.isSyncing || isLoading)

                    Menu {
                        if !coordinator.syncWarnings.isEmpty || !coordinator.syncErrors.isEmpty {
                            Button {
                                onShowReport()
                            } label: {
                                Label("Отчет синхронизации", systemImage: "exclamationmark.triangle")
                            }
                        }

                        Button(role: .destructive) {
                            onConfirmDelete()
                        } label: {
                            Label("Удалить будильники SanPlan", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(minWidth: 44, minHeight: 44)
                            .foregroundColor(accentBlue)
                    }
                }
            }
        }
    }

    private var authorizationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.slash.fill")
                    .foregroundColor(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Разрешите системные будильники")
                        .font(.headline)
                    Text("SanPlan использует официальный Apple AlarmKit для звонка на заблокированном экране.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Button {
                Task { await coordinator.requestAuthorization() }
            } label: {
                Text("Разрешить доступ")
                    .font(.subheadline)
                    .bold()
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(accentBlue)
        }
        .padding(14)
        .background(cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private var syncStatusSummaryCard: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(coordinator.isAuthorized ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)

                    Text(coordinator.statusMessage)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }

                Spacer()

                if let syncDate = coordinator.lastSyncDate {
                    Text("Синхр: \(syncDate.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Text("Активно: \(coordinator.activeAlarmCount)")
                    .font(.caption2)
                    .bold()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(accentBlue.opacity(0.12))
                    .foregroundColor(accentBlue)
                    .cornerRadius(6)
            }

            if !coordinator.syncWarnings.isEmpty || !coordinator.syncErrors.isEmpty {
                Button {
                    onShowReport()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Есть замечания синхронизации (открыть отчет)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
        }
        .padding(12)
        .background(cardBackground)
        .cornerRadius(10)
    }

    private func nextSignalCard(record: RegisteredAlarmRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("БЛИЖАЙШИЙ СИГНАЛ")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(accentBlue)
                Spacer()
                Image(systemName: "alarm.waves.left.and.right.fill")
                    .foregroundColor(accentBlue)
            }

            Text(record.title)
                .font(.title3)
                .bold()
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(formatClock(record.fireDate, timeZoneId: record.timeZone))
                .font(.largeTitle.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(accentBlue)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Срабатывание")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(formatDateTime(record.fireDate, timeZoneId: record.timeZone))
                        .font(.subheadline)
                        .bold()
                        .foregroundColor(.primary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 2) {
                    Text("Событие")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(formatDateTime(record.resolvedEventDate, timeZoneId: record.timeZone))
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }

                Spacer()

                Text(formatOffsetBadge(record.offsetMinutes))
                    .font(.caption)
                    .bold()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(accentBlue.opacity(0.15))
                    .foregroundColor(accentBlue)
                    .cornerRadius(6)
            }

            if let tz = record.timeZone, !tz.isEmpty {
                Text("Часовой пояс: \(tz)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(cardBackground)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accentBlue.opacity(0.25), lineWidth: 1)
        )
    }

    private var activeAlarmsGroupedSection: some View {
        let grouped = Dictionary(grouping: coordinator.activeRecords, by: { $0.planId })
        let sortedPlanIDs = grouped.keys.sorted {
            (grouped[$0]?.first?.fireDate ?? .distantFuture) < (grouped[$1]?.first?.fireDate ?? .distantFuture)
        }

        return VStack(alignment: .leading, spacing: 12) {
            Text("Расписание системных сигналов")
                .font(.headline)
                .padding(.horizontal, 4)

            ForEach(sortedPlanIDs, id: \.self) { planID in
                if let alarms = grouped[planID] {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(alarms.first?.title ?? "Будильник")
                                .font(.subheadline)
                                .bold()
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Text("Сигналов: \(alarms.count)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Divider()

                        ForEach(alarms) { alarm in
                            HStack {
                                Image(systemName: "alarm")
                                    .foregroundColor(accentBlue)
                                    .font(.subheadline)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(formatDateTime(alarm.fireDate, timeZoneId: alarm.timeZone))
                                        .font(.subheadline)
                                        .bold()
                                    Text("Событие: \(formatDateTime(alarm.resolvedEventDate, timeZoneId: alarm.timeZone))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(coordinator.systemStateConfirmed ? "Установлен" : "Сохранён · требуется проверка системы")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Text(formatOffsetBadge(alarm.offsetMinutes))
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color(UIColor.tertiarySystemGroupedBackground))
                                    .cornerRadius(4)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(12)
                    .background(cardBackground)
                    .cornerRadius(10)
                }
            }
        }
    }

    private var emptyStateCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "alarm")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
                .padding(.top, 12)

            Text("Нет запланированных будильников")
                .font(.headline)
                .foregroundColor(.primary)

            Text("Будильники создаются автоматически на основе задач и событий с напоминаниями. Добавьте задачу в календаре или проверьте время.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            Button {
                Task { await onRefresh() }
            } label: {
                Text("Обновить расписание")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(accentBlue)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .cornerRadius(12)
    }

    private var diagnosticsSection: some View {
        DisclosureGroup("Диагностика AlarmKit", isExpanded: $isDiagnosticsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Тестовый будильник на 1 минуту вперед для проверки звонка на заблокированном экране без симуляции:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    Task { await coordinator.scheduleTestAlarmInOneMinute() }
                } label: {
                    HStack {
                        Image(systemName: "clock.badge.checkmark")
                        Text("Проверка через 1 минуту")
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(accentBlue)
                .disabled(coordinator.isSyncing || isLoading)

                Text("Проверка прозвучит и после закрытия приложения. Личные будильники iPhone эта функция не меняет.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)
        }
        .padding(12)
        .background(cardBackground)
        .cornerRadius(10)
    }

    private func formatDateTime(_ date: Date, timeZoneId: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        if let tzId = timeZoneId, let tz = TimeZone(identifier: tzId) {
            formatter.timeZone = tz
        } else {
            formatter.timeZone = .current
        }
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: date)
    }

    private func formatClock(_ date: Date, timeZoneId: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = timeZoneId.flatMap { TimeZone(identifier: $0) } ?? .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func formatOffsetBadge(_ minutes: Int) -> String {
        if minutes == 0 {
            return "в момент события"
        } else if minutes == 60 {
            return "за 1 час"
        } else if minutes == 1440 {
            return "за 1 день"
        } else if minutes % 1440 == 0 {
            return "за \(minutes / 1440) дн."
        } else if minutes % 60 == 0 {
            return "за \(minutes / 60) ч."
        } else {
            return "за \(minutes) мин."
        }
    }
}

/// Экран отчета о предупреждениях и ошибках синхронизации.
struct WarningsReportSheet: View {
    let warnings: [String]
    let errors: [String]
    let activeCount: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Сводка")) {
                    HStack {
                        Text("Активных будильников SanPlan")
                        Spacer()
                        Text("\(activeCount)")
                            .bold()
                            .foregroundColor(Color(red: 0.10, green: 0.28, blue: 0.60))
                    }
                    Text("Будильники сохраняются в системе iOS 26 независимо от работы приложения. Для обновления расписания нажмите кнопку обновления.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !errors.isEmpty {
                    Section(header: Text("Ошибки синхронизации")) {
                        ForEach(errors, id: \.self) { error in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                                Text(error)
                                    .font(.subheadline)
                            }
                        }
                    }
                }

                if !warnings.isEmpty {
                    Section(header: Text("Предупреждения и политика ограничений")) {
                        ForEach(warnings, id: \.self) { warning in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundColor(.blue)
                                Text(warning)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Отчет SanPlan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Закрыть") {
                        dismiss()
                    }
                }
            }
        }
    }
}
