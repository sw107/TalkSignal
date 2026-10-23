import AppKit

struct IconChoice {
    let title: String
    let symbol: String
    static let all: [IconChoice] = [
        .init(title: "말풍선", symbol: "bubble.left.fill"),
        .init(title: "하트", symbol: "heart.fill"),
        .init(title: "별", symbol: "star.fill"),
        .init(title: "종", symbol: "bell.fill"),
        .init(title: "편지", symbol: "envelope.fill"),
        .init(title: "발자국", symbol: "pawprint.fill"),
        .init(title: "달", symbol: "moon.fill"),
        .init(title: "사람", symbol: "person.fill"),
        .init(title: "직접 입력한 이모지", symbol: "emoji")
    ]
}

struct Preferences {
    var target: String
    var icon: String
    var emoji: String
    var showCount: Bool
    static func load() -> Preferences {
        let defaults = UserDefaults.standard
        let icon = defaults.string(forKey: "icon") ?? "bubble.left.fill"
        return .init(target: defaults.string(forKey: "target") ?? "",
                     icon: IconChoice.all.contains(where: { $0.symbol == icon }) ? icon : "bubble.left.fill",
                     emoji: defaults.string(forKey: "emoji") ?? "💌",
                     showCount: defaults.object(forKey: "showCount") as? Bool ?? true)
    }
    func save() {
        let defaults = UserDefaults.standard
        defaults.set(target, forKey: "target")
        defaults.set(icon, forKey: "icon")
        defaults.set(emoji, forKey: "emoji")
        defaults.set(showCount, forKey: "showCount")
    }
}

final class SettingsController: NSWindowController {
    private let name = NSTextField()
    private let icons = NSPopUpButton()
    private let emoji = NSTextField()
    private let count = NSButton(checkboxWithTitle: "메뉴바에 안 읽은 숫자도 표시", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let statusDot = NSTextField(labelWithString: "●")
    private let saveButton = NSButton(title: "저장하고 적용", target: nil, action: nil)
    var onSave: ((Preferences) -> Void)?
    var onPermission: (() -> Void)?

    init(preferences: Preferences) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "TalkSignal 설정"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        load(preferences)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }
    private func build() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])
        func add(_ view: NSView, full: Bool = true) {
            stack.addArrangedSubview(view)
            if full { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        add(label("소중한 연락, 메뉴바에서", size: 23, weight: .bold))
        add(label("지정한 채팅방에 안 읽은 메시지가 있으면 분홍색 점이 켜져요.", color: .secondaryLabelColor))
        stack.setCustomSpacing(24, after: stack.arrangedSubviews.last!)
        add(label("개인 이름 또는 채팅방 이름", weight: .semibold))
        name.placeholderString = "1:1 상대 이름 또는 단체 채팅방 이름"
        name.setAccessibilityIdentifier("targetName")
        name.setAccessibilityLabel("감지할 채팅방 이름")
        name.font = .systemFont(ofSize: 14)
        name.heightAnchor.constraint(equalToConstant: 30).isActive = true
        add(name)
        add(label("개인 이름은 1:1 채팅, 단체방 이름은 그 방 전체의 안 읽음을 확인해요. 띄어쓰기·이모지까지 같게 입력해 주세요. 같은 이름이 여러 방에 해당하면 감지를 중단해요.", size: 11, color: .secondaryLabelColor))
        stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
        add(label("메뉴바 아이콘", weight: .semibold))
        icons.addItems(withTitles: IconChoice.all.map(\.title))
        icons.target = self
        icons.action = #selector(iconChanged)
        icons.setAccessibilityIdentifier("iconChoice")
        icons.setAccessibilityLabel("메뉴바 아이콘")
        for (index, choice) in IconChoice.all.enumerated() where choice.symbol != "emoji" {
            let image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: choice.title)
            image?.size = NSSize(width: 16, height: 16)
            icons.item(at: index)?.image = image
        }
        add(icons)
        emoji.placeholderString = "예: 💌 · 🌷 · 🐱"
        emoji.setAccessibilityIdentifier("customEmoji")
        emoji.setAccessibilityLabel("직접 입력할 이모지")
        add(emoji)
        add(count)
        stack.setCustomSpacing(20, after: count)
        let separator = NSBox()
        separator.boxType = .separator
        add(separator)
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.setAccessibilityIdentifier("monitorStatus")
        let stateRow = NSStackView(views: [statusDot, status])
        stateRow.orientation = .horizontal
        stateRow.spacing = 8
        add(stateRow)
        add(label("카톡이 실행 중이면 창과 알림 센터를 닫아도 감지해요. 폰에서 읽은 상태가 Mac에 동기화되면 점과 숫자가 꺼져요.", size: 12, color: .secondaryLabelColor))
        let permission = NSButton(title: "전체 디스크 접근 설정…", target: self, action: #selector(permissionClicked))
        permission.bezelStyle = .rounded
        add(permission, full: false)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.setAccessibilityIdentifier("saveSettings")
        add(saveButton, full: false)
        add(label("전체 디스크 접근은 macOS의 넓은 권한이에요. 앱은 카톡 DB·설정과 기기 식별값을 사용하며, 메시지 본문 조회·외부 전송·수신 기록 저장은 하지 않아요.", size: 11, color: .secondaryLabelColor))
        window?.initialFirstResponder = name
    }
    func load(_ preferences: Preferences) {
        name.stringValue = preferences.target
        icons.selectItem(at: IconChoice.all.firstIndex(where: { $0.symbol == preferences.icon }) ?? 0)
        emoji.stringValue = preferences.emoji
        count.state = preferences.showCount ? .on : .off
        iconChanged()
    }
    func update(_ state: SignalState) {
        status.stringValue = state.message
        statusDot.textColor = state.isWarning ? .systemOrange : .secondaryLabelColor
        if case .ready(let unread) = state, unread.count > 0 { statusDot.textColor = .systemPink }
    }
    @objc private func iconChanged() { emoji.isHidden = icons.indexOfSelectedItem != IconChoice.all.count - 1 }
    @objc private func permissionClicked() { onPermission?() }
    @objc private func save() {
        let target = ChatParser.normalized(name.stringValue)
        guard !target.isEmpty else {
            status.stringValue = "감지할 채팅방 이름을 입력해 주세요."
            statusDot.textColor = .systemOrange
            window?.makeFirstResponder(name)
            return
        }
        let symbol = IconChoice.all[max(0, icons.indexOfSelectedItem)].symbol
        let glyph = String(emoji.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1))
        let preferences = Preferences(target: target, icon: symbol, emoji: glyph.isEmpty ? "💌" : glyph, showCount: count.state == .on)
        onSave?(preferences)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var preferences = Preferences.load()
    private var state: SignalState = .checking
    private var settings: SettingsController?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "TalkSignal.database", qos: .utility)
    private let reader = ChatReader()
    private var busy = false
    private var generation = 0
    private var lastCheck: Date?
    private var previewUntil = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launching TalkSignal must never launch or activate KakaoTalk.
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.setAccessibilityLabel("TalkSignal")
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(appearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.poll() }
        poll()
        if preferences.target.isEmpty { openSettings() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }
    @objc private func appearanceChanged() { DispatchQueue.main.async { self.render() } }
    private func poll() {
        guard !busy else { return }
        busy = true
        let target = preferences.target
        let version = generation
        queue.async {
            let result = self.reader.read(target: target) { message in
                DispatchQueue.main.async {
                    guard version == self.generation else { return }
                    self.state = .preparing(message)
                    self.settings?.update(self.state)
                    self.render()
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                guard version == self.generation else { self.poll(); return }
                self.state = result
                self.lastCheck = Date()
                self.settings?.update(result)
                self.render()
            }
        }
    }
    private func image(for state: SignalState) -> NSImage {
        let symbolName = preferences.icon
        let emoji = preferences.emoji
        let preview = Date() < previewUntil
        let hasUnread = preview || state.hasUnread
        let warning = !preview && state.isWarning
        let colored = hasUnread || warning || symbolName == "emoji"
        let result = NSImage(size: NSSize(width: 25, height: 20), flipped: false) { rect in
            if symbolName == "emoji" {
                (emoji as NSString).draw(at: NSPoint(x: 0, y: 0), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
            } else if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
                (symbol.withSymbolConfiguration(config) ?? symbol).draw(in: NSRect(x: 1, y: 2, width: 17, height: 16))
            }
            if hasUnread || warning {
                (hasUnread ? NSColor.systemPink : NSColor.systemOrange).setFill()
                NSBezierPath(ovalIn: NSRect(x: 19, y: 2, width: 6, height: 6)).fill()
            }
            return true
        }
        result.isTemplate = !colored
        return result
    }
    private func render() {
        guard let button = item?.button else { return }
        button.image = image(for: state)
        button.imagePosition = .imageLeading
        button.title = ""
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        if preferences.showCount, case .ready(let count) = state, count.count > 0 { button.title = " \(count.label)" }
        button.toolTip = "TalkSignal · \(preferences.target.isEmpty ? "설정 필요" : preferences.target)\n\(state.message)"
        button.setAccessibilityValue(state.message)
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector? = nil, key: String = "") -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.target = self
            menu.addItem(entry)
            return entry
        }
        _ = add(preferences.target.isEmpty ? "TalkSignal" : "감지 대상: \(preferences.target)")
        _ = add(state.message)
        if let lastCheck {
            let format = DateFormatter()
            format.dateFormat = "HH:mm:ss"
            _ = add("최근 확인 \(format.string(from: lastCheck))")
        }
        menu.addItem(.separator())
        _ = add("설정…", #selector(openSettings), key: ",")
        _ = add("지금 확인", #selector(refresh))
        _ = add("알림 표시 미리보기", #selector(preview))
        if state == .permission { _ = add("전체 디스크 접근 설정…", #selector(openPermissions)) }
        menu.addItem(.separator())
        _ = add("TalkSignal 종료", #selector(quit), key: "q")
        item.menu = menu
    }
    @objc private func refresh() {
        queue.async { self.reader.retry() }
        poll()
    }
    @objc private func preview() {
        previewUntil = Date().addingTimeInterval(4)
        render()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.render() }
    }
    @objc private func openSettings() {
        if settings == nil {
            settings = SettingsController(preferences: preferences)
            settings?.onSave = { [weak self] value in
                guard let self else { return }
                self.preferences = value
                value.save()
                self.generation += 1
                self.state = .checking
                self.settings?.update(self.state)
                self.render()
                self.refresh()
            }
            settings?.onPermission = { [weak self] in self?.openPermissions() }
        }
        settings?.update(state)
        settings?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func openPermissions() {
        // Explicit user action opens the system pane; the user grants permission.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main
struct TalkSignal {
    static func main() {
        if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--probe" {
            let reader = ChatReader()
            for _ in 0..<2 {
                let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
                let start = Date()
                let state = reader.read(target: CommandLine.arguments[2])
                let output: [String: Any] = ["state": state.message, "seconds": Date().timeIntervalSince(start),
                    "frontmostBefore": before,
                    "frontmostAfter": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"]
                let data = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
