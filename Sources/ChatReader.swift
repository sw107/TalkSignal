import AppKit

// All calls except stop() are confined to the app's serial database queue.
final class ChatReader {
    private var database = LocalUnreadReader()
    private var processID: pid_t?
    private var failedSearches = 0
    private var paused: SignalState?
    private var resolvedRoom: RoomUnread?

    func stop() { database.stop() }
    func retry() { paused = nil; failedSearches = 0 }

    static func state(for rooms: [RoomUnread]) -> SignalState {
        guard !rooms.isEmpty else { return .missing }
        guard rooms.count == 1 else { return .failure("같은 이름의 채팅방이 여러 개라 구분할 수 없어요") }
        guard let count = rooms[0].unread, count >= 0 else { return .unavailable }
        return .ready(UnreadCount(count: count, isLowerBound: false))
    }

    // Always resolve again on the serial DB queue. Never reuse an old target/account route.
    func directChatDestination(target: String) -> Result<URL, ChatOpenError> {
        let state = read(target: target)
        guard case .ready = state else { return .failure(ChatOpenError(message: state.message)) }
        guard let url = resolvedRoom?.directChatURL else {
            return .failure(ChatOpenError(message: "바로 열기는 일반 1:1 채팅만 지원해요. 우클릭 메뉴의 ‘카카오톡 열기’를 이용해 주세요."))
        }
        return .success(url)
    }

    func read(target: String, progress: @escaping (String) -> Void = { _ in }) -> SignalState {
        resolvedRoom = nil
        guard !ChatParser.normalized(target).isEmpty else { return .unconfigured }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.kakao.KakaoTalkMac").first?.processIdentifier
        if pid != processID {
            database = LocalUnreadReader()
            processID = pid
            retry()
        }
        guard pid != nil else { return .stopped }
        if let paused { return paused }
        do {
            let rooms = try database.read(target: target, progress: progress)
            failedSearches = 0
            if rooms.count == 1 { resolvedRoom = rooms[0] }
            return Self.state(for: rooms)
        } catch let error as UnreadError {
            if error == .access { return .permission }
            let state = SignalState.failure(error.message)
            // Bound expensive discovery attempts; permission/transient query failures retry automatically.
            if error == .identity {
                failedSearches += 1
                if failedSearches >= 3 { paused = state }
            } else if [.key, .schema, .ambiguousAccount, .noDatabase].contains(error) {
                paused = state
            }
            return state
        } catch { return .unavailable }
    }
}

struct ChatOpenError: Error { let message: String }
