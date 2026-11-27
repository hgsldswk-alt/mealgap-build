import StoreKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel

    var body: some View {
        Form {
            Section {
                NavigationLink(L.t("templates.title")) { TemplatesView(model: model) }.accessibilityIdentifier("settings.templates")
                NavigationLink(L.t("import.title")) { ImportView(model: model) }.accessibilityIdentifier("settings.import")
            }
            Section {
                Toggle(L.t("settings.reminder"), isOn: Binding(get: {
                    model.state.reminders && [.authorized, .provisional, .ephemeral].contains(model.notificationStatus)
                }, set: { enabled in Task { await model.reminders(enabled) } }))
                .accessibilityIdentifier("settings.reminder")
                if model.notificationStatus == .denied {
                    Text(L.t("settings.denied")).font(.footnote).accessibilityIdentifier("settings.denied")
                    Button(L.t("settings.system")) {
                        if !Launch.testing, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.accessibilityIdentifier("settings.system")
                }
            } footer: {
                Text(L.t("settings.reminderFoot"))
            }
            if !Launch.isFree {
                Section {
                    if let entitlement = model.entitlement {
                        if entitlement.purchasedPro { Text(L.t("pro.owned")) }
                        else if model.hasPro { Text(L.f("pro.until", L.date(entitlement.trialEnd, zone: TimeZone.current.identifier))) }
                        else { Text(L.t("pro.expired")) }
                    }
                    Button(L.t("pro.title")) { model.paywall = true }.accessibilityIdentifier("settings.pro")
                    Button(L.t("pro.restore")) { Task { await model.restore() } }.accessibilityIdentifier("settings.restore").disabled(model.storeBusy)
                }
            }
            Section {
                NavigationLink(L.t("settings.privacy")) { Text(L.t("settings.privacyBody")).padding(24).navigationTitle(L.t("settings.privacy")) }
                    .accessibilityIdentifier("settings.privacy")
                NavigationLink(L.t("settings.recommend")) { SharePreview(model: model, minutes: nil, milestone: false) }
                    .accessibilityIdentifier("settings.recommend")
            }
            if let fault = model.error { Text(fault).foregroundStyle(Design.accent).accessibilityIdentifier("settings.error") }
            if let notice = model.notice { Text(notice).foregroundStyle(.secondary) }
        }
        .navigationTitle(L.t("settings.title"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L.t("common.close")) { dismiss() }.accessibilityIdentifier("settings.close") } }
    }
}

struct TemplatesView: View {
    let model: AppModel
    @State private var showNew = false

    var body: some View {
        List {
            Button {
                model.perform(.select(nil))
            } label: {
                selectionLabel(L.t("templates.noTemplate"), selected: model.state.selected == nil)
            }.accessibilityIdentifier("templates.none")
            ForEach(model.state.templates) { template in
                Section {
                    Button { model.perform(.select(template.id)) } label: {
                        selectionLabel(template.title, selected: model.state.selected == template.id)
                    }.accessibilityIdentifier("templates.select")
                    NavigationLink(L.t("share.template")) { SharePreview(model: model, minutes: template.minutes, milestone: false) }
                        .accessibilityIdentifier("templates.share")
                    NavigationLink(L.t("templates.edit")) { TemplateEditor(model: model, template: template) }
                        .accessibilityIdentifier("templates.edit")
                } footer: {
                    if template.localName != nil { Text(L.duration(Double(template.minutes) * 60)) }
                }
            }
            Button(L.t("templates.new")) {
                if model.state.canCreateTemplate(pro: model.hasPro) { showNew = true }
                else { model.paywall = true }
            }.accessibilityIdentifier("templates.new")
            if let fault = model.error { Text(fault).foregroundStyle(Design.accent) }
        }
        .navigationTitle(L.t("templates.title"))
        .navigationDestination(isPresented: $showNew) { TemplateEditor(model: model) }
    }

    private func selectionLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
        }.accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct TemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let template: TimingTemplate?
    @State private var name: String
    @State private var minutes: String
    @State private var fault: String?
    @State private var delete = false

    init(model: AppModel, template: TimingTemplate? = nil) {
        self.model = model
        self.template = template
        _name = State(initialValue: template?.localName ?? "")
        _minutes = State(initialValue: template.map { String($0.minutes) } ?? "")
    }

    var body: some View {
        Form {
            TextField(L.t("templates.name"), text: $name).accessibilityIdentifier("templates.name")
            TextField(L.t("templates.minutes"), text: $minutes).keyboardType(.numberPad)
                .disabled(template?.imported == true).accessibilityIdentifier("templates.minutes")
            if let fault { Text(fault).foregroundStyle(Design.accent) }
            Button(L.t("common.save")) { save() }.accessibilityIdentifier("templates.save").disabled(model.busy)
            if template != nil {
                Button(L.t("common.delete"), role: .destructive) { delete = true }.accessibilityIdentifier("templates.delete")
            }
        }
        .navigationTitle(L.t(template == nil ? "templates.new" : "templates.edit"))
        .alert(L.t("templates.deleteQuestion"), isPresented: $delete) {
            Button(L.t("common.cancel"), role: .cancel) {}
            Button(L.t("common.delete"), role: .destructive) { if let template { run(.deleteTemplate(template.id)) } }
        }
    }

    private func save() {
        guard let duration = Int(minutes.trimmingCharacters(in: .whitespacesAndNewlines)), (1...10080).contains(duration) else {
            fault = L.t("error.minutes")
            return
        }
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        var next = template ?? TimingTemplate(minutes: duration, imported: false, created: Launch.now())
        next.localName = clean.isEmpty ? nil : clean
        next.minutes = duration
        run(.saveTemplate(next, pro: model.hasPro))
    }

    private func run(_ operation: MealAction) {
        Task {
            do { try await model.change(operation); dismiss() }
            catch {
                if (error as? MealError) == .pro { model.paywall = true }
                else { fault = message(error) }
            }
        }
    }
}

struct ImportView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let external: Bool
    @State private var input = ""
    @State private var minutes: Int?
    @State private var filePicker = false
    @State private var fault: String?
    @State private var done = false

    private let showClose: Bool

    init(model: AppModel, initial: Int? = nil, showClose: Bool = false) {
        self.model = model
        self.showClose = showClose
        external = initial != nil
        _minutes = State(initialValue: initial)
    }

    var body: some View {
        Form {
            if done { Text(L.t("import.saved")).accessibilityIdentifier("import.saved") }
            else if let minutes {
                Text(L.f("import.preview", L.duration(Double(minutes) * 60))).accessibilityIdentifier("import.preview")
                Button(L.t("import.save")) {
                    Task {
                        do { try await model.change(.importTemplate(minutes)); done = true; fault = nil }
                        catch { fault = message(error) }
                    }
                }.accessibilityIdentifier("import.save").disabled(model.busy || !model.loaded)
                if !external { Button(L.t("common.back")) { self.minutes = nil; fault = nil }.accessibilityIdentifier("import.back") }
            } else {
                TextEditor(text: $input).frame(minHeight: 96)
                    .accessibilityLabel(L.t("import.input")).accessibilityIdentifier("import.input")
                if Launch.testing, let preset = ProcessInfo.processInfo.environment["MEAL_GAP_TEST_CODE"] {
                    Button(L.t("import.paste")) { paste(preset) }.accessibilityIdentifier("import.paste")
                } else {
                    PasteButton(payloadType: String.self) { values in
                        if let value = values.first { paste(value) }
                    }.accessibilityLabel(Text(L.t("import.paste"))).accessibilityIdentifier("import.paste")
                }
                Button(L.t("import.check")) { preview() }.accessibilityIdentifier("import.check")
                Button(L.t("import.file")) {
                    if Launch.testing, let data = ProcessInfo.processInfo.environment["MEAL_GAP_TEST_FILE"] {
                        do {
                            let url = try ShareRequest.file(Data(data.utf8), named: "Import.mealinterval")
                            read(url, temporary: true)
                        } catch { fault = message(error, fallback: "error.template") }
                    } else { filePicker = true }
                }.accessibilityIdentifier("import.file")
            }
            if let fault { Text(fault).foregroundStyle(Design.accent).accessibilityIdentifier("import.error") }
        }
        .navigationTitle(L.t("import.title"))
        .toolbar {
            if showClose || external || done {
                ToolbarItem(placement: .cancellationAction) { Button(L.t("common.close")) { dismiss() }.accessibilityIdentifier("import.close") }
            }
        }
        .task {
            if Launch.testing, let preset = ProcessInfo.processInfo.environment["MEAL_GAP_TEST_CODE"] { input = preset }
        }
        .onAppear { if external { model.pendingImport = nil } }
        .fileImporter(isPresented: $filePicker, allowedContentTypes: [.mealInterval]) { result in
            switch result {
            case .success(let url): read(url)
            case .failure: fault = L.t("error.template")
            }
        }
    }

    private func read(_ url: URL, temporary: Bool = false) {
        Task {
            defer { if temporary { ShareRequest.cleanup([url]) } }
            do { minutes = try await Task.detached { try TemplateCode.fromFile(url) }.value; fault = nil }
            catch { fault = message(error, fallback: "error.template") }
        }
    }

    private func paste(_ text: String) {
        input = text
        preview()
    }

    private func preview() {
        do { minutes = try TemplateCode.decode(input); fault = nil }
        catch { fault = message(error, fallback: "error.template") }
    }
}

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Label(L.t("pro.templates"), systemImage: "square.stack")
                Label(L.t("history.trend"), systemImage: "chart.bar.xaxis")
                Label(L.t("history.image"), systemImage: "photo")
            } header: { Text(L.t("pro.once")) }
            Section {
                Text(L.t("pro.detail"))
                if model.entitlement?.purchasedPro == true { Text(L.t("pro.owned")) }
                else if let product = model.products.first(where: { $0.id == AppModel.proID }) {
                    Button(L.f("pro.buy", product.displayPrice)) { Task { await model.purchase(product) } }.accessibilityIdentifier("pro.buy")
                } else if Launch.testing {
                    Text(L.f("pro.buy", "$2.99")).accessibilityIdentifier("pro.testPrice")
                } else if !model.storeBusy {
                    Button(L.t("pro.retry")) { Task { await model.loadProducts() } }.accessibilityIdentifier("pro.retry")
                }
                if model.entitlement?.trialClaimedAt == nil, model.entitlement?.purchasedPro != true,
                   let trial = model.products.first(where: { $0.id == AppModel.trialID }) {
                    Button(L.t("pro.claim")) { Task { await model.purchase(trial) } }.accessibilityIdentifier("pro.claim")
                } else if Launch.testing {
                    Text(L.t("pro.claim")).foregroundStyle(.secondary)
                }
                Button(L.t("pro.restore")) { Task { await model.restore() } }.accessibilityIdentifier("pro.restore")
                if model.storeBusy { ProgressView() }
                if let notice = model.notice { Text(notice).foregroundStyle(.secondary) }
                if let fault = model.error { Text(fault).foregroundStyle(Design.accent) }
            }.disabled(model.storeBusy)
        }
        .navigationTitle(L.t("pro.title"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L.t("common.close")) { dismiss() }.accessibilityIdentifier("pro.close") } }
        .task { await model.loadProducts() }
    }
}
