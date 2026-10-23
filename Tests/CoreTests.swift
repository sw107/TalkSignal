import Foundation

@main
struct CoreTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            guard condition() else { fatalError(description) }
            checks += 1
        }
        let name = ChatField(value: "테스트💕", identifier: "name")
        let time = ChatField(value: "오전 9:03", identifier: "time")
        check(ChatParser.matches("테스트💕", target: " 테스트💕 "), "trim exact name")
        check(!ChatParser.matches("테스트💕 회사", target: "테스트💕"), "no prefix match")
        check(!ChatParser.matches("", target: ""), "empty target")
        check(ChatParser.matches("가", target: "가"), "Korean normalization")
        check(ChatParser.unread([name, time]) == .zero, "no badge means zero")
        check(ChatParser.unread([name, time, .init(value: "2", identifier: "")]) == .init(count: 2, isLowerBound: false), "new message count")
        check(ChatParser.unread([name, time, .init(value: "99+", identifier: "")]) == .init(count: 99, isLowerBound: true), "capped badge")
        check(ChatParser.unread([name, .init(value: "10", identifier: "members"), time]) == .zero, "member count is not unread")
        check(ChatParser.unread([.init(value: "123", identifier: "name"), time]) == .zero, "numeric contact name")
        check(ChatParser.unread([name]) == nil, "partial row is unknown")
        check(ChatParser.unread([name, time, .init(value: "unexpected", identifier: "")]) == nil, "unknown badge is not zero")
        check(ChatParser.badge("99999999999999999999999999999") == nil, "overflow")
        check(ChatParser.badge("-1") == nil, "negative badge")
        check(ChatParser.badge("2 messages") == nil, "unknown format")
        check(SignalState.closed.isWarning && !SignalState.ready(.zero).isWarning, "unavailable differs from read")
        print("PASS: \(checks) checks")
    }
}
