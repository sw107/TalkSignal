import AppKit
import ApplicationServices

// Explicit user clicks only. Read window titles and direct row-name labels;
// never inspect message preview areas or the conversation's editor/history.
final class ChatOpener {
    static var hasPermission: Bool { AXIsProcessTrusted() }
    private static let bundleID = "com.kakao.KakaoTalkMac"
    private struct Failure: Error { let message: String }
    private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }
    private static func text(_ element: AXUIElement, _ key: String) -> String {
        value(element, key) as? String ?? ""
    }
    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    private static func find(_ element: AXUIElement, role: String, depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }
        let currentRole = text(element, kAXRoleAttribute)
        if currentRole == role { return element }
        // No descent into rows or message previews/editors.
        guard [kAXWindowRole, kAXGroupRole, kAXScrollAreaRole, kAXSplitGroupRole].contains(currentRole) else { return nil }
        for child in children(element) {
            if let result = find(child, role: role, depth: depth + 1) { return result }
        }
        return nil
    }
    private static func rowName(_ row: AXUIElement) -> String? {
        for cell in children(row) where text(cell, kAXRoleAttribute) == kAXCellRole {
            for label in children(cell) where text(label, kAXRoleAttribute) == kAXStaticTextRole {
                return text(label, kAXValueAttribute)
            }
        }
        return nil
    }
    private static func key(_ code: CGKeyCode, flags: CGEventFlags = [], pid: pid_t) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw Failure(message: "카톡에 키 입력을 전달하지 못했어요")
        }
        down.flags = flags; up.flags = flags
        down.postToPid(pid); up.postToPid(pid)
    }
    static func open(name: String, applicationURL: URL, isCurrent: @escaping () -> Bool,
                     completion: @escaping (String?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { application, error in
            guard error == nil, let application else {
                DispatchQueue.main.async { completion("카카오톡을 열지 못했어요") }; return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let pid = application.processIdentifier
                let root = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(root, 0.3)
                func windows() -> [AXUIElement] { value(root, kAXWindowsAttribute) as? [AXUIElement] ?? [] }
                func ensureCurrent() throws {
                    let current = DispatchQueue.main.sync { isCurrent() }
                    guard current else { throw Failure(message: "설정이 바뀌어 채팅방 열기를 취소했어요") }
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                        throw Failure(message: "다른 앱으로 전환되어 채팅방 열기를 멈췄어요. 다시 클릭해 주세요.")
                    }
                }
                func mainWindow() -> AXUIElement? { windows().first { text($0, kAXIdentifierAttribute) == "Main Window" } }
                do {
                    // Wait for Launch Services to restore a closed/minimized main window.
                    for _ in 0..<30 {
                        if mainWindow() != nil && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    try ensureCurrent()
                    guard let main = mainWindow() else { throw Failure(message: "카톡 채팅 목록 창을 찾지 못했어요") }
                    AXUIElementSetAttributeValue(main, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    guard AXUIElementPerformAction(main, kAXRaiseAction as CFString) == .success else {
                        throw Failure(message: "카톡 채팅 목록을 앞으로 가져오지 못했어요")
                    }
                    // Cmd-2 and Cmd-F operate on the main window; no message editor typing.
                    try key(19, flags: .maskCommand, pid: pid)
                    Thread.sleep(forTimeInterval: 0.15)
                    try ensureCurrent()
                    try key(3, flags: .maskCommand, pid: pid)
                    var search: AXUIElement?
                    for _ in 0..<20 {
                        search = find(main, role: kAXTextFieldRole)
                        if search != nil { break }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    try ensureCurrent()
                    guard let search,
                          text(search, kAXSubroleAttribute) == kAXSearchFieldSubrole,
                          AXUIElementSetAttributeValue(search, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
                          let focusedSearch = value(root, kAXFocusedUIElementAttribute), CFEqual(focusedSearch, search) else {
                        throw Failure(message: "카톡 채팅방 검색란을 확인하지 못했어요")
                    }
                    // Setting AXValue alone can change the visible string without firing
                    // Kakao's search handler. Generate normal editing events in the verified search field.
                    try key(0, flags: .maskCommand, pid: pid)
                    try ensureCurrent()
                    guard let stillFocused = value(root, kAXFocusedUIElementAttribute), CFEqual(stillFocused, search) else {
                        throw Failure(message: "검색 입력 위치가 바뀌어 열기를 취소했어요")
                    }
                    let units = Array(name.utf16)
                    guard !units.isEmpty, units.count <= 512,
                          let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                          let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                        throw Failure(message: "채팅방 이름을 검색란에 입력하지 못했어요")
                    }
                    units.withUnsafeBufferPointer { buffer in
                        down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                        up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                    }
                    down.postToPid(pid); up.postToPid(pid)
                    // Reacquire the result table during asynchronous search. A fixed 0.4 s
                    // delay missed results when starting with an empty/closed chat list.
                    var readyTable: AXUIElement?
                    var readyRow: AXUIElement?
                    var stableMatches = 0
                    for _ in 0..<40 {
                        Thread.sleep(forTimeInterval: 0.15)
                        try ensureCurrent()
                        guard let currentMain = mainWindow(),
                              ChatParser.matches(text(search, kAXValueAttribute), target: name),
                              let table = find(currentMain, role: kAXTableRole) else {
                            stableMatches = 0; continue
                        }
                        let rows = value(table, kAXRowsAttribute) as? [AXUIElement] ?? children(table)
                        let matches = rows.filter { row in
                            text(row, kAXRoleAttribute) == kAXRowRole && rowName(row).map { ChatParser.matches($0, target: name) } == true
                        }
                        guard matches.count == 1, let row = matches.first else {
                            stableMatches = 0; continue
                        }
                        stableMatches += 1
                        if stableMatches >= 3 { readyTable = table; readyRow = row; break }
                    }
                    guard let table = readyTable, let row = readyRow else {
                        throw Failure(message: "검색 결과에서 ‘\(name)’ 방 하나를 확인하지 못했어요. 카톡 검색 결과를 확인해 주세요.")
                    }
                    guard AXUIElementSetAttributeValue(table, kAXSelectedRowsAttribute as CFString, [row] as CFArray) == .success,
                          AXUIElementSetAttributeValue(table, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else {
                        throw Failure(message: "대상 채팅방을 선택하지 못했어요")
                    }
                    // Enter is permitted only with the list focused and exactly the validated row selected.
                    try ensureCurrent()
                    guard let focused = value(root, kAXFocusedUIElementAttribute), CFEqual(focused, table),
                          let selected = value(table, kAXSelectedRowsAttribute) as? [AXUIElement], selected.count == 1,
                          CFEqual(selected[0], row), rowName(row).map({ ChatParser.matches($0, target: name) }) == true else {
                        throw Failure(message: "채팅 목록의 선택 상태가 바뀌어 열기를 취소했어요")
                    }
                    try key(36, pid: pid)
                    var opened = false
                    for _ in 0..<30 {
                        opened = windows().contains { text($0, kAXIdentifierAttribute) != "Main Window" && ChatParser.matches(text($0, kAXTitleAttribute), target: name) }
                        if opened { break }
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    guard opened else { throw Failure(message: "대상 채팅방 창이 열린 것을 확인하지 못했어요. 카톡 상태를 확인해 주세요.") }
                    DispatchQueue.main.async { completion(nil) }
                } catch let failure as Failure {
                    DispatchQueue.main.async { completion(failure.message) }
                } catch {
                    DispatchQueue.main.async { completion("채팅방을 열지 못했어요") }
                }
            }
        }
    }
}
