import Foundation

/// DateFormatter is slow to create and these run per row on every redraw, so each pattern/locale/zone is made once.
/// Formatting and parsing with an unchanged formatter is thread-safe.
enum FormatterCache {
    private static let lock = NSLock()
    private static var cache: [String: DateFormatter] = [:]

    static func date(_ format: String, locale: String, timeZone: TimeZone? = nil,
                     gregorian: Bool = false, lenient: Bool? = nil) -> DateFormatter {
        let key = "\(format)|\(locale)|\(timeZone?.identifier ?? "-")|\(gregorian)|\(String(describing: lenient))"
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[key] { return known }
        let f = DateFormatter()
        if gregorian { f.calendar = Calendar(identifier: .gregorian) }
        f.locale = Locale(identifier: locale)
        if let timeZone { f.timeZone = timeZone }
        f.dateFormat = format
        if let lenient { f.isLenient = lenient }
        cache[key] = f
        return f
    }
}
