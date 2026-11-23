import Foundation

/// TileKit 里的调试开关（`EUCLID_*` 环境变量）。
///
/// 全部在启动时读一次、留成常量：`ProcessInfo.processInfo.environment` **每访问一次**都要把
/// 整份环境重新拼成一个字典（本机实测约 29 µs，比查一个留住的字典慢上千倍），
/// 放在每帧 / 每块瓦片的判断里就是纯浪费。新增开关也请加在这里，别散落到调用点上。
public enum TileKitTrace {
    /// 隔离大 ZIP 基准的索引缓存，避免删除或覆盖用户日常缓存。
    public static let zipIndexCacheDirectory = ProcessInfo.processInfo.environment["EUCLID_ZIP_INDEX_CACHE"]
    /// `EUCLID_TM_TRACE=1`：打印高斯-克吕格反算的中间量。
    public static let transverseMercator =
        ProcessInfo.processInfo.environment["EUCLID_TM_TRACE"] != nil
    /// `EUCLID_RASTER_TRACE=1`：打印单幅影像每块瓦片的解码几何。
    public static let raster =
        ProcessInfo.processInfo.environment["EUCLID_RASTER_TRACE"] != nil
    /// `EUCLID_TIFF_TRACE=1`：打印 TIFF 解压失败时的探测信息。
    public static let tiff =
        ProcessInfo.processInfo.environment["EUCLID_TIFF_TRACE"] != nil
}
