import Foundation

@main
struct CoreTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            guard condition() else { fatalError(description) }
            checks += 1
        }
        check(ChatParser.matches("테스트💕", target: " 테스트💕 "), "trim exact name")
        check(!ChatParser.matches("테스트💕 회사", target: "테스트💕"), "no prefix match")
        check(!ChatParser.matches("", target: ""), "empty target")
        check(ChatParser.matches("가", target: "가"), "Korean normalization")
        let received = ChatReader.state(for: [RoomUnread(name: "테스트💕", unread: 1)])
        let read = ChatReader.state(for: [RoomUnread(name: "테스트💕", unread: 0)])
        check(received.hasUnread && !received.isWarning, "received activates pink indicator")
        check(!read.hasUnread && !read.isWarning && read == .ready(.zero), "phone sync to zero clears indicator")
        check(ChatReader.state(for: []).isWarning, "missing is unknown, not read")
        check(ChatReader.state(for: [.init(name: "test", unread: nil)]).isWarning, "null is unknown")
        check(ChatReader.state(for: [.init(name: "test", unread: -1)]).isWarning, "negative is unknown")
        check(ChatReader.state(for: [.init(name: "test", unread: 0), .init(name: "test", unread: 1)]).isWarning, "ambiguous name is unknown")
        check(SignalState.permission.isWarning && !SignalState.permission.hasUnread, "permission failure is not an unread result")
        check(SignalState.stopped.isWarning, "stopped Kakao is unknown")
        try runUnreadSelfTests()
        print("PASS: \(checks) name/state checks")
    }
}
