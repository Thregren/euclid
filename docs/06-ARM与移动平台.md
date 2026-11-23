# ARM64 与移动平台准备

2026-10-07，本轮源码版本 1.16.0。目标为 macOS 14+、iOS / iPadOS 17+，统一 ARM64。

## 已完成

- [x] 删除 Intel / 通用二进制构建分支，打包明确指定 arm64 并校验实际架构。
- [x] 核心库在编译时拒绝非 ARM64 目标；模拟器也使用 arm64。
- [x] Swift Package 声明 macOS 与 iOS 最低版本，提供独立 `TileRendering` 库产品。
- [x] 将 `TileLayerStack` 与 `MapRenderSnapshot` 从 AppKit 宿主移入共享渲染模块。
- [x] 系统减少动态效果偏好由平台注入；图层几何翻转由宿主选择。
- [x] 提供 UIKit 画布，支持平移、捏合缩放、双击放大、点坐标回调、无障碍缩放/平移。
- [x] 移动端使用较小的瓦片、影像块与出图预算，处理内存警告及前后台请求暂停/恢复，视口未变化时不重复回调 UI 状态。
- [x] 增加 `ScopedFileAccess` 与 `ScopedTileSource`，把 Files 文档访问权限与异步来源绑定。
- [x] 增加三平台编译脚本、Release 基准程序、并发与数值回归检查。

## 模块边界

| 模块 | 职责 | 平台依赖 |
| --- | --- | --- |
| TileKit | 投影、测量、文件格式、下载、解码、分析、缓存、访问租约 | Foundation、CoreGraphics、ImageIO、Compression、Network、Accelerate |
| TileRendering | 瓦片图层金字塔、祖先兜底、加载调度、网格、出图快照 | Foundation、CoreGraphics、QuartzCore、TileKit |
| TileCanvasUIView | UIKit 触控输入、坐标转换、无障碍、移动端生命周期 | iOS / iPadOS 条件编译的 UIKit |
| EuclidApp | macOS 窗口、工具面板、快捷键、鼠标、标注、文件选择 | SwiftUI、AppKit、共享模块 |

相机输入坐标原点在左下、y 向上。共享图层/出图坐标原点在左上、y 向下。
UIKit 使用 `coordinate(forLayerPoint:)`、`translated(byLayerDelta:)`，避免复制投影公式。
macOS 图层默认翻转几何；UIKit 画布显式使用 `TileLayerStack(flipsGeometry: false)`。

## 性能与生命周期

1. `TileProvider` 使用请求身份与调用方集合。同一瓦片共享一次加载；取消一个调用方不影响
   其他调用方，全部取消才取消底层任务。旧请求不得清掉失效后重建的请求，取消不写缺片缓存。
2. 预取使用 utility 优先级。解码闸门先放行前台请求，所有供应者还共用全局并发上限。
3. 图层栈持有预取、祖先查询与重铺任务，视野/层级变更时取消过期工作；8 ms 内的返回合并重铺。
4. macOS 画布按总预算分配各图层缓存，隐藏层只保留小缓存；iOS 使用更小的设备预算。
   这些是瓦片缓存额度，图层当前引用的图片、TIFF 块及出图临时内存不等于零。
5. TIFF 同键并发 miss 合并成一次解码；全局锁不覆盖解码与等待。文件失效后旧结果不写新缓存。
   文件租约按句柄身份归还，避免旧租约关闭同路径新句柄。收缩到零可释放全部块缓存。
6. TIFF 原始解码不再预先分配未使用的透明缓冲。网格采样复用当前块，坏块不逐像素重试；
   小图及原始比例浏览跳过不适用的持久化概览查询。
7. 数值统计按 4096 样本分块，Accelerate 批量转为 Double 后过滤 NaN / Inf，并做向量归约。
   保留 Double 累加；向量归约顺序可能导致极小浮点误差，验证按误差容限比较。
8. 土方量按扫描行计算多边形有效列区间，保持奇偶填充与原来的边界规则。
9. 出图快照检查倍率、尺寸与像素预算，避免 NaN 转整数或异常尺寸导致巨量分配。

## 基准

Apple M1 Max，Release 构建；预热一次后测七次，取中位数。命令：

```bash
./Scripts/run-benchmarks.sh
```

| 算法环节 | 原实现 | 优化后 | 倍率 |
| --- | --- | --- | --- |
| 1,048,576 个 Float 样本统计（含 NaN） | 2.067 ms | 0.839 ms | 2.46× |
| 512² 网格 / 256 边多边形范围判定 | 100.793 ms | 1.500 ms | 67.20× |

基准比较算法结果，包含统计工作缓冲开销；范围判定包含每行交点生成、排序和列区间查找。
这不是 TIFF 全链路、GPU 帧率或整应用的提速倍数。

最终通过 `run-benchmarks.sh` 复测：统计 2.006 → 1.153 ms（1.74×），范围判定
89.211 → 1.221 ms（73.04×），结果一致。两轮统计约 1.7–2.5×，范围判定约 67–73×；
设备负载与温度会影响绝对耗时。

## 编译与验证

```bash
./Scripts/build-app.sh        # ARM64 macOS .app
./Scripts/run-checks.sh       # 核心、渲染、并发与数值回归
./Scripts/check-platforms.sh  # macOS / iOS 真机 / ARM64 iOS 模拟器 SDK
```

本轮自检 **714 项通过**（修改前为 657 项）。共享模块已用三套 SDK 编译通过。
macOS ARM64 Release 应用已实际启动，用本地瓦片核对窗口显示和 PNG 导出，方向与影像一致。
签名严格校验在 `/tmp` 副本通过；本机文稿目录的文件提供程序会重新添加扩展属性，
需要签名稳定的测试产物时可使用 `DIST=/tmp/euclid-dist ./Scripts/build-app.sh`。

跨平台检查只构建 `TileRendering` 及依赖的 `TileKit`。iPhone 与 iPad 共用 iOS SDK。
`Euclid` 可执行产品仍然是 macOS AppKit 宿主；移动应用应选择库产品，不选择这个可执行产品。

## 移动 App 后续接入

创建 iOS App target（设备家族选 iPhone、iPad），将此仓库作为本地 Swift Package，
引用 `TileKit` 与 `TileRendering`。`TileCanvasUIView` 可直接放进 UIViewController，
或用 UIViewRepresentable 包装进 SwiftUI。

通过文档选择器拿到 URL 后，在加载数据集前创建访问租约，并绑定到来源：

```swift
let access = ScopedFileAccess(url: documentURL)
let dataset = try RasterLoader.load(url: documentURL)
let source = ScopedTileSource(source: dataset.source, access: access)
canvas.setSource(source, name: dataset.name, tileSize: dataset.tileSize,
                 worldRect: dataset.worldRect, maximumDataZoom: dataset.maximumDataZoom)
```

当前交付是可编译的核心、共享渲染与 UIKit 入口。移动端仍需窗口/导航、导入导出流程、
测量标注适配、工具面板、Apple Pencil 交互，以及 iPhone/iPad 真机视觉与手势验证。
尚未提供移动 App 安装包，也未验证 App Store 签名、后台长期服务或跨设备性能。

## 后续 Metal 接入

当前已利用 ARM64 与 Accelerate 的 CPU 向量能力。Core Animation 继续负责瓦片合成。
Metal 计算可以放入共享核心，优先评估坡度/差异/着色等像素计算；保留 CPU 回退，
将准备数据、GPU 提交和回读计入基准。世界坐标及精密量测保持 Double，不为 GPU 路径降精度。
整画布替换为 Metal 要在实际图层提交/合成成为主要瓶颈时再决定。
