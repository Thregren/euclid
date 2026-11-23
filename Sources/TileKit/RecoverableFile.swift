import Darwin
import Foundation

/// Atomic documents with three previous generations. Never deletes the source on read failure.
public enum RecoverableFile {
    public static let maximumDocumentBytes = 64 * 1024 * 1024

    public static func write(_ data: Data, to url: URL, backups: Int = 3) throws {
        guard data.count <= maximumDocumentBytes else { throw RecoverableFileError.tooLarge }
        guard (0...32).contains(backups) else { throw POSIXError(.EINVAL) }
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: url.path), backups > 0 {
            let previous = try boundedData(from: url, maximumBytes: Int64(maximumDocumentBytes))
            for index in stride(from: backups, through: 2, by: -1) {
                let prior = backupURL(url, index: index - 1)
                if manager.fileExists(atPath: prior.path) {
                    let bytes = try boundedData(from: prior, maximumBytes: Int64(maximumDocumentBytes))
                    try writePrivate(bytes, to: backupURL(url, index: index))
                }
            }
            try writePrivate(previous, to: backupURL(url, index: 1))
        }
        try writePrivate(data, to: url)
    }
    public static func backupURL(_ url: URL, index: Int) -> URL {
        url.appendingPathExtension("backup-\(index)")
    }
    public static func read<T: Decodable>(
        _ type: T.Type, from url: URL, maximumBytes: Int64 = 64 * 1024 * 1024,
        validate: (T) -> Bool = { _ in true }
    ) -> (value: T, recovered: Bool)? {
        for index in 0...3 {
            let candidate = index == 0 ? url : backupURL(url, index: index)
            if let data = try? boundedData(from: candidate, maximumBytes: maximumBytes),
               let value = try? JSONDecoder().decode(type, from: data), validate(value) {
                return (value, index != 0)
            }
        }
        return nil
    }

    public static func boundedData(from url: URL, maximumBytes: Int64 = 64 * 1024 * 1024) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int64(Int.max) else { throw POSIXError(.EINVAL) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var information = stat()
        guard Darwin.fstat(handle.fileDescriptor, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard information.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        guard information.st_size >= 0, information.st_size <= maximumBytes else { throw RecoverableFileError.tooLarge }
        let data = try handle.read(upToCount: Int(maximumBytes) + 1) ?? Data()
        guard data.count <= maximumBytes else { throw RecoverableFileError.tooLarge }
        return data
    }

    /// Create the temporary file with owner-only permissions before any private bytes reach disk.
    private static func writePrivate(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let directory = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(directory) }
        guard Darwin.fsync(directory) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

public enum RecoverableFileError: LocalizedError {
    case tooLarge
    public var errorDescription: String? { "存档或备份超过 64 MiB 限额；原文件已保留" }
}
