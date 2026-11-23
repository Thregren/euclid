import Foundation

/// ZIP64 writer with a disk-backed central directory. Memory is bounded by one input tile.
public final class StreamingZipWriter {
    private let handle: FileHandle
    private let central: FileHandle
    private let centralURL: URL
    private var offset: UInt64 = 0
    private var count: UInt64 = 0
    private var closed = false
    public init(url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        centralURL = url.appendingPathExtension("directory-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              FileManager.default.createFile(atPath: centralURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
        central = try FileHandle(forUpdating: centralURL)
    }
    deinit {
        try? handle.close(); try? central.close()
        try? FileManager.default.removeItem(at: centralURL)
    }
    public func append(name: String, data: Data) throws {
        try Task.checkCancellation()
        guard !closed, !name.hasPrefix("/"), !name.split(separator: "/").contains(".."),
              name.utf8.count <= 65_535, data.count <= ZipArchive.maximumEntryBytes else { throw CocoaError(.fileWriteInvalidFileName) }
        let bytes = Data(name.utf8), size = UInt64(data.count), crc = ZIP.crc32(data)
        var header = Data()
        header.zip32(0x04034b50); header.zip16(45); header.zip16(0x800); header.zip16(0)
        header.zip16(0); header.zip16(0); header.zip32(crc); header.zip32(.max); header.zip32(.max)
        header.zip16(UInt16(bytes.count)); header.zip16(20); header.append(bytes)
        header.zip16(1); header.zip16(16); header.zip64(size); header.zip64(size)
        try handle.write(contentsOf: header); try handle.write(contentsOf: data)
        var entry = Data()
        entry.zip32(0x02014b50); entry.zip16(45); entry.zip16(45); entry.zip16(0x800); entry.zip16(0)
        entry.zip16(0); entry.zip16(0); entry.zip32(crc); entry.zip32(.max); entry.zip32(.max)
        entry.zip16(UInt16(bytes.count)); entry.zip16(28); entry.zip16(0); entry.zip16(0); entry.zip16(0)
        entry.zip32(0); entry.zip32(.max); entry.append(bytes)
        entry.zip16(1); entry.zip16(24); entry.zip64(size); entry.zip64(size); entry.zip64(offset)
        try central.write(contentsOf: entry)
        offset += UInt64(header.count) + size; count += 1
    }
    public func finish() throws {
        guard !closed else { return }
        let start = offset
        let length = try central.offset()
        try central.seek(toOffset: 0)
        while let bytes = try central.read(upToCount: 2 << 20), !bytes.isEmpty {
            try Task.checkCancellation(); try handle.write(contentsOf: bytes); offset += UInt64(bytes.count)
        }
        var footer = Data()
        let zip64Offset = offset
        footer.zip32(0x06064b50); footer.zip64(44); footer.zip16(45); footer.zip16(45)
        footer.zip32(0); footer.zip32(0); footer.zip64(count); footer.zip64(count); footer.zip64(length); footer.zip64(start)
        footer.zip32(0x07064b50); footer.zip32(0); footer.zip64(zip64Offset); footer.zip32(1)
        footer.zip32(0x06054b50); footer.zip16(0); footer.zip16(0); footer.zip16(.max); footer.zip16(.max)
        footer.zip32(.max); footer.zip32(.max); footer.zip16(0)
        try handle.write(contentsOf: footer); try handle.synchronize(); try handle.close(); try central.close()
        try FileManager.default.removeItem(at: centralURL)
        closed = true
    }
}
private extension Data {
    mutating func zip16(_ value: UInt16) { var value = value.littleEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
    mutating func zip32(_ value: UInt32) { var value = value.littleEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
    mutating func zip64(_ value: UInt64) { var value = value.littleEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
}
