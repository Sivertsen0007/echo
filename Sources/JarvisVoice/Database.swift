import Foundation
import SQLite3

/// Thin wrapper around system SQLite. One file: ~/.jarvis-voice/db.sqlite.
///
/// Schema is created on first open and migrated forward via `userVersion`.
/// All writes happen on the shared queue to keep things simple.
extension Notification.Name {
    static let transcriptionsChanged = Notification.Name("EchoTranscriptionsChanged")
    static let hotkeyChanged = Notification.Name("EchoHotkeyChanged")
}

final class Database {
    static let shared = Database()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "jarvis-voice.db")

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jarvis-voice")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("db.sqlite").path

        if sqlite3_open(path, &db) != SQLITE_OK {
            NSLog("DB open failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA foreign_keys=ON")
        migrate()
    }

    // MARK: - Schema

    private func migrate() {
        let current = userVersion()
        if current < 1 {
            exec("""
                CREATE TABLE transcriptions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at TEXT NOT NULL,
                    raw_text TEXT NOT NULL,
                    final_text TEXT NOT NULL,
                    audio_duration_s REAL NOT NULL,
                    latency_s REAL,
                    app_bundle_id TEXT,
                    app_name TEXT,
                    word_count INTEGER NOT NULL,
                    discarded INTEGER NOT NULL DEFAULT 0
                );
            """)
            exec("CREATE INDEX idx_transcriptions_created_at ON transcriptions(created_at);")
            setUserVersion(1)
        }
        if current < 2 {
            // Track which Style preset was applied. Null = no LLM was called.
            // Existing rows stay null, so historical costs only count Whisper.
            exec("ALTER TABLE transcriptions ADD COLUMN style_used TEXT;")
            exec("ALTER TABLE transcriptions ADD COLUMN style_prompt_chars INTEGER NOT NULL DEFAULT 0;")
            setUserVersion(2)
        }
        if current < 3 {
            // Which transcription provider handled this row. Null = legacy
            // (treat as OpenAI for cost purposes).
            exec("ALTER TABLE transcriptions ADD COLUMN provider TEXT;")
            setUserVersion(3)
        }
        if current < 4 {
            // Which model produced this row. Enables per-model cost attribution
            // and latency comparison. Null = legacy (use provider default rate).
            exec("ALTER TABLE transcriptions ADD COLUMN model TEXT;")
            setUserVersion(4)
        }
    }

    private func userVersion() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func setUserVersion(_ v: Int) { exec("PRAGMA user_version=\(v)") }

    // MARK: - Helpers

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            NSLog("DB exec failed: \(err.map { String(cString: $0) } ?? "?") for SQL: \(sql)")
            sqlite3_free(err)
        }
    }

    // MARK: - Writes

    func logTranscription(rawText: String, finalText: String, audioDuration: TimeInterval,
                          latency: TimeInterval, appBundleId: String?, appName: String?,
                          styleUsed: String? = nil, stylePromptChars: Int = 0,
                          provider: String? = nil, model: String? = nil,
                          discarded: Bool = false) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            let sql = """
                INSERT INTO transcriptions
                  (created_at, raw_text, final_text, audio_duration_s, latency_s,
                   app_bundle_id, app_name, word_count, discarded, style_used, style_prompt_chars, provider, model)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                NSLog("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            let now = ISO8601DateFormatter().string(from: Date())
            let words = finalText.split(whereSeparator: { $0.isWhitespace }).count
            // SQLITE_TRANSIENT signals "copy the bytes, do not retain pointer".
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, now, -1, transient)
            sqlite3_bind_text(stmt, 2, rawText, -1, transient)
            sqlite3_bind_text(stmt, 3, finalText, -1, transient)
            sqlite3_bind_double(stmt, 4, audioDuration)
            sqlite3_bind_double(stmt, 5, latency)
            if let bid = appBundleId { sqlite3_bind_text(stmt, 6, bid, -1, transient) } else { sqlite3_bind_null(stmt, 6) }
            if let nm = appName { sqlite3_bind_text(stmt, 7, nm, -1, transient) } else { sqlite3_bind_null(stmt, 7) }
            sqlite3_bind_int(stmt, 8, Int32(words))
            sqlite3_bind_int(stmt, 9, discarded ? 1 : 0)
            if let s = styleUsed { sqlite3_bind_text(stmt, 10, s, -1, transient) } else { sqlite3_bind_null(stmt, 10) }
            sqlite3_bind_int(stmt, 11, Int32(stylePromptChars))
            if let p = provider { sqlite3_bind_text(stmt, 12, p, -1, transient) } else { sqlite3_bind_null(stmt, 12) }
            if let m = model { sqlite3_bind_text(stmt, 13, m, -1, transient) } else { sqlite3_bind_null(stmt, 13) }
            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("insert failed: \(String(cString: sqlite3_errmsg(db)))")
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .transcriptionsChanged, object: nil)
            }
        }
    }

    // MARK: - Reads

    struct Transcription {
        let id: Int64
        let createdAt: String
        let rawText: String
        let finalText: String
        let duration: Double
        let latency: Double
        let appName: String?
        let wordCount: Int
    }

    struct DailyStats {
        let date: String        // YYYY-MM-DD
        let wordCount: Int
        let transcriptionCount: Int
        let recordingSeconds: Double
        var wpm: Double {
            recordingSeconds > 0 ? Double(wordCount) / (recordingSeconds / 60.0) : 0
        }
    }

    func recentTranscriptions(limit: Int = 50) -> [Transcription] {
        var result: [Transcription] = []
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return }
            let sql = """
                SELECT id, created_at, raw_text, final_text, audio_duration_s,
                       COALESCE(latency_s, 0), app_name, word_count
                FROM transcriptions
                WHERE discarded = 0
                ORDER BY id DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let appName = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                result.append(Transcription(
                    id: sqlite3_column_int64(stmt, 0),
                    createdAt: String(cString: sqlite3_column_text(stmt, 1)),
                    rawText: String(cString: sqlite3_column_text(stmt, 2)),
                    finalText: String(cString: sqlite3_column_text(stmt, 3)),
                    duration: sqlite3_column_double(stmt, 4),
                    latency: sqlite3_column_double(stmt, 5),
                    appName: appName,
                    wordCount: Int(sqlite3_column_int(stmt, 7))
                ))
            }
        }
        return result
    }

    /// Aggregates per local date. Last `days` calendar days.
    func dailyStats(days: Int = 30) -> [DailyStats] {
        var result: [DailyStats] = []
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return }
            // SQLite stores ISO8601 strings; substr(...,1,10) gives YYYY-MM-DD (UTC).
            let sql = """
                SELECT substr(created_at, 1, 10) AS d,
                       SUM(word_count), COUNT(*), SUM(audio_duration_s)
                FROM transcriptions
                WHERE discarded = 0
                  AND created_at >= datetime('now', ?)
                GROUP BY d
                ORDER BY d DESC;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, "-\(days) days", -1, transient)
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(DailyStats(
                    date: String(cString: sqlite3_column_text(stmt, 0)),
                    wordCount: Int(sqlite3_column_int(stmt, 1)),
                    transcriptionCount: Int(sqlite3_column_int(stmt, 2)),
                    recordingSeconds: sqlite3_column_double(stmt, 3)
                ))
            }
        }
        return result
    }

    func searchTranscriptions(query: String, limit: Int = 200) -> [Transcription] {
        var result: [Transcription] = []
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return }
            let sql: String
            var args: [String] = []
            if query.isEmpty {
                sql = """
                    SELECT id, created_at, raw_text, final_text, audio_duration_s,
                           COALESCE(latency_s, 0), app_name, word_count
                    FROM transcriptions
                    WHERE discarded = 0
                    ORDER BY id DESC LIMIT ?;
                """
            } else {
                sql = """
                    SELECT id, created_at, raw_text, final_text, audio_duration_s,
                           COALESCE(latency_s, 0), app_name, word_count
                    FROM transcriptions
                    WHERE discarded = 0
                      AND (final_text LIKE ? OR raw_text LIKE ? OR COALESCE(app_name,'') LIKE ?)
                    ORDER BY id DESC LIMIT ?;
                """
                let pat = "%\(query)%"
                args = [pat, pat, pat]
            }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, a) in args.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), a, -1, transient)
            }
            sqlite3_bind_int(stmt, Int32(args.count + 1), Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let appName = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                result.append(Transcription(
                    id: sqlite3_column_int64(stmt, 0),
                    createdAt: String(cString: sqlite3_column_text(stmt, 1)),
                    rawText: String(cString: sqlite3_column_text(stmt, 2)),
                    finalText: String(cString: sqlite3_column_text(stmt, 3)),
                    duration: sqlite3_column_double(stmt, 4),
                    latency: sqlite3_column_double(stmt, 5),
                    appName: appName,
                    wordCount: Int(sqlite3_column_int(stmt, 7))
                ))
            }
        }
        return result
    }

    func deleteTranscription(id: Int64) {
        queue.async { [weak self] in
            guard let self = self, let db = self.db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "DELETE FROM transcriptions WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_int64(stmt, 1, id)
            _ = sqlite3_step(stmt)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .transcriptionsChanged, object: nil)
            }
        }
    }

    /// Cumulative totals across all time.
    func totals() -> (words: Int, transcriptions: Int, seconds: Double) {
        var w = 0, c = 0
        var s = 0.0
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return }
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT COALESCE(SUM(word_count),0), COUNT(*), COALESCE(SUM(audio_duration_s),0) FROM transcriptions WHERE discarded = 0;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            if sqlite3_step(stmt) == SQLITE_ROW {
                w = Int(sqlite3_column_int(stmt, 0))
                c = Int(sqlite3_column_int(stmt, 1))
                s = sqlite3_column_double(stmt, 2)
            }
        }
        return (w, c, s)
    }

    struct AppUsage {
        let appName: String
        let wordCount: Int
        let transcriptionCount: Int
    }

    /// Word totals per app over the last `days`. Sorted by word count desc.
    func topApps(days: Int = 30, limit: Int = 10) -> [AppUsage] {
        var result: [AppUsage] = []
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return }
            let sql = """
                SELECT COALESCE(app_name, '(unknown)'), SUM(word_count), COUNT(*)
                FROM transcriptions
                WHERE discarded = 0
                  AND created_at >= datetime('now', ?)
                GROUP BY app_name
                ORDER BY SUM(word_count) DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, "-\(days) days", -1, transient)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(AppUsage(
                    appName: String(cString: sqlite3_column_text(stmt, 0)),
                    wordCount: Int(sqlite3_column_int(stmt, 1)),
                    transcriptionCount: Int(sqlite3_column_int(stmt, 2))
                ))
            }
        }
        return result
    }

    struct CostBreakdown {
        let whisperUSD: Double
        let llmUSD: Double
        var totalUSD: Double { whisperUSD + llmUSD }
        let audioSeconds: Double
        let llmInputChars: Int
        let llmOutputChars: Int
    }

    /// Sum of all API spend over a date range. Pass nil for `sinceClause` to
    /// get all-time totals.
    private func costBreakdown(sinceClause: String?) -> CostBreakdown {
        // We compute transcribe cost row-by-row because each row's provider
        // may have a different per-minute rate.
        var audio = 0.0
        var transcribeUSD = 0.0
        var inChars = 0, outChars = 0
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return }
            let whereExtra = sinceClause.map { "AND created_at >= datetime('now', '\($0)')" } ?? ""
            let sql = """
                SELECT audio_duration_s, COALESCE(provider, 'openai'), model,
                       CASE WHEN style_used IS NOT NULL AND style_used != 'raw'
                            THEN length(raw_text) + style_prompt_chars ELSE 0 END,
                       CASE WHEN style_used IS NOT NULL AND style_used != 'raw'
                            THEN length(final_text) ELSE 0 END
                FROM transcriptions
                WHERE discarded = 0 \(whereExtra);
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let s = sqlite3_column_double(stmt, 0)
                let provider = String(cString: sqlite3_column_text(stmt, 1))
                let model = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                audio += s
                transcribeUSD += Costs.transcribeCost(audioSeconds: s, provider: provider, model: model)
                inChars += Int(sqlite3_column_int64(stmt, 3))
                outChars += Int(sqlite3_column_int64(stmt, 4))
            }
        }
        return CostBreakdown(
            whisperUSD: transcribeUSD,
            llmUSD: Costs.llmCost(inputChars: inChars, outputChars: outChars),
            audioSeconds: audio,
            llmInputChars: inChars,
            llmOutputChars: outChars
        )
    }

    func costAllTime() -> CostBreakdown { costBreakdown(sinceClause: nil) }

    func costThisMonth() -> CostBreakdown {
        costBreakdown(sinceClause: "start of month")
    }

    func costLast(days: Int) -> CostBreakdown {
        costBreakdown(sinceClause: "-\(days) days")
    }

    /// Daily USD spend over the last `days`, oldest first.
    func costsByDay(days: Int) -> [(date: String, usd: Double)] {
        var perDay: [String: Double] = [:]
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return }
            let sql = """
                SELECT substr(created_at, 1, 10) AS d,
                       audio_duration_s, COALESCE(provider, 'openai'), model,
                       CASE WHEN style_used IS NOT NULL AND style_used != 'raw'
                            THEN length(raw_text) + style_prompt_chars ELSE 0 END,
                       CASE WHEN style_used IS NOT NULL AND style_used != 'raw'
                            THEN length(final_text) ELSE 0 END
                FROM transcriptions
                WHERE discarded = 0
                  AND created_at >= datetime('now', ?)
                ORDER BY d ASC;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, "-\(days) days", -1, transient)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let date = String(cString: sqlite3_column_text(stmt, 0))
                let audio = sqlite3_column_double(stmt, 1)
                let provider = String(cString: sqlite3_column_text(stmt, 2))
                let model = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let inChars = Int(sqlite3_column_int64(stmt, 4))
                let outChars = Int(sqlite3_column_int64(stmt, 5))
                let cost = Costs.transcribeCost(audioSeconds: audio, provider: provider, model: model)
                         + Costs.llmCost(inputChars: inChars, outputChars: outChars)
                perDay[date, default: 0] += cost
            }
        }
        return perDay.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Average API latency over the last `days`.
    func averageLatency(days: Int = 30) -> Double {
        var avg = 0.0
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return }
            let sql = """
                SELECT AVG(latency_s) FROM transcriptions
                WHERE discarded = 0 AND latency_s > 0
                  AND created_at >= datetime('now', ?);
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, "-\(days) days", -1, transient)
            if sqlite3_step(stmt) == SQLITE_ROW {
                avg = sqlite3_column_double(stmt, 0)
            }
        }
        return avg
    }

    struct ModelLatency {
        let model: String           // "(legacy)" for rows recorded before v4
        let count: Int
        let avgLatencySeconds: Double
        let avgDurationSeconds: Double
    }

    /// Average round-trip latency grouped by model over the last `days`.
    /// This is the comparison tool for choosing a default: dictate the same
    /// phrases under each model, then read the per-model averages here.
    /// Sorted fastest-first.
    func latencyByModel(days: Int = 30) -> [ModelLatency] {
        var result: [ModelLatency] = []
        queue.sync { [weak self] in
            guard let self = self, let db = self.db else { return }
            let sql = """
                SELECT COALESCE(model, '(legacy)') AS m,
                       COUNT(*), AVG(latency_s), AVG(audio_duration_s)
                FROM transcriptions
                WHERE discarded = 0 AND latency_s > 0
                  AND created_at >= datetime('now', ?)
                GROUP BY m
                ORDER BY AVG(latency_s) ASC;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, "-\(days) days", -1, transient)
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(ModelLatency(
                    model: String(cString: sqlite3_column_text(stmt, 0)),
                    count: Int(sqlite3_column_int(stmt, 1)),
                    avgLatencySeconds: sqlite3_column_double(stmt, 2),
                    avgDurationSeconds: sqlite3_column_double(stmt, 3)
                ))
            }
        }
        return result
    }

    /// Day streak: number of consecutive calendar days ending today with >= 1 transcription.
    func dayStreak() -> Int {
        let stats = dailyStats(days: 365)
        guard !stats.isEmpty else { return 0 }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")

        let dates = Set(stats.compactMap { fmt.date(from: $0.date) }
                              .map { cal.startOfDay(for: $0) })
        var streak = 0
        var cursor = today
        // If today has no entries yet, streak still counts yesterday onward.
        if !dates.contains(cursor) {
            cursor = cal.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while dates.contains(cursor) {
            streak += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return streak
    }
}
