import Foundation
import Darwin

// Serial-queue only. Keep only extracted account markers and filesystem metadata.
// A changed, replaced, unreadable or malformed preferences file never reuses old markers.
final class AccountMarkers {
    private struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        init(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw UnreadError.access }
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }
    private var stamps: [String: Stamp] = [:]
    private var markers: [String]?
    private(set) var parseCount = 0

    func read(folder: URL) throws -> [String] {
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter {
                $0.lastPathComponent.hasPrefix("com.kakao.KakaoTalkMac") && $0.pathExtension == "plist"
            }
            var current: [String: Stamp] = [:]
            for url in urls {
                guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { throw UnreadError.access }
                current[url.path] = try Stamp(url)
            }
            if current == stamps, let markers { return markers }
            var result: [String] = []
            for url in urls {
                let data = try Data(contentsOf: url)
                guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw UnreadError.query }
                parseCount += 1
                for (name, value) in plist where name.hasPrefix("DESIGNATEDFRIENDSREVISION:") {
                    if let revision = value as? NSNumber, revision.intValue != 0 { result.append(name) }
                }
                for name in ["userId", "user_id", "KAKAO_USER_ID", "userID"] {
                    if let value = plist[name] as? NSNumber { result.append(name + ":" + value.stringValue) }
                    else if let value = plist[name] as? String { result.append(name + ":" + value) }
                }
                guard try Stamp(url) == current[url.path] else { throw UnreadError.query }
            }
            stamps = current; markers = Array(Set(result)).sorted()
            return markers!
        } catch {
            stamps = [:]; markers = nil
            if let error = error as? UnreadError { throw error }
            throw UnreadError.access
        }
    }
}
