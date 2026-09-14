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
        let existed = try self.databaseExists()
        guard let db = try self.open(readOnly: false) else {
            throw CLIProxyAPISpendError.storeUnreadable
        }
        defer { sqlite3_close(db) }
        try Self.ensureSchema(db, allowInitialize: !existed)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw CLIProxyAPISpendError.storeUnreadable
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
            throw CLIProxyAPISpendError.storeUnreadable
        }
        defer { sqlite3_finalize(statement) }

        var inserted = 0
        var duplicates = 0
        for event in events {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            do {
                try Self.bind(statement, 1, event.dedupeKey)
                try Self.bind(statement, 2, fingerprint)
                try Self.bind(statement, 3, event.requestID)
                try Self.requireOK(sqlite3_bind_double(statement, 4, event.occurredAt.timeIntervalSince1970))
                try Self.bind(statement, 5, event.authIndex)
                try Self.bind(statement, 6, event.upstreamProvider)
                try Self.bind(statement, 7, event.model)
                try Self.bind(statement, 8, event.alias)
                try Self.bindOptionalInt(statement, 9, event.tokens.inputTokens)
                try Self.bindOptionalInt(statement, 10, event.tokens.outputTokens)
                try Self.bindOptionalInt(statement, 11, event.tokens.reasoningTokens)
                try Self.bindOptionalInt(statement, 12, event.tokens.cacheReadTokens)
                try Self.bindOptionalInt(statement, 13, event.tokens.cacheCreationTokens)
                try Self.bindOptionalInt(statement, 14, event.tokens.totalTokens)
                try Self.requireOK(sqlite3_bind_int(statement, 15, event.failed ? 1 : 0))
                try Self.bindOptionalInt(statement, 16, event.statusCode)
            } catch {
                _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw error
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw CLIProxyAPISpendError.storeUnreadable
            }
            if sqlite3_changes(db) == 0 {
                duplicates += 1
            } else {
                inserted += 1
            }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw CLIProxyAPISpendError.storeUnreadable
        }
        return CLIProxyAPISpendInsertResult(inserted: inserted, duplicates: duplicates, dropped: 0)
    }

    public func loadEvents(fingerprint: String) throws -> [CLIProxyAPISpendEvent] {
        guard !fingerprint.isEmpty else { return [] }
        guard let db = try self.open(readOnly: true) else { return [] }
        defer { sqlite3_close(db) }
        let version = try Self.userVersion(db)
        guard version == Self.schemaVersion else {
            throw CLIProxyAPISpendError.unsupportedSchema
        }
        var statement: OpaquePointer?
        let sql = """
        SELECT request_id, occurred_at, auth_index, upstream_provider, model, alias,
               input_tokens, output_tokens, reasoning_tokens, cache_read_tokens, cache_creation_tokens,
               total_tokens, failed, status_code
        FROM events
        WHERE credential_scope = ?
        ORDER BY occurred_at ASC, request_id ASC
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CLIProxyAPISpendError.storeUnreadable
        }
        defer { sqlite3_finalize(statement) }
        try Self.bind(statement, 1, fingerprint)
        var events: [CLIProxyAPISpendEvent] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
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
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw CLIProxyAPISpendError.storeUnreadable
        }
        return events
    }

    private func databaseExists() throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: self.databaseURL.path)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return false
        } catch {
            throw CLIProxyAPISpendError.storeUnreadable
        }
    }

    private func open(readOnly: Bool) throws -> OpaquePointer? {
        if readOnly, try !self.databaseExists() {
            return nil
        }
        if !readOnly {
            do {
                try FileManager.default.createDirectory(
                    at: self.databaseURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
            } catch {
                throw CLIProxyAPISpendError.storeUnreadable
            }
        }
        var db: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(self.databaseURL.path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CLIProxyAPISpendError.storeUnreadable
        }
        sqlite3_busy_timeout(db, 250)
        if !readOnly {
            _ = sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
            _ = sqlite3_exec(db, "PRAGMA synchronous = NORMAL", nil, nil, nil)
        }
        return db
    }

    private static func ensureSchema(_ db: OpaquePointer?, allowInitialize: Bool) throws {
        let version = try self.userVersion(db)
        if version == Self.schemaVersion {
            return
        }
        guard version == 0, allowInitialize else {
            throw version == 0 ? CLIProxyAPISpendError.storeUnreadable : CLIProxyAPISpendError.unsupportedSchema
        }
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
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CLIProxyAPISpendError.storeUnreadable
        }
        try Self.setUserVersion(db, Self.schemaVersion)
        let written = try self.userVersion(db)
        guard written == Self.schemaVersion else {
            throw CLIProxyAPISpendError.storeUnreadable
        }
    }

    private static func userVersion(_ db: OpaquePointer?) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            throw CLIProxyAPISpendError.storeUnreadable
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CLIProxyAPISpendError.storeUnreadable
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func setUserVersion(_ db: OpaquePointer?, _ version: Int) throws {
        guard sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil) == SQLITE_OK else {
            throw CLIProxyAPISpendError.storeUnreadable
        }
    }

    private static func requireOK(_ status: Int32) throws {
        guard status == SQLITE_OK else {
            throw CLIProxyAPISpendError.storeUnreadable
        }
    }

    private static func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) throws {
        if let value {
            try self.requireOK(
                sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
            return
        }
        try self.requireOK(sqlite3_bind_null(statement, index))
    }

    private static func bindOptionalInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int?) throws {
        if let value {
            try self.requireOK(sqlite3_bind_int64(statement, index, Int64(value)))
            return
        }
        try self.requireOK(sqlite3_bind_null(statement, index))
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
