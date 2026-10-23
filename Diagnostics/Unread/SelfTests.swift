import Foundation
import CSQLCipher

func runUnreadSelfTests() throws {
    var handle: OpaquePointer?
    precondition(sqlite3_open(":memory:", &handle) == SQLITE_OK)
    guard let db = handle else { fatalError("fixture open failed") }
    defer { sqlite3_close(db) }
    let fixture = """
        CREATE TABLE NTChatRoom(chatId INTEGER,linkId INTEGER,chatName TEXT,countOfNewMessage INTEGER,directChatMemberUserId INTEGER,displayMemberIds BLOB);
        CREATE TABLE NTUser(userId INTEGER,linkId INTEGER,displayName TEXT,friendNickName TEXT,nickName TEXT,phoneNumber TEXT);
        CREATE TABLE NTChatMeta(chatId INTEGER,type INTEGER,content TEXT);
        CREATE TABLE NTOpenLink(linkId INTEGER,linkName TEXT);
        CREATE TABLE NTChatContext(userId INTEGER PRIMARY KEY, forbidden TEXT);
        CREATE TABLE NTChatMessage(message TEXT);
        INSERT INTO NTChatContext(userId) VALUES(99);
        INSERT INTO NTChatRoom VALUES
          (1,0,NULL,2,0,NULL),(2,0,NULL,0,10,NULL),(3,0,'미확인',NULL,0,NULL),
          (4,0,'중복',1,0,NULL),(5,0,'중복',3,0,NULL),
          (6,0,'바꾼 1:1 방 이름',4,11,NULL),(7,80,NULL,7,0,NULL),
          (8,0,NULL,5,0,NULL),(9,0,NULL,0,0,NULL),
          (10,0,'기본 제목',1,0,NULL),(-1,0,'sentinel',9,0,NULL);
        INSERT INTO NTUser VALUES
          (10,0,'테스트 상대',NULL,NULL,'must never read'),
          (11,0,'개인 별명','옛 이름','프로필명',NULL),
          (12,0,'참여자A',NULL,NULL,NULL),(13,0,'참여자B',NULL,NULL,NULL),
          (12,80,'다른 링크의 A',NULL,NULL,NULL),(99,0,'나',NULL,NULL,NULL);
        INSERT INTO NTChatMeta VALUES
          (1,3,'테스트 단체방'),(1,1,'공지 내용은 이름 아님'),
          (1,3,'테스트 단체방'),(9,1,'공지뿐인 방'),(10,3,'후순위 제목');
        INSERT INTO NTOpenLink VALUES(80,'오픈방');
        INSERT INTO NTChatMessage VALUES('must never be read');
        """
    precondition(sqlite3_exec(db, fixture, nil, nil, nil) == SQLITE_OK)
    let members = try PropertyListSerialization.data(fromPropertyList: [99,13,12], format: .binary, options: 0)
    var setup: OpaquePointer?
    precondition(sqlite3_prepare_v2(db, "UPDATE NTChatRoom SET displayMemberIds=? WHERE chatId=8", -1, &setup, nil) == SQLITE_OK)
    _ = members.withUnsafeBytes { sqlite3_bind_blob(setup, 1, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    precondition(sqlite3_step(setup) == SQLITE_DONE); sqlite3_finalize(setup)

    func rooms(_ name: String) throws -> [RoomUnread] { try LocalUnreadReader.queryRooms(db, target: name) }
    func expect(_ name: String, _ expected: [RoomUnread]) throws { let actual = try rooms(name); precondition(actual == expected, "Room mismatch: " + name) }
    try expect("테스트 단체방", [.init(name: "테스트 단체방", unread: 2)])
    try expect(" 테스트 단체방 ", [.init(name: "테스트 단체방", unread: 2)])
    try expect("테스트 상대", [.init(name: "테스트 상대", unread: 0)])
    try expect("개인 별명", [.init(name: "바꾼 1:1 방 이름", unread: 4)])
    try expect("바꾼 1:1 방 이름", [.init(name: "바꾼 1:1 방 이름", unread: 4)])
    try expect("옛 이름", []) // current display name wins over old contact/profile names
    try expect("오픈방", [.init(name: "오픈방", unread: 7)])
    try expect("참여자A, 참여자B", [.init(name: "참여자A, 참여자B", unread: 5)])
    try expect("참여자A", []) // membership never means a sender match
    try expect("공지 내용은 이름 아님", [])
    try expect("공지뿐인 방", [])
    try expect("후순위 제목", [])
    try expect("기본 제목", [.init(name: "기본 제목", unread: 1)])
    try expect("sentinel", [])
    try expect("", [])
    try expect("없는 방", [])
    try expect("미확인", [.init(name: "미확인", unread: nil)])
    let duplicate = try rooms("중복")
    precondition(duplicate.count == 2)
    func denied(_ sql: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        return sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_AUTH
    }
    precondition(denied("SELECT message FROM NTChatMessage"))
    precondition(denied("SELECT phoneNumber FROM NTUser"))
    precondition(denied("SELECT forbidden FROM NTChatContext"))
    precondition(denied("UPDATE NTChatRoom SET countOfNewMessage=0"))
    precondition(denied("ATTACH DATABASE ':memory:' AS other"))
    var extensionStatement: OpaquePointer?
    precondition(sqlite3_prepare_v2(db, "SELECT load_extension('unused')", -1, &extensionStatement, nil) != SQLITE_OK)
    sqlite3_finalize(extensionStatement)

    sqlite3_set_authorizer(db, nil, nil)
    precondition(sqlite3_exec(db, "UPDATE NTChatRoom SET countOfNewMessage=0 WHERE chatId=1; UPDATE NTChatMeta SET content='바뀐 단체방' WHERE chatId=1 AND type=3", nil, nil, nil) == SQLITE_OK)
    try expect("테스트 단체방", [])
    try expect("바뀐 단체방", [.init(name: "바뀐 단체방", unread: 0)])
    sqlite3_set_authorizer(db, nil, nil)
    precondition(sqlite3_exec(db, "INSERT INTO NTChatRoom VALUES(1,81,'바뀐 단체방',0,0,NULL)", nil, nil, nil) == SQLITE_OK)
    let separateLinks = try rooms("바뀐 단체방")
    precondition(separateLinks.count == 2) // real room key is (chatId, linkId)
    print("PASS: group titles, renamed direct aliases, open/group names, duplicate joins, rename/read sync; message/phone reads, writes, ATTACH/extensions blocked")
}
