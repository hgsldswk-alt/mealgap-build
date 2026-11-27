import Foundation

enum Launch {
    static let freePeriod = false
    static let arguments = ProcessInfo.processInfo.arguments
    static let testing = arguments.contains("-ui-testing")
    static var isFree: Bool { isFree(arguments: arguments) }
    static func isFree(arguments: [String]) -> Bool {
        freePeriod && !arguments.contains(where: ["-paid-mode", "-paywall", "-expired"].contains)
    }
    static let now: @Sendable () -> Date = {
        if testing, arguments.contains("-fixtures") {
            return ISO8601DateFormatter().date(from: "2026-11-20T12:34:00Z") ?? Date()
        }
        return Date()
    }
}
