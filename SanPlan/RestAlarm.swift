import Foundation
import Combine
import SwiftUI
import AlarmKit

public protocol RestAlarmProtocol: AnyObject, Sendable {
    var authorizationState: AlarmManager.AuthorizationState { get }
    func requestAuthorization() async throws
    func schedule(at date: Date, exerciseName: String) async throws
    func cancel() async throws
}

public final class LiveRestAlarmService: RestAlarmProtocol, @unchecked Sendable {
    public static let sharedRestAlarmId = UUID(uuidString: "7B6D7A94-984F-4C82-9B7E-708B48B22360")!

    public init() {}

    public var authorizationState: AlarmManager.AuthorizationState {
        AlarmManager.shared.authorizationState
    }

    public func requestAuthorization() async throws {
        _ = try await AlarmManager.shared.requestAuthorization()
    }

    public func schedule(at date: Date, exerciseName: String) async throws {
        let alertPresentation = AlarmPresentation.Alert(
            title: LocalizedStringResource("Отдых завершён: \(exerciseName)"),
            stopButton: AlarmButton(text: "Остановить", textColor: .white, systemImageName: "stop.circle")
        )
        let metadata = SanPlanAlarmMetadata(
            planId: "sanplan-workout-rest",
            title: "Отдых: \(exerciseName)",
            targetDate: date,
            offsetMinutes: 0
        )
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alertPresentation),
            metadata: metadata,
            tintColor: Color(red: 0.16, green: 0.40, blue: 0.96)
        )
        let configuration = AlarmManager.AlarmConfiguration<SanPlanAlarmMetadata>.alarm(
            schedule: .fixed(date),
            attributes: attributes,
            sound: .default
        )
        try await AlarmManager.shared.schedule(id: Self.sharedRestAlarmId, configuration: configuration)
    }

    public func cancel() async throws {
        try await AlarmManager.shared.cancel(id: Self.sharedRestAlarmId)
    }
}

@MainActor
public final class RestAlarmCoordinator: ObservableObject {
    @Published public private(set) var isAuthorized: Bool = false
    @Published public private(set) var scheduledDate: Date? = nil
    @Published public private(set) var warningMessage: String? = nil

    private let service: RestAlarmProtocol

    public init(service: RestAlarmProtocol = LiveRestAlarmService()) {
        self.service = service
        checkAuthorization()
    }

    public func checkAuthorization() {
        isAuthorized = (service.authorizationState == .authorized)
    }

    public func requestAuthorization() async {
        do {
            try await service.requestAuthorization()
            checkAuthorization()
            if !isAuthorized {
                warningMessage = "В доступе к AlarmKit отказано. При заблокированном телефоне сигнал не прозвучит."
            } else {
                warningMessage = nil
            }
        } catch {
            warningMessage = "Ошибка авторизации сигналов: \(error.localizedDescription)"
        }
    }

    public func schedule(at date: Date, exerciseName: String) async {
        // First rest of a fresh install: ask here, in context, instead of warning about a choice never offered.
        if service.authorizationState == .notDetermined {
            await requestAuthorization()
        }
        checkAuthorization()
        if !isAuthorized {
            warningMessage = "Нет разрешения на будильники: при заблокированном телефоне сигнал отдыха не прозвучит."
            scheduledDate = nil
            return
        }
        do {
            // The id is fixed, so an earlier rest alarm must go before the new one is set.
            try? await service.cancel()
            try await service.schedule(at: date, exerciseName: exerciseName)
            scheduledDate = date
            if isAuthorized {
                warningMessage = nil
            }
        } catch {
            scheduledDate = nil
            warningMessage = "Не удалось запланировать сигнал AlarmKit: \(error.localizedDescription). При блокировке экрана сигнал может не прозвучать."
        }
    }

    public func cancel() async {
        scheduledDate = nil
        do {
            try await service.cancel()
        } catch {
            // Cancel failure should not block workout operations
        }
    }
}
