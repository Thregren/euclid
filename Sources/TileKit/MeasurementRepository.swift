import Foundation

/// Each dataset owns its document; user measurements are not an evictable cache.
public actor MeasurementRepository {
    private struct Document: Codable {
        var version = 1
        let datasetPath: String
        let updatedAt: Date
        let measurements: [GeoMeasurement]
    }
    private struct LegacyEntry: Codable { let updatedAt: Date; let measurements: [GeoMeasurement] }
    private struct Legacy: Codable { let entries: [String: LegacyEntry] }
    public let directory: URL
    private let legacyURL: URL
    private var notice: String?

    public init(legacyURL: URL) {
        self.legacyURL = legacyURL
        directory = legacyURL.deletingPathExtension().appendingPathExtension("datasets")
    }
    public func documentURL(for datasetPath: String) -> URL {
        directory.appending(path: FileIdentity.hash(datasetPath) + ".json")
    }
    public func measurements(for datasetPath: String) -> [GeoMeasurement] {
        measurementsIfPresent(for: datasetPath) ?? []
    }
    /// A missing document differs from an explicitly saved empty document during session recovery.
    public func measurementsIfPresent(for datasetPath: String) -> [GeoMeasurement]? {
        let url = documentURL(for: datasetPath)
        if let loaded = RecoverableFile.read(Document.self, from: url, validate: {
            $0.version == 1 && $0.datasetPath == datasetPath
        }) {
            if loaded.recovered { notice = "测量存档已从上一份备份恢复" }
            return loaded.value.measurements
        }
        if FileManager.default.fileExists(atPath: url.path) {
            notice = "测量存档读不出来，原文件已保留；请检查存档与备份"
            return nil
        }
        if let legacy = RecoverableFile.read(Legacy.self, from: legacyURL) {
            return legacy.value.entries[datasetPath]?.measurements
        }
        return nil
    }
    public func save(_ measurements: [GeoMeasurement], for datasetPath: String) throws {
        let document = Document(datasetPath: datasetPath, updatedAt: Date(), measurements: measurements)
        let url = documentURL(for: datasetPath)
        // Preserve unreadable current data before starting a new generation.
        if FileManager.default.fileExists(atPath: url.path),
           RecoverableFile.read(Document.self, from: url, validate: { $0.version == 1 && $0.datasetPath == datasetPath }) == nil {
            let copy = url.appendingPathExtension("corrupt-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: url, to: copy)
        }
        try RecoverableFile.write(JSONEncoder().encode(document), to: url)
    }
    public func takeNotice() -> String? { defer { notice = nil }; return notice }
}
