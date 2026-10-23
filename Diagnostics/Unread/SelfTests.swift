import Foundation
import CSQLCipher

func runUnreadSelfTests() throws {
    var handle: OpaquePointer?
    precondition(sqlite3_open(":memory:", &handle) == SQLITE_OK)
    guard let db = handle else { fatalError("fixture open failed") }
    defer { sqlite3_close(db) }
    let fixture = """
        CREATE TABLE NTChatRoom(chatName TEXT,countOfNewMessage INTEGER,directChatMemberUserId INTEGER);
        CREATE TABLE NTUser(userId INTEGER,linkId INTEGER,displayName TEXT,friendNickName TEXT,nickName TEXT);
        CREATE TABLE NTChatMessage(message TEXT);
        INSERT INTO NTChatRoom VALUES('식사방',2,0),(NULL,0,10),('미확인',NULL,0),('중복',1,0),('중복',3,0);
        INSERT INTO NTUser VALUES(10,0,'테스트 상대',NULL,NULL);
        INSERT INTO NTChatMessage VALUES('must never be read');
        """
    precondition(sqlite3_exec(db, fixture, nil, nil, nil) == SQLITE_OK)
    let group = try LocalUnreadReader.queryRooms(db, target: "식사방")
    precondition(group == [RoomUnread(name: "식사방", unread: 2)])
    let direct = try LocalUnreadReader.queryRooms(db, target: "테스트 상대")
    precondition(direct.first?.unread == 0)
    let unknown = try LocalUnreadReader.queryRooms(db, target: "미확인")
    precondition(unknown.count == 1 && unknown[0].unread == nil)
    let duplicate = try LocalUnreadReader.queryRooms(db, target: "중복")
    precondition(duplicate.count == 2)
    let missing = try LocalUnreadReader.queryRooms(db, target: "없는 방")
    precondition(missing.isEmpty)
    func denied(_ sql: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        return sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_AUTH
    }
    precondition(denied("SELECT message FROM NTChatMessage"))
    precondition(denied("UPDATE NTChatRoom SET countOfNewMessage=0"))
    precondition(denied("ATTACH DATABASE ':memory:' AS other"))
    let extensionDenied = "load_extension".withCString { name in unreadAuthorizer(nil, SQLITE_FUNCTION, nil, name, nil, nil) == SQLITE_DENY }
    precondition(extensionDenied)
    var extensionStatement: OpaquePointer?
    precondition(sqlite3_prepare_v2(db, "SELECT load_extension('unused')", -1, &extensionStatement, nil) != SQLITE_OK)
    sqlite3_finalize(extensionStatement)
    sqlite3_set_authorizer(db, nil, nil)
    precondition(sqlite3_exec(db, "UPDATE NTChatRoom SET countOfNewMessage=0 WHERE chatName='식사방'", nil, nil, nil) == SQLITE_OK)
    let afterRead = try LocalUnreadReader.queryRooms(db, target: "식사방")
    precondition(afterRead.first?.unread == 0)
    print("PASS: group/direct/unknown/duplicate/missing room results; message reads, writes, ATTACH and extension loading denied")
}
