import Foundation

/// Common gym and home exercises, grouped by the main muscle, for picking instead of typing.
public enum ExerciseLibrary {
    public struct Group: Identifiable, Equatable {
        public let id: String
        public let title: String
        public let exercises: [String]
    }

    public static let groups: [Group] = [
        Group(id: "chest", title: "Грудь", exercises: [
            "Жим штанги лёжа", "Жим гантелей лёжа", "Жим на наклонной скамье", "Жим гантелей на наклонной",
            "Разведение гантелей лёжа", "Сведение в кроссовере", "Отжимания", "Отжимания на брусьях", "Жим в тренажёре на грудь"
        ]),
        Group(id: "back", title: "Спина", exercises: [
            "Подтягивания", "Тяга верхнего блока", "Тяга штанги в наклоне", "Тяга гантели в наклоне",
            "Тяга горизонтального блока", "Становая тяга", "Гиперэкстензия", "Тяга Т-грифа", "Пуловер"
        ]),
        Group(id: "legs", title: "Ноги", exercises: [
            "Приседания со штангой", "Приседания", "Фронтальные приседания", "Жим ногами", "Выпады",
            "Болгарские сплит-приседания", "Румынская тяга", "Разгибание ног в тренажёре",
            "Сгибание ног в тренажёре", "Ягодичный мост", "Подъём на носки", "Зашагивания на платформу"
        ]),
        Group(id: "shoulders", title: "Плечи", exercises: [
            "Жим штанги стоя", "Жим гантелей сидя", "Махи гантелями в стороны", "Махи в наклоне",
            "Тяга штанги к подбородку", "Face pull", "Шраги"
        ]),
        Group(id: "arms", title: "Руки", exercises: [
            "Подъём штанги на бицепс", "Подъём гантелей на бицепс", "Молотки", "Концентрированный подъём",
            "Французский жим", "Разгибание на блоке", "Жим узким хватом", "Обратные отжимания от скамьи",
            "Сгибание запястий"
        ]),
        Group(id: "core", title: "Пресс и кор", exercises: [
            "Скручивания", "Подъём ног в висе", "Планка", "Боковая планка", "Русские скручивания",
            "Велосипед", "Ролик для пресса", "Мёртвый жук", "Обратные скручивания"
        ]),
        Group(id: "cardio", title: "Кардио и всё тело", exercises: [
            "Бёрпи", "Прыжки со скакалкой", "Махи гирей", "Трастеры", "Альпинист", "Прыжки на тумбу"
        ]),
    ]

    public static var allExercises: [String] {
        groups.flatMap(\.exercises)
    }

    /// Groups filtered by a search query, case- and ё-insensitive. An empty query returns everything.
    public static func search(_ query: String) -> [Group] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            let hits = group.exercises.filter { normalize($0).contains(needle) }
            return hits.isEmpty ? nil : Group(id: group.id, title: group.title, exercises: hits)
        }
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")
    }
}
