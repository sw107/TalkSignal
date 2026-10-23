import Foundation
import Darwin
import IOKit

// Run only against the synthetic fixture created by test-sandbox.sh.
let path = CommandLine.arguments[1]
let readDenied = FileManager.default.contents(atPath: path) == nil
let descriptor = open(path, O_WRONLY) // never truncate or write, even if unexpectedly allowed
let writeDenied = descriptor < 0 && [EACCES, EPERM].contains(errno)
if descriptor >= 0 { close(descriptor) }
let sock = socket(AF_INET, SOCK_STREAM, 0)
var address = sockaddr_in()
address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
address.sin_family = sa_family_t(AF_INET)
address.sin_port = UInt16(9).bigEndian
address.sin_addr.s_addr = inet_addr("127.0.0.1")
let result = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
let networkDenied = result == -1 && [EPERM, EACCES].contains(errno)
close(sock)
let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
let identifierAvailable = entry != 0 && IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() is String
if entry != 0 { IOObjectRelease(entry) }
print("unselectedReadDenied=\(readDenied) writeDenied=\(writeDenied) networkDenied=\(networkDenied) deviceIdentifierAvailable=\(identifierAvailable)")
exit(readDenied && writeDenied && networkDenied && identifierAvailable ? 0 : 1)
