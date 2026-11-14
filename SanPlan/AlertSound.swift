import Foundation

// Звук сигнала (конец отдыха, напоминания планов): чистая логика выбора, хранения и отката на системный тон.
// Экран выбора — AlertSoundPicker.swift, синхронизация — AlertSoundSettings.swift.
//
// Ограничения AlarmKit (форум Apple Developer, не документация): файл лежит в бандле приложения или в Library/Sounds,
// короче 30 секунд, играет один раз без повтора. Системный тон звонит, пока сигнал не остановят.

public enum AlertSoundChoice: Equatable, Sendable {
    /// Системный тон AlarmKit: звонит, пока не остановите.
    case system
    /// Наш тон из бандла: имя файла вместе с расширением.
    case builtin(String)
    /// Свой файл из Library/Sounds: имя файла вместе с расширением.
    case custom(String)

    public static let maxSeconds: Double = 30
    /// При импорте длиннее обрезается до этого.
    public static let importSeconds: Double = 29

    /// Значение в общих настройках: «system», «builtin:<файл>» или «custom:<файл>». Пустое и незнакомое — системный.
    public init(stored: String?) {
        guard let stored else { self = .system; return }
        if stored.hasPrefix("builtin:"), stored.count > 8 { self = .builtin(String(stored.dropFirst(8))) }
        else if stored.hasPrefix("custom:"), stored.count > 7 { self = .custom(String(stored.dropFirst(7))) }
        else { self = .system }
    }

    public var stored: String {
        switch self {
        case .system: return "system"
        case .builtin(let name): return "builtin:\(name)"
        case .custom(let name): return "custom:\(name)"
        }
    }

    /// Выбор, который можно проиграть сейчас: если файл пропал (другое устройство, удалён, не вошёл в сборку), остаётся системный тон.
    public func resolved(builtinExists: (String) -> Bool, customExists: (String) -> Bool) -> AlertSoundChoice {
        switch self {
        case .system: return .system
        case .builtin(let name): return builtinExists(name) ? self : .system
        case .custom(let name): return customExists(name) ? self : .system
        }
    }

    /// Имя файла для `AlertSound.named`; `nil` — системный тон.
    public var fileName: String? {
        switch self {
        case .system: return nil
        case .builtin(let name), .custom(let name): return name
        }
    }
}

/// Что делать с настройкой, когда она есть и на устройстве, и в аккаунте: побеждает более свежая.
public enum AlertSoundSync {
    public enum Action: Equatable {
        case none
        case apply(String)
        case push
    }

    /// `remoteStored == nil` — записи нет или в ней нет этого поля (например, её создал веб ради `restSound`).
    public static func decide(localStored: String, localAt: Int64, remoteStored: String?, remoteAt: Int64) -> Action {
        guard let remoteStored else { return localStored == "system" ? .none : .push }
        if localStored == remoteStored { return .none }
        return remoteAt > localAt ? .apply(remoteStored) : .push
    }
}

/// Громкость сигнала: AlarmKit не меняет её при воспроизведении, поэтому ступень выбирает файл
/// (`имя.m4a` для 100 %, `имя-v60.m4a`, `-v35`, `-v20`). Нет варианта — играет полный файл.
public enum AlertSoundVolume {
    public static let steps: [Int] = [100, 60, 35, 20]

    /// Приводит значение к ближайшей ступени; пусто и 0 — полная громкость.
    public static func normalized(_ percent: Int?) -> Int {
        guard let percent, percent > 0 else { return 100 }
        return steps.min { abs($0 - percent) < abs($1 - percent) } ?? 100
    }

    /// Суффикс `-vNN` встроенных и своих вариантов.
    public static func suffix(_ percent: Int) -> String { percent >= 100 ? "" : "-v\(percent)" }

    /// Имена файлов по убыванию предпочтения: вариант ступени (то же расширение, затем m4a — так сохраняет экспорт), затем полный файл.
    public static func candidates(base: String, percent: Int) -> [String] {
        let percent = normalized(percent)
        let url = URL(fileURLWithPath: base)
        let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        guard percent < 100 else { return [base] }
        let same = "\(stem)\(suffix(percent)).\(ext)", m4a = "\(stem)\(suffix(percent)).m4a"
        return (same == m4a ? [same] : [same, m4a]) + [base]
    }

    /// Первый существующий файл из `candidates`; `nil` — ни одного нет.
    public static func fileName(base: String, percent: Int, exists: (String) -> Bool) -> String? {
        candidates(base: base, percent: percent).first(where: exists)
    }

    /// Это вариант громкости (`…-v60.m4a`), а не отдельный тон.
    public static func isVariant(_ fileName: String) -> Bool {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        return steps.contains { $0 < 100 && stem.hasSuffix("-v\($0)") }
    }

    public static func decide(localPercent: Int, localAt: Int64, remotePercent: Int?, remoteAt: Int64) -> AlertSoundSync.Action {
        guard let remotePercent else { return localPercent == 100 ? .none : .push }
        let remote = normalized(remotePercent)
        if remote == localPercent { return .none }
        return remoteAt > localAt ? .apply(String(remote)) : .push
    }
}

public enum AlertSoundImport {
    public enum Plan: Equatable {
        case copy
        case trim
    }

    public static let allowedExtensions: Set<String> = ["mp3", "m4a", "wav", "caf", "aac", "aif", "aiff"]

    public static func plan(duration: Double) -> Plan {
        duration > AlertSoundChoice.maxSeconds ? .trim : .copy
    }

    /// Имя копии в Library/Sounds. Обрезанный файл всегда m4a.
    public static func storedName(id: String, original: String, plan: Plan) -> String {
        let ext = plan == .trim ? "m4a" : (URL(fileURLWithPath: original).pathExtension.lowercased())
        return "custom-\(id).\(ext.isEmpty ? "m4a" : ext)"
    }

    public static func isSupported(_ fileName: String) -> Bool {
        allowedExtensions.contains(URL(fileURLWithPath: fileName).pathExtension.lowercased())
    }
}

public enum AlertSoundLibrary {
    /// Встроенные тоны — файлы с таким началом имени в корне бандла: `arna-tone-01-pulse.caf`.
    public static let builtinPrefix = "arna-tone-"
    public static let builtinExtensions: Set<String> = ["caf", "wav", "m4a", "mp3"]

    /// Имена встроенных тонов по порядку (из списка имён файлов бандла).
    public static func builtinNames(in fileNames: [String]) -> [String] {
        fileNames
            .filter { $0.hasPrefix(builtinPrefix) && builtinExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) && !AlertSoundVolume.isVariant($0) }
            .sorted()
    }

    /// Русские названия наших тонов (по части имени после номера).
    static let russianTitles = ["kalimba": "Калимба", "piano": "Фортепиано", "savepoint": "Точка сохранения"]

    /// «arna-tone-02-morning-bell.caf» → «Morning bell»; без имени после номера — «Тон 2».
    public static func title(forBuiltin fileName: String) -> String {
        var body = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        body = String(body.dropFirst(builtinPrefix.count))
        var digits = ""
        while let first = body.first, first.isNumber { digits.append(first); body.removeFirst() }
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: "-_ ")).replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        if let russian = russianTitles[body.lowercased()] { return russian }
        guard let first = body.first else { return "Тон \(Int(digits) ?? 1)" }
        return first.uppercased() + body.dropFirst()
    }

    public static func builtinNames(bundle: Bundle = .main) -> [String] {
        let all = builtinExtensions.flatMap { bundle.paths(forResourcesOfType: $0, inDirectory: nil) }
        return builtinNames(in: all.map { ($0 as NSString).lastPathComponent })
    }

    public static func builtinURL(_ name: String, bundle: Bundle = .main) -> URL? {
        let url = URL(fileURLWithPath: name)
        return bundle.url(forResource: url.deletingPathExtension().lastPathComponent, withExtension: url.pathExtension)
    }

    /// Каталог, откуда AlarmKit берёт свои файлы: Library/Sounds контейнера.
    public static func customDirectory(fileManager: FileManager = .default) -> URL {
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Sounds", isDirectory: true)
    }

    public static func customURL(_ name: String) -> URL { customDirectory().appendingPathComponent(name) }

    /// Файл, который надо отдать AlarmKit при выбранной ступени; `nil` — системный тон (файла нет совсем).
    public static func playableName(_ choice: AlertSoundChoice, percent: Int) -> String? {
        switch choice {
        case .system: return nil
        case .builtin(let name): return AlertSoundVolume.fileName(base: name, percent: percent) { builtinURL($0) != nil }
        case .custom(let name): return AlertSoundVolume.fileName(base: name, percent: percent) { FileManager.default.fileExists(atPath: customURL($0).path) }
        }
    }

    public static func choiceIsPlayable(_ choice: AlertSoundChoice) -> AlertSoundChoice {
        choice.resolved(
            builtinExists: { builtinURL($0) != nil },
            customExists: { FileManager.default.fileExists(atPath: customURL($0).path) }
        )
    }
}
