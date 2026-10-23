import Foundation
import CommonCrypto
import IOKit
import CSQLCipher
import IdentityScan

enum UnreadError: Error, Equatable {
    case access, noDatabase, identity, ambiguousAccount, key, schema, query, cancelled
    var message: String {
        switch self {
        case .access: return "카톡 데이터 접근 불가 · 이 앱의 전체 디스크 접근을 확인해 주세요"
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
    "NTChatRoom": ["chatName", "countOfNewMessage", "directChatMemberUserId"],
    "NTUser": ["userId", "linkId", "displayName", "friendNickName", "nickName"]
]
func unreadAuthorizer(_ context: UnsafeMutableRawPointer?, _ action: Int32,
                      _ first: UnsafePointer<CChar>?, _ second: UnsafePointer<CChar>?,
                      _ database: UnsafePointer<CChar>?, _ trigger: UnsafePointer<CChar>?) -> Int32 {
    if action == SQLITE_SELECT { return SQLITE_OK }
    if action == SQLITE_READ, let first, let second,
       allowedColumns[String(cString: first)]?.contains(String(cString: second)) == true,
       database.map({ String(cString: $0) }) == "main" { return SQLITE_OK }
    if action == SQLITE_FUNCTION, let second,
       ["coalesce", "nullif"].contains(String(cString: second).lowercased()) { return SQLITE_OK }
    return SQLITE_DENY
}

final class LocalUnreadReader {
    private(set) var diagnostics: [String: Any] = [:]
    private let base = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/com.kakao.KakaoTalkMac/Data/Library")
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
        let databases = entries.filter { $0.lastPathComponent.range(of: "^[0-9a-fA-F]{78}(\\.db)?$", options: .regularExpression) != nil }
        diagnostics["databaseFiles"] = databases.count
        guard !databases.isEmpty else { throw UnreadError.noDatabase }
        let prefFolder = base.appendingPathComponent("Preferences")
        let prefURLs = ((try? fm.contentsOfDirectory(at: prefFolder, includingPropertiesForKeys: nil)) ?? []).filter {
            $0.lastPathComponent.hasPrefix("com.kakao.KakaoTalkMac") && $0.pathExtension == "plist"
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
        // Installed before preparing any user-data query. Only this fixed SELECT
        // is supported; no arbitrary SQL interface or message-reading function.
        sqlite3_set_authorizer(db, unreadAuthorizer, nil)
        let sql = """
            SELECT COALESCE(NULLIF(r.chatName,''),NULLIF(u.displayName,''),NULLIF(u.friendNickName,''),u.nickName),
                   r.countOfNewMessage
            FROM NTChatRoom r
            LEFT JOIN NTUser u ON r.directChatMemberUserId=u.userId AND u.linkId=0
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw UnreadError.schema }
        defer { sqlite3_finalize(statement) }
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        var result: [RoomUnread] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                let name = String(cString: value)
                if name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping == target {
                    let count = sqlite3_column_type(statement, 1) == SQLITE_INTEGER ? Int(sqlite3_column_int64(statement, 1)) : -1
                    result.append(RoomUnread(name: name, unread: count >= 0 ? count : nil))
                }
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw UnreadError.query }
        return result
    }
    // Observe account markers so a running app does not keep using a previous account's key.
    // Values remain in memory. No message or authentication-token fields are inspected.
    private func currentAccountMarker() throws -> [String] {
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: base.appendingPathComponent("Preferences"), includingPropertiesForKeys: nil) }
        catch { throw UnreadError.access }
        var markers: [String] = []
        for url in urls where url.lastPathComponent.hasPrefix("com.kakao.KakaoTalkMac") && url.pathExtension == "plist" {
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
