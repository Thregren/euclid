import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 无概览大图的持久化概览缓存。
///
/// 上亿像素的正射影像如果 TIFF 里没带内建概览，「适应窗口」那一屏要把整幅影像
/// 逐块解一遍、再缩到屏幕上 —— 每开一次就要几十秒，转个层级还会再来一遍。
///
/// 这里把**第一次**算出来的降采样快照（长边 ≤ 2048）写到磁盘：
/// 之后再打开这份影像，低层级直接用这张小图铺，几乎瞬开。
/// 缓存键带文件路径、大小与修改时间，影像被替换掉就会自动失效。
public actor RasterOverviewCache {
    public static let shared = RasterOverviewCache()

    /// 概览长边（像素）。2048 铺满一屏绰绰有余，内存与磁盘都压得住。
    public static let maximumPixelSize = 2048
    /// 小于这个像素数的影像不值得做概览（直接解也很快）。
    static let minimumPixelCount = 40_000_000
    /// 磁盘上最多留这么多字节的概览，超了按最久没用清掉。
    static let diskBudgetBytes = 256 << 20

    /// 内存里保留的概览图（最近用到的两份）。
    private var memory: [String: CGImage] = [:]
    private var memoryOrder: [String] = []
    /// 正在生成 / 已失败的键，避免同一份影像被反复排队。
    private var inFlight: Set<String> = []
    private var failed: Set<String> = []
    /// 概览生成好之后通知界面重铺（由 App 层注入；TileKit 不认识 UI）。
    public var onReady: (@Sendable (URL) -> Void)?

    private let directory: URL?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        directory = base?
            .appending(path: "Euclid", directoryHint: .isDirectory)
            .appending(path: "overviews", directoryHint: .isDirectory)
    }

    // MARK: - 读

    /// 已经就绪的概览图（内存里有；没有就顺手读一次磁盘）。没有则 nil，**不阻塞**。
    ///
    /// 没就绪时把生成任务排到后台，生成完通过 `onReady` 通知。
    public func readyImage(for dataset: RasterDataset) -> CGImage? {
        readyImage(fileURL: dataset.fileURL, tileSize: dataset.tileSize)
    }

    /// 同上，直接给文件与瓦片边长（铺瓦片时手上只有这两个）。
    public func readyImage(fileURL: URL, tileSize: Int) -> CGImage? {
        let key = Self.key(fileURL: fileURL, tileSize: tileSize)
        if let cached = memory[key] {
            touch(key)
            return cached
        }
        if let image = loadFromDisk(key: key) {
            store(image, key: key)
            return image
        }
        return nil
    }

    /// 这份影像值不值得做概览（够大、且 TIFF 没带内建概览）。
    public static func qualifies(_ dataset: RasterDataset) -> Bool {
        guard !dataset.hasOverviews, dataset.isGeoreferenced else { return false }
        return dataset.pixelWidth * dataset.pixelHeight >= minimumPixelCount
    }

    /// 只按尺寸判断（铺瓦片时手上没有整份 `RasterDataset`）。
    public static func qualifiesLargeImage(pixelWidth: Int, pixelHeight: Int) -> Bool {
        pixelWidth * pixelHeight >= minimumPixelCount
    }

    /// 排队生成概览（已经在做 / 已经有了 / 做过了就不重复排）。
    public func scheduleGeneration(for dataset: RasterDataset) {
        guard Self.qualifies(dataset) else { return }
        scheduleGeneration(fileURL: dataset.fileURL, tileSize: dataset.tileSize) {
            dataset.renderOverview(maxPixelSize: Self.maximumPixelSize)
        }
    }

    /// 排队生成概览：生成动作由调用方给（缓存本身不认识影像格式）。
    public func scheduleGeneration(
        fileURL: URL,
        tileSize: Int,
        render: @escaping @Sendable () -> CGImage?
    ) {
        let key = Self.key(fileURL: fileURL, tileSize: tileSize)
        guard memory[key] == nil, !inFlight.contains(key), !failed.contains(key) else { return }
        if loadFromDisk(key: key) != nil { return }
        inFlight.insert(key)
        Task.detached(priority: .utility) {
            // 生成在主线程之外做：这是几十秒级的解码，绝不能占着界面。
            let image = render()
            await RasterOverviewCache.shared.finishGeneration(image: image, key: key, url: fileURL)
        }
    }

    private func finishGeneration(image: CGImage?, key: String, url: URL) {
        inFlight.remove(key)
        guard let image else {
            failed.insert(key)
            return
        }
        store(image, key: key)
        writeToDisk(image, key: key)
        pruneDiskIfNeeded()
        onReady?(url)
    }

    /// 某个缓存键的概览图（铺瓦片时用；只在内存里找，保证是同步的）。
    public func memoryImage(forKey key: String) -> CGImage? {
        guard let image = memory[key] else { return nil }
        touch(key)
        return image
    }

    // MARK: - 内存

    private func store(_ image: CGImage, key: String) {
        memory[key] = image
        touch(key)
        while memoryOrder.count > 2, let oldest = memoryOrder.first {
            memoryOrder.removeFirst()
            memory[oldest] = nil
        }
    }

    private func touch(_ key: String) {
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
    }

    // MARK: - 磁盘

    package static func key(fileURL: URL, tileSize: Int) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))
        let size = (attributes?[.size] as? Int) ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(fileURL.path(percentEncoded: false))|\(size)|\(Int(modified))|\(tileSize)"
    }

    /// 缓存键 → 文件名：路径太长也当不了文件名，这里压成一个定长的十六进制串。
    package static func fileName(for key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private func fileURL(for key: String) -> URL? {
        directory?.appending(path: "\(Self.fileName(for: key)).jpg")
    }

    private func loadFromDisk(key: String) -> CGImage? {
        guard let url = fileURL(for: key), let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func writeToDisk(_ image: CGImage, key: String) {
        guard let directory, let url = fileURL(for: key) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        CGImageDestinationFinalize(destination)
    }

    /// 超过预算就按「最久没动过」清到预算以内。
    private func pruneDiskIfNeeded() {
        guard let directory else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }
        var files: [(url: URL, date: Date, size: Int)] = []
        var total = 0
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let size = values?.fileSize ?? 0
            total += size
            files.append((entry, values?.contentModificationDate ?? .distantPast, size))
        }
        guard total > Self.diskBudgetBytes else { return }
        for file in files.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
            if total <= Self.diskBudgetBytes { break }
        }
    }

    /// 自检用：把磁盘缓存清掉（不动用户的其它文件）。
    public func clearDiskCache() {
        guard let directory else { return }
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for entry in entries { try? FileManager.default.removeItem(at: entry) }
        memory.removeAll()
        memoryOrder.removeAll()
        failed.removeAll()
    }
}
