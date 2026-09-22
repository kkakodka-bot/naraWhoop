import Foundation
import SQLite3

/// One account directory, one FULL/WAL authority. Immutable transfer/spool bytes stay outside SQLite.
/// A committed migration marker prevents retained legacy files from resurrecting settled debt.
final class CloudMetadataStore {
    private var db: OpaquePointer?
    let directory: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let kinds: Set<String> = ["json", "selection", "continuation", "control", "progress", "receipt"]

    init(directory: URL) throws {
        let directory = directory.lastPathComponent == "source-progress" ? directory.deletingLastPathComponent() : directory
        self.directory = directory
        let path = directory.appendingPathComponent("cloud-metadata.sqlite")
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw CloudUploadError.corruptJournal
        }
        do {
            sqlite3_busy_timeout(db, 5_000)
            // Opening a namespace is not an admitted integrity-scan opportunity. Reject future
            // schemas cheaply; explicit integrityCheck() remains available to maintenance/tests.
            let schema = try text("PRAGMA user_version") ?? "0"
            guard schema == "0" || schema == "1" else { throw CloudUploadError.corruptJournal }
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS entries (name TEXT PRIMARY KEY, kind TEXT NOT NULL, body BLOB NOT NULL)")
            try execute("CREATE INDEX IF NOT EXISTS entries_kind ON entries(kind,name)")
            try execute("CREATE TABLE IF NOT EXISTS files (name TEXT PRIMARY KEY, bytes INTEGER NOT NULL CHECK(bytes>=0))")
            try execute("CREATE TABLE IF NOT EXISTS accounting (id INTEGER PRIMARY KEY CHECK(id=1), bytes INTEGER NOT NULL, count INTEGER NOT NULL)")
            try execute("INSERT OR IGNORE INTO accounting VALUES(1,0,0)")
            try execute("CREATE TRIGGER IF NOT EXISTS files_insert AFTER INSERT ON files BEGIN UPDATE accounting SET bytes=bytes+NEW.bytes,count=count+1 WHERE id=1; END")
            try execute("CREATE TRIGGER IF NOT EXISTS files_update AFTER UPDATE ON files BEGIN UPDATE accounting SET bytes=bytes+NEW.bytes-OLD.bytes WHERE id=1; END")
            try execute("CREATE TRIGGER IF NOT EXISTS files_delete AFTER DELETE ON files BEGIN UPDATE accounting SET bytes=bytes-OLD.bytes,count=count-1 WHERE id=1; END")
            try migrateLegacy()
            guard try text("SELECT value FROM settings WHERE key='migration'") == "1" else { throw CloudUploadError.corruptJournal }
            if schema == "0" { try execute("PRAGMA user_version=1") }
            for name in ["cloud-metadata.sqlite", "cloud-metadata.sqlite-wal", "cloud-metadata.sqlite-shm"] {
                let url = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
                #endif
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { close() }
    func close() {
        if let db { sqlite3_close_v2(db); self.db = nil }
    }

    private func migrateLegacy() throws {
        try transaction {
            if try text("SELECT value FROM settings WHERE key='migration'") == "1" { return }
            // Import one value at a time. A failed import rolls back both entries and authority.
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            var paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
            let progress = directory.appendingPathComponent("source-progress", isDirectory: true)
            if FileManager.default.fileExists(atPath: progress.path) {
                let info = try progress.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard info.isSymbolicLink != true else { throw CloudUploadError.corruptJournal }
                paths += try FileManager.default.contentsOfDirectory(at: progress, includingPropertiesForKeys: keys)
            }
            for url in paths {
                guard !url.lastPathComponent.hasPrefix("cloud-metadata.sqlite") else { continue }
                let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard info.isSymbolicLink != true else { throw CloudUploadError.corruptJournal }
                guard info.isRegularFile == true else { continue }
                let size = info.fileSize ?? 0
                try recordFile((url.deletingLastPathComponent().lastPathComponent == "source-progress" ? "source-progress/" : "") + url.lastPathComponent, bytes: size)
                guard Self.kinds.contains(url.pathExtension) else { continue }
                let limit = url.pathExtension == "selection" ? 768 * 1_048_576 : 16 * 1_048_576
                guard size <= limit else { throw CloudUploadError.corruptJournal }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                try put(url.lastPathComponent, data: data)
                guard try read(url.lastPathComponent) == data else { throw CloudUploadError.corruptJournal }
            }
            try execute("INSERT INTO settings(key,value) VALUES('migration','1')")
        }
    }

    func validateOwner(_ namespace: String) throws {
        try transaction {
            if let saved = try text("SELECT value FROM settings WHERE key='owner'") {
                guard saved == namespace else { throw CloudUploadError.staleOwner }
            } else {
                try run("INSERT INTO settings(key,value) VALUES('owner',?)", strings: [namespace])
            }
        }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func read(_ name: String) throws -> Data? {
        try valid(name)
        return try statement("SELECT body FROM entries WHERE name=?", strings: [name]) { s in
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW else { throw failure(code) }
            let count = Int(sqlite3_column_bytes(s, 0))
            guard count > 0 else { return Data() }
            guard let bytes = sqlite3_column_blob(s, 0) else { throw CloudUploadError.corruptJournal }
            return Data(bytes: bytes, count: count)
        }
    }
    func contains(_ name: String) throws -> Bool {
        try valid(name)
        return try statement("SELECT 1 FROM entries WHERE name=?", strings: [name]) { s in
            let code = sqlite3_step(s)
            guard code == SQLITE_ROW || code == SQLITE_DONE else { throw failure(code) }
            return code == SQLITE_ROW
        }
    }
    func names(kind: String) throws -> [String] {
        try statement("SELECT name FROM entries WHERE kind=? ORDER BY name", strings: [kind]) { s in
            var names: [String] = []
            while true {
                let code = sqlite3_step(s)
                if code == SQLITE_DONE { return names }
                guard code == SQLITE_ROW, let value = sqlite3_column_text(s, 0) else { throw failure(code) }
                names.append(String(cString: value))
            }
        }
    }
    func put(_ name: String, data: Data) throws {
        try valid(name)
        try statement("INSERT INTO entries(name,kind,body) VALUES(?,?,?) ON CONFLICT(name) DO UPDATE SET body=excluded.body,kind=excluded.kind",
                      strings: [name, (name as NSString).pathExtension]) { s in
            let code = data.withUnsafeBytes { bytes -> Int32 in
                if bytes.isEmpty { return sqlite3_bind_zeroblob(s, 3, 0) }
                return sqlite3_bind_blob64(s, 3, bytes.baseAddress, UInt64(bytes.count), transient)
            }
            guard code == SQLITE_OK else { throw failure(code) }
            try done(s)
        }
    }
    func remove(_ name: String) throws { try valid(name); try run("DELETE FROM entries WHERE name=?", strings: [name]) }
    func recordFile(_ name: String, bytes: Int) throws {
        try valid(name)
        guard bytes >= 0 else { throw CloudUploadError.corruptJournal }
        try statement("INSERT INTO files(name,bytes) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET bytes=excluded.bytes", strings: [name]) { s in
            sqlite3_bind_int64(s, 2, Int64(bytes)); try done(s)
        }
    }
    func forgetFile(_ name: String) throws { try valid(name); try run("DELETE FROM files WHERE name=?", strings: [name]) }
    func fileNames(suffix: String) throws -> [String] {
        try statement("SELECT name FROM files WHERE substr(name,-?)=? ORDER BY name", strings: []) { s in
            sqlite3_bind_int(s, 1, Int32(suffix.count))
            sqlite3_bind_text(s, 2, suffix, -1, transient)
            var names: [String] = []
            while true {
                let code = sqlite3_step(s)
                if code == SQLITE_DONE { return names }
                guard code == SQLITE_ROW, let value = sqlite3_column_text(s, 0) else { throw failure(code) }
                names.append(String(cString: value))
            }
        }
    }
    func fileBytes(_ name: String) throws -> Int {
        try statement("SELECT bytes FROM files WHERE name=?", strings: [name]) { s in
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { return 0 }
            guard code == SQLITE_ROW else { throw failure(code) }
            return Int(sqlite3_column_int64(s, 0))
        }
    }
    func metadataBytes(_ name: String) throws -> Int {
        try statement("SELECT length(body) FROM entries WHERE name=?", strings: [name]) { s in
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { return 0 }
            guard code == SQLITE_ROW else { throw failure(code) }
            return Int(sqlite3_column_int64(s, 0))
        }
    }
    func accounting() throws -> (used: Int, files: Int) {
        let values: (Int, Int) = try statement("SELECT bytes,count FROM accounting WHERE id=1", strings: []) { s in
            guard sqlite3_step(s) == SQLITE_ROW else { throw CloudUploadError.corruptJournal }
            return (Int(sqlite3_column_int64(s, 0)), Int(sqlite3_column_int64(s, 1)))
        }
        // SQLite allocation and WAL are bounded metadata, measured directly without rescanning bodies.
        var allocated = 0, count = 0
        for name in ["cloud-metadata.sqlite", "cloud-metadata.sqlite-wal", "cloud-metadata.sqlite-shm"] {
            let url = directory.appendingPathComponent(name)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { allocated += size; count += 1 }
        }
        return (values.0 + allocated, values.1 + count)
    }
    func integrityCheck() throws -> String { try text("PRAGMA integrity_check") ?? "missing" }
    private func valid(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 512, !name.contains(".."), name != ".",
              (!name.contains("/") || (name.hasPrefix("source-progress/") && name.filter { $0 == "/" }.count == 1)) else { throw CloudUploadError.corruptJournal }
    }
    private func execute(_ sql: String) throws {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw failure(code) }
    }
    private func run(_ sql: String, strings: [String]) throws { try statement(sql, strings: strings) { try done($0) } }
    private func text(_ sql: String) throws -> String? {
        try statement(sql, strings: []) { s in
            let code = sqlite3_step(s)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW, let value = sqlite3_column_text(s, 0) else { throw failure(code) }
            return String(cString: value)
        }
    }
    private func statement<T>(_ sql: String, strings: [String], body: (OpaquePointer) throws -> T) throws -> T {
        var s: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &s, nil)
        guard code == SQLITE_OK, let s else { throw failure(code) }
        defer { sqlite3_finalize(s) }
        for (index, string) in strings.enumerated() {
            let code = sqlite3_bind_text(s, Int32(index + 1), string, -1, transient)
            guard code == SQLITE_OK else { throw failure(code) }
        }
        return try body(s)
    }
    private func done(_ s: OpaquePointer) throws {
        let code = sqlite3_step(s)
        guard code == SQLITE_DONE else { throw failure(code) }
    }
    private func failure(_ code: Int32) -> Error {
        if code == SQLITE_FULL { return CloudUploadError.storageFull }
        return CloudUploadError.corruptJournal
    }
}
