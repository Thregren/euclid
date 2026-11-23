import Foundation

/// Versioned, disposable directory-run index. Old indexes are rebuilt automatically.
package enum ZipIndexCache {
    package struct Payload: Codable {
        package var rowSpans: [String: [ZipDirectorySpan]]
        package var entryCount: Int
        package var centralDirectorySize: UInt64
        package var isZip64: Bool
    }
    private struct Envelope: Codable {
        var version = 2
        let identity: FileIdentity
        let payload: Payload
    }
    private static let maximumFileBytes = 32 << 20
    private static var directory: URL? {
        if let path = TileKitTrace.zipIndexCacheDirectory { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "Euclid/zip-index", directoryHint: .isDirectory)
    }
    package static func load(for url: URL, fileSize: UInt64) -> Payload? {
        guard let identity = FileIdentity(url: url), identity.bytes >= 0, UInt64(identity.bytes) == fileSize,
              let file = directory?.appending(path: identity.cacheKey + ".idx"),
              let attrs = try? file.resourceValues(forKeys: [.fileSizeKey]),
              let size = attrs.fileSize, size <= maximumFileBytes,
              let data = try? Data(contentsOf: file),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 2, envelope.identity == identity else { return nil }
        let payload = envelope.payload
        guard payload.entryCount >= 0, payload.centralDirectorySize <= fileSize,
              !payload.rowSpans.isEmpty,
              payload.rowSpans.values.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.end >= $0.start && $0.end <= fileSize } }) else { return nil }
        return payload
    }
    package static func save(rowSpans: [String: [ZipDirectorySpan]], entryCount: Int,
                             centralDirectorySize: UInt64, isZip64: Bool, for url: URL, fileSize: UInt64) {
        guard let directory, let identity = FileIdentity(url: url), identity.bytes >= 0, UInt64(identity.bytes) == fileSize else { return }
        let payload = Payload(rowSpans: rowSpans, entryCount: entryCount,
                              centralDirectorySize: centralDirectorySize, isZip64: isZip64)
        guard let data = try? JSONEncoder().encode(Envelope(identity: identity, payload: payload)), data.count <= maximumFileBytes else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: identity.cacheKey + ".idx"), options: .atomic)
        DiskCacheMaintenance.prune(directory: directory, suffix: "idx", maximumFiles: 128, maximumBytes: 64 << 20)
    }
}
