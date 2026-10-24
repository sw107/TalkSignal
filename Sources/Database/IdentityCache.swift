import Foundation
import Security

// One app-owned, non-synchronizing login-keychain item. Never enumerate keychain
// contents or persist the SQLCipher key, device UUID, account hash or messages.
final class IdentityCache {
    private let service: String
    init(service: String = "io.github.sw107.TalkSignal.startup-identity.v1") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "current-account",
         kSecAttrSynchronizable as String: false,
         // Legacy macOS login keychain works with this ad-hoc sandboxed build.
         // Deny interactive access: a locked/changed-signature item is a cache miss.
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
    static func validated(_ data: Data, matching hash: String, digest: (Int) -> String) -> Int? {
        guard data.count <= 20, !data.isEmpty,
              data.allSatisfy({ (48...57).contains($0) }),
              let text = String(data: data, encoding: .utf8), let id = Int(text), id > 0,
              String(id) == text, digest(id) == hash else { return nil }
        return id
    }
    func load(matching hash: String, digest: (Int) -> String) -> Int? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return Self.validated(data, matching: hash, digest: digest)
    }
    @discardableResult func save(verified id: Int) -> Bool {
        guard id > 0 else { return false }
        let value = Data(String(id).utf8)
        var request = query
        request[kSecValueData as String] = value
        request[kSecAttrLabel as String] = "TalkSignal 빠른 시작 계정 식별값"
        let status = SecItemAdd(request as CFDictionary, nil)
        if status == errSecSuccess { return true }
        guard status == errSecDuplicateItem else { return false }
        return SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary) == errSecSuccess
    }
    @discardableResult func remove() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
