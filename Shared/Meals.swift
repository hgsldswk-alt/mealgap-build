import Foundation

struct ActiveInterval: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var start: Date
    var zone: String
    var templateID: UUID?
    var targetMinutes: Int?
}

struct IntervalRecord: Codable, Equatable, Identifiable, Sendable {
    var active: ActiveInterval
    var end: Date
    var endZone: String
    var source: String
    var updated: Date
    var id: UUID { active.id }
    var duration: TimeInterval { end.timeIntervalSince(active.start) }
    var range: String {
        let showZone = active.zone != endZone || L.offset(active.start, zone: TimeZone(identifier: active.zone) ?? .current) != L.offset(end, zone: TimeZone(identifier: endZone) ?? .current)
        return L.f("range", L.date(active.start, zone: active.zone, includeZone: showZone), L.date(end, zone: endZone, includeZone: showZone))
    }
}

struct TimingTemplate: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var localName: String?
    var minutes: Int
    var imported: Bool
    var created: Date
    var title: String { localName ?? L.duration(Double(minutes) * 60) }
}

struct MealState: Codable, Equatable, Sendable {
    var active: ActiveInterval?
    var records: [IntervalRecord] = []
    var templates: [TimingTemplate] = []
    var selected: UUID?
    var reminders = false
    var revision = 0
    var milestoneSeen: Set<Int> = []
    var milestonePending: Int?
    var usedDays: Set<String> = []
    var reviewAttempted = false
    var coreReviewProgress: CoreReviewProgress?
    var selectedTemplate: TimingTemplate? { templates.first { $0.id == selected } }
    var sorted: [IntervalRecord] { records.sorted { $0.end > $1.end } }
    var canReview: Bool { active == nil && records.count >= 3 && usedDays.count >= 3 && !reviewAttempted }
    func canCreateTemplate(pro: Bool) -> Bool { pro || !templates.contains { !$0.imported } }
}

enum MealError: LocalizedError, Equatable {
    case storage, future, order, stale, invalidTemplate, duplicate, pro, overlap(IntervalRecord)
    var errorDescription: String? { message }
    var message: String {
        switch self {
        case .storage: return L.t("error.storage")
        case .future: return L.t("error.future")
        case .order: return L.t("error.order")
        case .stale: return L.t("error.stale")
        case .invalidTemplate: return L.t("error.template")
        case .duplicate: return L.t("error.duplicate")
        case .pro: return L.t("error.pro")
        case .overlap(let record): return L.f("error.overlap", record.range)
        }
    }
}

enum MealAction: Sendable {
    case start(Date, UUID?, useDefault: Bool = false), finish(Date, String), discard(UUID)
    case replaceActive(ActiveInterval), complete(IntervalRecord, activeID: UUID?, editing: Bool), delete(UUID)
    case saveTemplate(TimingTemplate, pro: Bool), importTemplate(Int), select(UUID?), deleteTemplate(UUID)
    case reminders(Bool), visit, dismissMilestone, review
}

extension MealState {
    mutating func apply(_ action: MealAction, now: Date, zone: TimeZone) throws {
        let zoneID = zone.identifier
        switch action {
        case .start(let date, let templateID, let useDefault):
            guard active == nil else { return }
            let template = templates.first { $0.id == (useDefault ? selected : templateID) }
            let candidate = ActiveInterval(start: date, zone: zoneID, templateID: template?.id, targetMinutes: template?.minutes)
            try validate(candidate, through: now, now: now)
            active = candidate
        case .finish(let date, let source):
            guard let active else { return }
            try append(IntervalRecord(active: active, end: date, endZone: zoneID, source: source, updated: now), now: now)
            self.active = nil
            var calendar = Calendar.current
            calendar.timeZone = zone
            coreReviewProgress = .recording(coreReviewProgress, at: now, calendar: calendar)
        case .discard(let id):
            guard active?.id == id else { throw MealError.stale }
            active = nil
        case .replaceActive(let candidate):
            guard active?.id == candidate.id else { throw MealError.stale }
            try validate(candidate, through: now, now: now)
            active = candidate
        case .complete(let record, let activeID, let editing):
            if let activeID, active?.id != activeID { throw MealError.stale }
            if editing && !records.contains(where: { $0.id == record.id }) { throw MealError.stale }
            if !editing && activeID == nil && active != nil { throw MealError.stale }
            if editing, let active, record.end > active.start && record.active.start < now { throw MealError.stale }
            try append(record, now: now)
            if activeID != nil { active = nil }
            if !editing {
                var calendar = Calendar.current
                calendar.timeZone = zone
                coreReviewProgress = .recording(coreReviewProgress, at: now, calendar: calendar)
            }
        case .delete(let id):
            records.removeAll { $0.id == id }
            if let count = milestonePending, records.count < count { milestonePending = nil }
        case .saveTemplate(let template, let pro):
            guard (1...10080).contains(template.minutes) else { throw MealError.invalidTemplate }
            if let index = templates.firstIndex(where: { $0.id == template.id }) {
                templates[index] = template
            } else {
                guard !template.imported, canCreateTemplate(pro: pro) else { throw MealError.pro }
                templates.append(template)
            }
        case .importTemplate(let minutes):
            guard (1...10080).contains(minutes) else { throw MealError.invalidTemplate }
            guard !templates.contains(where: { $0.imported && $0.minutes == minutes }) else { throw MealError.duplicate }
            templates.append(TimingTemplate(minutes: minutes, imported: true, created: now))
        case .select(let id):
            guard id == nil || templates.contains(where: { $0.id == id }) else { throw MealError.stale }
            selected = id
        case .deleteTemplate(let id):
            templates.removeAll { $0.id == id }
            if selected == id { selected = nil }
        case .reminders(let enabled): reminders = enabled
        case .visit: usedDays.insert(Self.day(now, zone: zone))
        case .dismissMilestone: milestonePending = nil
        case .review:
            guard canReview else { throw MealError.stale }
            reviewAttempted = true
        }
    }

    private func validate(_ candidate: ActiveInterval, through end: Date, now: Date, excluding id: UUID? = nil) throws {
        guard candidate.start <= now, end <= now else { throw MealError.future }
        if let conflict = records.first(where: { $0.id != id && $0.active.start < end && $0.end > candidate.start }) {
            throw MealError.overlap(conflict)
        }
    }

    private mutating func append(_ record: IntervalRecord, now: Date) throws {
        guard record.end > record.active.start else { throw MealError.order }
        try validate(record.active, through: record.end, now: now, excluding: record.id)
        records.removeAll { $0.id == record.id }
        records.append(record)
        if [7, 30].contains(records.count), milestoneSeen.insert(records.count).inserted {
            milestonePending = records.count
        }
    }

    static func day(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func trend(days: Int, now: Date, zone: TimeZone) -> [TrendPoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let grouped = Dictionary(grouping: records) { record in
            Self.day(record.end, zone: TimeZone(identifier: record.endZone) ?? zone)
        }
        return (0..<days).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let key = Self.day(date, zone: zone)
            guard let items = grouped[key] else { return nil }
            return TrendPoint(day: key, seconds: items.map(\.duration).reduce(0, +) / Double(items.count))
        }
    }

    func csv() -> String {
        let format = ISO8601DateFormatter()
        let rows = sorted.map { record in
            [format.string(from: record.active.start), record.active.zone, format.string(from: record.end), record.endZone, String(Int(record.duration))].joined(separator: ",")
        }
        return (["started_at_utc,start_timezone,ended_at_utc,end_timezone,duration_seconds"] + rows).joined(separator: "\r\n") + "\r\n"
    }
}

struct TrendPoint: Equatable {
    let day: String
    let seconds: TimeInterval
}
