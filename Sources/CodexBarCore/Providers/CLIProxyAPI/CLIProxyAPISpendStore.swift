#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
import Foundation

public struct CLIProxyAPISpendInsertResult: Sendable, Equatable {
    public let inserted: Int
    public let duplicates: Int
    public let dropped: Int

    public init(inserted: Int, duplicates: Int, dropped: Int) {
        self.inserted = inserted
        self.duplicates = duplicates
        self.dropped = dropped
    }
}

public struct CLIProxyAPISpendStore: Sendable {
    public static let databaseFilename = "cliproxyapi-spend.sqlite"
    private static let schemaVersion = 1

    public let databaseURL: URL

    public init(cacheRoot: URL) {
        self.databaseURL = cacheRoot.appendingPathComponent(Self.databaseFilename, isDirectory: false)
    }

    public static func defaultRootURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("CodexBar", isDirectory: true)
            .appendingPathComponent("cliproxyapi-spend", isDirectory: true)
    }

    public func insert(
        _ events: [CLIProxyAPISpendEvent],
        fingerprint: String) throws -> CLIProxyAPISpendInsertResult
    {
        guard !events.isEmpty else {
            return CLIProxyAPISpendInsertResult(inserted: 0, duplicates: 0, dropped: 0)
        }
        guard !fingerprint.isEmpty else {
            return CLIProxyAPISpendInsertResult(inserted: 0, duplicates: 0, dropped: events.count)
        }
        guard let db = self.open(readOnly: false) else {
            throw CLIProxyAPISpendError.persistFailed("could not open spend store")
        }
        defer { sqlite3_close(db) }
        Self.ensureSchema(db)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw CLIProxyAPISpendError.persistFailed("could not begin write")
        }
        var statement: OpaquePointer?
        let sql = """
        INSERT OR IGNORE INTO events(
            dedupe_key, credential_scope, request_id, occurred_at, auth_index, upstream_provider, model, alias,
            input_tokens, output_tokens, reasoning_tokens, cache_read_tokens, cache_creation_tokens,
            total_tokens, failed, status_code
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw CLIProxyAPISpendError.persistFailed("could not prepare insert")
        }
        defer { sqlite3_finalize(statement) }

        var inserted = 0
        var duplicates = 0
        for event in events {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            Self.bind(statement, 1, event.dedupeKey)
            Self.bind(statement, 2, fingerprint)
            Self.bind(statement, 3, event.requestID)
            sqlite3_bind_double(statement, 4, event.occurredAt.timeIntervalSince1970)
            Self.bind(statement, 5, event.authIndex)
            Self.bind(statement, 6, event.upstreamProvider)
            Self.bind(statement, 7, event.model)
            Self.bind(statement, 8, event.alias)
            Self.bindOptionalInt(statement, 9, event.tokens.inputTokens)
            Self.bindOptionalInt(statement, 10, event.tokens.outputTokens)
            Self.bindOptionalInt(statement, 11, event.tokens.reasoningTokens)
            Self.bindOptionalInt(statement, 12, event.tokens.cacheReadTokens)
            Self.bindOptionalInt(statement, 13, event.tokens.cacheCreationTokens)
            Self.bindOptionalInt(statement, 14, event.tokens.totalTokens)
            sqlite3_bind_int(statement, 15, event.failed ? 1 : 0)
            Self.bindOptionalInt(statement, 16, event.statusCode)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw CLIProxyAPISpendError.persistFailed("insert failed")
            }
            if sqlite3_changes(db) == 0 {
                duplicates += 1
            } else {
                inserted += 1
            }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw CLIProxyAPISpendError.persistFailed("commit failed")
        }
        return CLIProxyAPISpendInsertResult(inserted: inserted, duplicates: duplicates, dropped: 0)
    }

    public func loadEvents(fingerprint: String) throws -> [CLIProxyAPISpendEvent] {
        guard !fingerprint.isEmpty else { return [] }
        guard let db = self.open(readOnly: true) else { return [] }
        defer { sqlite3_close(db) }
        guard Self.userVersion(db) == Self.schemaVersion else { return [] }
        var statement: OpaquePointer?
        let sql = """
        SELECT request_id, occurred_at, auth_index, upstream_provider, model, alias,
               input_tokens, output_tokens, reasoning_tokens, cache_read_tokens, cache_creation_tokens,
               total_tokens, failed, status_code
        FROM events
        WHERE credential_scope = ?
        ORDER BY occurred_at ASC, request_id ASC
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        Self.bind(statement, 1, fingerprint)
        var events: [CLIProxyAPISpendEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            events.append(CLIProxyAPISpendEvent(
                requestID: Self.text(statement, 0) ?? "",
                occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                authIndex: Self.text(statement, 2) ?? "",
                upstreamProvider: Self.text(statement, 3) ?? "unknown",
                model: Self.text(statement, 4) ?? "unknown",
                alias: Self.text(statement, 5) ?? "unknown",
                tokens: CLIProxyAPISpendTokenMix(
                    inputTokens: Self.optionalInt(statement, 6),
                    outputTokens: Self.optionalInt(statement, 7),
                    reasoningTokens: Self.optionalInt(statement, 8),
                    cacheReadTokens: Self.optionalInt(statement, 9),
                    cacheCreationTokens: Self.optionalInt(statement, 10),
                    totalTokens: Self.optionalInt(statement, 11)),
                failed: sqlite3_column_int(statement, 12) != 0,
                statusCode: Self.optionalInt(statement, 13)))
        }
        return events
    }

    private func open(readOnly: Bool) -> OpaquePointer? {
        if readOnly, !FileManager.default.fileExists(atPath: self.databaseURL.path) {
            return nil
        }
        if !readOnly {
            try? FileManager.default.createDirectory(
                at: self.databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        var db: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(self.databaseURL.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            if readOnly { return nil }
            self.rebuild()
            guard sqlite3_open_v2(self.databaseURL.path, &db, flags, nil) == SQLITE_OK else {
                sqlite3_close(db)
                return nil
            }
            return db
        }
        sqlite3_busy_timeout(db, 250)
        if !readOnly {
            _ = sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
            _ = sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        }
        return db
    }

    private func rebuild() {
        try? FileManager.default.removeItem(at: self.databaseURL)
    }

    private static func ensureSchema(_ db: OpaquePointer?) {
        guard self.userVersion(db) == 0 else { return }
        let sql = """
        CREATE TABLE IF NOT EXISTS events (
            dedupe_key TEXT NOT NULL,
            credential_scope TEXT NOT NULL,
            request_id TEXT NOT NULL,
            occurred_at REAL NOT NULL,
            auth_index TEXT NOT NULL,
            upstream_provider TEXT NOT NULL,
            model TEXT NOT NULL,
            alias TEXT NOT NULL,
            input_tokens INTEGER,
            output_tokens INTEGER,
            reasoning_tokens INTEGER,
            cache_read_tokens INTEGER,
            cache_creation_tokens INTEGER,
            total_tokens INTEGER,
            failed INTEGER NOT NULL,
            status_code INTEGER,
            PRIMARY KEY (dedupe_key, credential_scope)
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { return }
        Self.setUserVersion(db, Self.schemaVersion)
    }

    private static func userVersion(_ db: OpaquePointer?) -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func setUserVersion(_ db: OpaquePointer?, _ version: Int) {
        _ = sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil)
    }

    private static func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private static func bindOptionalInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private static func optionalInt(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        if sqlite3_column_type(statement, index) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }
}
