import Foundation
import Security
import StoreKit
import Combine

actor EntitlementKeychain {
    private let service = "com.hgsldswk.beforeafter.entitlement"

    func start(at now: Date, free: Bool) throws -> Entitlement {
        var value = try read() ?? Entitlement(firstOpen: now)
        if !free { value.beginPaidMode(at: now) }
        try write(value)
        return value
    }

    func cache(_ value: Entitlement) throws {
        var updated = value
        if let prior = try read() {
            updated.firstOpen = min(prior.firstOpen, updated.firstOpen)
            updated.proStartedAt = prior.proStartedAt ?? updated.proStartedAt
            if let claim = prior.trialClaimedAt { updated.recordTrial(at: claim) }
        }
        try write(updated)
    }

    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "local-v1"]
    }

    private func read() throws -> Entitlement? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CollageError.writeFailed }
        return try JSONDecoder().decode(Entitlement.self, from: data)
    }

    private func write(_ value: Entitlement) throws {
        let data = try JSONEncoder().encode(value)
        let fields = [kSecValueData as String: data]
        let status = SecItemUpdate(identity as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CollageError.writeFailed }
        } else if status != errSecSuccess {
            throw CollageError.writeFailed
        }
    }
}

@MainActor
final class Purchases: ObservableObject {
    var proID: String {
        Bundle.main.object(forInfoDictionaryKey: "BeforeAfterProProductID") as? String ?? "com.hgsldswk.beforeafter.pro"
    }
    var trialID: String {
        Bundle.main.object(forInfoDictionaryKey: "BeforeAfterTrialProductID") as? String ?? "com.hgsldswk.beforeafter.trial"
    }
    let free = Launch.isFree
    let testing: Bool
    private let keychain = EntitlementKeychain()
    private var observation: Task<Void, Never>?
    private var refreshGeneration = 0
    private var starting = false
    @Published private(set) var entitlement: Entitlement?
    @Published private(set) var products: [Product] = []
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    @Published private var now = Date()

    init(testing: Bool) { self.testing = testing }
    deinit { observation?.cancel() }

    var hasPro: Bool { free || entitlement?.hasPro(at: Date(), free: false) == true }
    var remainingDays: Int { entitlement?.remainingDays(at: now) ?? 0 }
    var paid: Bool { entitlement?.purchasedPro == true }
    var pro: Product? { products.first { $0.id == proID } }
    var trial: Product? { products.first { $0.id == trialID } }

    func start() async {
        guard !starting, entitlement == nil else { return }
        starting = true
        defer { starting = false }
        now = Date()
        if testing {
            let expired = ProcessInfo.processInfo.arguments.contains("-expired")
            let start = expired ? now.addingTimeInterval(-40 * 86_400) : now
            entitlement = Entitlement(firstOpen: start, proStartedAt: start)
            return
        }
        do {
            entitlement = try await keychain.start(at: now, free: free)
        } catch {
            notice = "pay.unavailable"
        }
        guard !free else { return }
        if observation == nil {
            observation = Task { [weak self] in
                for await verification in StoreKit.Transaction.updates {
                    guard let self else { return }
                    if case let .verified(transaction) = verification,
                       transaction.productID == self.proID || transaction.productID == self.trialID {
                        await self.refresh(trialReceipt: transaction.productID == self.trialID ? transaction : nil)
                        await transaction.finish()
                    }
                }
            }
        }
        Task { await refresh() }
    }

    func foreground() async {
        now = Date()
        if !testing && entitlement == nil && !free { await start() }
        if !testing && !free { await refresh() }
    }

    func loadProducts() async {
        now = Date()
        guard !free, !testing else { return }
        do {
            products = try await Product.products(for: [proID, trialID])
            notice = pro == nil || trial == nil ? "pay.unavailable" : nil
        } catch {
            notice = "pay.unavailable"
        }
    }

    func purchase(_ product: Product) async {
        guard !free, !testing, !busy else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                await refresh(trialReceipt: transaction.productID == trialID ? transaction : nil)
                await transaction.finish()
            case .success(.unverified):
                notice = "pay.unverified"
            case .pending:
                notice = "pay.pending"
            case .userCancelled:
                break
            @unknown default:
                notice = "pay.unavailable"
            }
        } catch {
            notice = "pay.unavailable"
        }
    }

    func restore() async {
        guard !free, !busy else { return }
        if testing {
            notice = "pay.noPurchase"
            return
        }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refresh()
            notice = paid ? "pay.restored" : "pay.noPurchase"
        } catch {
            notice = "pay.unavailable"
        }
    }

    private func refresh(trialReceipt: StoreKit.Transaction? = nil) async {
        if let receipt = trialReceipt, receipt.revocationDate == nil, var value = entitlement {
            value.recordTrial(at: receipt.originalPurchaseDate)
            entitlement = value
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        var purchased = false
        var earliest: Date?
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case let .verified(transaction) = result, transaction.revocationDate == nil else { continue }
            if transaction.productID == proID { purchased = true }
            if transaction.productID == trialID {
                let date = transaction.originalPurchaseDate
                earliest = min(earliest ?? date, date)
            }
        }
        guard refreshGeneration == generation, var latest = entitlement else { return }
        latest.purchasedPro = purchased
        if let earliest { latest.recordTrial(at: earliest) }
        entitlement = latest
        now = Date()
        do { try await keychain.cache(latest) } catch { notice = "pay.unavailable" }
    }
}
