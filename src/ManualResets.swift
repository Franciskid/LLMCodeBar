import Foundation

/// Saved, redeemable limit resets. These are unrelated to automatic quota windows.
struct ManualResetAllowance: Codable {
    var kind: String
    var count: Int
    var expiresAt: Date?
    var startsAt: Date?

    var key: String { "\(kind).\(expiresAt?.timeIntervalSince1970 ?? 0).\(startsAt?.timeIntervalSince1970 ?? 0)" }
    func unexpired(at now: Date) -> Bool { count > 0 && (expiresAt.map { $0 > now } ?? true) }
    func available(at now: Date) -> Bool { unexpired(at: now) && (startsAt.map { $0 <= now } ?? true) }
}

struct ManualResetInventory: Codable {
    var allowances: [ManualResetAllowance]
    var fetchedAt: Date
    /// An optional inventory read must not discard working quota data.
    var error: String?

    func availableCount(at now: Date = Date()) -> Int {
        allowances.filter { $0.available(at: now) }.reduce(0) { $0 + $1.count }
    }

    func lines(at now: Date = Date()) -> [String] {
        let held = allowances.filter { $0.unexpired(at: now) }
        if error != nil && held.isEmpty { return ["Manual resets: unavailable"] }
        var result = ["Manual resets: \(availableCount(at: now)) available\(error == nil ? "" : " · cached")"]
        for grant in held {
            var text = "\(grant.count) \(grant.kind) · "
            if let starts = grant.startsAt, starts > now { text += "from \(Self.dateText(starts)) · " }
            text += grant.expiresAt.map { Self.dateText($0) } ?? "expiry not provided"
            result.append(text)
        }
        return result
    }

    static func dateText(_ date: Date, now: Date = Date(), locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now) ? "d MMM" : "d MMM yyyy")
        return formatter.string(from: date)
    }
}

enum ManualResets {
    static func date(_ value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func claude(_ json: [String: Any], now: Date = Date()) -> ManualResetInventory? {
        guard let block = json["cedar_ember"] as? [String: Any], let eligible = block["eligible"] as? Bool else { return nil }
        // "surface" means the server withheld inventory, not that the balance is zero.
        if !eligible, block["ineligible_reason"] as? String == "surface" { return nil }
        if !eligible { return ManualResetInventory(allowances: [], fetchedAt: now) }
        guard let grants = block["grants"] as? [[String: Any]] else { return nil }
        let allowances: [ManualResetAllowance] = grants.compactMap { grant in
            guard let number = grant["resets_left"] as? NSNumber, number.doubleValue.rounded() == number.doubleValue,
                  number.intValue > 0, grant["paused"] as? Bool != true else { return nil }
            let expiry = date(grant["ends_at"])
            let starts = date(grant["starts_at"])
            if let value = grant["ends_at"], !(value is NSNull), expiry == nil { return nil }
            if let value = grant["starts_at"], !(value is NSNull), starts == nil { return nil }
            if let expiry, expiry <= now { return nil }
            let type = grant["type"] as? String ?? ""
            let clears = grant["clears"] as? [String] ?? []
            let kind: String
            if grant["gives_back_weekly"] as? Bool == true {
                kind = (grant["label"] as? String ?? "").lowercased().contains("fable") || type == "fable" ? "Fable" : "New-model"
            } else {
                switch type {
                case "full": kind = "Full"
                case "session": kind = "5-hour"
                case "weekly": kind = "Weekly"
                default:
                    let session = clears.contains("five_hour")
                    let week = clears.contains { $0.hasPrefix("seven_day") }
                    kind = session && week ? "Full" : session ? "5-hour" : week ? "Weekly" : "Other"
                }
            }
            return ManualResetAllowance(kind: kind, count: number.intValue, expiresAt: expiry, startsAt: starts)
        }
        return ManualResetInventory(allowances: grouped(allowances), fetchedAt: now)
    }

    static func codex(_ json: [String: Any], now: Date = Date()) -> ManualResetInventory? {
        guard let credits = json["credits"] as? [[String: Any]] else { return nil }
        let allowances: [ManualResetAllowance] = credits.compactMap { credit in
            guard credit["status"] as? String == "available" else { return nil }
            let expiry = date(credit["expires_at"])
            if let value = credit["expires_at"], !(value is NSNull), expiry == nil { return nil }
            if let expiry, expiry <= now { return nil }
            return ManualResetAllowance(kind: credit["reset_type"] as? String == "codex_rate_limits" ? "Full" : "Other",
                count: 1, expiresAt: expiry, startsAt: nil)
        }
        return ManualResetInventory(allowances: grouped(allowances), fetchedAt: now)
    }

    private static func grouped(_ allowances: [ManualResetAllowance]) -> [ManualResetAllowance] {
        var groups: [String: ManualResetAllowance] = [:]
        for allowance in allowances {
            var group = groups[allowance.key] ?? ManualResetAllowance(kind: allowance.kind, count: 0, expiresAt: allowance.expiresAt, startsAt: allowance.startsAt)
            group.count += allowance.count
            groups[allowance.key] = group
        }
        return groups.values.sorted {
            if $0.expiresAt != $1.expiresAt { return ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
            return $0.key < $1.key
        }
    }

    static func unavailable(previous: ManualResetInventory?, message: String) -> ManualResetInventory {
        var result = previous ?? ManualResetInventory(allowances: [], fetchedAt: .distantPast)
        result.error = message
        return result
    }
}
