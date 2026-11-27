import Foundation

private final class LocalizationAnchor: NSObject {}

enum L {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, bundle: Bundle(for: LocalizationAnchor.self), comment: "")
    }
    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: args)
    }
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        return minutes >= 60 ? f("duration.full", minutes / 60, minutes % 60) : f("duration.short", minutes)
    }
    static func date(_ date: Date, zone: String, includeZone: Bool = false, timeOnly: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: zone) ?? .current
        formatter.dateStyle = timeOnly ? .none : .medium
        formatter.timeStyle = .short
        let value = formatter.string(from: date)
        return includeZone ? "\(value) (\(zone), \(offset(date, zone: formatter.timeZone)))" : value
    }
    static func offset(_ date: Date, zone: TimeZone) -> String {
        let minutes = zone.secondsFromGMT(for: date) / 60
        return String(format: "UTC%@%02d:%02d", minutes < 0 ? "−" : "+", abs(minutes) / 60, abs(minutes) % 60)
    }
}
