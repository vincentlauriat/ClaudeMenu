import Foundation

/// One meter as reported by Anthropic's OAuth usage endpoint.
struct Meter: Identifiable, Equatable {
    /// Raw key in the API response (`five_hour`, `seven_day`, `seven_day_opus`, …).
    let key: String
    /// Display name: `session`, `all`, or the model suffix (`opus`, `fable`, …).
    let name: String
    /// Percentage already used, 0…100 (may exceed 100 on overage).
    let utilization: Double
    /// When the window resets, if the API provided it.
    let resetsAt: Date?
    /// Window length in hours (5 for the session meter, 168 for weekly ones).
    let windowHours: Double

    var id: String { key }

    var isSession: Bool { key == "five_hour" }
}

/// Everything read from Anthropic's gauge in one call.
struct GaugeSnapshot: Equatable {
    let fetchedAt: Date
    let session: Meter?
    let week: Meter?
    /// Per-model weekly meters (everything that is neither `five_hour` nor `seven_day`).
    let models: [Meter]

    /// `all` first, then the per-model meters.
    var weeklyMeters: [Meter] {
        var list: [Meter] = []
        if let week { list.append(week) }
        list.append(contentsOf: models)
        return list
    }
}

/// What the fast-jev-compaction plugin did over one window, read off its transcript notices.
struct JevWindow: Equatable {
    var compactions = 0          // Jev replaced the summary
    var fallbacks = 0            // Jev gave up, built-in summary used
    var messagesBefore = 0
    var messagesKept = 0
    var reductionSum = 0.0       // sum of per-compaction reduction % (chars)

    var avgReductionPct: Double { compactions > 0 ? reductionSum / Double(compactions) : 0 }
    var messagesPruned: Int { messagesBefore - messagesKept }
    var attempts: Int { compactions + fallbacks }
}

/// Token counts derived from the local transcripts (exact, ours).
struct TranscriptStats: Equatable {
    let scannedAt: Date
    let messagesToday: Int
    let messagesWeek: Int
    let outputToday: Int
    let outputWeek: Int
    let readToday: Int
    let readWeek: Int
    var jevToday = JevWindow()
    var jevWeek = JevWindow()

    var avgOutputPerMessage: Double {
        messagesWeek > 0 ? Double(outputWeek) / Double(messagesWeek) : 0
    }
    var avgReadPerMessage: Double {
        messagesWeek > 0 ? Double(readWeek) / Double(messagesWeek) : 0
    }

    static let empty = TranscriptStats(scannedAt: .distantPast, messagesToday: 0, messagesWeek: 0,
                                       outputToday: 0, outputWeek: 0, readToday: 0, readWeek: 0)
}
