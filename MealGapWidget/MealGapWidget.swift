import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MealGapWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MealActivity.self) { context in
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("home.elapsed")).font(.headline)
                    Text(L.f("home.since", L.date(context.state.start, zone: context.state.zone, timeOnly: true))).font(.caption)
                }
                Spacer()
                timer(context.state.start, stale: context.isStale).font(.title2.bold())
            }
            .padding(16)
            .activityBackgroundTint(Color(red: 0.97, green: 0.96, blue: 0.94))
            .foregroundStyle(Color(red: 0.15, green: 0.12, blue: 0.10))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "fork.knife") }
                DynamicIslandExpandedRegion(.trailing) { timer(context.state.start, stale: context.isStale) }
                DynamicIslandExpandedRegion(.bottom) { Text(L.f("home.since", L.date(context.state.start, zone: context.state.zone, timeOnly: true))) }
            } compactLeading: {
                Image(systemName: "fork.knife")
            } compactTrailing: {
                timer(context.state.start, stale: context.isStale).frame(width: 57)
            } minimal: {
                Image(systemName: "clock")
            }
        }
    }

    @ViewBuilder private func timer(_ start: Date, stale: Bool) -> some View {
        if stale { Text(L.t("activity.open")) }
        else { Text(timerInterval: start...start.addingTimeInterval(8 * 3600), countsDown: false).monospacedDigit() }
    }
}
