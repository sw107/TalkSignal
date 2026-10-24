import Foundation
import Darwin
import CSQLCipher

// Serial-queue only. Keep the cipher connection, never a read transaction, between polls.
// Every caller must hold the existing read-only folder grants while using this session.
final class ReadOnlySession {
    private var handle: OpaquePointer?
    private var fileIdentity: String?
    private var cachedVersion: Int64?
    private var cachedTarget: String?
    private var cachedRooms: [RoomUnread]?
    private(set) var queryCount = 0

    deinit { reset() }
    func reset() {
        if let handle { sqlite3_close(handle) }
        handle = nil; fileIdentity = nil
        cachedVersion = nil; cachedTarget = nil; cachedRooms = nil
    }
    private func identity(_ path: String) throws -> String {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw UnreadError.access }
        return "\(path):\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }
    private func version(_ db: OpaquePointer) throws -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA data_version", -1, &stmt, nil) == SQLITE_OK else { throw UnreadError.query }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw UnreadError.query }
        return sqlite3_column_int64(stmt, 0)
    }
    func read(path: String, target: String, open: () throws -> OpaquePointer) throws -> [RoomUnread] {
        do {
            let currentIdentity = try identity(path)
            if currentIdentity != fileIdentity { reset() }
            if handle == nil {
                let db = try open()
                guard sqlite3_db_readonly(db, "main") == 1 else { sqlite3_close(db); throw UnreadError.access }
                handle = db; fileIdentity = currentIdentity
                sqlite3_set_authorizer(db, unreadAuthorizer, nil)
            }
            guard let db = handle else { throw UnreadError.access }
            let currentVersion = try version(db)
            let normalized = RoomNames.normalized(target)
            if currentVersion == cachedVersion, normalized == cachedTarget, let cachedRooms { return cachedRooms }
            let rooms = try LocalUnreadReader.queryRooms(db, target: normalized)
            queryCount += 1
            // A concurrent commit must cause another query next time, not cache stale rows.
            if try version(db) == currentVersion {
                cachedVersion = currentVersion; cachedTarget = normalized; cachedRooms = rooms
            } else {
                cachedVersion = nil; cachedTarget = nil; cachedRooms = nil
            }
            guard try identity(path) == currentIdentity else { throw UnreadError.query }
            return rooms
        } catch {
            reset() // Never reuse stale results after an access / SQL / replacement error.
            throw error
        }
    }
}
