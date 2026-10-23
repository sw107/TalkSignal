import AppKit
import ApplicationServices

// All methods must run on one serial queue. This reader never launches, activates,
// raises, scrolls or changes KakaoTalk, and never reads message preview text areas.
final class ChatReader {
    static let bundleID = "com.kakao.KakaoTalkMac"
    private var cachedRow: AXUIElement?
    private var cachedPID: pid_t?
    private var cachedTarget = ""
    private var deadline = Date.distantFuture
    private enum Failure: Error { case ax, deadline }

    private func get(_ element: AXUIElement, _ key: String) throws -> CFTypeRef {
        guard Date() < deadline else { throw Failure.deadline }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
              let value else { throw Failure.ax }
        return value
    }
    private func text(_ element: AXUIElement, _ key: String) throws -> String {
        guard let value = try get(element, key) as? String else { throw Failure.ax }
        return value
    }
    private func children(_ element: AXUIElement) throws -> [AXUIElement] {
        guard let result = try get(element, kAXChildrenAttribute) as? [AXUIElement] else { throw Failure.ax }
        return result
    }
    private func fields(_ row: AXUIElement) throws -> [ChatField] {
        var result: [ChatField] = []
        for cell in try children(row) {
            guard try text(cell, kAXRoleAttribute) == kAXCellRole else { continue }
            for node in try children(cell) {
                // Do not descend into the message-preview scroll area.
                guard try text(node, kAXRoleAttribute) == kAXStaticTextRole else { continue }
                let value = try text(node, kAXValueAttribute)
                // AXIdentifier is optional on unread badges.
                let identifier = (try? text(node, kAXIdentifierAttribute)) ?? ""
                result.append(ChatField(value: value, identifier: identifier))
            }
        }
        return result
    }
    private func findTable(_ element: AXUIElement, depth: Int = 0) throws -> AXUIElement? {
        guard depth < 8 else { return nil }
        let role = try text(element, kAXRoleAttribute)
        if role == kAXTableRole { return element }
        guard [kAXWindowRole, kAXScrollAreaRole, kAXGroupRole, kAXSplitGroupRole].contains(role) else { return nil }
        for child in try children(element) {
            if let table = try findTable(child, depth: depth + 1) { return table }
        }
        return nil
    }

    func read(target: String) -> SignalState {
        let target = ChatParser.normalized(target)
        guard !target.isEmpty else { return .unconfigured }
        guard AXIsProcessTrusted() else { return .permission }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            cachedRow = nil
            return .stopped
        }
        if cachedPID != app.processIdentifier || cachedTarget != target {
            cachedRow = nil
            cachedPID = app.processIdentifier
            cachedTarget = target
        }
        deadline = Date().addingTimeInterval(5)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        do {
            guard let windows = try get(root, kAXWindowsAttribute) as? [AXUIElement] else { return .unavailable }
            guard let main = windows.first(where: { (try? text($0, kAXIdentifierAttribute)) == "Main Window" }) else {
                cachedRow = nil
                return .closed
            }
            // Verify the chat list is still exposed even when using the cached row.
            guard let table = try findTable(main) else { cachedRow = nil; return .unavailable }
            if let cachedRow, let items = try? fields(cachedRow),
               let name = items.first?.value, ChatParser.matches(name, target: target),
               let count = ChatParser.unread(items) {
                return .ready(count)
            }
            cachedRow = nil
            let rows: [AXUIElement]
            if let exposedRows = try? get(table, kAXRowsAttribute) as? [AXUIElement] {
                rows = exposedRows
            } else {
                rows = try children(table)
            }
            for row in rows {
                guard try text(row, kAXRoleAttribute) == kAXRowRole else { continue }
                let items = try fields(row)
                guard let name = items.first?.value, ChatParser.matches(name, target: target) else { continue }
                guard let count = ChatParser.unread(items) else { return .unavailable }
                cachedRow = row
                return .ready(count)
            }
            return .missing
        } catch {
            cachedRow = nil
            return .unavailable
        }
    }
}

