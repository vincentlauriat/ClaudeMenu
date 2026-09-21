import Foundation

/// Counts tokens straight off Claude Code's transcripts (`~/.claude/projects/**/*.jsonl`).
///
/// Incremental: each file is read from the byte offset reached last time, so a refresh
/// only costs the lines appended since. Assistant messages are split across several
/// JSONL lines (one per content block) that repeat the same `usage`, so they are
/// de-duplicated by `message.id` before counting.
actor TranscriptScanner {
    struct Entry {
        let timestamp: TimeInterval
        let output: Int
        /// Context read for the turn: input + cache read + cache creation.
        let read: Int
    }

    /// One fast-jev-compaction notice (`type: system`, content `fast-jev-compaction: …`).
    struct JevEntry {
        let timestamp: TimeInterval
        let success: Bool
        let messagesBefore: Int
        let messagesKept: Int
        let reductionPct: Double
    }

    private struct FileState {
        var offset: UInt64 = 0
        var entries: [Entry] = []
        var jev: [JevEntry] = []
        var seenIDs: Set<String> = []
    }

    private var states: [String: FileState] = [:]
    private let root: URL
    private static let assistantMarker = Data("\"type\":\"assistant\"".utf8)
    private static let jevMarker = Data("\"content\":\"fast-jev-compaction: ".utf8)
    private static let jevKept = try! NSRegularExpression(pattern: #"kept (\d+)/(\d+) messages"#)
    private static let jevReduction = try! NSRegularExpression(pattern: #"(\d+)% reduction"#)

    init(root: URL = ClaudePaths.projectsDir) {
        self.root = root
    }

    /// Rescans files touched since `weekStart` and aggregates the two windows.
    func stats(weekStart: Date, todayStart: Date, now: Date) -> TranscriptStats {
        scan(since: weekStart)

        var stats = (mt: 0, mw: 0, ot: 0, ow: 0, rt: 0, rw: 0)
        var jevToday = JevWindow(), jevWeek = JevWindow()
        let week = weekStart.timeIntervalSince1970
        let today = todayStart.timeIntervalSince1970
        for state in states.values {
            for e in state.entries where e.timestamp >= week {
                stats.mw += 1; stats.ow += e.output; stats.rw += e.read
                if e.timestamp >= today {
                    stats.mt += 1; stats.ot += e.output; stats.rt += e.read
                }
            }
            for j in state.jev where j.timestamp >= week {
                Self.fold(j, into: &jevWeek)
                if j.timestamp >= today { Self.fold(j, into: &jevToday) }
            }
        }
        var result = TranscriptStats(scannedAt: now,
                                     messagesToday: stats.mt, messagesWeek: stats.mw,
                                     outputToday: stats.ot, outputWeek: stats.ow,
                                     readToday: stats.rt, readWeek: stats.rw)
        result.jevToday = jevToday
        result.jevWeek = jevWeek
        return result
    }

    // MARK: - Scanning

    private func scan(since cutoff: Date) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles]) else { return }
        var live = Set<String>()

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate,
                  let size = values.fileSize else { continue }
            // A file untouched since the cutoff cannot hold entries inside the window.
            guard mtime >= cutoff else { continue }
            live.insert(url.path)

            var state = states[url.path] ?? FileState()
            let fileSize = UInt64(size)
            if fileSize < state.offset { state = FileState() }      // rewritten → start over
            if fileSize > state.offset {
                ingest(url: url, into: &state)
            }
            state.entries.removeAll { $0.timestamp < cutoff.timeIntervalSince1970 }
            state.jev.removeAll { $0.timestamp < cutoff.timeIntervalSince1970 }
            states[url.path] = state
        }
        states = states.filter { live.contains($0.key) }
    }

    private func ingest(url: URL, into state: inout FileState) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: state.offset)
        } catch { return }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        // Only consume complete lines; a half-written last line waits for the next tick.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let usable = data[data.startIndex...lastNewline]
        state.offset += UInt64(usable.count)

        for line in usable.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if line.range(of: Self.assistantMarker) != nil {
                if let entry = Self.parseAssistantLine(line, seen: &state.seenIDs) {
                    state.entries.append(entry)
                }
            } else if line.range(of: Self.jevMarker) != nil {
                if let entry = Self.parseJevLine(line, seen: &state.seenIDs) {
                    state.jev.append(entry)
                }
            }
        }
    }

    private static func fold(_ j: JevEntry, into w: inout JevWindow) {
        if j.success {
            w.compactions += 1
            w.messagesBefore += j.messagesBefore
            w.messagesKept += j.messagesKept
            w.reductionSum += j.reductionPct
        } else {
            w.fallbacks += 1
        }
    }

    /// `fast-jev-compaction: kept 132/244 messages, no summary (83% reduction; …)`
    /// `fast-jev-compaction: fallback to built-in summary (…)`
    private static func parseJevLine(_ line: Data.SubSequence, seen: inout Set<String>) -> JevEntry? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              obj["type"] as? String == "system",
              let content = obj["content"] as? String, content.hasPrefix("fast-jev-compaction: "),
              let ts = (obj["timestamp"] as? String).flatMap(ISO8601.parse) else { return nil }
        // The hook both logs and toasts the same text; one notice per timestamp+text is enough.
        guard seen.insert("jev:\(ts.timeIntervalSince1970):\(content)").inserted else { return nil }
        let range = NSRange(content.startIndex..., in: content)
        if let m = jevKept.firstMatch(in: content, range: range),
           let kept = Int(content[Range(m.range(at: 1), in: content)!]),
           let before = Int(content[Range(m.range(at: 2), in: content)!]) {
            var pct = 0.0
            if let r = jevReduction.firstMatch(in: content, range: range),
               let v = Double(content[Range(r.range(at: 1), in: content)!]) { pct = v }
            return JevEntry(timestamp: ts.timeIntervalSince1970, success: true,
                            messagesBefore: before, messagesKept: kept, reductionPct: pct)
        }
        if content.contains("fallback to built-in summary") {
            return JevEntry(timestamp: ts.timeIntervalSince1970, success: false,
                            messagesBefore: 0, messagesKept: 0, reductionPct: 0)
        }
        return nil
    }

    private static func parseAssistantLine(_ line: Data.SubSequence, seen: inout Set<String>) -> Entry? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let ts = (obj["timestamp"] as? String).flatMap(ISO8601.parse) else { return nil }
        if let id = message["id"] as? String {
            guard seen.insert(id).inserted else { return nil }
        }
        func int(_ key: String) -> Int {
            (usage[key] as? Int) ?? (usage[key] as? NSNumber)?.intValue ?? 0
        }
        let read = int("input_tokens") + int("cache_read_input_tokens") + int("cache_creation_input_tokens")
        return Entry(timestamp: ts.timeIntervalSince1970, output: int("output_tokens"), read: read)
    }
}
