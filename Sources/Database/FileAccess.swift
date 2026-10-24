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
    private var resolved: [Location: (data: Data, url: URL)] = [:]
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
        resolved.removeAll()
    }
    func withReadAccess<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        let stored = Location.allCases.map { ($0, defaults.data(forKey: keyPrefix + $0.rawValue)) }
        lock.unlock()
        var accessed: [URL] = []
        defer { for url in accessed.reversed() { url.stopAccessingSecurityScopedResource() } }
        for (location, data) in stored {
            guard let data else { throw UnreadError.access }
            lock.lock(); let cached = resolved[location]; lock.unlock()
            let url: URL
            var stale = false
            if let cached, cached.data == data { url = cached.url }
            else {
                url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            guard Self.valid(url, for: location), url.startAccessingSecurityScopedResource() else { throw UnreadError.access }
            accessed.append(url)
            var cacheData = data
            if stale {
                let renewed = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
                lock.lock(); defaults.set(renewed, forKey: keyPrefix + location.rawValue); lock.unlock()
                cacheData = renewed
            }
            // Cache only URL resolution. Revalidate the exact path and acquire/release
            // its existing read-only security scope for every read, including cache hits.
            lock.lock(); resolved[location] = (cacheData, url); lock.unlock()
        }
        return try body()
    }
}
