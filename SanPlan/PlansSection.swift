import Foundation

/// Верхний переключатель раздела «Планы»: планы, привычки и цели — отдельные виды. Фильтр «Сегодня / Неделя / Все» есть только у планов.
/// Выбранная вкладка — удобство устройства: хранится в UserDefaults, не в облаке.
public enum PlansSection: String, CaseIterable, Identifiable, Sendable {
    case plans = "Планы"
    case habits = "Привычки"
    case goals = "Цели"
    public var id: String { rawValue }

    public static let storageKey = "arna.plans.section.v1"

    public static func stored(_ defaults: UserDefaults = .standard) -> PlansSection {
        defaults.string(forKey: storageKey).flatMap(PlansSection.init(rawValue:)) ?? .plans
    }

    public func store(_ defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}
