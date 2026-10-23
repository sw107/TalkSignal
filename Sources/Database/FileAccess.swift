import Foundation
import Darwin

// No broad entitlement or fallback to Full Disk Access. Only two explicit user grants.
// All other personal file locations remain outside the App Sandbox.
final class FileAccess {
    enum Location: String, CaseIterable { case preferences, database }
    static let shared = FileAccess()
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let keyPrefix = "readonlyBookmark."
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    static var userHome: URL {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
    }
    static var kakaoLibrary: URL {
        userHome.appendingPathComponent("Library/Containers/com.kakao.KakaoTalkMac/Data/Library", isDirectory: true)
    }
    static func expected(_ location: Location) -> URL {
        kakaoLibrary.appendingPathComponent(location == .preferences ? "Preferences" : "Application Support/com.kakao.KakaoTalkMac", isDirectory: true)
    }
    static func valid(_ url: URL, for location: Location) -> Bool {
        // Do not accept an ancestor, a different application, or a redirected directory.
        let expected = expected(location).standardizedFileURL
        return url.standardizedFileURL.path == expected.path
            && url.resolvingSymlinksInPath().path == expected.path
    }
    var configured: Bool {
        lock.lock(); defer { lock.unlock() }
        return Location.allCases.allSatisfy { defaults.data(forKey: keyPrefix + $0.rawValue) != nil }
    }
    func save(_ urls: [Location: URL]) throws {
        var values: [Location: Data] = [:]
        for location in Location.allCases {
            guard let url = urls[location], Self.valid(url, for: location) else { throw UnreadError.access }
            values[location] = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                  includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        lock.lock(); defer { lock.unlock() }
        for (location, data) in values { defaults.set(data, forKey: keyPrefix + location.rawValue) }
    }
    func withReadAccess<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        let stored = Location.allCases.map { ($0, defaults.data(forKey: keyPrefix + $0.rawValue)) }
        lock.unlock()
        var accessed: [URL] = []
        defer { for url in accessed.reversed() { url.stopAccessingSecurityScopedResource() } }
        for (location, data) in stored {
            guard let data else { throw UnreadError.access }
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard Self.valid(url, for: location), url.startAccessingSecurityScopedResource() else { throw UnreadError.access }
            accessed.append(url)
            if stale {
                let renewed = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
                lock.lock(); defaults.set(renewed, forKey: keyPrefix + location.rawValue); lock.unlock()
            }
        }
        return try body()
    }
}
