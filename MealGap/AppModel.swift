import Foundation
import Observation
import StoreKit
import UserNotifications

@MainActor @Observable
final class AppModel {
    let store = MealStore.shared
    private let vault = EntitlementVault()
    var state = MealState()
    var loaded = false
    var busy = false
    var error: String?
    var undo: UndoMeal?
    var entitlement: Entitlement?
    var paywall = false
    var notificationStatus: UNAuthorizationStatus = .notDetermined
    var pendingImport: Int?
    var notice: String?
    var reviewPending = false
    var hasPro: Bool { Launch.isFree || entitlement?.hasPro(at: Launch.now()) == true }

    func load() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if !loaded, Launch.testing, Launch.arguments.contains("-reset") {
                try await store.resetForTesting(Launch.arguments.contains("-fixtures") ? Self.fixtures() : MealState())
            }
            state = try await store.change(.visit).0
            loaded = true
            self.error = nil
            if undo?.revision != state.revision { undo = nil }
            if Launch.testing && Launch.arguments.contains("-paywall") && entitlement == nil { paywall = true }
        } catch { self.error = message(error) }
        do { entitlement = try await vault.open(at: Launch.now()) }
        catch { entitlement = nil }
        await refreshNotificationStatus()
        await MealServices.shared.sync(canStartActivity: true)
    }

    func change(_ action: MealAction) async throws {
        guard loaded, !busy else { throw MealError.stale }
        busy = true
        defer { busy = false }
        let (value, token) = try await store.change(action)
        if value.revision != state.revision {
            undo = token
            switch action {
            case .finish, .complete(_, _, false): CoreReview.shared.record(value.coreReviewProgress)
            default: break
            }
        }
        state = value
        self.error = nil
        if let token {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if self?.undo?.revision == token.revision { self?.undo = nil }
            }
        }
        Task { await MealServices.shared.sync(canStartActivity: true) }
    }

    func perform(_ action: MealAction) {
        Task {
            do { try await change(action) }
            catch { self.error = message(error) }
        }
    }

    func undoLast() async {
        guard let undo, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            state = try await store.undo(undo)
            self.undo = nil
            self.error = nil
            Task { await MealServices.shared.sync(canStartActivity: true) }
        } catch {
            self.undo = nil
            self.error = message(error)
        }
    }

    func refreshNotificationStatus() async {
        if Launch.testing {
            notificationStatus = Launch.arguments.contains("-notifications-denied") ? .denied : .notDetermined
        } else {
            notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    func reminders(_ enabled: Bool) async {
        do {
            if enabled && notificationStatus == .notDetermined && !Launch.testing {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                await refreshNotificationStatus()
            }
            guard !enabled || [.authorized, .provisional, .ephemeral].contains(notificationStatus) else { return }
            try await change(.reminders(enabled))
        } catch { self.error = message(error) }
    }

    func importFile(_ url: URL) async {
        do {
            pendingImport = try await Task.detached { try TemplateCode.fromFile(url) }.value
        } catch { self.error = message(error, fallback: "error.template") }
    }

    func recordShare(_ success: Bool) {
        if success, state.canReview { reviewPending = true }
    }

    func reviewIfEligible(_ request: () -> Void) async {
        guard reviewPending, state.canReview, !busy, !paywall, error == nil else { return }
        reviewPending = false
        guard CoreReview.shared.attempt(request) else { return }
        try? await change(.review)
    }

    static let proID = "com.hgsldswk.mealgap.pro"
    static let trialID = "com.hgsldswk.mealgap.trial"
    var products: [Product] = []
    var storeBusy = false

    func loadProducts() async {
        guard !Launch.testing, !Launch.isFree, products.count < 2, !storeBusy else { return }
        storeBusy = true
        defer { storeBusy = false }
        do {
            let available = try await Product.products(for: [Self.proID, Self.trialID])
            products = available.filter { $0.type == .nonConsumable }
        }
        catch { return }
    }

    func watchStore() async {
        guard !Launch.testing, !Launch.isFree else { return }
        await refreshEntitlements()
        for await update in Transaction.updates {
            if Task.isCancelled { break }
            if case .verified(let transaction) = update { try? await accept(transaction) }
        }
    }

    private func refreshEntitlements() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result { try? await accept(transaction) }
        }
        if case .verified(let transaction)? = await Transaction.latest(for: Self.proID), transaction.revocationDate != nil {
            try? await accept(transaction)
        }
    }

    private func accept(_ transaction: Transaction) async throws {
        switch transaction.productID {
        case Self.proID:
            entitlement = try await vault.verify(pro: transaction.revocationDate == nil)
        case Self.trialID:
            if transaction.revocationDate == nil { entitlement = try await vault.verify(trial: transaction.originalPurchaseDate) }
        default: return
        }
        await transaction.finish()
    }

    func purchase(_ product: Product) async {
        guard !storeBusy, !Launch.testing else { return }
        storeBusy = true
        defer { storeBusy = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                try await accept(transaction)
                if product.id == Self.proID { paywall = false }
                else { notice = L.t("pro.trialSaved") }
            case .success(.unverified): self.error = L.t("pro.failure")
            case .pending: notice = L.t("pro.pending")
            default: break
            }
        } catch { self.error = L.t("pro.failure") }
    }

    func restore() async {
        guard !Launch.testing, !storeBusy else { return }
        storeBusy = true
        defer { storeBusy = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            notice = L.t(entitlement?.purchasedPro == true || entitlement?.trialClaimedAt != nil ? "pro.restored" : "pro.none")
        } catch { self.error = L.t("pro.failure") }
    }

    private static func fixtures() -> MealState {
        let now = Launch.now()
        var state = MealState()
        let template = TimingTemplate(minutes: 720, imported: false, created: now)
        state.templates = [template]
        let count = Launch.arguments.contains("-milestone") ? 6 : 5
        for day in 0..<count {
            let end = now.addingTimeInterval(-19740 - Double(day * 86400))
            let start = end.addingTimeInterval(-Double(42900 - day * 525))
            state.records.append(IntervalRecord(active: ActiveInterval(start: start, zone: "UTC"), end: end, endZone: "UTC", source: "fixture", updated: end))
        }
        if Launch.arguments.contains("-running") {
            state.active = ActiveInterval(start: now.addingTimeInterval(-15840), zone: "UTC", templateID: template.id, targetMinutes: template.minutes)
        }
        return state
    }
}

func message(_ error: Error, fallback: String = "error.storage") -> String {
    (error as? MealError)?.message ?? L.t(fallback)
}
