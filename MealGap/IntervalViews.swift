import Charts
import SwiftUI

struct IntervalEditor: View {
    enum Mode: String, CaseIterable { case start, complete, adjust, finish, edit }
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let original: ActiveInterval?
    let record: IntervalRecord?
    @State private var mode: Mode
    @State private var start: Date
    @State private var end: Date
    @State private var templateID: UUID?
    @State private var fault: String?
    @State private var confirmDiscard = false
    @State private var confirmDelete = false

    init(model: AppModel, active: ActiveInterval? = nil, record: IntervalRecord? = nil) {
        self.model = model
        original = active
        self.record = record
        _mode = State(initialValue: record != nil ? .edit : active != nil ? .adjust : .start)
        _start = State(initialValue: record?.active.start ?? active?.start ?? Self.testDate("MEAL_GAP_TEST_START") ?? Launch.now().addingTimeInterval(-3600))
        _end = State(initialValue: record?.end ?? Self.testDate("MEAL_GAP_TEST_END") ?? Launch.now())
        _templateID = State(initialValue: active?.templateID ?? (active == nil ? model.state.selected : nil))
    }

    private var startZone: TimeZone {
        TimeZone(identifier: record?.active.zone ?? original?.zone ?? Self.localZone.identifier) ?? .current
    }
    private var endZone: TimeZone { TimeZone(identifier: record?.endZone ?? Self.localZone.identifier) ?? .current }

    private static var localZone: TimeZone {
        if Launch.testing, let id = ProcessInfo.processInfo.environment["MEAL_GAP_TEST_ZONE"], let zone = TimeZone(identifier: id) { return zone }
        return .current
    }

    private static func testDate(_ key: String) -> Date? {
        guard Launch.testing, let date = ProcessInfo.processInfo.environment[key] else { return nil }
        return ISO8601DateFormatter().date(from: date)
    }

    var body: some View {
        Form {
            if record == nil {
                Section(L.t("editor.mode")) {
                    ForEach(original == nil ? [Mode.start, .complete] : [.adjust, .finish], id: \.self) { option in
                        Button {
                            mode = option
                            fault = nil
                        } label: {
                            HStack {
                                Text(L.t("editor.\(option.rawValue)"))
                                Spacer()
                                if mode == option { Image(systemName: "checkmark").accessibilityHidden(true) }
                            }.contentShape(Rectangle())
                        }
                        .accessibilityAddTraits(mode == option ? .isSelected : [])
                        .accessibilityIdentifier("editor.mode.\(option.rawValue)")
                    }
                }
            }
            if mode != .finish { ZonedPicker(key: "editor.startDate", id: "editor.startDate", date: $start, zone: startZone) }
            if [.complete, .finish, .edit].contains(mode) { ZonedPicker(key: "editor.endDate", id: "editor.endDate", date: $end, zone: endZone) }
            if mode == .start || mode == .adjust {
                Picker(L.t("templates.title"), selection: $templateID) {
                    Text(L.t("templates.noTemplate")).tag(nil as UUID?)
                    if let id = original?.templateID, !model.state.templates.contains(where: { $0.id == id }) {
                        Text(L.t("templates.previous")).tag(Optional(id))
                    }
                    ForEach(model.state.templates) { template in Text(template.title).tag(Optional(template.id)) }
                }.accessibilityIdentifier("editor.template")
            }
            if let fault { Text(fault).foregroundStyle(Design.accent).accessibilityIdentifier("editor.error") }
            Button(L.t("common.save")) { save() }.accessibilityIdentifier("editor.save").disabled(model.busy)
            if original != nil {
                Button(L.t("editor.discard"), role: .destructive) { confirmDiscard = true }.accessibilityIdentifier("editor.discard")
            }
            if record != nil {
                Button(L.t("common.delete"), role: .destructive) { confirmDelete = true }.accessibilityIdentifier("editor.delete")
            }
        }
        .navigationTitle(L.t(record != nil ? "editor.edit" : original != nil ? "home.adjust" : "home.backfill"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("common.close")) { dismiss() }.accessibilityIdentifier("editor.close")
            }
        }
        .alert(L.t("editor.discard"), isPresented: $confirmDiscard) {
            Button(L.t("common.cancel"), role: .cancel) {}
            Button(L.t("editor.discard"), role: .destructive) { if let original { run(.discard(original.id)) } }
        }
        .alert(L.t("editor.deleteQuestion"), isPresented: $confirmDelete) {
            Button(L.t("common.cancel"), role: .cancel) {}
            Button(L.t("common.delete"), role: .destructive) { if let record { run(.delete(record.id)) } }
        }
    }

    private func save() {
        let template = model.state.templates.first { $0.id == templateID }
        var active = original ?? record?.active ?? ActiveInterval(start: start, zone: startZone.identifier)
        if mode != .finish { active.start = start }
        if mode == .adjust, active.templateID != templateID { active.templateID = template?.id; active.targetMinutes = template?.minutes }
        switch mode {
        case .start: run(.start(start, templateID))
        case .adjust: run(.replaceActive(active))
        case .complete, .finish, .edit:
            let value = IntervalRecord(active: active, end: end, endZone: endZone.identifier, source: record?.source ?? "manual", updated: Launch.now())
            run(.complete(value, activeID: original?.id, editing: record != nil))
        }
    }

    private func run(_ action: MealAction) {
        Task {
            do { try await model.change(action); dismiss() }
            catch { fault = message(error) }
        }
    }
}

struct ZonedPicker: View {
    let key: String
    let id: String
    @Binding var date: Date
    let zone: TimeZone

    var body: some View {
        DatePicker(L.t(key), selection: $date, in: ...Launch.now(), displayedComponents: [.date, .hourAndMinute])
            .environment(\.timeZone, zone).accessibilityIdentifier(id)
        let alternatives = repeatedTimes
        if alternatives.count > 1 {
            Picker(L.t("editor.offset"), selection: Binding(get: {
                zone.secondsFromGMT(for: date)
            }, set: { offset in
                if let choice = alternatives.first(where: { zone.secondsFromGMT(for: $0) == offset }) { date = choice }
            })) {
                ForEach(alternatives, id: \.self) { choice in
                    Text(L.offset(choice, zone: zone)).tag(zone.secondsFromGMT(for: choice))
                }
            }
        } else {
            Text("\(zone.identifier) · \(L.offset(date, zone: zone))").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var repeatedTimes: [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let reference = calendar.startOfDay(for: date).addingTimeInterval(-1)
        let alternatives = [Calendar.RepeatedTimePolicy.first, .last].compactMap {
            calendar.nextDate(after: reference, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: $0)
        }.filter { calendar.isDate($0, inSameDayAs: date) && $0 <= Launch.now() }
        return Array(Set(alternatives)).sorted()
    }
}

struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    @State private var share: ShareRequest?
    @State private var requested = false
    @State private var preparing = false
    @State private var trend = false
    @State private var fault: String?

    var body: some View {
        List {
            Section {
                Button(L.t("history.csv")) { export(image: false) }.accessibilityIdentifier("history.csv").disabled(preparing)
                Button(L.t("history.image")) {
                    if model.hasPro { export(image: true) } else { model.paywall = true }
                }.accessibilityIdentifier("history.image").disabled(preparing)
                Button(L.t("history.trend")) {
                    if model.hasPro { trend = true } else { model.paywall = true }
                }.accessibilityIdentifier("history.trend")
                if requested { Text(L.t("share.requested")).accessibilityIdentifier("share.requested") }
                if let fault { Text(fault).foregroundStyle(Design.accent) }
            }
            Section {
                if model.state.records.isEmpty { Text(L.t("history.empty")).foregroundStyle(.secondary) }
                ForEach(model.state.sorted) { record in
                    NavigationLink {
                        IntervalEditor(model: model, record: record)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L.duration(record.duration)).font(.headline.monospacedDigit())
                            Text(record.range).font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }.accessibilityIdentifier("history.record")
                }
            }
        }
        .navigationTitle(L.t("history.title"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L.t("common.close")) { dismiss() }.accessibilityIdentifier("history.close") } }
        .sheet(isPresented: $trend) { NavigationStack { TrendView(state: model.state) } }
        .sheet(item: $share, onDismiss: { share = nil }) { item in
            ActivitySheet(request: item) { success in model.recordShare(success); share = nil }
        }
    }

    private func export(image: Bool) {
        preparing = true
        requested = false
        fault = nil
        let snapshot = model.state
        Task {
            defer { preparing = false }
            do {
                let files = try await Task.detached {
                    if image { return try ShareArt.history(snapshot.sorted) }
                    return [try ShareRequest.file(Data(snapshot.csv().utf8), named: "MealGap.csv")]
                }.value
                if Launch.testing {
                    requested = true
                    ShareRequest.cleanup(files)
                } else { share = ShareRequest(items: files, files: files) }
            } catch { fault = message(error) }
        }
    }
}

struct TrendView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var days = 7
    let state: MealState

    var body: some View {
        let now = Launch.now()
        let points = state.trend(days: days, now: now, zone: .current)
        let recent = state.trend(days: 7, now: now, zone: .current)
        let thirty = state.trend(days: 30, now: now, zone: .current)
        List {
            Picker(L.t("history.trend"), selection: $days) {
                Text(L.t("trend.7")).tag(7)
                Text(L.t("trend.30")).tag(30)
            }.pickerStyle(.segmented).accessibilityIdentifier("trend.days")
            if points.isEmpty { Text(L.t("history.empty")) }
            else {
                Chart(points, id: \.day) { point in
                    BarMark(x: .value(L.t("trend.date"), point.day), y: .value(L.t("trend.hours"), point.seconds / 3600))
                        .foregroundStyle(Design.accent)
                        .accessibilityLabel(Text(point.day)).accessibilityValue(Text(L.duration(point.seconds)))
                }.chartXAxis(.hidden).frame(height: 200).accessibilityIdentifier("trend.chart")
                LabeledContent(L.t("trend.weekMean"), value: mean(recent))
                LabeledContent(L.t("trend.monthMean"), value: mean(thirty))
            }
        }
        .navigationTitle(L.t("history.trend"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L.t("common.close")) { dismiss() }.accessibilityIdentifier("trend.close") } }
    }

    private func mean(_ points: [TrendPoint]) -> String {
        points.isEmpty ? "—" : L.duration(points.map(\.seconds).reduce(0, +) / Double(points.count))
    }
}
