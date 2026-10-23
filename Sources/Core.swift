import Foundation

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

}

enum SignalState: Equatable {
    case unconfigured, permission, stopped, missing, unavailable, checking
    case ready(UnreadCount)
    case preparing(String), failure(String)

    var message: String {
        switch self {
        case .unconfigured: return "감지할 사람을 설정해 주세요"
        case .permission: return "TalkSignal의 전체 디스크 접근 권한이 필요해요"
        case .stopped: return "카카오톡이 실행 중이 아니에요"
        case .missing: return "지정한 이름을 카톡 DB에서 찾지 못했어요"
        case .unavailable: return "안 읽은 수를 확인할 수 없어요"
        case .checking: return "카톡의 안 읽은 수 확인 중…"
        case .preparing(let message), .failure(let message): return message
        case .ready(let count): return count.count > 0 ? "안 읽은 메시지 \(count.label)개" : "안 읽은 메시지가 없어요"
        }
    }

    var hasUnread: Bool {
        if case .ready(let unread) = self { return unread.count > 0 }
        return false
    }

    var isWarning: Bool {
        switch self {
        case .permission, .stopped, .missing, .unavailable, .failure: return true
        default: return false
        }
    }
}

