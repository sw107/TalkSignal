import Foundation

struct ChatField {
    let value: String
    let identifier: String
}

struct UnreadCount: Equatable {
    let count: Int
    let isLowerBound: Bool
    var label: String { "\(count)" + (isLowerBound ? "+" : "") }
    static let zero = UnreadCount(count: 0, isLowerBound: false)
}

enum ChatParser {
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    static func matches(_ name: String, target: String) -> Bool {
        let target = normalized(target)
        return !target.isEmpty && normalized(name) == target
    }

    static func badge(_ text: String) -> UnreadCount? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerBound = text.hasSuffix("+")
        let digits = lowerBound ? String(text.dropLast()) : text
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int(digits), count > 0 else { return nil }
        return UnreadCount(count: count, isLowerBound: lowerBound)
    }

    // KakaoTalk exposes name, timestamp and unread badge as separate static texts.
    // The badge has no AXIdentifier; name/timestamp/member-count fields have IDs.
    // Require a timestamp/metadata field so a partial row is never reported as read.
    static func unread(_ fields: [ChatField]) -> UnreadCount? {
        guard fields.count >= 2 else { return nil }
        let anonymous = fields.dropFirst().filter { $0.identifier.isEmpty && !$0.value.isEmpty }
        if anonymous.isEmpty { return .zero }
        guard anonymous.count == 1 else { return nil }
        return badge(anonymous[0].value)
    }
}

enum SignalState: Equatable {
    case unconfigured, permission, stopped, closed, missing, unavailable, checking
    case ready(UnreadCount)

    var message: String {
        switch self {
        case .unconfigured: return "감지할 사람을 설정해 주세요"
        case .permission: return "손쉬운 사용 권한이 필요해요"
        case .stopped: return "카카오톡이 실행 중이 아니에요"
        case .closed: return "카톡 채팅 목록을 열고 최소화해 주세요"
        case .missing: return "지정한 채팅방을 목록에서 찾지 못했어요"
        case .unavailable: return "채팅 목록을 확인할 수 없어요"
        case .checking: return "채팅 목록 확인 중…"
        case .ready(let count): return count.count > 0 ? "안 읽은 메시지 \(count.label)개" : "안 읽은 메시지가 없어요"
        }
    }

    var isWarning: Bool {
        switch self {
        case .permission, .stopped, .closed, .missing, .unavailable: return true
        default: return false
        }
    }
}

