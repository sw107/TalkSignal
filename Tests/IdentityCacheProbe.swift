import Foundation

@main struct IdentityCacheProbe {
    static func main() {
        // Isolated synthetic service only. No personal keychain item is queried.
        let service = CommandLine.arguments[1]
        precondition(service.hasPrefix("io.github.sw107.TalkSignal.synthetic-cache-test."))
        let store = IdentityCache(service: service)
        let digest: (Int) -> String = { "synthetic-\($0)" }
        if CommandLine.arguments[2] == "seed" {
            precondition(store.save(verified: 101), "synthetic keychain add")
            precondition(store.save(verified: 202), "synthetic keychain update")
            print("PASS: sandboxed synthetic keychain add/update")
        } else {
            precondition(store.load(matching: "synthetic-202", digest: digest) == 202, "restart must reuse cached identity")
            precondition(store.load(matching: "synthetic-303", digest: digest) == nil, "wrong account must not reuse")
            precondition(store.remove(), "synthetic keychain cleanup")
            precondition(store.load(matching: "synthetic-202", digest: digest) == nil, "removed cache must miss")
            print("PASS: fresh-process cache reuse, wrong-account rejection and synthetic cleanup")
        }
    }
}
