import SwiftUI
import StoreKit
import UniformTypeIdentifiers

@main @MainActor
struct MealGapApp: App {
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            HomeView(model: model)
                .tint(Design.accent)
                .preferredColorScheme(.light)
        }
    }
}

enum Design {
    static let paper = Color(red: 248/255, green: 245/255, blue: 239/255)
    static let surface = Color(red: 253/255, green: 250/255, blue: 245/255)
    static let ink = Color(red: 38/255, green: 30/255, blue: 26/255)
    static let muted = Color(red: 113/255, green: 100/255, blue: 93/255)
    static let line = Color(red: 227/255, green: 217/255, blue: 208/255)
    static let accent = Color(red: 139/255, green: 73/255, blue: 54/255)
    static let tint = Color(red: 241/255, green: 228/255, blue: 220/255)
}

struct MealButton: View {
    let key: String
    let id: String
    var primary = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(L.t(key)).font(.headline).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 49)
                .padding(.horizontal, 8)
                .foregroundStyle(primary ? Color.white : Design.accent)
                .background(primary ? Design.accent : Color.clear, in: RoundedRectangle(cornerRadius: 15))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

struct HomeView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scene
    @Environment(\.requestReview) private var requestReview
    @ScaledMetric(relativeTo: .largeTitle) private var readingSize = 56.0
    @State private var sheet: Route?
    @State private var templateToShare: TimingTemplate?
    @State private var templateFilePicker = false

    enum Route: String, Identifiable {
        case history, settings, adjust, backfill, milestone, templateShare, importing
        var id: String { rawValue }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    timer
                    if let latest = model.state.sorted.first { recent(latest) }
                    if model.undo != nil {
                        HStack {
                            Text(L.t("home.saved"))
                            Spacer()
                            Button { Task { await model.undoLast() } } label: {
                                Text(L.t("home.undo")).frame(minHeight: 44).contentShape(Rectangle())
                            }
                                .accessibilityIdentifier("home.undo")
                        }.font(.subheadline)
                    }
                    if let count = model.state.milestonePending {
                        HStack {
                            Button { sheet = .milestone } label: {
                                Text(L.f("milestone.banner", count)).frame(minHeight: 44).contentShape(Rectangle())
                            }
                                .accessibilityIdentifier("milestone.share")
                            Spacer()
                            Button { model.perform(.dismissMilestone) } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                                .accessibilityLabel(L.t("common.close")).accessibilityIdentifier("milestone.dismiss")
                        }
                    }
                    if let fault = model.error { Text(fault).foregroundStyle(Design.accent).accessibilityIdentifier("home.error") }
                    Spacer(minLength: 20)
                    actions
                    if model.loaded { templateActions }
                }
                .padding(24)
                .frame(minHeight: geometry.size.height, alignment: .top)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Design.paper.ignoresSafeArea())
        .foregroundStyle(Design.ink)
        .sheet(item: $sheet, onDismiss: checkReview) { route in
            NavigationStack {
                switch route {
                case .history: HistoryView(model: model)
                case .settings: SettingsView(model: model)
                case .adjust: if let active = model.state.active { IntervalEditor(model: model, active: active) }
                case .backfill: IntervalEditor(model: model)
                case .milestone: SharePreview(model: model, minutes: model.state.selectedTemplate?.minutes, milestone: true)
                case .templateShare:
                    if let templateToShare { SharePreview(model: model, minutes: templateToShare.minutes, milestone: false) }
                case .importing: ImportView(model: model, initial: model.pendingImport, showClose: true)
                }
            }
            .sheet(isPresented: $model.paywall) { NavigationStack { PaywallView(model: model) } }
        }
        .sheet(isPresented: Binding(get: { sheet == nil && model.paywall }, set: { model.paywall = $0 }), onDismiss: checkReview) {
            NavigationStack { PaywallView(model: model) }
        }
        .fileImporter(isPresented: $templateFilePicker, allowedContentTypes: [.mealInterval]) { result in
            switch result {
            case .success(let url): Task { await model.importFile(url) }
            case .failure: model.error = L.t("error.template")
            }
        }
        .onOpenURL { url in
            guard url.isFileURL, url.pathExtension.lowercased() == "mealinterval" else { return }
            Task { await model.importFile(url) }
        }
        .onChange(of: model.pendingImport) { _, value in
            if value != nil && sheet == nil && !model.paywall { sheet = .importing }
        }
        .task { await model.load() }
        .task { await model.watchStore() }
        .reviewAfterCoreAction(when: reviewHome) { requestReview() }
        .onChange(of: scene) { _, phase in if phase == .active { Task { await model.load() } } }
        .onChange(of: model.reviewPending) { _, _ in checkReview() }
    }

    private var reviewHome: Bool {
        sheet == nil && !templateFilePicker && !model.paywall && !model.busy && model.loaded
            && model.error == nil && model.notice == nil && model.pendingImport == nil && model.state.active == nil
    }

    private func checkReview() {
        guard sheet == nil, scene == .active else { return }
        if model.pendingImport != nil, !model.paywall { sheet = .importing; return }
        guard reviewHome else { return }
        Task { @MainActor in
            guard reviewHome, scene == .active else { return }
            await model.reviewIfEligible { requestReview() }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack { title; Spacer(minLength: 8); navigation }
            VStack(alignment: .leading) { title; navigation }
        }
    }

    private var title: some View { Text(L.t("app.title")).font(.title.bold()).accessibilityAddTraits(.isHeader) }
    private var navigation: some View {
        HStack(spacing: 14) {
            Button(L.t("history.title")) { sheet = .history }.accessibilityIdentifier("home.history")
            Button(L.t("settings.title")) { sheet = .settings }.accessibilityIdentifier("home.settings")
        }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
    }

    private var timer: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(L.t("home.elapsed")).font(.headline)
                Spacer()
                if model.state.active != nil {
                    Label(L.t("home.running"), systemImage: "circle.fill").font(.caption.weight(.semibold)).foregroundStyle(Design.accent)
                }
            }
            if let active = model.state.active {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let seconds = Launch.now().timeIntervalSince(active.start)
                    Text(seconds < 0 ? L.t("home.clock") : L.duration(seconds))
                        .font(.system(size: readingSize, weight: .semibold, design: .rounded))
                        .monospacedDigit().accessibilityIdentifier("home.elapsed")
                }
                Divider()
                HStack(alignment: .top) {
                    let zone = TimeZone(identifier: active.zone) ?? .current
                    let sameDay = MealState.day(active.start, zone: zone) == MealState.day(Launch.now(), zone: zone)
                    Text(L.f("home.since", L.date(active.start, zone: active.zone, timeOnly: sameDay)))
                    Spacer()
                    Text(L.t("home.now"))
                }.font(.subheadline).foregroundStyle(Design.muted)
                if let minutes = active.targetMinutes { Text(L.f("home.target", L.duration(Double(minutes) * 60))).font(.footnote).foregroundStyle(Design.muted) }
            } else {
                Text("—").font(.system(size: 66, weight: .light)).foregroundStyle(Design.muted).accessibilityHidden(true)
                Divider()
                Text(L.t("home.empty")).font(.subheadline).foregroundStyle(Design.muted)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 238, alignment: .topLeading)
        .background(model.state.active == nil ? Design.surface : Design.tint, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Design.line))
    }

    private func recent(_ record: IntervalRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L.t("home.recent")).font(.subheadline.weight(.semibold))
                Spacer()
                Text(L.duration(record.duration)).font(.subheadline.bold()).foregroundStyle(Design.accent)
            }
            Text(record.range).font(.footnote).foregroundStyle(Design.muted)
        }.padding(15).background(Design.surface, in: RoundedRectangle(cornerRadius: 14))
          .accessibilityElement(children: .contain).accessibilityIdentifier("home.recent")
    }

    private var templateActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { templateButtons }
            VStack(alignment: .leading, spacing: 0) { templateButtons }
        }.font(.footnote.weight(.semibold))
    }

    @ViewBuilder private var templateButtons: some View {
        if !model.state.templates.isEmpty {
            Menu {
                ForEach(model.state.templates) { template in
                    Button(template.title) {
                        templateToShare = template
                        sheet = .templateShare
                    }.accessibilityIdentifier("home.shareTemplate.option")
                }
            } label: { Text(L.t("share.template")).frame(minHeight: 44) }
                .accessibilityIdentifier("home.shareTemplate")
        }
        Button { sheet = .importing } label: {
            Text(L.t("import.title")).frame(minHeight: 44).contentShape(Rectangle())
        }
            .accessibilityIdentifier("home.importTemplate")
        Button { chooseTemplateFile() } label: {
            Text(L.t("import.file")).frame(minHeight: 44).contentShape(Rectangle())
        }
            .accessibilityIdentifier("home.importTemplateFile")
    }

    private func chooseTemplateFile() {
        if Launch.testing, let text = ProcessInfo.processInfo.environment["MEAL_GAP_TEST_FILE"] {
            Task {
                do {
                    let url = try ShareRequest.file(Data(text.utf8), named: "Import.mealinterval")
                    defer { ShareRequest.cleanup([url]) }
                    await model.importFile(url)
                } catch { model.error = message(error, fallback: "error.template") }
            }
        } else { templateFilePicker = true }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            if !model.loaded {
                if model.error == nil { ProgressView() }
                else { MealButton(key: "common.retry", id: "home.retry") { Task { await model.load() } } }
            } else if model.state.active != nil {
                Text(L.t("home.finishHint")).font(.footnote).foregroundStyle(Design.muted)
                MealButton(key: "home.finish", id: "home.finish", primary: true) { model.perform(.finish(Launch.now(), "timer")) }.disabled(model.busy)
                MealButton(key: "home.adjust", id: "home.adjust") { sheet = .adjust }
            } else {
                Text(L.t("home.startHint")).font(.footnote).foregroundStyle(Design.muted)
                MealButton(key: "home.start", id: "home.start", primary: true) { model.perform(.start(Launch.now(), nil, useDefault: true)) }.disabled(model.busy)
                MealButton(key: "home.backfill", id: "home.backfill") { sheet = .backfill }
            }
        }.frame(maxWidth: .infinity)
    }
}
