import AppKit
import ApplicationServices
import SQLite3

// A separate diagnostic app so Full Disk Access can be granted only to this
// executable. Queries only KakaoTalk records. No copying/export of the database,
// no network, no UI actions in KakaoTalk or Notification Center.
struct DBCheck {
    var readable = false
    var error = ""
    var latestID: Int64 = 0
    var latestTargetID: Int64 = 0
    var latestTargetDate: Double = 0
    var recordsChecked = 0
    var matchingIDs: [Int64] = []
    var headerKeys: [String] = []
    var diagnostics: [String: Any] = [:]
}

func readDB(target: String) -> DBCheck {
    var result = DBCheck()
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
        result.error = "알림 DB를 열 수 없음 · 전체 디스크 접근 권한을 확인해 주세요"
        if let db { sqlite3_close(db) }
        return result
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 500)
    sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil)
    func columns(_ table: String) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { names.append(String(cString: name)) }
        }
        return names
    }
    guard Set(["app_id", "identifier"]).isSubset(of: Set(columns("app"))),
          Set(["rec_id", "app_id", "data", "delivered_date"]).isSubset(of: Set(columns("record"))) else {
        result.error = "이 macOS의 DB 구조는 추가 확인이 필요해요"
        result.headerKeys = columns("app").map { "app." + $0 } + columns("record").map { "record." + $0 }
        return result
    }
    // Aggregate metadata only. Never enumerate other applications' identities
    // or retrieve their notification payloads while investigating an empty match.
    func scalar(_ sql: String) -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int64(statement, 0)
    }
    result.diagnostics["totalApps"] = scalar("SELECT COUNT(*) FROM app")
    result.diagnostics["totalRecords"] = scalar("SELECT COUNT(*) FROM record")
    result.diagnostics["exactKakaoApps"] = scalar("SELECT COUNT(*) FROM app WHERE identifier='com.kakao.KakaoTalkMac'")
    result.diagnostics["recordColumns"] = columns("record")
    result.diagnostics["appColumns"] = columns("app")
    var metadata: OpaquePointer?
    let metadataSQL = "SELECT a.identifier, COUNT(r.rec_id) FROM app a LEFT JOIN record r ON r.app_id=a.app_id WHERE lower(a.identifier) LIKE '%kakao%' GROUP BY a.app_id,a.identifier"
    if sqlite3_prepare_v2(db, metadataSQL, -1, &metadata, nil) == SQLITE_OK {
        var candidates: [[String: Any]] = []
        while sqlite3_step(metadata) == SQLITE_ROW {
            if let identifier = sqlite3_column_text(metadata, 0) {
                candidates.append(["identifier": String(cString: identifier), "recordCount": sqlite3_column_int64(metadata, 1)])
            }
        }
        result.diagnostics["kakaoCandidates"] = candidates
    }
    sqlite3_finalize(metadata)
    if let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
        result.diagnostics["dbBytes"] = attributes[.size]
        if let modified = attributes[.modificationDate] as? Date {
            result.diagnostics["dbModifiedAt"] = ISO8601DateFormatter().string(from: modified)
        }
    }
    let sql = """
    SELECT r.rec_id, r.delivered_date, r.data FROM record r
    JOIN app a ON a.app_id = r.app_id
    WHERE a.identifier = 'com.kakao.KakaoTalkMac' COLLATE NOCASE
    ORDER BY r.rec_id DESC LIMIT 30
    """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        result.error = "카카오톡 기록 조회 실패"
        return result
    }
    defer { sqlite3_finalize(statement) }
    let target = target.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    var headerDiagnostics: [[String: Any]] = []
    var step = sqlite3_step(statement)
    while step == SQLITE_ROW {
        result.recordsChecked += 1
        let id = sqlite3_column_int64(statement, 0)
        result.latestID = max(result.latestID, id)
        if let bytes = sqlite3_column_blob(statement, 2) {
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
            if let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                let request = dictionary["req"] as? [String: Any] ?? [:]
                result.headerKeys = Array(request.keys).sorted()
                // The serialized record also contains the body; never inspect,
                // display, persist or log the body. Use only title/subtitle.
                let headers = [request["titl"] as? String, request["subt"] as? String].compactMap { $0 }
                // Temporary diagnosis: notification headers only, no message body
                // or opaque user-data values. Keep this local report out of Git.
                headerDiagnostics.append([
                    "recordID": id,
                    "deliveredAt": ISO8601DateFormatter().string(from: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1))),
                    "title": request["titl"] as? String ?? "",
                    "subtitle": request["subt"] as? String ?? "",
                    "titleType": request["titl"].map { String(describing: type(of: $0)) } ?? "missing",
                    "requestKeys": Array(request.keys).sorted(),
                    "userDataKeys": (request["usda"] as? [String: Any]).map { Array($0.keys).sorted() } ?? [],
                    "headerContainsTarget": !target.isEmpty && headers.contains { $0.precomposedStringWithCanonicalMapping.contains(target) }
                ])
                let matches = !target.isEmpty && headers.contains {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping == target
                }
                if matches {
                    result.matchingIDs.append(id)
                    if id > result.latestTargetID {
                        result.latestTargetID = id
                        result.latestTargetDate = sqlite3_column_double(statement, 1)
                    }
                }
            }
        }
        step = sqlite3_step(statement)
    }
    guard step == SQLITE_DONE else { result.error = "DB가 사용 중이거나 조회에 실패했어요"; return result }
    result.diagnostics["notificationHeaders"] = headerDiagnostics
    result.readable = true
    return result
}

final class DBCheckApp: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var name: NSTextField!
    var state: NSTextField!
    var details: NSTextField!
    var timer: Timer?
    var busy = false
    var baseline: Int64?
    var lastTarget = ""
    let queue = DispatchQueue(label: "TalkSignalDBCheck.read", qos: .utility)
    var reportPath: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configURL = Bundle.main.url(forResource: "DiagnosticConfig", withExtension: "json")
        let config = configURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        reportPath = config["reportPath"]
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 350), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "TalkSignal 알림 DB 검사"
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        func add(_ view: NSView) { stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let heading = NSTextField(labelWithString: "창을 열지 않는 알림 감지 테스트")
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        add(heading)
        name = NSTextField(string: config["target"] ?? "")
        name.placeholderString = "감지할 발신자 이름"
        name.setAccessibilityIdentifier("targetName")
        add(name)
        state = NSTextField(wrappingLabelWithString: "DB 권한 확인 중…")
        state.font = .systemFont(ofSize: 14, weight: .semibold)
        state.setAccessibilityIdentifier("dbStatus")
        add(state)
        details = NSTextField(wrappingLabelWithString: "")
        details.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        add(details)
        add(NSTextField(wrappingLabelWithString: "카톡 알림 제목·부제목을 판별해요. 원인 진단용 로컬 결과에는 제목·부제목과 시각을 기록해요. 메시지 본문은 출력·저장하지 않아요."))
        let permission = NSButton(title: "전체 디스크 접근 설정 열기…", target: self, action: #selector(openPermissions))
        permission.bezelStyle = .rounded
        add(permission)
        let quit = NSButton(title: "검사 종료", target: self, action: #selector(quit))
        quit.bezelStyle = .rounded
        add(quit)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil); return false
    }
    @objc func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
    @objc func quit() { NSApp.terminate(nil) }
    func poll() {
        guard !busy else { return }
        busy = true
        let target = name.stringValue
        if target != lastTarget { baseline = nil; lastTarget = target }
        queue.async {
            let start = Date()
            let result = readDB(target: target)
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
            // Window metadata only: no screenshots or UI activation.
            let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            func visible(_ bundleID: String) -> Int {
                let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map { Int($0.processIdentifier) })
                return onScreen.filter { pids.contains($0[kCGWindowOwnerPID as String] as? Int ?? -1) }.count
            }
            let kakaoVisible = visible("com.kakao.KakaoTalkMac")
            let ncVisible = visible("com.apple.notificationcenterui")
            DispatchQueue.main.async {
                self.busy = false
                guard target == self.name.stringValue else { return }
                if result.readable && self.baseline == nil { self.baseline = result.latestID }
                let newCount = result.matchingIDs.filter { $0 > (self.baseline ?? Int64.max) }.count
                let formatter = ISO8601DateFormatter()
                let targetDate = result.latestTargetDate > 0 ? formatter.string(from: Date(timeIntervalSinceReferenceDate: result.latestTargetDate)) : ""
                self.state.stringValue = result.readable ? (result.latestTargetID > 0 ? "지정한 발신자의 카톡 알림을 찾았어요" : "DB 조회 성공 · 일치하는 알림 없음") : result.error
                self.state.textColor = result.readable ? .systemGreen : .systemOrange
                self.details.stringValue = "검사 시작 후 새 일치 알림: \(newCount)개\n화면의 카톡 창: \(kakaoVisible) · 알림 센터 창: \(ncVisible)\n최근 일치 알림: \(targetDate.isEmpty ? "없음" : targetDate)"
                let report: [String: Any] = [
                    "checkedAt": formatter.string(from: Date()), "dbReadable": result.readable, "error": result.error,
                    "latestKakaoRecordID": result.latestID, "latestTargetRecordID": result.latestTargetID,
                    "latestTargetAt": targetDate, "baselineRecordID": self.baseline ?? -1,
                    "newTargetNotifications": newCount, "kakaoRecordsChecked": result.recordsChecked,
                    "headerKeys": result.headerKeys, "kakaoOnScreenWindows": kakaoVisible,
                    "notificationCenterOnScreenWindows": ncVisible, "frontmost": front,
                    "querySeconds": Date().timeIntervalSince(start),
                    "diagnostics": result.diagnostics
                ]
                if let path = self.reportPath, let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
                }
            }
        }
    }
}

@main struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = DBCheckApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
