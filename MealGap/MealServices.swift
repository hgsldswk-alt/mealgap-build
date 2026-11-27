import ActivityKit
import Foundation
import AppIntents
import UserNotifications

actor MealServices {
    static let shared = MealServices()
    private static let reminderID = "meal-gap-target"
    private var running = false
    private var requested = false
    private var mayStart = false

    func sync(canStartActivity: Bool) async {
        guard !Launch.testing else { return }
        requested = true
        mayStart = mayStart || canStartActivity
        guard !running else { return }
        running = true
        while requested {
            requested = false
            let startAllowed = mayStart
            mayStart = false
            guard let state = try? await MealStore.shared.snapshot() else { continue }
            await updateActivities(state.active, canStart: startAllowed)
            await updateReminder(state)
        }
        running = false
    }

    private func updateActivities(_ active: ActiveInterval?, canStart: Bool) async {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        let now = Date()
        let eligible = active.flatMap { now >= $0.start && now.timeIntervalSince($0.start) < 8 * 3600 && enabled ? $0 : nil }
        var existing = false
        for activity in Activity<MealActivity>.activities {
            if let eligible, activity.attributes.intervalID == eligible.id, !existing,
               activity.activityState != .ended, activity.activityState != .dismissed {
                existing = true
                let next = MealActivity.ContentState(start: eligible.start, zone: eligible.zone)
                if activity.content.state != next {
                    await activity.update(ActivityContent(state: next, staleDate: eligible.start.addingTimeInterval(8 * 3600)))
                }
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        if let eligible, !existing, canStart {
            let content = ActivityContent(state: MealActivity.ContentState(start: eligible.start, zone: eligible.zone), staleDate: eligible.start.addingTimeInterval(8 * 3600))
            _ = try? Activity.request(attributes: MealActivity(intervalID: eligible.id), content: content, pushType: nil)
        }
    }

    private func updateReminder(_ state: MealState) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
        guard state.reminders, let active = state.active, let minutes = active.targetMinutes else { return }
        let remaining = active.start.addingTimeInterval(Double(minutes) * 60).timeIntervalSinceNow
        guard remaining > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = L.t("app.title")
        content.body = L.t("reminder.body")
        content.sound = .default
        content.userInfo = ["intervalID": active.id.uuidString]
        try? await center.add(UNNotificationRequest(identifier: Self.reminderID, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, remaining), repeats: false)))
    }
}

struct StartMealIntent: AppIntent {
    static let title: LocalizedStringResource = "home.start"
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let now = Date()
        let (_, change) = try await MealStore.shared.change(.start(now, nil, useDefault: true), now: now)
        await MealServices.shared.sync(canStartActivity: false)
        return .result(dialog: change == nil ? IntentDialog("home.running") : IntentDialog("intent.started"))
    }
}

struct FinishMealIntent: AppIntent {
    static let title: LocalizedStringResource = "home.finish"
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let now = Date()
        let (_, change) = try await MealStore.shared.change(.finish(now, "shortcut"), now: now)
        await MealServices.shared.sync(canStartActivity: false)
        return .result(dialog: change == nil ? IntentDialog("intent.idle") : IntentDialog("intent.finished"))
    }
}

struct ReadMealIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.read"
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let active = try await MealStore.shared.snapshot().active else { return .result(dialog: IntentDialog("intent.idle")) }
        let seconds = Date().timeIntervalSince(active.start)
        if seconds < 0 { return .result(dialog: IntentDialog("home.clock")) }
        let duration = L.duration(seconds)
        return .result(dialog: IntentDialog("\(duration)"))
    }
}

struct MealShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartMealIntent(), phrases: ["Start a meal interval in \(.applicationName)"], shortTitle: "home.start", systemImageName: "play")
        AppShortcut(intent: FinishMealIntent(), phrases: ["End the meal interval in \(.applicationName)"], shortTitle: "home.finish", systemImageName: "stop")
        AppShortcut(intent: ReadMealIntent(), phrases: ["Check the meal interval in \(.applicationName)"], shortTitle: "intent.read", systemImageName: "clock")
    }
}
