import SwiftUI
import WebKit

/// Встраивание системного WKWebView из предоставленного root шлюза PlanGateway.
struct PlanWebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView.scrollView.keyboardDismissMode = .interactive
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Управление сессией и навигацией выполняется внутри PlanGateway
    }
}

/// Главный пользовательский интерфейс компаньона SanPlan.
struct ContentView: View {
    @ObservedObject var gateway: PlanGateway
    @ObservedObject var coordinator: AlarmCoordinator
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingReportSheet: Bool = false
    @State private var showingDeleteConfirmation: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Баннер авторизации AlarmKit при необходимости
                if !coordinator.isAuthorized {
                    authorizationHeaderView
                }

                // Информационная панель статуса синхронизации
                statusSummaryBar

                // Веб-интерфейс SanPlan с сохранением клавиатуры и safe area
                PlanWebViewContainer(webView: gateway.webView)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        Image(systemName: "alarm.fill")
                            .foregroundColor(.purple)
                        Text("SanPlan")
                            .font(.headline)
                            .bold()
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await syncFromGateway()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if coordinator.isSyncing {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("Обновить будильники")
                        }
                        .foregroundColor(.teal)
                    }
                    .disabled(coordinator.isSyncing)

                    Menu {
                        Button {
                            Task {
                                await coordinator.scheduleTestAlarmInOneMinute()
                            }
                        } label: {
                            Label("Проверка через минуту", systemImage: "clock.badge.checkmark")
                        }

                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Удалить будильники SanPlan", systemImage: "trash")
                        }

                        if !coordinator.syncWarnings.isEmpty || !coordinator.syncErrors.isEmpty {
                            Button {
                                showingReportSheet = true
                            } label: {
                                Label("Отчет и предупреждения", systemImage: "exclamationmark.triangle")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(.purple)
                    }
                }
            }
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
            .onChange(of: scenePhase) { newPhase in
                // Автообновление на переднем плане только если пользователь ранее согласился и авторизовал
                if newPhase == .active && coordinator.hasUserOptedIn && coordinator.isAuthorized {
                    Task {
                        await syncFromGateway()
                    }
                }
            }
        }
    }

    private var authorizationHeaderView: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge.slash.fill")
                .foregroundColor(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Разрешите системные будильники")
                    .font(.subheadline)
                    .bold()
                Text("Для системного будильника на заблокированном экране.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Разрешить") {
                Task {
                    await coordinator.requestAuthorization()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private var statusSummaryBar: some View {
        VStack(spacing: 4) {
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
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.15))
                    .foregroundColor(.purple)
                    .cornerRadius(4)
            }

            if !coordinator.syncWarnings.isEmpty || !coordinator.syncErrors.isEmpty {
                Button {
                    showingReportSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("Есть предупреждения синхронизации (нажмите для просмотра)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(uiColor: .tertiarySystemGroupedBackground))
    }

    private func syncFromGateway() async {
        do {
            let plans = try await gateway.loadPlans()
            await coordinator.syncAlarms(plans: plans)
        } catch {
            coordinator.reportFetchError(error.localizedDescription)
        }
    }
}

/// Выделенный экран отчета о предупреждениях и ошибках синхронизации.
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
                            .foregroundColor(.purple)
                    }
                    Text("Будильники сохраняются на устройстве независимо от работы приложения. Для обновления расписания откройте приложение и нажмите «Обновить будильники».")
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
                                    .foregroundColor(.teal)
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

