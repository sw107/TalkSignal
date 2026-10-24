import Foundation
import Darwin
import CSQLCipher

func runEnergyTests() throws {
    func require(_ condition: Bool, _ message: String = "energy test failed") { precondition(condition, message) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let prefs = directory.appendingPathComponent("Preferences")
    try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
    let pref = prefs.appendingPathComponent("com.kakao.KakaoTalkMac.plist")
    func writePref(_ id: Int) throws {
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["userId": id], format: .binary, options: 0)
        try bytes.write(to: pref, options: .atomic)
    }
    let markers = AccountMarkers()
    try writePref(101)
    try require(markers.read(folder: prefs) == ["userId:101"])
    for _ in 0..<20 { _ = try markers.read(folder: prefs) }
    require(markers.parseCount == 1, "unchanged preferences must not be reparsed")
    try writePref(202)
    try require(markers.read(folder: prefs) == ["userId:202"], "atomic replacement must change account")
    let bytes = try PropertyListSerialization.data(fromPropertyList: ["userId": 303], format: .binary, options: 0)
    try bytes.write(to: pref)
    try require(markers.read(folder: prefs) == ["userId:303"], "in-place same-size write must change account")
    try Data("malformed".utf8).write(to: pref)
    do { _ = try markers.read(folder: prefs); preconditionFailure("malformed preferences must not reuse account") }
    catch UnreadError.query { }
    try FileManager.default.removeItem(at: pref)
    try require(markers.read(folder: prefs).isEmpty, "deleted preference must remove account")
    let elsewhere = directory.appendingPathComponent("unselected.plist")
    try bytes.write(to: elsewhere)
    try FileManager.default.createSymbolicLink(at: pref, withDestinationURL: elsewhere)
    do { _ = try markers.read(folder: prefs); preconditionFailure("symlink must be rejected") }
    catch UnreadError.access { }
    print("PASS: unchanged preference reuse; account replacement, in-place edit, malformed, deletion and symlink invalidation")
    let path = directory.appendingPathComponent("synthetic.db").path
    func exec(_ db: OpaquePointer, _ sql: String) {
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "fixture SQL failed")
    }
    func writer() -> OpaquePointer {
        var db: OpaquePointer?
        precondition(sqlite3_open(path, &db) == SQLITE_OK)
        exec(db!, "PRAGMA key='synthetic-test-only'; PRAGMA cipher_compatibility=3; PRAGMA journal_mode=WAL;")
        exec(db!, """
          CREATE TABLE NTChatRoom(chatId INTEGER,linkId INTEGER,chatName TEXT,countOfNewMessage INTEGER,directChatMemberUserId INTEGER,displayMemberIds BLOB);
          CREATE TABLE NTUser(userId INTEGER,linkId INTEGER,displayName TEXT,friendNickName TEXT,nickName TEXT);
          CREATE TABLE NTChatMeta(chatId INTEGER,type INTEGER,content TEXT);
          CREATE TABLE NTOpenLink(linkId INTEGER,linkName TEXT);
          CREATE TABLE NTChatContext(userId INTEGER);
          INSERT INTO NTChatRoom VALUES(1,0,'Energy fixture',0,0,NULL);
          """)
        return db!
    }
    var writerDB: OpaquePointer? = writer()
    defer { if let writerDB { sqlite3_close(writerDB) } }
    var opens = 0
    func openReadOnly() throws -> OpaquePointer {
        var db: OpaquePointer?
        precondition(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK)
        exec(db!, "PRAGMA key='synthetic-test-only'; PRAGMA cipher_compatibility=3; PRAGMA query_only=ON;")
        opens += 1
        return db!
    }
    let session = ReadOnlySession()
    defer { session.reset() }
    func read(_ target: String = "Energy fixture") throws -> [RoomUnread] {
        try session.read(path: path, target: target, open: openReadOnly)
    }
    try require(read() == [.init(name: "Energy fixture", unread: 0)])
    for _ in 0..<20 { _ = try read() }
    precondition(opens == 1 && session.queryCount == 1, "unchanged polls must reuse connection and results")
    exec(writerDB!, "UPDATE NTChatRoom SET countOfNewMessage=2")
    try require(read().first?.unread == 2, "WAL receive must invalidate cached zero")
    exec(writerDB!, "UPDATE NTChatRoom SET countOfNewMessage=0")
    try require(read().first?.unread == 0, "phone read must invalidate cached unread")
    exec(writerDB!, "UPDATE NTChatRoom SET chatName='Renamed'")
    try require(read().isEmpty, "rename must invalidate cached name")
    try require(read("Renamed").first?.unread == 0, "target changes must invalidate cache")
    // Read transactions must have ended, allowing the writer to checkpoint its WAL.
    precondition(sqlite3_wal_checkpoint_v2(writerDB!, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK)

    let freshStart = clock()
    for _ in 0..<5 {
        let db = try openReadOnly()
        _ = try LocalUnreadReader.queryRooms(db, target: "Renamed")
        sqlite3_close(db)
    }
    let freshMs = Double(clock() - freshStart) / Double(CLOCKS_PER_SEC) * 1000 / 5
    let cachedStart = clock()
    for _ in 0..<50 { _ = try read("Renamed") }
    let cachedMs = Double(clock() - cachedStart) / Double(CLOCKS_PER_SEC) * 1000 / 50
    print(String(format: "Synthetic encrypted DB CPU per poll: reopen=%.3f ms; reused/unchanged=%.3f ms", freshMs, cachedMs))

    sqlite3_close(writerDB!); writerDB = nil
    try FileManager.default.moveItem(atPath: path, toPath: path + ".previous")
    writerDB = writer()
    exec(writerDB!, "UPDATE NTChatRoom SET countOfNewMessage=7")
    try require(read().first?.unread == 7, "replacement DB must reopen instead of serving old handle")
    sqlite3_close(writerDB!); writerDB = nil
    try FileManager.default.removeItem(atPath: path)
    do { _ = try read(); preconditionFailure("missing file must not serve cached results") }
    catch UnreadError.access { }
    print("PASS: connection/result reuse, WAL receive/read/rename, target change, checkpoint, replacement and missing-file invalidation")
}
