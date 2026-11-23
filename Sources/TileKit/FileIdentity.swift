import Darwin
import Foundation

/// Shared cache identity: path, inode, device, size and nanosecond modification time.
public struct FileIdentity: Codable, Hashable, Sendable {
    public let path: String
    public let device: Int32
    public let inode: UInt64
    public let bytes: Int64
    public let seconds: Int64
    public let nanoseconds: Int64

    public init?(url: URL) {
        let path = url.resolvingSymlinksInPath().canonicalFilePath
        var value = stat()
        guard Darwin.lstat(path, &value) == 0 else { return nil }
        self.path = path
        device = value.st_dev
        inode = value.st_ino
        bytes = value.st_size
        seconds = Int64(value.st_mtimespec.tv_sec)
        nanoseconds = Int64(value.st_mtimespec.tv_nsec)
    }

    public var cacheKey: String {
        "\(Self.hash(path))-\(device)-\(inode)-\(bytes)-\(seconds)-\(nanoseconds)"
    }

    public static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x100000001b3 }
        return String(value, radix: 16)
    }
}
