import Foundation
import Security

struct Entitlement: Codable, Equatable {
    var firstOpen: Date
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false

    var trialStart: Date {
        let local = proStartedAt ?? firstOpen
        return min(local, trialClaimedAt ?? local)
    }
    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86400) }
    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || (now >= trialStart && now < trialEnd)
    }
    mutating func open(at now: Date, free: Bool) {
        if !free && proStartedAt == nil { proStartedAt = now }
    }
    mutating func applyVerified(pro: Bool? = nil, trial: Date? = nil) {
        if let pro { purchasedPro = pro }
        if let trial { trialClaimedAt = min(trialClaimedAt ?? trial, trial) }
    }
}

actor EntitlementVault {
    private var cached: Entitlement?
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.hgsldswk.mealgap.entitlement", kSecAttrAccount as String: "local"]
    }

    func open(at now: Date) throws -> Entitlement {
        if let cached { return cached }
        if Launch.testing {
            return Entitlement(firstOpen: Launch.arguments.contains("-expired") ? now.addingTimeInterval(-31 * 86400) : now)
        }
        var request = query
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        let loaded: Entitlement
        if status == errSecItemNotFound { loaded = Entitlement(firstOpen: now) }
        else if status == errSecSuccess, let data = result as? Data { loaded = try JSONDecoder().decode(Entitlement.self, from: data) }
        else { throw MealError.storage }
        var current = loaded
        current.open(at: now, free: Launch.isFree)
        if status == errSecItemNotFound || current != loaded { try save(current) }
        cached = current
        return current
    }

    func verify(pro: Bool? = nil, trial: Date? = nil) throws -> Entitlement {
        let previous = try open(at: Launch.now())
        var current = previous
        current.applyVerified(pro: pro, trial: trial)
        if current != previous { try save(current) }
        return current
    }

    private func save(_ value: Entitlement) throws {
        if !Launch.testing {
            let data = try JSONEncoder().encode(value)
            let attrs = [kSecValueData as String: data]
            let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw MealError.storage }
            } else if status != errSecSuccess { throw MealError.storage }
        }
        cached = value
    }
}
