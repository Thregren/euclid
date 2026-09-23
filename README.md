# 尺规 · Euclid

macOS 原生本地瓦片查看器，为 **WebODM / ODM 输出的正射影像 XYZ 瓦片**设计，
支持坐标读取、折线测距与多边形测面积。没有联网依赖，所有计算在本机完成。

界面为三栏结构：左侧是数据源与最近打开，中间是瓦片画布（左下角浮动缩放控件与比例尺），
右侧检查器实时显示指针坐标、测量结果与数据集信息，底部是状态栏。

## 特性

- **流畅浏览**：Core Animation 图层金字塔渲染，平移缩放由窗口服务器在 GPU 上合成，
  拖动时不重绘 CPU；稀疏覆盖、缺片、符号链接挂载都能正确处理
- **坐标读取**：度分秒、十进制度、Web Mercator 米、瓦片 `z/x/y`、瓦片内像素，
  一键复制或输入经纬度跳转
- **测距**：多点折线，逐段给出长度、方位角、罗盘方位与转角，另有总长与起终点直线距离
- **测面积**：多边形测地面积、周长与闭合边长
- **测量辅助**：顶点吸附、拖动微调、Shift 约束正交与 45°、多条测量并存且各自配色
- **导出**：GeoJSON / KML / CSV，或直接复制到剪贴板
- **原生体验**：三栏结构、检查器、工具栏、状态栏、比例尺、深浅色自适应

## 快速开始

```bash
git clone https://github.com/Thregren/euclid.git
cd euclid
./Scripts/build-app.sh
open "dist/尺规.app"
```

需要 macOS 14+ 与 Swift 6 工具链（Xcode 或 CommandLineTools 均可）。
**没有 Xcode 也能完整构建**，脚本会直接产出可双击的 `.app`。

自检（可选带数据集目录）：

```bash
./Scripts/run-checks.sh
./Scripts/run-checks.sh /path/to/tiles
```

## 使用

打开数据集：⌘O 选择文件夹，或把文件夹拖到窗口 / Dock 图标上；应用会记住上次打开的目录。
也可以直接选择装数据集的父目录，应用会向下找三层。

| 工具 | 快捷键 | 操作 |
| --- | --- | --- |
| 浏览 | V / ⌘1 | 拖动平移，滚轮或捏合缩放，双击放大，⌥双击缩小 |
| 点坐标 | C / ⌘2 | 单击取点，坐标显示在检查器 |
| 测距 | D / ⌘3 | 点击加点，双击或回车结束，⌫ 撤销，Esc 取消 |
| 测面积 | A / ⌘4 | 点击加点，双击或回车闭合 |

测量时按住 Shift 约束方向为水平、垂直或 45°，按住 ⌘ 关闭顶点吸附，
拖动任意顶点可微调已完成的测量。⌘0 适配数据范围，⌘⇧0 恢复原始比例。

## 架构

### 总览

```
┌─────────────────────────── EuclidApp（可执行，UI 层）───────────────────────────┐
│  SwiftUI 外壳                        AppKit 画布                               │
│  ├ RootView / SidebarView             └ TileCanvasNSView                      │
│  ├ InspectorView + InspectorSections       ├ tileHostLayer  瓦片图层金字塔      │
│  ├ StatusBarView / ScaleBarView            ├ gridLayer      瓦片网格            │
│  └ MapControls                             └ MeasurementOverlay  测量标注      │
│                                                                               │
│  状态：AppModel（应用状态）· ViewportState（视图读数）· MeasurementStore（测量）│
└───────────────────────────────────┬───────────────────────────────────────────┘
                                    │ 单向依赖
┌───────────────────────────────────▼───────────────────────────────────────────┐
│                        TileKit（核心库，无 UI 依赖，可单测）                     │
│  GeoCoordinate / WebMercator   投影与坐标换算                                   │
│  SlippyTile / TileLayout       瓦片标识与磁盘布局                               │
│  DatasetDiscovery              数据集嗅探、布局判定、覆盖范围                    │
│  DirectoryTileSource           散文件数据源读取                                 │
│  TileProvider                  actor：LRU 缓存 + 并发解码闸门 + 缺片负缓存      │
│  MapCamera                     视图变换、缩放锚点、可见瓦片范围                  │
│  Geodesy / Measurement         测地线距离、面积、测量模型                        │
│  MeasurementExport             GeoJSON / KML / CSV                              │
└───────────────────────────────────────────────────────────────────────────────┘
                                    ▲
                    TileKitCheck ───┘  自带断言的自检程序（83 项）
```

依赖方向严格单向：`TileKit` 不认识 UI，`EuclidApp` 只消费 `TileKit`，
因此所有投影、测量、解析逻辑都可以脱离界面测试。

### 目录结构

```
Sources/TileKit/          核心库
  GeoCoordinate.swift       坐标类型、Web Mercator 正反算
  SlippyTile.swift          瓦片标识、目录布局与行号约定
  DirectoryTileSource.swift 目录型数据源、图片解码
  DatasetDiscovery.swift    数据集嗅探、扩展名与布局判定、覆盖范围统计
  TileProvider.swift        图片供应者（LRU 缓存、并发闸门、负缓存）
  MapCamera.swift           相机变换与可见瓦片计算
  Geodesy.swift             Vincenty 测地线、面积、显示格式化
  Measurement.swift         测量模型与结果计算
  MeasurementExport.swift   导出格式
Sources/EuclidApp/        应用层
  EuclidApp.swift           @main 入口、AppDelegate、菜单命令
  AppModel.swift            应用状态、数据集打开流程、导出动作
  RootView.swift            窗口结构、工具栏、工具提示
  SidebarView.swift         数据源列表、位置、最近打开
  InspectorView.swift       检查器整体布局
  InspectorSections.swift   指针坐标分区、测量结果分区
  TileCanvasNSView.swift    AppKit 画布：瓦片渲染、缩放平移、工具交互
  TileMapView.swift         NSViewRepresentable 桥接
  MeasurementOverlay.swift  测量标注图层渲染
  MeasurementStore.swift    工具状态机、草稿与已完成测量
  StatusBarView.swift       底部状态栏
  ScaleBarView.swift        比例尺
  CoordinateText.swift      坐标文本格式化
  DebugFixtures.swift       调试示例数据（环境变量开启）
Sources/TileKitCheck/     自检程序
Scripts/                  构建与自检脚本
```

### 关键设计决策

**渲染：CALayer 金字塔，不用 Metal。**
每个可见瓦片对应一个 `CALayer`，`contents` 直接指向解码后的 `CGImage`。
平移缩放只改图层 transform，由窗口服务器合成，CPU 不参与重绘——
与 MapKit、`CATiledLayer` 同思路。选它而不是 Metal 的原因是本机环境没有 Metal 着色器编译器
（`xcrun metal` 不存在），且图元简单、不需要自定义着色器；
渲染路径封装在 `TileCanvasNSView` 内，将来要换后端不影响其它层。

**数据：按需列举，绝不全量扫描。**
单个数据集可能有几十万个瓦片文件，全量遍历要几十秒。
应用只为当前层级枚举目录，缺片记入负缓存避免重复 IO；
覆盖范围统计会挑一个规模适中的层级取样（默认目录数 ≤ 400），
百万级文件的数据集也能秒开。

**布局嗅探：用「另一种编排是否存在」判定轴向。**
`<z>/<a>/<b>` 里 a 是列号还是行号，靠检查磁盘上是否存在 `<z>/<b>/<a>` 来判断——
因为只有正确的轴向才会存在转置路径。行号基准（XYZ 北起源 / TMS 南起源）无法从文件名推断，
按 WebODM 默认约定取 XYZ，并在数据结构里保留可配置项。

**坐标约定：三种坐标系各司其职。**
世界坐标是归一化的 Web Mercator（`0...1`，x 向东、y 向南）；
NSView 未翻转，视图坐标 y 向上，鼠标事件直接可用；
图层坐标 y 向下，靠 `isGeometryFlipped` 统一，瓦片与测量标注共用同一套换算。
所有换算围绕 `MapCamera` 一处收敛，避免多套变换互相打架。

**并发：UI 全在主线程，解码交给 actor。**
`TileProvider` 是 actor，内部用 LRU 缓存（按字节限流）、
固定并发闸门（`AsyncLimiter`，默认同时 6 个解码）与缺片负缓存；
`Task.detached` 负责实际的磁盘读取与解码，结果回到主线程装进图层。
视口变化时按「离视图中心近的优先」排序请求，数据集切换用世代号丢弃过期结果。

**测量：几何计算与交互分离。**
`Geodesy` 只做数学（Vincenty 反向公式、球面过剩面积），`MeasurementStore` 管状态机
（草稿、完成、选中、撤销），`MeasurementOverlay` 只管画。
距离一律走 WGS84 椭球公式而非墨卡托平面距离，避免纬度带来的系统误差；
拖动预览阶段才用轻量近似，保证每帧不掉帧。

**坐标系基准：**
WebODM / ODM 输出的正射影像基于 WGS84（CGCS2000 与 WGS84 的差异在厘米级），
因此坐标读数直接按 WGS84 输出，不做 GCJ-02 之类的偏移转换。

### 扩展点

- **加数据源**（MBTiles、PMTiles、WMS）：实现与 `DirectoryTileSource` 等价的小接口，
  在 `TileProvider` 处替换即可，渲染与测量层不用改
- **加测量工具**（量角器、多段面积累加）：在 `MeasurementKind` 加枚举分支、
  `MeasurementCalculator` 补计算、`MeasurementStore` 补交互状态
- **加导出格式**：在 `MeasurementExporter` 增加一个静态方法，
  在 `MeasurementExportFormat` 登记即可出现在菜单里

## 质量保障

`./Scripts/run-checks.sh` 覆盖 83 项检查：

- 投影与瓦片编号往返一致性，并与真实数据集实测编号对照
- 相机变换互逆性、缩放锚点不变性、适配范围后的完整性
- **Vincenty 1975 标准算例**（Flinders Peak → Buninyong，与文献值相差 < 1 cm）
- 测地面积与独立解析值对照、面积与绕行方向无关
- 边界与异常输入：同点、近对跖点、越界瓦片、少于三点的多边形、方位角归一化
- 导出格式结构校验、真实数据集嗅探（布局、层级、瓦片尺寸、覆盖范围）

## 已知限制

- 首次打开「文稿」「桌面」「下载」中的目录时，macOS 会要求一次文件访问授权
- 测量结果保存在内存中，退出后清空，需要留存请先导出
- 发布包为 ad-hoc 签名，其它机器首次打开需要右键「打开」，或执行
  `xattr -dr com.apple.quarantine /Applications/尺规.app`

## 文档

- [技术路线](docs/01-技术路线.md)｜[构建与运行](docs/02-构建与运行.md)｜[开发进度](docs/03-进度.md)｜[使用说明](docs/04-使用说明.md)

## License

[MIT](LICENSE) © 2026 Thregren
