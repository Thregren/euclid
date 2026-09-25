# 尺规 · Euclid

macOS 原生的正射影像查看器与量测工具，为 **WebODM / ODM 的输出**设计。
两种本地来源都能直接打开：

- **瓦片目录**（`<z>/<x>/<y>.png`，ODM / gdal2tiles 的默认产物）
- **单幅 GeoTIFF / TIFF**（`odm_orthophoto.tif` 那种一整幅大图，不用先切瓦片）

按地理参考摆到正确位置，读坐标、测距离、量面积、画圆、导出结果、出图——
全部在本机完成，没有联网依赖。

当前版本 **1.12.0**，下载见 [Releases](https://github.com/Thregren/euclid/releases/latest)。

## 特性

**看得清、动得顺**

- 瓦片用 Core Animation 图层金字塔渲染，平移缩放交给窗口服务器在 GPU 上合成，
  拖动时 CPU 不重绘；稀疏覆盖、缺片、符号链接挂载都能正确处理
- 单幅 GeoTIFF 按屏幕需要的区域现解：分块 / 横条、Deflate / LZW / PackBits / JPEG、
  8 与 16 位、灰度 / RGB / 调色板 / alpha、Predictor 2 都支持；
  **内存占用与影像大小无关**（实测 6100 万像素的 ODM 影像：首屏 84 ms、1:1 取图 25 ms）
- 文件里的内建概览（`gdaladdo` 的 reduced-resolution 目录、COG 的 SubIFD）当金字塔用，
  缩小取低分辨率级；本地影像按设备像素 1:1 显示，Retina 上不糊

**量得准**

- 坐标读取：度分秒、十进制度、Web Mercator 米、瓦片 `z/x/y`、瓦片内像素，
  一键复制或输入经纬度跳转
- 测距：多点折线，逐段给出长度、方位角、罗盘方位与转角，另有总长与起终点直线距离
- 测面积：多边形测地面积、周长与闭合边长；画圆：点圆心 + 点半径，
  之后可拖动半径点或输入精确半径（米 / 公里）
- 测量辅助：顶点吸附、拖动微调、Shift 约束正交与 45°、多条测量并存且各自配色
- 距离与面积走 WGS84 椭球公式（Vincenty），不是墨卡托平面近似
- **坐标基准**：底图若是高德 / 腾讯（GCJ-02）或百度（BD-09），在侧栏选一下基准即可与
  WGS84 正射影像对齐，偏移方向与量级写在状态栏与检查器里

**拿得走**

- 导出 Excel（`.xlsx`，四张工作表）/ GeoJSON / KML / CSV，或直接复制到剪贴板
- 出图：⌘⇧E 把当前视图存成 PNG，⌘⇧C 放进剪贴板；成图带一条信息栏
  （数据源、中心坐标、层级、比例尺）
- 在线底图与下载：内置天地图、OpenStreetMap 预设，也能填任意 URL 模板；
  按范围与层级把瓦片取到本地，落成 `<z>/<x>/<y>` 直接离线浏览
- **本地瓦片服务**：一键把本地瓦片目录用 HTTP 提供给别的工具（只绑 127.0.0.1、只读、带 CORS），
  在 OSM 在线编辑器 / QGIS 里填 `http://127.0.0.1:端口/{z}/{x}/{y}.png` 就能拿本地影像当底图
- **多图层**：本地数据集、单幅影像、在线底图都能作为图层叠加，每层一条独立的不透明度、
  单独的显示开关与移除按钮；列表顺序就是叠放顺序，其中「基准层」是测量、存档与相机尺度的依据
- **从影像生成瓦片**：把 GeoTIFF / TIFF 切成各级瓦片（⌘⇧T），
  尺寸 512（默认，本地浏览 1:1）/ 256 可选，格式 JPEG（质量默认 85）或 PNG，生成完直接打开
- 测量结果按数据集 / 影像路径自动存档，下次打开自动恢复

## 快速开始

下载 [Releases](https://github.com/Thregren/euclid/releases/latest) 里的
`Euclid-<版本>-macos-arm64.zip`（Apple Silicon，macOS 14+），解压后把「尺规.app」拖进「应用程序」。
发布包是 ad-hoc 签名、未做公证，首次打开请**右键 → 打开**，或执行：

```bash
xattr -dr com.apple.quarantine /Applications/尺规.app
```

Intel 机器目前需要从源码构建。从源码构建只依赖 Swift 6 工具链，**不需要 Xcode**：

```bash
git clone https://github.com/Thregren/euclid.git
cd euclid
./Scripts/build-app.sh        # 产出 dist/尺规.app
./Scripts/run-checks.sh       # 运行自检（329 项）
```

## 使用

**打开**

- ⌘O 打开瓦片目录（也可以直接选装数据集的父目录，会向下找三层），
  或把文件夹拖到窗口 / Dock 图标上
- ⌘⇧O 打开单幅影像（`.tif` / `.tiff`，也收 PNG / JPEG），或把文件直接拖进窗口
- 打开过的目录与影像都记在侧栏「最近打开」里

**工具**

| 工具 | 快捷键 | 操作 |
| --- | --- | --- |
| 浏览 | V / ⌘1 | 滚轮或捏合缩放，中键拖动、左键拖动、双指滚动平移，双击放大，⌥双击缩小 |
| 点坐标 | C / ⌘2 | 单击取点，坐标显示在检查器 |
| 测距 | D / ⌘3 | 点击加点，双击或回车结束，⌫ 撤销，Esc 取消 |
| 测面积 | A / ⌘4 | 点击加点，双击或回车闭合 |
| 画圆 | O / ⌘5 | 点击定圆心，再点一次定半径；之后可拖动半径点或输入半径 |
| 记点 | P | 把指针所在位置记成一个点（与「点坐标」工具**同一份数据**，随时可用，不必切工具） |

测量时按住 Shift 约束方向为水平、垂直或 45°，按住 ⌘ 临时关闭顶点吸附。
⌘0 适配数据范围，⌘⇧0 恢复原始比例。选中的测量可以在检查器里单独改样式，
也可以「应用到全部」。⌘Z / ⌘⇧Z 撤销与重做。

**出图与导出**

- ⌘⇧E 导出当前视图为 PNG（保存面板里可以取消「包含测量标注」，导出一张干净地图）
- ⌘⇧C 直接复制当前视图到剪贴板
- 测量结果支持 Excel / GeoJSON / KML / CSV 与剪贴板复制

## 软件架构

### 分层与依赖

整仓约 13,600 行 Swift，分三层，依赖方向严格单向：`TileKit` 不认识界面，
`EuclidApp` 只消费 `TileKit`，因此投影、取图、测量、导出、TIFF 解码全都可以脱离界面测试。

```
┌──────────────────── EuclidApp（可执行，UI 层）─────────────────────┐
│  SwiftUI 外壳                         AppKit 画布                  │
│  ├ RootView / SidebarView              └ TileCanvasNSView          │
│  ├ InspectorView（坐标 / 测量 / 数据源）   ├ TileLayerStack ×2        │
│  ├ StatusBarView / ScaleBarView            │  （在线底图 / 本地影像） │
│  └ MapControls / DownloadSheet             └ MeasurementOverlay     │
│  ViewExporter（出图合成）                                           │
│  状态：AppModel · ViewportState · MeasurementStore · TileDownloadModel │
└───────────────────────────────┬────────────────────────────────────┘
                                │ 单向依赖
┌───────────────────────────────▼────────────────────────────────────┐
│                     TileKit（核心库，无 UI 依赖，可单测）            │
│  GeoCoordinate / WebMercator     投影与坐标换算                      │
│  SlippyTile / TileLayout         瓦片标识与磁盘布局                  │
│  DatasetDiscovery                瓦片数据集嗅探与覆盖范围             │
│  TileImageSource 及其实现         取图通道：目录 / 远程 / 单幅影像     │
│  TileProvider                     actor：LRU 缓存 + 并发闸门 + 负缓存 │
│  MapCamera                       视图变换、缩放锚点、可见瓦片范围     │
│  TIFF / TIFFDecoder              单幅 TIFF 解析与按区域解码          │
│  GeoTIFF / Projection            地理参考与投影换算（UTM / 高斯克吕格）│
│  Geodesy / Measurement           测地线距离、面积、测量模型           │
│  MeasurementExport / XLSX        导出格式与零依赖 OOXML 生成          │
│  TileSource / TileDownloader     URL 模板与批量下载                  │
│  Datum                           GCJ-02 / BD-09 基准偏移与互转        │
└────────────────────────────────────────────────────────────────────┘
                                ▲
                  TileKitCheck ─┘ 自带断言的自检（329 项）
```

### 功能模块

**核心库 `TileKit`**

| 模块 | 文件 | 职责与要点 |
| --- | --- | --- |
| 坐标与投影 | `GeoCoordinate.swift` | `GeoCoordinate`（WGS84）与 `WebMercator`：归一化世界坐标（0…1、y 向南）↔ 经纬度 ↔ 墨卡托米；另有该纬度上每世界单位的实地米数 |
| 瓦片标识 | `SlippyTile.swift` | 瓦片对象、`<z>/<x>/<y>` 磁盘布局、行列轴向（x 先 / y 先）、行号零点（XYZ / TMS）、瓦片边长 |
| 数据集发现 | `DatasetDiscovery.swift` | 向下嗅探瓦片数据集；用「另一种编排是否存在」判定轴向；抽样统计覆盖范围，不全量遍历 |
| 取图通道 | `TileImageSource.swift`、`DirectoryTileSource.swift`、`RemoteTileSource.swift`、`GeoTIFF.swift` | 统一的「给我这一格」协议，默认实现是「取字节 + `ImageIO` 解码」；单幅影像覆盖成「按区域现解」，省掉一次编解码往返 |
| 图片供应 | `TileProvider.swift` | actor：按字节限流的 LRU 内存缓存、`AsyncLimiter` 并发闸门（默认 6–8 路解码）、缺片负缓存、在途请求合并 |
| 相机 | `MapCamera.swift` | 视图 ↔ 世界 ↔ 图层三套坐标的换算、缩放锚点补偿、缩放上下限夹取、可见瓦片行列范围；整数层级时一张瓦片刚好对应它的原始像素 |
| 单幅影像 | `TIFF.swift`、`TIFFDecoder.swift`、`GeoTIFF.swift`、`Projection.swift` | TIFF / BigTIFF 目录解析（含 IFD 链与 SubIFD 概览）、按区域解压与采样、GeoTIFF 标签 → 像素仿射变换、投影到 WGS84 |
| 测地计算 | `Geodesy.swift` | Vincenty 反向与直接公式、测地圆采样、球面过剩面积、显示格式化（距离 / 面积 / 方位角） |
| 测量模型 | `Measurement.swift`、`MeasurementStyle.swift` | 点 / 折线 / 多边形 / 圆四种测量，分段结果与闭合差；带缓存的求值（键为类型 + 顶点，圆另按圆心 + 半径）；与 UI 无关的颜色分量与逐条样式 |
| 导出 | `MeasurementExport.swift`、`XLSX.swift` | GeoJSON / KML / CSV / Excel；`XLSX` 零依赖生成 OOXML，自带「存储式 ZIP」打包与 CRC32、以及反解校验 |
| 在线源与下载 | `TileSource.swift`、`TileDownloader.swift` | URL 模板（`{z}` `{x}` `{y}` `{-y}` `{s}` `{key}`）、预设、下载计划（只存每层行列范围）、并发 + 限速 + 重试退避 + 缺片 + 续下 + 落盘清单 |
| 坐标基准 | `Datum.swift` | WGS84 / GCJ-02 / BD-09 互转（正向多项式拟合、反向迭代逼近）与相对 WGS84 的米制偏移 |

**应用层 `EuclidApp`**

| 模块 | 文件 | 职责与要点 |
| --- | --- | --- |
| 入口与菜单 | `EuclidApp.swift` | `@main`、`AppDelegate`（响应拖放打开）、菜单（打开、下载、出图、工具、撤销重做） |
| 应用状态 | `AppModel.swift` | 状态中枢：数据源列表与选中项、单幅影像载入、装配去抖（签名不变不重装）、状态栏提示、存档调度、出图与导出动作 |
| 画布桥接 | `TileMapView.swift`、`CanvasController`（在 `AppModel.swift`） | SwiftUI ↔ AppKit 的命令通道：装配图层、设不透明度、适配窗口、取画面像素 |
| 画布与渲染 | `TileCanvasNSView.swift` | 双图层栈 + 标注层；滚轮 / 中键 / 捏合 / 双击 / 方向键交互；缩放上下限；离屏渲染（调试截图与出图共用） |
| 图层栈 | `TileLayerStack.swift` | 「一个数据源 ↔ 一个宿主图层」的全套逻辑：换层级留旧图兜底、祖先贴图、同帧接图、缺片负缓存、按中心距离排序取图、空闲预取、瓦片网格、不透明度 |
| 测量交互 | `MeasurementStore.swift` | 工具状态机（浏览 / 点 / 测距 / 测面积 / 画圆）、草稿与已完成测量、选中、撤销重做（1.5 s 合并窗口）、半径输入、顶点吸附数据 |
| 标注绘制 | `MeasurementOverlay.swift`、`MeasurementPalette.swift` | 描边 / 填充 / 顶点 / 标注 / 半径辅助线各用图层池复用；圆环采样缓存；深浅色与「减少动态效果」适配；出图前的文字翻转补偿 |
| 界面 | `RootView.swift`、`SidebarView.swift`、`InspectorView.swift`、`InspectorSections.swift`、`StatusBarView.swift`、`ScaleBarView.swift`、`InterfaceStyle.swift`、`CoordinateText.swift` | 三栏结构、数据源列表与最近打开、检查器分区、状态栏读数、比例尺（与出图共用刻度算法）、语义色与材质 |
| 底图与下载界面 | `OnlineBasemap.swift`、`TileDownloadModel.swift`、`DownloadSheet.swift` | 在线底图配置与有效性判定；下载面板参数、计划预览、进度与取消 |
| 出图 | `ViewExporter.swift` | 画面 + 信息栏（数据源、中心坐标、层级、比例尺）合成 PNG，供保存与剪贴板 |
| 存档 | `MeasurementArchive.swift` | 测量结果按数据集 / 影像路径存到 `~/Library/Application Support/Euclid/` |
| 调试 | `DebugFixtures.swift` | 环境变量驱动的示例测量、缩放 / 出图 / 底图 / 外观脚本（只影响开发） |

**自检与样本**

| 模块 | 文件 | 职责 |
| --- | --- | --- |
| 自检程序 | `Sources/TileKitCheck/main.swift` | 自带断言的检查程序（没有 XCTest 也能跑）：投影、相机、测地、测量、导出、下载、基准、TIFF 解码、投影换算，以及「拿一个数据集 / 影像文件当参数」的体检模式 |
| 回归样本 | `Fixtures/TIFF/` | 由 **libtiff** 写出的 TIFF（横条 / 分块 × 未压缩 / Deflate / LZW / PackBits）+ 源图 + 生成脚本；定位点取 UTM 中央经线上的整数格点，与真实测区无关 |
| 脚本 | `Scripts/build-app.sh`、`Scripts/run-checks.sh` | 构建并组装 `.app`（剥离调试信息、检查本机路径残留、ad-hoc 签名）；跑自检 |

### 一次取图的完整链路

1. **相机**算出可见瓦片与整数层级；单幅影像则先把瓦片范围换算成影像像素区域
2. **图层栈**决定这一帧要哪些格子（与上一帧比对），按「离视图中心近的优先」排序，受并发额度约束派发
3. **`TileProvider`**（actor）先查内存缓存；未命中才向来源要图——目录来源读文件 + 解码，
   单幅影像按区域解压采样；同一格的并发请求合并成一次
4. 结果回主线程装进 `CALayer`（`contents` + `contentsRect`），首次出现淡入；
   换层级时新图层先透明，由保留的上一层影像顶着，自己的图到了再替换
5. 自己没有图时用**祖先贴图**兜底；确认「自己没有、祖先也没有」的格子记进 `unresolvedTiles`，
   避免每帧重试造成空转
6. 视野安定后**预取**外圈一圈瓦片；测量标注由独立的 `MeasurementOverlay` 图层绘制，
   用的是同一个 `MapCamera`，因此与影像天然对齐

### 线程与缓存

- **主线程**：全部界面状态与图层装配（`AppModel`、`TileCanvasNSView`、`TileLayerStack` 都是 `@MainActor`）
- **后台**：`TileProvider` 是 actor，磁盘读取与解码在 `Task.detached` 里执行，
  并发由 `AsyncLimiter` 限流；单幅影像的区域解码同样在后台
- **缓存分四层**：瓦片图片的 LRU 内存缓存（按字节限流）→ 缺片负缓存 →
  TIFF 目录解析缓存（只存几 KB 元数据）→ 测量求值缓存；都不随会话时长无限增长

### 关键设计决策

- **渲染用 CALayer 金字塔而不是 Metal**：平移缩放只改图层 transform，
  由窗口服务器合成，CPU 不参与重绘；要换后端也只影响 `TileCanvasNSView` 一处
- **数据按需列举，绝不全量扫描**：几十万瓦片的数据集也秒开；
  覆盖范围只挑一个规模适中的层级取样
- **单幅影像自己读 TIFF**：`ImageIO` 解不出 GeoTIFF 的地理标签，整张大图进内存也不现实。
  `TIFF.swift` 只读目录结构（尺寸、分块表、GeoKey），`TIFFDecoder.swift` 按区域解像素；
  于是单幅影像与瓦片数据集在下游完全同构——同一套缓存、测量与出图，内存与文件大小无关
- **坐标系分三种各司其职**：世界坐标（归一化 Web Mercator）、视图坐标（y 向上）、
  图层坐标（y 向下，靠 `isGeometryFlipped` 统一），换算只在 `MapCamera` 一处收敛
- **测量求值带缓存**：按「类型 + 顶点」记忆（圆另按「圆心 + 半径」，连 360 点采样一起），
  平移缩放时只取缓存、按新相机换算屏幕位置，不再每帧重算测地线

- **加载不闪**：新图层不刷占位色、由上层影像顶着；数据范围算出来之前不铺图；
  缺图格子只尝试有限次。这三条都是逐帧日志量出来的（见[开发进度](docs/03-进度.md) M6.2）
- **界面按 HIG 收敛**：语义字号与语义色、控制层浮在内容之上的材质、工具栏只留高频操作

### 源码结构

```
Sources/TileKit/          核心库（无 UI 依赖）
  GeoCoordinate.swift       坐标类型、Web Mercator 正反算
  SlippyTile.swift          瓦片标识、磁盘布局与行号约定
  DatasetDiscovery.swift    数据集嗅探、布局判定、覆盖范围
  TileImageSource.swift     取图协议与公共请求头
  DirectoryTileSource.swift 目录型来源、图片解码
  RemoteTileSource.swift    在线来源
  TileProvider.swift        LRU 缓存、并发闸门、负缓存
  MapCamera.swift           相机变换与可见瓦片
  TIFF.swift                TIFF / BigTIFF 目录解析（含 GeoTIFF 标签）
  TIFFDecoder.swift         按区域解码（Deflate / LZW / PackBits / JPEG + Predictor 2）
  GeoTIFF.swift             地理参考、单幅影像模型与取图来源
  Projection.swift          经纬度 / Web 墨卡托 / 横轴墨卡托
  Geodesy.swift             Vincenty 测地线、面积、格式化
  Measurement.swift         测量模型与求值（带缓存）
  MeasurementStyle.swift    与 UI 无关的颜色分量与样式
  MeasurementExport.swift   导出格式
  XLSX.swift                OOXML 生成 + 存储式 ZIP 打包与校验
  TileSource.swift          URL 模板、预设、下载计划
  TileDownloader.swift      批量下载（并发 / 限速 / 重试 / 清单）
  Datum.swift               GCJ-02 / BD-09 基准互转
Sources/EuclidApp/        应用层
  EuclidApp.swift           入口、菜单命令
  AppModel.swift            应用状态、装配流程、出图与导出动作
  RootView.swift            窗口结构、工具栏、工具提示
  SidebarView.swift         数据源列表、位置、最近打开
  InspectorView.swift       检查器布局
  InspectorSections.swift   指针坐标与测量分区
  TileCanvasNSView.swift    AppKit 画布：渲染与交互
  TileMapView.swift         SwiftUI ↔ AppKit 桥接
  TileLayerStack.swift      单条瓦片图层栈
  MeasurementOverlay.swift  测量标注绘制
  MeasurementStore.swift    测量状态机
  MeasurementPalette.swift  调色板与样式解析
  MeasurementArchive.swift  测量存档
  StatusBarView.swift       底部状态栏
  ScaleBarView.swift        比例尺（与出图共用刻度算法）
  CoordinateText.swift      坐标文本格式化
  DownloadSheet.swift       下载面板
  TileDownloadModel.swift   下载面板状态
  OnlineBasemap.swift       在线底图配置
  ViewExporter.swift        出图合成
  InterfaceStyle.swift      控件材质与「减少动态效果」判定
  DebugFixtures.swift       调试脚本（环境变量开启）
Sources/TileKitCheck/     自检程序
Fixtures/TIFF/            自检用的 TIFF 回归样本与生成脚本
Scripts/                  构建与自检脚本
docs/                     技术路线、构建与运行、开发进度、使用说明
```

更细的设计取舍（为什么这么选、踩过什么坑）见[技术路线](docs/01-技术路线.md)与
[开发进度](docs/03-进度.md)。

## 质量保障

`./Scripts/run-checks.sh` 覆盖 **329 项检查**（本机没有 XCTest，自检是一个自带断言的可执行目标）：

- 投影与瓦片编号往返，并与真实数据集对照
- 相机变换互逆、缩放锚点不变、上下限处连续缩放不漂移
- **Vincenty 1975 标准算例**（与文献值相差 < 1 cm）、测地面积对照、
  圆的周长面积与 `2πr` / `πr²` 对照、直接与反向公式互逆
- 样式与存档解码回落、Excel 包的 ZIP 结构自校验（逐条 CRC）
- 在线下载：范围到行列的换算（含边界不多取）、模板与密钥、
  缺片 / 重试 / 跳过 / 并发 / 取消、落盘清单
- 在线取图：层级夹取、失败重试、404 视为缺片、内存缓存命中、负缓存、预取
- 坐标基准：境外不偏移、境内偏移量级、往返厘米级、与公开实现逐位对照、
  偏移基准下的下载计划
- **单幅影像**：用 **libtiff 写出的样本**（横条 / 分块 × 未压缩 / Deflate / LZW / PackBits）
  逐像素比对——同一张源图，一条路径走 `ImageIO`、一条走自带解码；
  GeoTIFF 四角与 **PROJ 9.7** 对照到毫米级；UTM / CGCS2000 / Web 墨卡托正反算对照

也可以直接给自检一个影像文件做体检：

```bash
./Scripts/run-checks.sh /path/to/orthophoto.tif
# 打印尺寸、坐标基准、地面分辨率、经纬度范围、原始比例与首屏耗时
```

发布包会剥离调试信息，构建脚本还会检查可执行文件里是否残留本机构建路径。

## 已知限制

- 单幅影像暂不支持分离平面（`PlanarConfiguration = 2`）、浮点样本、`Predictor = 3`、
  非 8 / 16 位位深与老式 JPEG-in-TIFF；认不出的投影按「未配准」显示，不猜位置
- **没有内建概览的大图**首次在很低倍数下看会慢些（要解压覆盖整幅的压缩块）：
  用 `gdaladdo` 补一次概览，或存成带概览的 GeoTIFF / COG
- 基准偏移取视图中心处的线性近似：城区（几公里）内误差在米级，省级视野下几十米，
  适合判读与配准检查，不适合高精度配准
- 首次打开「文稿」「桌面」「下载」里的文件时，macOS 会要求一次访问授权
- 发布包是 ad-hoc 签名，其它机器首次打开需要右键「打开」

## 文档

[技术路线](docs/01-技术路线.md)｜[构建与运行](docs/02-构建与运行.md)｜
[开发进度](docs/03-进度.md)｜[使用说明](docs/04-使用说明.md)

## 更新日志

### 1.12.0

- **多图层**：画布不再写死「本地 + 在线」两层，而是按图层列表装配——
  本地数据集、单幅影像、在线底图都能叠，每层各有独立的不透明度、显示开关与移除按钮，
  列表顺序即叠放顺序；「基准层」决定测量、存档与相机尺度。侧栏改成
  「图层 / 可用数据 / 位置 / 最近打开」四段
- **开关底图不再改动视野**（两处根因）：一是重配图层会改变相机里的瓦片边长，
  现在按「一个视图点对应多少米」套回去；二是每次重配都在按当前相机重算缩放下限，
  导致能缩小的范围被逐步收紧。另外「首次自动适配世界」改成了只在视野从未被放置过时发生
- **界面按钮标出快捷键**：复制坐标（⌥⌘C）、记下这个点（P）、保存到文件（⌘S）、从文件载入（⌥⌘O）、
  清除全部（⌘⇧K）、结束/撤销一点/取消（↩ / ⌫ / esc）、浮动缩放控件（⌘- / ⌘= / ⌘0）都在按钮上写明
- **清理**：移除重构后残留的相机配套状态（`dataset` / `onlineFitRect` / `defaultFitRect`），
  图层参数从画布搬到模型，画布只剩「按列表装配」一件事

### 1.11.0

- **开关在线底图不再改动视野**：重配图层会改变相机里的瓦片边长，原先沿用缩放层级会让画面跳一下；
  现在按「一个视图点对应多少米」套回去，开关底图 / 换源前后看到的范围完全一致
- **新增：本地瓦片服务**（⌘⇧L，或底图菜单里）：把本地瓦片目录用 HTTP 提供给本机其它程序，
  只监听 127.0.0.1、只读、只认瓦片路径、带 CORS；面板给出可直接复制的地址模板与请求计数，
  在 OSM 在线编辑器（iD）的背景设置里粘进去就能拿本地影像当底图
- **关掉最后一个窗口就退出**：不再留在菜单栏里挂着一个点不开的空壳

### 1.10.0

- **OSM 成为默认在线底图**；并修掉「打开在线底图时默认视图位置是错的」——
  世界范围矩形的高度写反了（负值），适配整个世界时视角被推到北极圈一带，
  现在正落在世界中心 (0°, 0°)
- **新增：P 记点**——把指针放到目标上按 P 就把该坐标记成一个点，与「点坐标」工具落的
  是同一种测量（同一份数据、同一套存档与导出），落点后自动选中可直接编辑；
  工具栏提示、状态栏与检查器里都写着这个快捷键
- **新增：⌘E 快速导出当前视图**（含标注、不弹面板，存进 `~/图片/尺规`）；
  工具栏「导出」菜单集中了出图、测量导出、测量存档与清除全部
- **测量存档变明确**：检查器里「保存到…／从文件载入…／清除全部」并排，并说明自动存档行为；
  自动存档文件可在访达中直接显示
- 工具栏从 11 项精简到 5 项（缩放入浮动控件、下载与生成瓦片并入底图菜单、测量操作收进「导出」菜单）

### 1.9.1

- **清理**：生成面板的六个分区收敛成一个共用外框、进度上报只保留一处真相、
  层级默认值简化为「一个影像像素对一个瓦片像素那一级往前 3 级」
- **健壮性**：单次生成加 100 万张的上限（超了直接给出明确提示，不空转磁盘与 CPU）；
  面板参数改为跟随当前影像（换一幅影像会自动重算层级与输出目录）；失败信息统一带上具体文件
- 补两个调试开关：`EUCLID_DEBUG_TILE_EXPORT`（无人值守跑一次生成并打印结果）、
  `EUCLID_DEBUG_TILE_EXPORT_SHEET`（只打开生成面板，便于截图核对）

### 1.9.0

- **新增：从影像生成各级瓦片**（⌘⇧T）。把一整幅 GeoTIFF / TIFF 切成 `<z>/<x>/<y>` 瓦片目录，
  尺寸 512（默认）/ 256 可选，格式 JPEG（质量默认 85）或 PNG
  - 复用与浏览完全相同的取图链路，切出来的瓦片与直接看 GeoTIFF 是同一份像素；
    纯无数据区不写文件，输出目录能被本程序直接打开
  - 实测一份 6100 万像素的 ODM 影像生成 z18–z21：写出 532 张（257 张无数据自动跳过）、
    0 失败、50.4 MB、4.4 秒
- 自检扩到 342 项：新增「生成 → 输出目录被识别为数据集 → 写出的 PNG 与直接渲染逐字节比对」闭环，
  以及 JPEG 质量核对
- 界面：左下角两张浮层卡片合成一张、工具提示移入状态栏、检查器把样式编辑折叠起来

### 1.8.0

- **新增：直接打开单幅影像（GeoTIFF / TIFF）**——⌘⇧O，或把 `.tif` 拖进窗口，
  `odm_orthophoto.tif` 不用先切瓦片就能看、能量、能出图
- 自带 TIFF 解析与按区域解码（Deflate / LZW / PackBits / JPEG、8 / 16 位、
  灰度 / RGB / 调色板 / alpha、Predictor 2），只解屏幕需要的那一块；
  内建概览当金字塔用；UTM / CGCS2000 高斯克吕格 / Web 墨卡托 / 经纬度都换算到 WGS84
- **修复：整块瓦片随机变空**——交给 `CGImage` 的像素指针只在 `withUnsafeBytes`
  闭包内有效，闭包返回后内存可能被复用；改成由 `Data` 支撑
- 自检扩到 329 项：新增 libtiff 写出的样本逐像素比对、PROJ 四角对照、
  UTM / 高斯克吕格正反算

### 1.7.0

- **新增：导出当前视图为图片**（⌘⇧E）与**复制到剪贴板**（⌘⇧C），
  成图带数据源、中心坐标、层级与比例尺信息栏
- **性能：测量结果不再每帧重算**——按「类型 + 顶点」缓存（圆含 360 点采样），
  自检里重复求值快约 50 倍
- **修复：导出的图片里文字上下颠倒**（`CALayer.render(in:)` 与 `CATextLayer` 的老问题）

### 1.6.0

- **新增：坐标基准对齐（GCJ-02 / BD-09）**——高德 / 腾讯 / 百度的底图与 WGS84
  正射影像叠加时不再差几百米；互转用公开的多项式拟合，境外坐标不偏移

### 1.5.0

- 本地影像与在线底图可以同时显示、各带不透明度滑杆，用来核对配准；
  瓦片图层逻辑抽成 `TileLayerStack`，在线与本地共用同一套兜底与缓存

### 1.4.0

- 按 Apple HIG 重做界面：语义字号、Liquid Glass 控制层、工具栏精简到 8 项、
  加载态与无障碍补齐、窗口标题改为「当前在看什么」

### 1.3.0

- 在线底图浏览（取图与本地同一条链路）、空闲预取；
  下载面板新增「复制范围 / 用剪贴板范围」与「复制瓦片清单」

### 1.2.0

- 在线瓦片下载：天地图 / OpenStreetMap 预设与自定义模板，带并发、限速、
  续下与来源清单；修掉加载与换层级时的一闪一闪

### 1.1.1

- 修掉「缩小后瓦片消失」与「缩放到极限后继续滚动会平移视图」

### 1.1.0

- 画圆、逐条样式、零依赖 Excel 导出（四张工作表）

### 1.0.0

- 首个版本：瓦片渲染与浏览、坐标读取、测距、测面积、GeoJSON / KML / CSV 导出

## License

[MIT](LICENSE)
