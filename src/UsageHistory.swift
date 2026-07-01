import Foundation

/// One recorded usage reading for a single account window.
struct UsageSample: Codable {
    var profileID: String
    var window: String
    var used: Double
    var at: Date
}

/// Persists a rolling 7-day history of usage readings to `usage_events.json`,
/// used to draw the per-window sparklines in the menu.
final class UsageHistoryStore {
    static let shared = UsageHistoryStore()

    private let queue = DispatchQueue(label: "fr.fraserv.llmusagebar.history")
    private var samples: [UsageSample]

    private let maxAge: TimeInterval = 7 * 86_400
    private let maxCount = 20_000
    private let minGap: TimeInterval = 45 // only dedupe near-simultaneous refreshes

    private init() {
        samples = Self.load()
    }

    /// Appends a reading per non-stale window, throttling near-duplicate points so
    /// the file doesn't balloon at short refresh intervals.
    func record(profiles: [LaunchProfile]) {
        let now = Date()
        queue.sync {
            for profile in profiles {
                guard profile.usageStale != true, let windows = profile.usage?.windows else { continue }
                for window in windows {
                    let last = samples.last { $0.profileID == profile.id && $0.window == window.title }
                    // Record on every refresh; only skip points from back-to-back
                    // refreshes seconds apart so the trend fills in quickly.
                    if let last, now.timeIntervalSince(last.at) < minGap {
                        continue
                    }
                    samples.append(UsageSample(profileID: profile.id, window: window.title, used: window.usedPercent, at: now))
                }
            }
            prune()
            persist()
        }
    }

    /// Time-ordered used-percent values for one window (oldest first).
    func series(profileID: String, window: String) -> [Double] {
        queue.sync {
            samples
                .filter { $0.profileID == profileID && $0.window == window }
                .sorted { $0.at < $1.at }
                .map(\.used)
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        samples.removeAll { $0.at < cutoff }
        if samples.count > maxCount {
            samples.removeFirst(samples.count - maxCount)
        }
    }

    private func persist() {
        Paths.shared.ensureSupportDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(samples) {
            try? data.write(to: Paths.shared.historyURL, options: .atomic)
        }
    }

    private static func load() -> [UsageSample] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Paths.shared.historyURL),
              let samples = try? decoder.decode([UsageSample].self, from: data) else {
            return []
        }
        return samples
    }
}
