import Foundation

/// Token savings reported by RTK (Rust Token Killer) through `rtk gain -d -f json`.
struct RTKStats: Equatable {
    struct Window: Equatable {
        var commands = 0
        var inputTokens = 0
        var savedTokens = 0
        var savingsPct: Double { inputTokens > 0 ? Double(savedTokens) / Double(inputTokens) * 100 : 0 }
    }
    let readAt: Date
    let allTime: Window
    let today: Window
    let week: Window
}

enum RTKGain {
    private static let candidates = [
        "/opt/homebrew/bin/rtk", "/usr/local/bin/rtk",
        NSHomeDirectory() + "/.cargo/bin/rtk", NSHomeDirectory() + "/.local/bin/rtk",
    ]

    /// The `rtk` binary if installed (GUI apps get a minimal PATH, so probe known prefixes).
    static var binary: URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static var isInstalled: Bool { binary != nil }

    /// Runs `rtk gain -d -f json` and folds the daily rows into today / week / all time.
    static func read(weekStart: Date, todayStart: Date, now: Date) -> RTKStats? {
        guard let binary else { return nil }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["gain", "-d", "-f", "json"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(root, weekStart: weekStart, todayStart: todayStart, now: now)
    }

    static func parse(_ root: [String: Any], weekStart: Date, todayStart: Date, now: Date) -> RTKStats? {
        guard let summary = root["summary"] as? [String: Any] else { return nil }
        var allTime = RTKStats.Window()
        allTime.commands = int(summary["total_commands"])
        allTime.inputTokens = int(summary["total_input"])
        allTime.savedTokens = int(summary["total_saved"])

        var today = RTKStats.Window()
        var week = RTKStats.Window()
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let todayKey = dayFormatter.string(from: todayStart)
        // RTK keys days by local date; a day belongs to the week if it ends after the window start.
        let weekStartDay = Calendar.current.startOfDay(for: weekStart)

        for case let row as [String: Any] in (root["daily"] as? [Any]) ?? [] {
            guard let key = row["date"] as? String, let day = dayFormatter.date(from: key) else { continue }
            let commands = int(row["commands"]), input = int(row["input_tokens"]), saved = int(row["saved_tokens"])
            if key == todayKey {
                today.commands += commands; today.inputTokens += input; today.savedTokens += saved
            }
            if day >= weekStartDay {
                week.commands += commands; week.inputTokens += input; week.savedTokens += saved
            }
        }
        return RTKStats(readAt: now, allTime: allTime, today: today, week: week)
    }

    private static func int(_ value: Any?) -> Int {
        (value as? Int) ?? (value as? NSNumber)?.intValue ?? Int((value as? Double) ?? 0)
    }
}
