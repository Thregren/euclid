import Darwin
import Foundation

/// Open path components relative to an already-open directory, refusing symlinks at every level.
/// fstat and the bounded read operate on the same descriptor, avoiding check/read path races.
package enum BoundedTileFile {
    package struct Entry: Sendable {
        package let name: String
        package let isDirectory: Bool
        package let isRegularFile: Bool
    }

    /// A bounded directory scan on descriptors, with the same no-symlink policy as tile reads.
    /// A truncated scan must not be mistaken for a complete geographic extent.
    package static func entries(root: URL, relativePath: String = "", limit: Int) throws -> [Entry] {
        let parts = relativePath.isEmpty ? [] : relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard limit > 0, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        var descriptor = open(root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for part in parts {
            let child = openat(descriptor, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let error = errno
            close(descriptor)
            guard child >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
            descriptor = child
        }
        guard let directory = fdopendir(descriptor) else {
            let error = errno; close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        defer { closedir(directory) }
        var result: [Entry] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return result
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard result.count < limit else { throw POSIXError(.EFBIG) }
            var info = stat()
            let valid = fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            result.append(Entry(name: name, isDirectory: valid && (info.st_mode & S_IFMT) == S_IFDIR,
                                isRegularFile: valid && (info.st_mode & S_IFMT) == S_IFREG))
        }
    }

    package static func read(root: URL, relativePath: String, maximumBytes: Int = 64 << 20) throws -> Data {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard maximumBytes > 0, !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        var descriptor = open(root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        for (index, part) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (index == parts.count - 1 ? O_NONBLOCK : O_DIRECTORY)
            let child = openat(descriptor, String(part), flags)
            guard child >= 0 else {
                if errno == ENOENT { throw CocoaError(.fileReadNoSuchFile) }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            close(descriptor); descriptor = child
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileReadUnknown) }
        guard info.st_size > 0 else { throw TileReadError.invalidImage }
        guard info.st_size <= maximumBytes else { throw TileReadError.tooLarge }
        var data = Data(count: Int(info.st_size))
        var position = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { throw TileReadError.invalidImage }
            while position < raw.count {
                try Task.checkCancellation()
                let count = pread(descriptor, base.advanced(by: position), raw.count - position, off_t(position))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
                position += count
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw TileReadError.unavailable }
        return data
    }
}
