import Foundation
import CommonCrypto
import IOKit
import CSQLCipher
import IdentityScan

enum UnreadError: Error, Equatable {
    case access, noDatabase, identity, ambiguousAccount, key, schema, query, cancelled
    var message: String {
        switch self {
        case .access: return "카톡 폴더 읽기 권한이 없어요 · 폴더를 다시 연결해 주세요"
        case .noDatabase: return "지원하는 카톡 로컬 DB를 찾지 못했어요"
        case .identity: return "현재 계정 식별값을 찾지 못했어요 · 추가 진단 필요"
        case .ambiguousAccount: return "여러 계정 정보가 있어 현재 계정을 확정할 수 없어요"
        case .key: return "현재 카톡 버전의 DB를 열지 못했어요 · 키 또는 형식 확인 필요"
        case .schema: return "현재 DB의 채팅방 이름/안 읽은 수 구조가 예상과 달라요"
        case .query: return "조회 실패 · 안 읽은 수를 0으로 간주하지 않아요"
        case .cancelled: return "검사가 중지됐어요"
        }
    }
}

struct RoomUnread: Equatable {
    let name: String
    let unread: Int?
}

// Restrict actual SQL reads to the room name/count and name-join columns.
// No message table, bodies, attachments, network, key output or DB writes.
private let allowedColumns: [String: Set<String>] = [
    "NTChatRoom": ["chatId", "linkId", "chatName", "countOfNewMessage", "directChatMemberUserId", "displayMemberIds"],
    "NTUser": ["userId", "linkId", "displayName", "friendNickName", "nickName"],
    "NTChatMeta": ["chatId", "type", "content"], // fixed SELECT restricts rows to title type 3
    "NTOpenLink": ["linkId", "linkName"],
    "NTChatContext": ["userId"]
]
func unreadAuthorizer(_ context: UnsafeMutableRawPointer?, _ action: Int32,
                      _ first: UnsafePointer<CChar>?, _ second: UnsafePointer<CChar>?,
                      _ database: UnsafePointer<CChar>?, _ trigger: UnsafePointer<CChar>?) -> Int32 {
    if action == SQLITE_SELECT { return SQLITE_OK }
    if action == SQLITE_TRANSACTION { return SQLITE_OK } // read snapshot, no write operations allowed
    // SQLite's INTEGER PRIMARY KEY scan also requests a table-row visit with
    // an empty column and nil database. This grants no extra value columns.
    if action == SQLITE_READ, first.map({ String(cString: $0) }) == "NTChatContext",
       second.map({ String(cString: $0) }) == "", database == nil { return SQLITE_OK }
    if action == SQLITE_READ, let first, let second,
       allowedColumns[String(cString: first)]?.contains(String(cString: second)) == true,
       database.map({ String(cString: $0) }) == "main" { return SQLITE_OK }
    if action == SQLITE_FUNCTION, let second,
       ["coalesce", "nullif"].contains(String(cString: second).lowercased()) { return SQLITE_OK }
    return SQLITE_DENY
}

final class LocalUnreadReader {
    private(set) var diagnostics: [String: Any] = [:]
    private let base = FileAccess.kakaoLibrary
    private var accountMarker: [String]?
    private var dbPath: String?
    private var key: String? // In-memory only, never arguments, report, log or disk.
    private var identitySearchStart = 1
    private var identitySearchHash = ""
    private let cancelLock = NSLock()
    private var stopped = false

    func stop() { cancelLock.lock(); stopped = true; cancelLock.unlock() }
    func resume() { cancelLock.lock(); stopped = false; cancelLock.unlock() }
    private func checkCancellation() throws {
        cancelLock.lock(); let value = stopped; cancelLock.unlock()
        if value { throw UnreadError.cancelled }
    }
    private func platformUUID() throws -> String {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard entry != 0 else { throw UnreadError.identity }
        defer { IOObjectRelease(entry) }
        guard let uuid = IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else {
            throw UnreadError.identity
        }
        return uuid
    }
    private func sha512(_ id: Int) -> String {
        let bytes = Array(String(id).utf8)
        var digest = [UInt8](repeating: 0, count: 64)
        CC_SHA512(bytes, CC_LONG(bytes.count), &digest)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    private func suffix(_ values: [String]) -> Int? {
        guard values.count >= 2, let first = values.first else { return nil }
        var common = Array(first.reversed())
        for value in values.dropFirst() {
            let other = Array(value.reversed())
            common = Array(zip(common, other).prefix { $0 == $1 }.map { $0.0 })
        }
        return Int(String(common.reversed()))
    }
    private func discover(progress: @escaping (String) -> Void) throws {
        try checkCancellation()
        let fm = FileManager.default
        let folder = base.appendingPathComponent("Application Support/com.kakao.KakaoTalkMac")
        let entries: [URL]
        do { entries = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) }
        catch { throw UnreadError.access }
        diagnostics["dataDirectoryReadable"] = true
        let databases = entries.filter { $0.resolvingSymlinksInPath().path == $0.standardizedFileURL.path && $0.lastPathComponent.range(of: "^[0-9a-fA-F]{78}(\\.db)?$", options: .regularExpression) != nil }
        diagnostics["databaseFiles"] = databases.count
        guard !databases.isEmpty else { throw UnreadError.noDatabase }
        let prefFolder = base.appendingPathComponent("Preferences")
        let prefURLs = ((try? fm.contentsOfDirectory(at: prefFolder, includingPropertiesForKeys: nil)) ?? []).filter {
            $0.resolvingSymlinksInPath().path == $0.standardizedFileURL.path && $0.lastPathComponent.hasPrefix("com.kakao.KakaoTalkMac") && $0.pathExtension == "plist"
        }
        var ids = Set<Int>()
        var hashes = Set<String>()
        diagnostics["preferenceFiles"] = prefURLs.count
        for url in prefURLs {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            for name in ["userId", "user_id", "KAKAO_USER_ID", "userID"] {
                if let n = plist[name] as? Int, n > 0 { ids.insert(n) }
                if let s = plist[name] as? String, let n = Int(s), n > 0 { ids.insert(n) }
            }
            if let values = plist["AlertKakaoIDsList"] as? [Any] {
                for value in values {
                    if let n = value as? Int, n > 0 { ids.insert(n) }
                    if let s = value as? String, let n = Int(s), n > 0 { ids.insert(n) }
                }
            }
            for prefix in ["FSChatWindowTransparency", "NSWindow Frame FSChatWindowFrame_"] {
                if let n = suffix(plist.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }), n > 0 {
                    ids.insert(n)
                }
            }
            for (name, value) in plist where name.hasPrefix("DESIGNATEDFRIENDSREVISION:") {
                guard let revision = value as? NSNumber, revision.intValue != 0 else { continue }
                let hash = String(name.dropFirst("DESIGNATEDFRIENDSREVISION:".count)).lowercased()
                if hash.count == 128, hash != sha512(0) { hashes.insert(hash) }
            }
        }
        guard hashes.count <= 1 else { throw UnreadError.ambiguousAccount }
        diagnostics["activeAccountHashes"] = hashes.count
        if let hash = hashes.first { ids = Set(ids.filter { sha512($0) == hash }) }
        diagnostics["candidateAccountValues"] = ids.count
        if ids.isEmpty, let hash = hashes.first {
            if hash != identitySearchHash { identitySearchHash = hash; identitySearchStart = 1 }
            let targetBytes = stride(from: 0, to: hash.count, by: 2).compactMap { offset -> UInt8? in
                let index = hash.index(hash.startIndex, offsetBy: offset)
                return UInt8(hash[index..<hash.index(index, offsetBy: 2)], radix: 16)
            }
            guard targetBytes.count == 64 else { throw UnreadError.identity }
            progress("이 Mac의 계정 식별값 확인 중… · 창을 열거나 서버에 접속하지 않아요")
            let deadline = Date().addingTimeInterval(90)
            let workers = min(4, ProcessInfo.processInfo.activeProcessorCount)
            let chunk = 1_000_000
            let upperBound = 2_000_000_000
            while identitySearchStart < upperBound {
                try checkCancellation()
                let start = identitySearchStart
                let foundLock = NSLock()
                var found: UInt64?
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    let begin = min(start + worker * chunk, upperBound)
                    let end = min(begin + chunk, upperBound)
                    let value = targetBytes.withUnsafeBufferPointer { bytes in
                        ts_scan_identity(UInt64(begin), UInt64(end), bytes.baseAddress)
                    }
                    if value != UInt64.max { foundLock.lock(); found = value; foundLock.unlock() }
                }
                identitySearchStart = min(start + workers * chunk, upperBound)
                if let found { ids.insert(Int(found)); break }
                let percent = identitySearchStart * 100 / upperBound
                progress("계정 식별값 확인 중… 탐색 범위 \(percent)% · 일시적으로 최대 \(workers)개 CPU 코어 사용")
                if Date() > deadline {
                    diagnostics["identitySearchNeedsMoreTime"] = true
                    throw UnreadError.identity
                }
            }
        }
        guard !ids.isEmpty else { throw UnreadError.identity }
        diagnostics["accountValueResolved"] = true
        let uuid = try platformUUID()
        var candidates: [(String, Int)] = []
        for id in ids.sorted() {
            try checkCancellation()
            let name = KeyDerivation.databaseName(userId: id, uuid: uuid)
            if let file = databases.first(where: { $0.lastPathComponent == name || $0.lastPathComponent == name + ".db" }) {
                candidates.append((file.path, id))
            }
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw candidates.count > 1 ? UnreadError.ambiguousAccount : UnreadError.key
        }
        diagnostics["databasePathMatched"] = true
        dbPath = candidate.0
        key = KeyDerivation.secureKey(userId: candidate.1, uuid: uuid)
    }
    private func open() throws -> OpaquePointer {
        guard let dbPath, let key else { throw UnreadError.identity }
        for compatibility in [3, 4] {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let db = handle else {
                if let handle { sqlite3_close(handle) }
                throw UnreadError.access
            }
            sqlite3_busy_timeout(db, 500)
            let setup = "PRAGMA key='\(key)'; PRAGMA cipher_compatibility=\(compatibility); PRAGMA query_only=ON;"
            var statement: OpaquePointer?
            let configured = sqlite3_exec(db, setup, nil, nil, nil) == SQLITE_OK
            let prepared = configured && sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master", -1, &statement, nil) == SQLITE_OK
            let valid = prepared && sqlite3_step(statement) == SQLITE_ROW
            sqlite3_finalize(statement)
            if valid && sqlite3_db_readonly(db, "main") == 1 {
                diagnostics["cipherCompatibility"] = compatibility
                diagnostics["databaseReadOnly"] = true
                // Column names only, to diagnose compatibility without payloads.
                for table in ["NTChatRoom", "NTUser"] {
                    var schema: OpaquePointer?
                    if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &schema, nil) == SQLITE_OK {
                        var columns: [String] = []
                        while sqlite3_step(schema) == SQLITE_ROW {
                            if let column = sqlite3_column_text(schema, 1) { columns.append(String(cString: column)) }
                        }
                        diagnostics[table + "Columns"] = columns
                    }
                    sqlite3_finalize(schema)
                }
                return db
            }
            sqlite3_close(db)
        }
        throw UnreadError.key
    }
    static func queryRooms(_ db: OpaquePointer, target: String) throws -> [RoomUnread] {
        sqlite3_set_authorizer(db, unreadAuthorizer, nil)
        let target = RoomNames.normalized(target)
        guard !target.isEmpty else { return [] }
        guard sqlite3_exec(db, "BEGIN DEFERRED TRANSACTION", nil, nil, nil) == SQLITE_OK else { throw UnreadError.query }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        // Resolve names first. Do not retrieve the unread counts of unrelated rooms.
        // Only room-title metadata (type 3), never notices or message content.
        let sql = """
            SELECT r.chatId, r.chatName, m.content, o.linkName,
                   COALESCE(NULLIF(u.displayName,''),NULLIF(u.friendNickName,''),u.nickName),
                   NULL, r.displayMemberIds, r.linkId
            FROM NTChatRoom r
            LEFT JOIN NTUser u ON r.directChatMemberUserId=u.userId AND u.linkId=0
            LEFT JOIN NTChatMeta m ON m.chatId=r.chatId AND m.type=3
            LEFT JOIN NTOpenLink o ON o.linkId=r.linkId
            WHERE r.chatId != -1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw UnreadError.schema }
        defer { sqlite3_finalize(statement) }
        func text(_ column: Int32) -> String? {
            sqlite3_column_text(statement, column).map { String(cString: $0) }
        }
        struct Match: Equatable { let names: RoomNames; let chatId: Int64; let linkId: Int64 }
        var matches: [String: Match] = [:]
        var memberNames: [String: String]?
        var selfID: Int64?
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let room = text(1), title = text(2), link = text(3), person = text(4)
            var generated: String?
            if RoomNames.resolve(room: room, title: title, openLink: link, person: person, members: nil) == nil,
               sqlite3_column_type(statement, 6) == SQLITE_BLOB,
               let bytes = sqlite3_column_blob(statement, 6) {
                if memberNames == nil {
                    let naming = try readMemberNames(db)
                    memberNames = naming.names; selfID = naming.selfID
                }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 6)))
                if let ids = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [NSNumber] {
                    let members = Set(ids.map(\.int64Value)).filter { $0 != selfID }.sorted()
                    let roomLink = sqlite3_column_int64(statement, 7)
                    let names = members.compactMap { memberNames?["\(roomLink):\($0)"] }
                    // Never manufacture a partial room name from missing member information.
                    if !names.isEmpty && names.count == members.count { generated = names.joined(separator: ", ") }
                }
            }
            if let names = RoomNames.resolve(room: room, title: title, openLink: link, person: person, members: generated), names.aliases.contains(target) {
                let match = Match(names: names, chatId: sqlite3_column_int64(statement, 0), linkId: sqlite3_column_int64(statement, 7))
                let id = "\(sqlite3_column_int64(statement, 0)):\(sqlite3_column_int64(statement, 7))"
                if let old = matches[id], old != match { throw UnreadError.query }
                matches[id] = match // join duplication cannot double the unread count
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw UnreadError.query }
        guard matches.count == 1, let match = matches.values.first else {
            return matches.keys.sorted().compactMap { matches[$0].map { RoomUnread(name: $0.names.display, unread: nil) } }
        }
        // A bound room key is the only unread-count query. Do not sum duplicate records.
        var countStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT countOfNewMessage FROM NTChatRoom WHERE chatId=? AND linkId=?", -1, &countStatement, nil) == SQLITE_OK else { throw UnreadError.schema }
        defer { sqlite3_finalize(countStatement) }
        sqlite3_bind_int64(countStatement, 1, match.chatId)
        sqlite3_bind_int64(countStatement, 2, match.linkId)
        var counts: [Int?] = []
        step = sqlite3_step(countStatement)
        while step == SQLITE_ROW {
            let count = sqlite3_column_type(countStatement, 0) == SQLITE_INTEGER ? Int(sqlite3_column_int64(countStatement, 0)) : -1
            counts.append(count >= 0 ? count : nil)
            step = sqlite3_step(countStatement)
        }
        guard step == SQLITE_DONE, !counts.isEmpty, counts.allSatisfy({ $0 == counts[0] }) else { throw UnreadError.query }
        return [RoomUnread(name: match.names.display, unread: counts[0])]
    }

    private static func readMemberNames(_ db: OpaquePointer) throws -> (names: [String: String], selfID: Int64?) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT userId FROM NTChatContext", -1, &stmt, nil) == SQLITE_OK else { throw UnreadError.schema }
        var own = Set<Int64>()
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW { own.insert(sqlite3_column_int64(stmt, 0)); step = sqlite3_step(stmt) }
        sqlite3_finalize(stmt)
        guard step == SQLITE_DONE, own.count <= 1 else { throw UnreadError.query }
        guard sqlite3_prepare_v2(db, "SELECT userId,linkId,COALESCE(NULLIF(displayName,''),NULLIF(friendNickName,''),nickName) FROM NTUser", -1, &stmt, nil) == SQLITE_OK else { throw UnreadError.schema }
        defer { sqlite3_finalize(stmt) }
        var names: [String: String] = [:]
        step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            if let value = sqlite3_column_text(stmt, 2) {
                let name = RoomNames.normalized(String(cString: value))
                if !name.isEmpty { names["\(sqlite3_column_int64(stmt, 1)):\(sqlite3_column_int64(stmt, 0))"] = name }
            }
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { throw UnreadError.query }
        return (names, own.first)
    }
    // Observe account markers so a running app does not keep using a previous account's key.
    // Values remain in memory. No message or authentication-token fields are inspected.
    private func currentAccountMarker() throws -> [String] {
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: base.appendingPathComponent("Preferences"), includingPropertiesForKeys: nil) }
        catch { throw UnreadError.access }
        var markers: [String] = []
        for url in urls where url.resolvingSymlinksInPath().path == url.standardizedFileURL.path && url.lastPathComponent.hasPrefix("com.kakao.KakaoTalkMac") && url.pathExtension == "plist" {
            let data: Data
            do { data = try Data(contentsOf: url) } catch { throw UnreadError.access }
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw UnreadError.query }
            for (name, value) in plist where name.hasPrefix("DESIGNATEDFRIENDSREVISION:") {
                if let revision = value as? NSNumber, revision.intValue != 0 { markers.append(name) }
            }
            for name in ["userId", "user_id", "KAKAO_USER_ID", "userID"] {
                if let value = plist[name] as? NSNumber { markers.append(name + ":" + value.stringValue) }
                else if let value = plist[name] as? String { markers.append(name + ":" + value) }
            }
        }
        return Array(Set(markers)).sorted()
    }
    func read(target: String, progress: @escaping (String) -> Void) throws -> [RoomUnread] {
        try checkCancellation()
        let marker = try currentAccountMarker()
        if marker != accountMarker {
            dbPath = nil
            key = nil
            identitySearchStart = 1
            identitySearchHash = ""
            accountMarker = marker
        }
        if dbPath == nil { try discover(progress: progress) }
        try checkCancellation()
        let db = try open()
        defer { sqlite3_close(db) }
        let rooms = try Self.queryRooms(db, target: target)
        guard try currentAccountMarker() == marker else { throw UnreadError.query }
        return rooms
    }
}
