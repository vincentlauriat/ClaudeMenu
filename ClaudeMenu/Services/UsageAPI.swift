import Foundation

enum UsageAPIError: LocalizedError {
    case http(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .http(401):
            return "Anthropic a refusé le jeton (401). Lance « claude » une fois pour le renouveler."
        case .http(429):
            return "Anthropic limite les lectures (429). Les chiffres affichés sont les derniers connus."
        case .http(let code):
            return "Les compteurs Anthropic ont répondu HTTP \(code)."
        case .malformed:
            return "Les compteurs Anthropic ont renvoyé une réponse inattendue."
        }
    }
}

/// `GET https://api.anthropic.com/api/oauth/usage` — the same gauge Claude Code's `/usage` shows.
///
/// Response shape (only the parts we use):
/// ```
/// { "five_hour": { "utilization": 54.0, "resets_at": "…" },
///   "seven_day": { "utilization": 84.0, "resets_at": "…" },
///   "seven_day_opus": { … }, "seven_day_sonnet": { … }, … }
/// ```
/// Every top-level object carrying a `utilization` is turned into a `Meter`, so new
/// per-model keys show up without a code change.
enum UsageAPI {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch(token: String) async throws -> GaugeSnapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UsageAPIError.http(http.statusCode)
        }
        return try parse(data, fetchedAt: Date())
    }

    static func parse(_ data: Data, fetchedAt: Date) throws -> GaugeSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageAPIError.malformed
        }
        var session: Meter?
        var week: Meter?
        var models: [Meter] = []

        for (key, value) in root {
            guard let dict = value as? [String: Any],
                  let utilization = number(dict["utilization"]) else { continue }
            // `extra_usage` is a spend meter, not a rate-limit window — skip it.
            if key == "extra_usage" { continue }
            let resetsAt = (dict["resets_at"] as? String).flatMap(ISO8601.parse)
            switch key {
            case "five_hour":
                session = Meter(key: key, name: "session", utilization: utilization,
                                resetsAt: resetsAt, windowHours: 5)
            case "seven_day":
                week = Meter(key: key, name: "all", utilization: utilization,
                             resetsAt: resetsAt, windowHours: 168)
            default:
                let name = key.hasPrefix("seven_day_") ? String(key.dropFirst("seven_day_".count)) : key
                models.append(Meter(key: key, name: name, utilization: utilization,
                                    resetsAt: resetsAt, windowHours: 168))
            }
        }
        models.sort { $0.name < $1.name }
        guard session != nil || week != nil else { throw UsageAPIError.malformed }
        return GaugeSnapshot(fetchedAt: fetchedAt, session: session, week: week, models: models)
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}

/// ISO-8601 parsing that accepts both `…Z` and `…​.123Z`.
enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ text: String) -> Date? {
        withFraction.date(from: text) ?? plain.date(from: text)
    }
}
