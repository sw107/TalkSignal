import AppKit
import CSQLCipher

final class UnreadCheckApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var target: NSTextField!
    private var state: NSTextField!
    private var details: NSTextField!
    private var timer: Timer?
    private var busy = false
    private var paused = false
    private var failures = 0
    private var reportURL: URL?
    private var lastSample = ""
    private let reader = LocalUnreadReader()
    private let queue = DispatchQueue(label: "TalkSignalUnreadCheck.read", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = Bundle.main.url(forResource: "Config", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        if let path = config["reportPath"] { reportURL = URL(fileURLWithPath: path) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "TalkSignal 카톡 안 읽음 검사"
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        func add(_ view: NSView) { stack.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let title = NSTextField(labelWithString: "카톡 자체 DB · 안 읽은 수 확인")
        title.font = .systemFont(ofSize: 20, weight: .bold); add(title)
        target = NSTextField(string: config["target"] ?? "")
        target.placeholderString = "채팅방 이름 또는 1:1 상대 이름"
        target.setAccessibilityIdentifier("targetRoom"); add(target)
        state = NSTextField(wrappingLabelWithString: "접근 권한 확인 중…")
        state.setAccessibilityIdentifier("unreadStatus")
        state.font = .systemFont(ofSize: 15, weight: .semibold); add(state)
        details = NSTextField(wrappingLabelWithString: "")
        details.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); add(details)
        add(NSTextField(wrappingLabelWithString: "채팅방 이름과 안 읽은 수만 조회해요. 메시지 본문 조회·전송과 DB 수정 기능은 없어요. 검사 결과는 이 Mac에만 저장돼요. 창을 닫아도 검사는 계속돼요."))
        let permissions = NSButton(title: "전체 디스크 접근 설정 열기…", target: self, action: #selector(openPermissions)); permissions.bezelStyle = .rounded; add(permissions)
        let retry = NSButton(title: "다시 검사", target: self, action: #selector(retry)); retry.bezelStyle = .rounded; add(retry)
        let quit = NSButton(title: "검사 종료", target: self, action: #selector(quit)); quit.bezelStyle = .rounded; add(quit)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return false }
    func applicationWillTerminate(_ notification: Notification) { reader.stop() }
    @objc private func openPermissions() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
    @objc private func retry() { paused = false; failures = 0; reader.resume(); poll() }
    @objc private func quit() { reader.stop(); NSApp.terminate(nil) }
    private func poll() {
        guard !busy, !paused else { return }
        let name = target.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { state.stringValue = "확인할 채팅방 이름을 입력해 주세요"; return }
        busy = true
        queue.async {
            let started = Date()
            var rooms: [RoomUnread] = []
            var failure: UnreadError?
            do { rooms = try self.reader.read(target: name) { message in
                DispatchQueue.main.async {
                    self.state.stringValue = message
                    if let url = self.reportURL,
                       let data = try? JSONSerialization.data(withJSONObject: [
                        "checkedAt": ISO8601DateFormatter().string(from: Date()),
                        "target": name, "status": message, "stage": "resolvingAccount",
                        "dbReadable": false, "unreadCount": NSNull()
                       ], options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: url, options: [.atomic])
                        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    }
                }
            } } catch let error as UnreadError { failure = error }
              catch { failure = .query }
            let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.kakao.KakaoTalkMac").map { Int($0.processIdentifier) })
            let visibleKakao = visible.filter { pids.contains($0[kCGWindowOwnerPID as String] as? Int ?? -1) }.count
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
            let diagnostics = self.reader.diagnostics
            DispatchQueue.main.async {
                self.busy = false
                guard self.target.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == name else { return }
                if failure == .identity || failure == .key || failure == .schema || failure == .ambiguousAccount {
                    self.failures += 1
                    if self.failures >= 3 { self.paused = true }
                } else if failure == nil { self.failures = 0 }
                let count = failure == nil && rooms.count == 1 ? rooms[0].unread : nil
                let status: String
                if let failure { status = failure.message + (self.paused ? " · 자동 검사 중지" : "") }
                else if rooms.isEmpty { status = "DB 조회 성공 · 일치하는 채팅방 없음" }
                else if rooms.count > 1 { status = "같은 이름의 방이 여러 개예요 · 대상을 확정할 수 없어요" }
                else if let count { status = count > 0 ? "안 읽은 메시지 \(count)개" : "안 읽은 메시지 없음 (0개)" }
                else { status = "안 읽은 수 형식을 확인할 수 없어요" }
                self.state.stringValue = status
                self.state.textColor = count == nil ? .systemOrange : .systemGreen
                let now = ISO8601DateFormatter().string(from: Date())
                self.details.stringValue = "확인 시각: \(now)\n화면의 카톡 창: \(visibleKakao) · 일치하는 방: \(rooms.count)개"
                let report: [String: Any] = ["checkedAt": now, "target": name,
                    "dbReadable": failure == nil, "status": status,
                    "matchCount": rooms.count, "unreadCount": count as Any? ?? NSNull(),
                    "kakaoOnScreenWindows": visibleKakao, "frontmost": front,
                    "querySeconds": Date().timeIntervalSince(started), "paused": self.paused,
                    "diagnostics": diagnostics]
                if let url = self.reportURL, let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: url, options: [.atomic])
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    let sampleKey = "\(name)|\(status)|\(rooms.count)"
                    if sampleKey != self.lastSample {
                        self.lastSample = sampleKey
                        let sample: [String: Any] = ["at": now, "target": name, "unreadCount": count as Any? ?? NSNull(), "status": status]
                        if let line = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]) {
                            let logURL = url.deletingPathExtension().appendingPathExtension("samples.jsonl")
                            if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                            if let handle = try? FileHandle(forWritingTo: logURL) {
                                defer { try? handle.close() }
                                _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line + Data([10]))
                            }
                        }
                    }
                }
            }
        }
    }
}

@main struct UnreadCheckMain {
    static func main() throws {
        if CommandLine.arguments.contains("--self-test") { try runUnreadSelfTests(); return }
        let app = NSApplication.shared
        let delegate = UnreadCheckApp()
        app.delegate = delegate; app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
