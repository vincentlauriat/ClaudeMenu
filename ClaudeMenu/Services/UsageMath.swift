import Foundation

/// Pace projection for one meter: where it lands at the current rate, what it would
/// take to land exactly on 100.
struct PaceProjection {
    let used: Double
    let hoursElapsed: Double
    let hoursLeft: Double
    let resetsAt: Date

    /// Percentage the window reaches at the reset if the current average rate holds.
    var landing: Double {
        let total = hoursElapsed + hoursLeft
        guard total > 0, hoursElapsed > 0 else { return used }
        return used * total / hoursElapsed
    }
    var runningPerHour: Double { hoursElapsed > 0 ? used / hoursElapsed : 0 }
    var neededPerHour: Double { hoursLeft > 0 ? max(0, 100 - used) / hoursLeft : 0 }
    var remaining: Double { max(0, 100 - used) }
    var daysLeft: Double { hoursLeft / 24 }
    /// Even daily spend that lands exactly on the limit.
    var evenSharePerDay: Double { daysLeft > 0 ? remaining / daysLeft : remaining }
    var isOver: Bool { landing > 100 }

    /// A projection needs enough elapsed time to mean anything: extrapolating from the
    /// first minutes of a window turns a normal start into an absurd rate.
    var isMeaningful: Bool {
        hoursElapsed >= 0.5 && hoursElapsed / (hoursElapsed + hoursLeft) >= 0.05
    }
}

enum UsageMath {
    static func projection(for meter: Meter, now: Date) -> PaceProjection? {
        guard let reset = meter.resetsAt else { return nil }
        let window = meter.windowHours * 3600
        let start = reset.addingTimeInterval(-window)
        let elapsed = min(window, max(0, now.timeIntervalSince(start)))
        let left = max(0, reset.timeIntervalSince(now))
        return PaceProjection(used: meter.utilization, hoursElapsed: elapsed / 3600,
                              hoursLeft: left / 3600, resetsAt: reset)
    }

    /// Start of the weekly window: 7 days before the `all` meter reset, or 7 days ago.
    static func weekStart(gauge: GaugeSnapshot?, now: Date) -> Date {
        if let reset = gauge?.week?.resetsAt {
            return reset.addingTimeInterval(-7 * 86400)
        }
        return now.addingTimeInterval(-7 * 86400)
    }
}

enum Format {
    /// 711 · 6.3k · 202.9k · 3.6M · 12.4M
    static func compact(_ value: Double) -> String {
        let abs = Swift.abs(value)
        switch abs {
        case ..<1000: return String(format: "%.0f", value)
        case ..<1_000_000: return trim(value / 1000) + "k"
        case ..<1_000_000_000: return trim(value / 1_000_000) + "M"
        default: return trim(value / 1_000_000_000) + "G"
        }
    }
    static func compact(_ value: Int) -> String { compact(Double(value)) }

    private static func trim(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    static func percent(_ v: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f%%", v)
    }

    static func hours(_ h: Double) -> String { String(format: "%.1f", h) }

    /// "0.3 min ago" · "12 min ago" · "2.1h ago"
    static func ago(_ since: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(since))
        if s < 60 { return String(format: "%.1f min ago", s / 60) }
        if s < 3600 { return String(format: "%.0f min ago", s / 60) }
        return String(format: "%.1fh ago", s / 3600)
    }

    static func agoHours(_ since: Date, now: Date) -> String {
        let h = max(0, now.timeIntervalSince(since)) / 3600
        return String(format: "%.0fh ago", h)
    }

    private static let resetLong: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE yyyy-MM-dd HH:mm"
        return f
    }()
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mma"
        f.amSymbol = "am"; f.pmSymbol = "pm"
        return f
    }()
    private static let built: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// "Wed 2026-09-23 20:00"
    static func resetDate(_ d: Date) -> String { resetLong.string(from: d) }
    /// "4:20pm (Europe/Paris)"
    static func resetClock(_ d: Date) -> String {
        "\(clock.string(from: d)) (\(TimeZone.current.identifier))"
    }
    static func timestamp(_ d: Date) -> String { built.string(from: d) }
}

/// French-facing formatters for the panel.
enum FR {
    private static let number: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.numberStyle = .decimal
        return f
    }()

    /// 12,5 (French decimal comma, thin grouping).
    static func num(_ v: Double, decimals: Int = 0) -> String {
        number.minimumFractionDigits = decimals
        number.maximumFractionDigits = decimals
        return number.string(from: NSNumber(value: v)) ?? String(format: "%.\(decimals)f", v)
    }

    /// "1 repli" / "3 replis"
    static func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(num(Double(count))) \(count > 1 ? plural : singular)"
    }

    /// "12,5 %"
    static func pct(_ v: Double, decimals: Int = 0) -> String { num(v, decimals: decimals) + " %" }

    /// 711 · 6,3 k · 202,9 k · 3,6 M
    static func compact(_ value: Double) -> String {
        let abs = Swift.abs(value)
        switch abs {
        case ..<1000: return num(value)
        case ..<1_000_000: return num(value / 1000, decimals: 1) + " k"
        case ..<1_000_000_000: return num(value / 1_000_000, decimals: 1) + " M"
        default: return num(value / 1_000_000_000, decimals: 1) + " Md"
        }
    }
    static func compact(_ value: Int) -> String { compact(Double(value)) }

    /// "4 j 4 h" · "2 h 42 min" · "12 min" · "< 1 min"
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d) j \(h) h" }
        if h > 0 { return "\(h) h \(String(format: "%02d", m)) min" }
        if m > 0 { return "\(m) min" }
        return "< 1 min"
    }

    /// "il y a 2 min" · "il y a 1 h 05 min" · "à l'instant"
    static func ago(_ since: Date, now: Date) -> String {
        let s = now.timeIntervalSince(since)
        if s < 60 { return "à l'instant" }
        return "il y a " + duration(s)
    }

    private static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "EEE d MMM 'à' HH:mm"
        return f
    }()
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// "mer. 23 sept. à 20:00"
    static func dayTime(_ d: Date) -> String { dayTime.string(from: d) }
    /// "17:50"
    static func time(_ d: Date) -> String { time.string(from: d) }
}
