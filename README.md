# 尺规 · Euclid

面向 Apple Silicon 的原生 macOS 正射影像查看器与量测工具。直接打开 WebODM / ODM 影像、瓦片目录、ZIP 瓦片包和栅格 MBTiles，在本机浏览、叠加、测量、分析并导出结果。

**当前版本：1.18.0** · **macOS 14+ / ARM64** · [下载最新版本](https://github.com/Thregren/euclid/releases/latest) · [MIT 许可证](LICENSE)

本版本整合 ARM64 架构、共享移动端模块、Metal 分析与数据工具，并修复文件解析、并发加载、测量归属、工作区恢复和凭据保存等 18 类问题。既有窗口、面板、工具条和样式保持不变。

## 下载与安装

从 [v1.18.0 Release](https://github.com/Thregren/euclid/releases/tag/v1.18.0) 选择：

| 文件 | 内容 |
| --- | --- |
| `Euclid-1.18.0-macos-arm64.zip` | 「尺规.app」，内含 `tiletools` 命令行工具 |
| `tiletools-1.18.0-macos-arm64.zip` | 独立 ARM64 命令行工具及许可证 |
| `Euclid-1.18.0-source.zip` | 对应发布提交的源码 |
| `SHA256SUMS.txt` | 下载文件的 SHA-256 校验值 |

解压后将「尺规.app」放入「应用程序」。仅支持 Apple Silicon，源码也不再提供 Intel / x86_64 或通用二进制构建。

当前发布包采用 **ad-hoc 签名，尚未进行 Developer ID 公证**。macOS 可能拦截首次打开；核对下载来源与校验值后，通过系统的允许打开流程启动，或按下文从源码构建。签名完整性校验通过不等同于 Apple 公证。

## 主要功能

- **本地大图浏览**：GeoTIFF / TIFF 按需解码，复用影像块与文件句柄；支持内建概览及持久化概览缓存。ZIP 直接索引和读取，无需整包解压。
- **图层与工作区**：多图层叠加、顺序调整、显示开关、不透明度、卷帘对比、多标签页、视角书签和工作区恢复。
- **测量与标注**：点坐标、多段测距、多边形面积、圆与标注；支持顶点吸附、拖动微调、方向约束、撤销和重做。
- **DEM 分析**：点高程、剖面、坡度、给定基准高程的挖填体积，以及两期影像差异。坐标、地面度量和体积累计保留 Double 精度。
- **数据交换**：测量导出 Excel、GeoJSON、KML、CSV、DXF、Shapefile；导入 GeoJSON / KML；当前视图与巡检图集导出 PNG。
- **在线与离线**：在线底图、自定义 URL 模板、按范围下载、暂停与继续、从单幅影像生成瓦片；本地只读 HTTP 服务提供 XYZ、TileJSON 与预览页。
- **命令行工具**：检查数据集、抽样或断点审计 ZIP、按范围与层级提取子集、启动本地瓦片服务。

## 支持的数据

| 来源 | 打开方式与说明 |
| --- | --- |
| 瓦片目录 | `<z>/<x>/<y>.<扩展名>`；可选择数据集本身或其父目录，支持 XYZ / TMS 等已识别布局 |
| ZIP 瓦片包 | 支持按层级与行范围命名的分卷，以及配有 `manifest.json` 的整年归档；直接读中央目录和目标瓦片 |
| GeoTIFF / TIFF | TIFF / BigTIFF、分块与横条、常用压缩、8 / 16 位及 Float32 样本、分离平面、Predictor 2 / 3、IFD / SubIFD 概览 |
| 栅格 MBTiles | SQLite 只读访问，PNG / JPEG / WebP，TMS 行号转 XYZ；不支持矢量 PBF |
| PNG / JPEG | 可作为普通影像查看；缺少地理参考时不具备真实地理坐标意义 |

地理参考支持经纬度、Web Mercator、UTM 和常用 CGCS2000 高斯克吕格分带；EPSG:4490 经纬度瓦片网格按其自身行列规则读取。无法识别的地理参考会标为未配准，不推测真实位置。

整年 ZIP 或特殊分卷布局应保留随数据附带的 `manifest.json`。格式识别、资源预算或完整性校验失败时会拒绝读取，不能据此认为任意 TIFF / ZIP 扩展都受支持。

## 常用操作

| 操作 | 快捷键或入口 |
| --- | --- |
| 打开本地数据 | ⌘O；也可将目录、ZIP 或 MBTiles 拖入窗口 |
| 打开单幅影像 | ⌘⇧O；也可直接拖入 TIFF / PNG / JPEG |
| 浏览、点坐标、测距、测面积、画圆 | V、C、D、A、O |
| 在指针处记点 | P |
| 适配数据范围 / 原始比例 | ⌘0 / ⌘⇧0 |
| 撤销 / 重做 | ⌘Z / ⌘⇧Z |
| 导出视图 PNG / 复制视图 | ⌘⇧E / ⌘⇧C |
| DEM 工具箱 | ⌥⌘D |
| 下载在线瓦片 / 从影像生成瓦片 | ⌘⇧D / ⌘⇧T |
| 本地瓦片服务 | ⌘⇧L |
| 新标签页 / 关闭标签页 / 切换标签页 | ⌘T / ⌥⌘W / ⌃⇥ |
| 命令面板 | ⌘K，可搜索命令并管理快捷键 |

滚轮或捏合缩放，中键拖动与双指滚动平移。测量时单击添加顶点，双击、回车或右键结束，Esc 取消；Shift 约束水平、垂直或 45° 方向，⌘ 临时关闭吸附。

左侧浮动图层面板支持拖动排序；右键菜单提供重命名、复制、设为基准与移除。右侧检查器显示测量、坐标、来源和最近打开记录。基准来源决定当前测量文档，切换来源时分别保存与恢复。

在线底图与下载共用来源、URL 模板、密钥和坐标基准设置。GCJ-02 / BD-09 底图可做显示偏移校正，测量与导出坐标保持 WGS84；显示偏移校正不替代影像精配准。批量下载应遵守所选服务的授权、配额与使用条款。

更多操作见 [使用说明](docs/04-使用说明.md)。

## tiletools 数据工具

应用内的工具位于：

```text
/Applications/尺规.app/Contents/MacOS/tiletools
```

也可以使用独立发布包中的 `tiletools-arm64`：

```bash
# 查看数据集或归档信息。
./tiletools-arm64 inspect /path/to/2025.zip

# 只读抽查 CRC 与图片解码。
./tiletools-arm64 check /path/to/2025.zip --samples 128

# 逐条审计 ZIP；中断后使用同一检查点继续。
./tiletools-arm64 check /path/to/2025.zip --full --checkpoint /path/to/report.json

# 每次处理 256 条，逐步完成大归档检查。
./tiletools-arm64 check /path/to/2025.zip --full \
  --checkpoint /path/to/report.json --max-records 256

# 按经纬度范围与层级提取；输出目录必须尚不存在。
./tiletools-arm64 extract /path/to/2025.zip /path/to/regional \
  --bounds 118.0,25.0,118.2,25.2 --zooms 10:12

# 提供本机只读服务，Ctrl-C 停止。
./tiletools-arm64 serve /path/to/regional --port 8766
```

提取输出每层一个 ZIP64 小包与 `manifest.json`，可重新拖入应用。读取错误或取消会使本次提取失败并清理临时输出，不会发布不完整子集。原始归档不被改写。

抽样检查不能证明整包完整；全量模式报告中的 `complete: false` 表示尚未完成。检查点与文件身份绑定，归档变化后不能沿用旧进度。完整断点审计用于 ZIP，目录和 MBTiles 支持覆盖抽查。

本地服务只监听 `127.0.0.1`，可将输出的 XYZ 地址填入 QGIS、MapLibre 或其他本机工具。它面向本机集成，不是带认证的公网地图服务器。详见 [数据工具与 Metal](docs/08-稳定性、数据工具与Metal.md)。

## Apple Silicon 与性能

瓦片合成使用 Core Animation；共享解码调度、请求合并、可取消预取和有界缓存控制后台负载。隐藏图层停止请求与预取，网络等待和重试不占用本地解码额度。文件身份包含路径、设备、inode、大小和纳秒修改时间，原位替换数据后刷新相应缓存。

数值统计使用 Accelerate。坡度、着色及部分差异计算提供 Metal 路径，复用 Apple Silicon 共享内存缓冲；自动模式按规模与适用条件选择，GPU 不可用或计算失败时回退 CPU。并非每一步分析都会在 GPU 上更快，也没有将整个画布改写为 Metal 渲染器。

### 大型 ZIP 验证

2026-10-15，Apple M1 Max、ARM64 Release，对用户提供的 `2025.zip` 进行只读测试：**171,788,867,086 字节（约 160 GiB）**，15,938,667 条记录，约 1.1 GiB 中央目录。

| 环节 | 结果 |
| --- | ---: |
| 独立空应用索引缓存，重新建立索引 | 693.061 ms |
| 随即重开已有索引 | 18.470 ms |
| 跨行查找 p50 / p95 | 2.689 / 4.051 ms |
| 125 张抽样瓦片读取与解码 | 125 / 125 成功，38.527 ms |

操作系统文件缓存未清理，这些数字不代表物理冷盘性能，也不是完整浏览帧率。125 张抽样通过不等于 1,593 万条记录已全部校验。

### Metal 计算验证

同日预热管线、多次中位数；2048 × 2048 样本，包含缓冲准备、提交、等待与结果回读：

| 计算 | CPU | Metal |
| --- | ---: | ---: |
| 坡度 | 63.626 ms | 2.527 ms |
| 着色 | 42.409 ms | 2.148 ms |
| 数组差值 | 13.342 ms | 2.667 ms |

这是计算环节基准，不代表影像读取、重投影或整帧耗时。Metal 同步接口仍会等待命令完成。方法、边界和原始日志见 [修复与验证记录](docs/10-体检修复与验证-2026-10-15.md)。

## 数据保存与隐私

- 本地影像浏览、测量和导出可离线使用；在线底图与下载只向用户选择的瓦片服务发起请求。应用没有遥测、崩溃上报或自动更新检查。
- 测量按数据来源分别保存，工作区定期保存标签页、图层、视角和分析图层；文件位于 `~/Library/Application Support/Euclid/`，采用原子写入并保留三代备份。
- 待保存测量绑定原文档；切页、取消、迟到的导入结果不会写入新来源。保存失败会反馈并保留待写状态，退出时可重试或取消退出。
- 离线卷的图层记录保留；卷恢复后再移除图层不会从旧记录复活。独立测量存档优先于旧工作区副本，已保存的清空操作也会保留。
- **恢复工作区所需的在线配置、密钥及含 token 的 URL 模板存入 macOS Keychain**，会话 JSON 只保存引用；旧会话及可解析备份会迁移，相关存档采用仅当前用户可读写的权限。
- ZIP、TIFF、图片、矢量、HTTP 响应和存档读取都设有格式与资源预算；本地文件服务拒绝越界路径、符号链接和非普通文件。

备份用于恢复最近的保存状态，仍建议另行保留重要测量的手动导出。仓库不包含用户测区数据、在线服务密钥或个人工作区存档。

## 从源码构建

需要 Apple Silicon Mac、Swift 6 工具链和 macOS SDK。macOS 应用可使用兼容的 Command Line Tools 或 Xcode 构建；iOS / iPadOS 共享模块检查需要 Xcode 与相应 SDK。

```bash
git clone https://github.com/Thregren/euclid.git
cd euclid
./Scripts/build-app.sh
```

默认产出 `dist/尺规.app` 与 `dist/tiletools-arm64`。发布构建显式指定 ARM64、剥离调试信息并进行 ad-hoc 签名。输出目录受 iCloud / 文件提供程序管理而导致签名失败时，可选择普通本地目录：

```bash
DIST=/tmp/euclid-dist ./Scripts/build-app.sh
```

构建参数可通过 `SWIFT_BUILD_FLAGS` 追加，例如受限开发环境中的 `--disable-sandbox`；该参数影响构建工具，不是应用的运行时沙盒设置。

### 运行验证

```bash
./Scripts/run-checks.sh
./Scripts/run-checks.sh /path/to/orthophoto.tif
./Scripts/run-benchmarks.sh --metal
./Scripts/run-benchmarks.sh --zip /path/to/2025.zip
./Scripts/check-platforms.sh
```

持久化和真实 AppModel 的独立回归使用已编译的 Debug 产品目录：

```bash
swift build -c debug --triple arm64-apple-macosx14.0
PRODUCTS="$(swift build -c debug --triple arm64-apple-macosx14.0 --show-bin-path)"
./Scripts/check-app-state.sh "$PRODUCTS"
./Scripts/check-app-models.sh "$PRODUCTS"
```

AppKit 模型回归需要可访问系统 GUI 服务的环境。测试使用临时应用、独立 UserDefaults 与临时测量存档，不写用户的 Euclid 偏好或在线凭据。

1.18.0 验收：**903 项核心与渲染检查、38 项持久化服务检查、31 项真实模型检查全部通过**；macOS ARM64 全产品 Debug、应用与 CLI Release 构建，以及共享模块三套 SDK 编译通过。14 个冻结界面文件的内容哈希一致。完整日志见 [validation-20261015](docs/validation-20261015/)。

## 架构与 iOS / iPadOS 进度

| 模块 | 职责 |
| --- | --- |
| `TileKit` | 数据源、投影、测量、ZIP / TIFF / MBTiles、分析、Metal、下载、HTTP 服务、资源预算与存档 |
| `TileRendering` | 共享瓦片图层调度、Core Animation 合成、离屏出图、UIKit 画布 |
| `EuclidApp` | macOS SwiftUI / AppKit 窗口、输入、图层、工具面板与文档状态 |
| `TileTools` | 检查、提取与本地服务的命令行入口 |
| `TileKitCheck` / `TileKitBench` | 回归检查与 Release 基准 |

共享核心与渲染模块支持 **macOS 14+、iOS / iPadOS 17+**，只构建 ARM64，包括 ARM64 模拟器。UIKit 画布已有触控输入、无障碍、文件访问租约和移动端资源预算。

**目前交付的是 macOS 应用及可复用的移动端共享模块，尚无完整 iPhone / iPad 应用或安装包。** 三套 SDK 编译通过不代表完成移动产品交付；独立 App target、导航与文档流程、测量标注适配、Apple Pencil、签名和真机交互仍需后续实现与验证。接入说明见 [ARM 与移动平台](docs/06-ARM与移动平台.md)。

## 已知边界

- 没有概览的大型压缩影像，首次低倍率浏览仍可能需要较多解码；带内建概览的 GeoTIFF / COG 更适合多尺度访问。
- 栅格 MBTiles 不支持矢量 PBF。GeoJSON / KML 中含内环的多边形会明确拒绝，避免将洞误算为有效面积。
- DEM 分析依赖输入高程单位、地理参考与无数据值的正确性；影像差异执行地理网格对齐，不会替用户完成原始影像的精配准。
- 元数据、像素、解压块、请求头、下载响应与存档均有资源限额；工作区存档最多 100 个标签页，超出时反馈保存失败。
- ARM64 移动模块可编译，完整移动 App 尚未交付；当前 macOS 包尚未公证。

## 文档与版本记录

- [使用说明](docs/04-使用说明.md)
- [构建与运行](docs/02-构建与运行.md)
- [技术路线](docs/01-技术路线.md)与[开发进度](docs/03-进度.md)
- [ARM64 与移动平台](docs/06-ARM与移动平台.md)
- [大型 ZIP 性能与界面恢复](docs/07-大型ZIP性能与工作区.md)
- [稳定性、数据工具与 Metal](docs/08-稳定性、数据工具与Metal.md)
- [18 类体检问题修复与验证](docs/10-体检修复与验证-2026-10-15.md)
- [历史 GitHub Releases](https://github.com/Thregren/euclid/releases)

历史阶段文档中的版本与测试数量对应当时快照；当前发布状态、凭据保存方式和验证结果以本 README、1.18.0 发布说明及最新修复记录为准。

## 许可证

[MIT](LICENSE)。
