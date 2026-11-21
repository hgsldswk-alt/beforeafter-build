import Foundation

struct Entitlement: Codable, Equatable {
    var firstOpen: Date
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false

    var trialStart: Date {
        let localStart = proStartedAt ?? firstOpen
        return min(localStart, trialClaimedAt ?? localStart)
    }

    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86_400) }

    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || (now >= trialStart.addingTimeInterval(-600) && now < trialEnd)
    }

    func remainingDays(at now: Date) -> Int {
        Int(max(0, min(30, ceil(trialEnd.timeIntervalSince(now) / 86_400))))
    }

    mutating func beginPaidMode(at now: Date) {
        if proStartedAt == nil { proStartedAt = now }
    }

    mutating func recordTrial(at date: Date) {
        trialClaimedAt = min(trialClaimedAt ?? date, date)
    }
}
