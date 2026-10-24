# 游戏库滚动与布局切换性能调研

日期：2026-10-20。源码范围：`main`，HEAD `c5d85ed`，包含当前工作区已有修改。用户确认的重点场景为游戏库滚动与布局切换。

建议先缓存混合排布、合并封面比例更新、复用布局切换所需的数据，再优化封面尺寸和处理队列。现有阴影、悬停缩放、封面裁剪、背景模糊和过渡曲线均作为视觉验收基线。

## 证据范围

本轮完成源码检查、Apple 官方资料核对，以及现有 `LibraryCoverGrid` 的独立优化编译基准。进程检查时 Whisky 主程序处于关闭状态；实际窗口的掉帧率、GPU 时间、功耗和切换峰值内存属于后续 GUI 采样项目。下文将源码事实、局部基准和优化假设分别标明。

当前工作区已具备以下优化，应保留并作为起点：

- `LazyVGrid` / `LazyVStack`，150 ms 搜索防抖，以及元数据首批 12 项、后续每批 48 项发布。
- `IconCache` actor 内执行封面解码、取色和模糊生成；1024 像素最大边；160 MiB 处理后图片缓存和 256 MiB 磁盘衍生缓存。
- 64×64 预模糊背景纹理、独立的 `LibraryAmbientController` 和悬停防抖。
- 进程观察结果在实际变化时发布，活动记录写入使用独立队列。

## 优先级与落点

### 1. 缓存排布结果，合并比例更新（高）

源码事实：[`LibraryView.swift`](../Whisky/Views/Library/LibraryView.swift) 的 `mixedCoverGrid` 在视图求值时创建 `LibraryCoverGrid`。卡片加载回调逐项更新父视图的 `coverAspectRatios`。元数据读取虽然已经分批发布，图片加载回调仍保留单项写回路径。

[`LibraryCoverGrid.swift`](../WhiskyKit/Sources/WhiskyKit/Library/LibraryCoverGrid.swift) 使用有界动态规划选择每行成员。行成员仅取决于条目顺序、横竖分类与列数；同列数内的宽度变化只影响列宽、封面宽度和高度。

建议：

- 将行成员计算和几何尺寸计算拆开，以“有序条目版本、横竖分类版本、列数”为缓存输入，复用现有打包算法及其输出。
- 合并同一更新周期内的比例变化；混合网格仅在横竖分类变化时重排，精确比例继续供图片裁剪和时间线使用。
- 混合网格当前同时使用行偏移、条目索引和显式条目 ID。检查排序、隐藏、横竖分类变化时的行生命周期；按条目 ID 复用图片与设置状态，减少条目跨行引起的重新加载。

视觉契约：保持当前混排顺序、横封面双列跨度、错落规则、边距与缩放。

### 2. 布局切换复用活动数据，收窄列表更新（高）

源码事实：`LibraryView` 的 `displayMode` 回调每次调用 `refreshActivity()`；[`LibraryModel.swift`](../Whisky/View%20Models/LibraryModel.swift) 随后读取全部条目的活动 JSON，合并结果、排序并重新赋值 `rows`。文件读取通过 `perform` 在后台执行，结果合并和列表发布位于主 actor。`groupsLaunchers` 和 `sort` 的变化也可能分别触发排序。

建议：布局切换直接使用现有活动快照，一次计算目标顺序并发布；活动变化通过详情保存、游戏退出、外部更新和显式刷新驱动。对相同展示值进行去重，逐项刷新有变化的记录。

`visible` 当前每次访问都重新筛选；时间线的行构造还多次访问该属性。将可见条目、日期分组和 ID 集合预先计算为展示快照，可以进一步降低滚动与切换期间的分配、筛选和字符串处理成本。目录变化时统一更新元数据任务版本，可替代每次父视图更新时的全量 ID 排序拼接。

视觉契约：保留当前切换淡入淡出、最近游玩顺序、自动更新与滚动锚点。源码显示 `GameActivityTracker.publishObservation` 已有变化检查，常规轮询的发布频率应以实测记录核对。

Apple 建议通过视图依赖分析缩小更新范围，并将反复执行的过滤等计算移到可复用数据中。[Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/)

### 3. 根据实际像素需求提供封面（高，侧重内存与解码需求）

源码事实：[`ArtworkDiskCache.swift`](../WhiskyKit/Sources/WhiskyKit/PE/ArtworkDiskCache.swift) 对所有用途使用最大边 1024 的缩略图，卡片和详情共用处理结果。

建议按显示点数、屏幕 backing scale、图片裁剪方式、自定义 zoom 和悬停放大系数计算目标像素，再选择 512 / 768 / 1024 / 更大尺寸档位。裁剪计算要覆盖另一条边，保留原图供更大详情图生成；缓存键增加尺寸档位和处理版本。

内存估算：相同比例的 RGBA 图片，最大边由 1024 降至 512，像素占用约为原来的 25%；这是像素数学估算。实际应用内存还包含视图持有、纹理、缓存和过渡期间的双份内容。详情图、Retina、自定义裁剪以及悬停最大缩放时的清晰度共同决定可采用的尺寸。

可见卡片及相邻少量条目获得优先加载；按 URL、尺寸和处理版本合并共享请求，离屏请求按订阅者数量取消。保持有界并发，观察 CPU 峰值和首屏完成时间。

### 4. 图片先交付，磁盘衍生缓存后台写入（中高，侧重冷缓存）

源码事实：[`IconCache.swift`](../WhiskyKit/Sources/WhiskyKit/PE/IconCache.swift) 的 `sampleAndStore` 先生成图片、模糊纹理和调色板，再同步调用 `diskCache.save`，最后返回图片。PNG 编码、原子写入及首次目录清理均占用同一个 actor，后续可见图片请求随队列等待。

建议先写内存缓存并返回可显示图片，再把磁盘编码和写入交给专用有界队列。首次清理独立调度；同一缓存键合并写入，保留现有原子写、源文件变化失效和磁盘预算语义。

同一衍生缓存命中的请求继续复用已有结果。该方案的收益重点是首次加载、缓存淘汰后的快速滚动以及冷启动。

### 5. 清除视图求值路径的同步文件访问（中）

源码事实：`LibraryMetadataArtwork.localURL`、自定义封面解析会调用 `GameMetadataStore.cachedCoverURL` / `customCoverURL`；两者是同步方法，内部调用 `fileExists`。`LibraryModel.updateEntries` 也在主 actor 逐项读取活动记录，更新扫描状态时再次读写目录配置。

建议在后台解析可用封面 URL 与设置，按条目缓存解析结果，通过封面版本、导入、替换和目录变化失效。目录扫描结果与活动记录在后台合成，主 actor 一次发布展示结果。

需要分别记录本地 SSD、冷文件缓存和外置卷下的耗时；这类同步访问在慢卷上可能放大卡顿。

## 渲染优化的适用范围

先记录 GPU 和渲染提交耗时，再决定阴影缓存或局部离屏合成的收益。透明层、动态文字和大型纹理会改变离屏缓存的成本；缩放后的边缘清晰度与阴影外扩区域需要一起检查。

经典卡片里的玻璃控件可以按邻近空间使用 `GlassEffectContainer` 共享采样，检查分组范围与 spacing，保留独立控件形状。当前书架封面的主要实现位于 `LibraryCoverCard`，玻璃优化对应经典卡片分支。Apple 提醒按空间关系分组，分组覆盖过大的区域也会扩大更新范围。[Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)、[Improving your app’s rendering efficiency](https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency)

## 独立排版基准

直接使用当前 `LibraryCoverGrid.swift`，通过 `xcrun swiftc -O` 编译；arm64，Xcode 27.0。输入横封面规则为 `index % 5 == 0 || index % 7 == 0`。每组执行 35 批、每批 10 次，前 5 批预热，统计其余批次每次构造的耗时。宽度为 1020…1029，均为 6 列。

| 条目数 | 中位耗时 / 次 | 批次均值 P95 / 次 |
| --- | ---: | ---: |
| 100 | 0.170 ms | 0.250 ms |
| 500 | 0.595 ms | 0.608 ms |
| 1000 | 1.190 ms | 1.203 ms |

三组在宽度 1020 与 1029 时得到相同的行成员。结果支持缓存排布的可行性。实际卡顿归因还需将构造次数、视图更新、文件访问、图片交付和 GPU 渲染时间对齐。

## 验证顺序与验收

1. 使用相同 Release 构建、数据集、窗口大小、屏幕刷新率和电源模式，记录冷缓存与热缓存。保留原始封面、模式和当前滚动位置。
2. 录制固定路径：连续滚动 20 秒；书架、时间线、经典布局循环切换；拖动窗口跨越列数阈值；混合横竖封面加载；打开并关闭详情。数据集覆盖 100 / 500 / 1000 项以及真实游戏库。
3. 先使用 Instruments 的 SwiftUI 模板关联更新原因、长 body、主线程 CPU 和 Hitches；随后单独检查 Allocations、File Activity、Metal System Trace 和功耗。分开录制可降低工具本身的干扰。Apple 的 SwiftUI 模板包含更新分析、Time Profiler 和响应性工具。[Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/)
4. 在排布、元数据批次、活动刷新、图片解码、PNG 编码与切换完成处添加临时 signpost，分别比较调用次数、累计耗时和最长耗时。
5. 对比帧超时次数与累计超时、切换延迟 P95、主线程忙碌时间、CPU/GPU 时间、峰值及稳定内存。60 Hz 每帧约 16.7 ms，120 Hz 每帧约 8.3 ms；应用工作与渲染共享这段预算。
6. 逐项核对相同封面的裁剪、颜色、模糊强度、阴影、悬停缩放与淡入淡出曲线。每次只改变一个优化方向，保留前后轨迹作为验收证据。

推荐实施顺序：排布和展示快照缓存 → 布局切换数据复用 → 图片写盘解耦 → 按实际像素尺寸供图；每一步完成后复测同一条滚动与切换路径。

## 其他页面与后台任务补充（2026-10-20）

本轮扩展检查容器、程序列表、控制台、诊断、设置、音频、启动及 Steam 监控。以下优先级综合源码路径、触发频率、影响范围和局部基准；真实 GUI 的耗时占比需要按对应场景采集。

| 部分 | 触发范围 | 优先级 | 优化方向 |
| --- | --- | --- | --- |
| 控制台日志 | 打开日志、持续输出 | 高 | 后台增量分类、分批交付、按需加载历史 |
| 诊断日志 | 搜索、过滤及父视图更新 | 高 | 按版本复用富文本、增量更新 NSTextStorage |
| 设置与全局观察 | 修改容器设置、输入程序参数 | 高 | 后台有序保存、定向发布变化 |
| 容器与程序列表 | 进入容器、刷新、修改设置 | 高 | 复用 Program 实例、后台加载设置与快捷方式 |
| 进程监控 | 持续运行，打开进程页时增加订阅 | 中高 | 同一容器共享查询与进行中的请求 |
| 侧栏计数 | 视图求值、刷新及每分钟探测 | 中 | 缓存目录计数、合并探测 |
| 启动及后台扫描 | 启动、多窗口出现、下载停滞 | 中 | 复用已加载数据、限量读尾部、共享任务 |

### 控制台：主线程分类和持续增长的数据

源码落点：[`ConsoleLogView.swift`](../Whisky/Views/Programs/ConsoleLogView.swift) `loadLog`、`loadNewContent`、`classifyLines`，[`ConsoleRunHistoryView.swift`](../Whisky/Views/Programs/ConsoleRunHistoryView.swift) 的两秒刷新，以及 [`ProgramView.swift`](../Whisky/Views/Programs/ProgramView.swift) `findRunEntry`。

打开日志时同步读取整份 UTF-8 文本；运行期间每秒在 MainActor 打开文件、读取追加内容、逐行执行分类并追加到 `logLines`。分类对每行测试至多六个 WINEDEBUG 正则，再检查错误关键字。列表、页脚和滚动定位各自访问 `filteredLines`，会遍历已积累的日志。`logLines` 在页面停留期间持续保留全部行。

运行历史页面每两秒读取并解码 plist，随后直接发布完整 history。`ProgramView` 在构造所选日志时也同步加载 history；输入参数等父视图变化会经过这一构造路径。

另一个具体路径：`loadNewContent` 在追加数据为空时直接返回，退出状态检查位于这条返回语句之后。最后一批日志已读取、退出时保持静默的进程，可能使该页继续保留运行标记和一秒定时器。建议把退出观察交给共享的运行历史状态，使内容读取与运行状态各自更新。

建议使用一个日志读取 actor 管理文件偏移、UTF-8 半字符、未完成行和文件轮转；有界批次读取、后台分类、合并 UI 交付。近期行常驻，旧行通过文件索引分页，完整日志继续支持导出。可见行保持相同字体、通道颜色、筛选结果及滚动行为。历史状态用通知或文件事件更新，按展示值去重。文件事件监控可用 [DispatchSourceFileSystemObject](https://developer.apple.com/documentation/dispatch/dispatchsourcefilesystemobject)，需要同时处理文件替换和重新订阅。

### 日志分类局部基准

独立脚本：[`bench-console-classification.swift`](../scripts/bench-console-classification.swift)。从本轮源码复制现有分类函数；使用合成的普通输出、WINEDEBUG、错误文本和中日文。`swiftc -O`，arm64，预先验证候选输出与当前输出相同，每项执行三次取中位数。前缀候选另外检查大小写、十六进制边界和 Unicode 等 17 个输入。

| 数据量 | 当前分类 | 预编译正则 | 固定前缀与十六进制判断 |
| --- | ---: | ---: | ---: |
| 10,000 行，421,389 字节 | 54.14 ms | 53.30 ms | 37.01 ms |
| 50,000 行，2,151,389 字节 | 279.71 ms | 271.46 ms | 190.28 ms |

固定前缀候选在本数据集中减少约 32% 分类时间。后台处理与分批交付仍是流畅度优化的重点。该基准仅覆盖拆行、分类和结果分配，文件 I/O、SwiftUI 更新、富文本和 GPU 时间属于实际页面采样项目。

复现命令（目录和产物均为一次性研究文件）：

```sh
bench_dir=$(mktemp -d /private/tmp/whisky-console-bench.XXXXXX)
xcrun swiftc -O -module-cache-path "$bench_dir/modules" \
  scripts/bench-console-classification.swift -o "$bench_dir/bench"
"$bench_dir/bench"
```

### 诊断：整段富文本重建和重复资源解码

源码落点：[`LogViewerView.swift`](../Whisky/Views/Diagnostics/LogViewerView.swift) `updateNSView` / `applyContent`，[`DiagnosticsView.swift`](../Whisky/Views/Diagnostics/DiagnosticsView.swift) `resolvedRemediations`，[`PatternLoader.swift`](../WhiskyKit/Sources/WhiskyKit/Diagnostics/PatternLoader.swift) `loadDefaults`。

每次 `updateNSView` 都会拆分全文、筛选、逐行创建富文本，再以 `setAttributedString` 替换整个 text storage。搜索每次输入都会改变输入属性；父视图的其他更新也会调用该桥接方法。Crash-related / 分类过滤还对行逐次查询 matches，长日志与大量匹配并存时会增加工作量。

`resolvedRemediations` 每次求值都会调用 `loadDefaults`，重新读取并解码两份内置 JSON；多个建议分组继续访问这一计算属性。

建议以日志版本、匹配版本、筛选状态和已应用搜索词作为展示键；内容相同时直接复用，筛选索引及格式预处理放到后台，主线程仅提交必要变化。类别匹配使用预计算行集合，复用字号、段落属性和行号索引；保持选区、滚动位置、行号和标记。内置规则在进程内解析一次，展示建议在诊断或相关设置变化时重算。Text storage 的批量编辑继续保留；Apple 说明 `endEditing` 会触发布局管理器更新，因此缩小编辑范围仍有价值。[Synchronizing Editing](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TextEditing/Tasks/BatchEditing.html)

### 设置：同步写盘与全局更新放大

源码落点：[`Bottle.swift`](../WhiskyKit/Sources/WhiskyKit/Whisky/Bottle.swift) 与 [`Program.swift`](../WhiskyKit/Sources/WhiskyKit/Whisky/Program.swift) 的 `settings.didSet`，[`BottleView.swift`](../Whisky/Views/Bottle/BottleView.swift) 的设置观察，[`EnvironmentArgView.swift`](../Whisky/Views/Programs/EnvironmentArgView.swift) 的输入持久化。

Bottle 和 Program 都在 MainActor；settings 每次写入都会同步编码 XML plist 并执行原子保存。程序参数直接绑定 settings，环境变量编辑也逐次持久化。容器 settings 改变后，`BottleView` 将全局 `BottleVM.shared.bottles` 数组重新赋值；整个窗口的观察者、侧栏计数以及 LibraryModel 的设置订阅可能随之更新。`ProgramsView` 还观察完整 settings，并再次检查全部程序文件和排序。

建议 UI 状态立即更新，保存采用每个实体独立的串行后台队列，合并同一编辑周期内的变化、按版本写入；启动、迁移、复制、退出前显式等待相应保存完成。保留原子替换与现有保存错误处理。全局列表只发布容器成员、位置和排序相关变化；程序列表只订阅 pins、blocklist 和程序目录变化。该方案需要覆盖 WhiskyCmd 与应用的跨进程设置可见性。

### 容器：后台扫描完成后的主线程工作

源码落点：[`Bottle+Extensions.swift`](../Whisky/Extensions/Bottle+Extensions.swift) `updateInstalledPrograms` / `getStartMenuPrograms`，[`Bottle.swift`](../WhiskyKit/Sources/WhiskyKit/Whisky/Bottle.swift) `pinnedPrograms`，[`ProgramsView.swift`](../Whisky/Views/Programs/ProgramsView.swift) `loadPrograms`。

已安装程序的目录遍历及 PE 解析已在后台，并合并进行中的扫描。后台结果返回后，主 actor 仍逐项创建 Program、解析设置路径、读取或创建程序 plist，再排序发布。每次进入容器的 `.task` 会请求一次扫描；已完成扫描的跨次缓存可以继续补充。

开始菜单路径仍同步枚举全局与用户目录，解析 `.lnk` 并删除处理完的链接；随后对开始菜单程序与程序列表双重循环匹配，逐项 pin 会触发多次 settings 保存。`pinnedPrograms` 在求值时逐 pin 检查文件、在线性程序列表中查找。

建议后台准备目录、PE、设置及快捷方式的值类型快照；按 URL 复用现有 Program 实例、批量应用 pin 改动、维护 URL 查找表。开始菜单删除和 pin 保存维持一致的失败恢复顺序。ProgramsView 使用已验证的目录快照，搜索结果按输入和目录版本计算；保留当前分组、排序、搜索与插入动画。

### 进程和侧栏：共享观察，降低唤醒和磁盘访问

源码落点：[`ProcessesViewModel.swift`](../Whisky/View%20Models/ProcessesViewModel.swift)、[`GameActivityTracker.swift`](../WhiskyKit/Sources/WhiskyKit/Library/GameActivityTracker.swift)、[`SteamClientOrchestrator.swift`](../WhiskyKit/Sources/WhiskyKit/Steam/SteamClientOrchestrator.swift)、[`BottleListEntry.swift`](../Whisky/Views/Bottle/BottleListEntry.swift)、[`ContentView+Sidebar.swift`](../Whisky/Views/ContentView+Sidebar.swift)。

进程页每三秒独立查询；游戏活动观察使用十秒常规周期、两秒待确认周期；Steam orchestrator 自己有十秒跟踪与一秒内部快照缓存。查询复用目前位于 orchestrator 内部，三个消费者仍可能各自产生同一容器的查询。

建议建立按容器隔离的共享快照服务，合并进行中的请求，在订阅者需求允许的窗口内复用结果。进程页隐藏或窗口遮挡时暂停纯展示轮询；游戏时长、退出确认和启动确认继续按原语义观察。错误与成功空结果保留独立状态；退出确认需要独立的新观察代次，缓存结果的多次读取保持同一代次。

侧栏每个条目在 onAppear、initial onChange 和每分钟探测中计算目录计数，Library 总 badge 又在视图求值期间遍历所有容器计算计数。计数会读取 FolderGameLibrary、LibraryVisibility 等文件并合并条目。建议复用目录版本对应的计数快照，只在 pin、隐藏状态、扫描结果和容器可用性变化时重算；首次探测合并为同一任务。

### 启动、下载和音频：保留既有边界，收窄剩余工作

启动时，`WhiskyApp.updateGPTKPayloadIfNeeded` 和 `BottleVM.loadBottles` 都会加载容器对象；加载过程同步读取容器元数据、验证 pins。ContentView 还同步扫描孤立容器。建议以后台值快照驱动加载，复用已加载容器 URL / 实例；每个进程共享 payload 维护任务，保留当前验证指纹与导入验证语义。

Steam 下载目录快照已经在 utility 任务中执行并支持取消；停滞证据检查只在达到阈值后发生。其 `checkLogEvidence` 会读取最近三份日志全文，再截取末尾 8000 字符，建议改为从文件尾有界读取并正确处理 UTF-8 边界，保持证据范围。该路径重点影响大日志下的后台 I/O 和内存。

音频设备观察使用 CoreAudio 属性监听，配置页还有两秒设备变化防抖；Winetricks 列表与缓存读取通过 detached 任务执行；GPTK 验证与部署也已在后台。以上路径保留现有实现，后续采样重点检查监听者与窗口生命周期、多窗口重复任务、音频设备列表重复枚举。终端设置的安装应用列表可按应用安装变化更新缓存。

## 扩展场景验收顺序

1. 打开 1 万 / 5 万行控制台，持续追加日志，筛选通道并验证静默退出后停止轮询；记录首屏、批次最长主线程时间、常驻内存与唤醒次数。
2. 搜索、过滤大诊断日志并触发建议区更新，比较全文重建次数、编辑范围和滚动稳定性。
3. 在包含大量 EXE 的容器反复导航，连续输入参数与环境变量；记录 Program 新建数量、plist 读写次数、全局发布次数，验证启动时读取最新配置。
4. 同时打开进程页并保持游戏活动跟踪，比较每容器实际子进程查询数；隐藏窗口后核对展示轮询及活动追踪的各自生命周期。
5. 多容器冷启动、多窗口、慢外置卷及大日志下载停滞分别采样。使用 Time Profiler 判断 CPU 工作，用 System Trace 检查文件 I/O、锁等待和线程调度，用 Swift Concurrency 检查 actor / executor 等待；采用同一 Release 构建与固定交互轨迹前后对比。[Profile, fix, and verify: Improve app responsiveness with Instruments](https://developer.apple.com/videos/play/wwdc2026/268/)

扩展部分推荐先处理设置保存与全局发布、控制台后台批次处理、诊断文本复用，再收敛进程查询和侧栏计数。各页面继续使用当前视觉样式和动画参数，以清除主线程工作与重复任务获取收益。


## 已实施的优化（2026-10-20）

基于 `main` 的 `c5d85ed` 和原有工作区修改实现，保留原有封面尺寸、取色、模糊纹理、阴影、悬停缩放与动画时长。

- **游戏库**：复用相同列数和跨度的混合排布；16 ms 合并封面比例回调；时间线单次计算可见条目；目录任务使用成员版本；布局切换复用活动数据并一次排序。
- **图片**：图片完成后立即交付内存结果，PNG 编码、写盘和预算清理由独立 utility 队列执行；衍生写入最多积压 16 项，保留原子写、版本失效与既有缓存预算。
- **控制台**：actor 每批最多读取 256 KiB，保留 UTF-8 片段和尾行；分类采用固定前缀；复用筛选结果；静默日志也观察退出状态。历史记录读取移到后台，程序页复用已加载历史。
- **诊断**：后台生成富文本、取消过期搜索任务、120 ms 搜索防抖；按输入版本复用展示；过滤预先计算行集合；内置诊断规则进程内加载一次。AppKit 主线程提交结果，保留字体、颜色、行号、选择范围和滚动位置。
- **设置**：GUI 将 100 ms 内的同路径保存合并到串行 utility 队列；CLI 保留同步保存。启动、复制、移动、迁移和退出设有落盘屏障；文件身份检测让后发生的外部修改保留优先级。
- **容器与程序**：程序设置随 PE 扫描在后台准备；复用 Program 实例并更新 PE 信息，按编辑版本应用外部设置。开始菜单目录遍历在后台执行，固定项批量提交；程序列表仅订阅相关设置。
- **观察与侧栏**：跨消费者共享同一容器及环境的进行中进程查询，完成后使用新的观察代次；相同进程列表保持已有展示值。侧栏目录计数使用共享后台快照，首轮探测合并，按目录变化失效。
- **启动**：payload 维护直接使用已登记容器路径，减少再次构造全部容器对象的工作。

新增回归覆盖日志小块 UTF-8、尾行追加、截断与替换、正则分类等价、排布几何、设置合并和外部写入优先级、共享查询与新观察，以及扫描期间的编辑保护。完整测试使用 `swift test --package-path WhiskyKit --skip-update --no-parallel`，通过 1,390 项 XCTest（3 项环境条件跳过）与 540 项 Swift Testing。修改文件通过 SwiftFormat、严格 SwiftLint 和 `git diff --check`；本地化覆盖 956 条字符串，第三方声明核对 6 个包、22 个保留文件。

安装与签名结果记录在 `/private/tmp/whisky-performance-deploy/`。运行时帧率和功耗改善继续以真实游戏库操作的 Instruments 前后轨迹作为验收依据。


### 安装验收

Release 已构建并替换 `/Applications/Whisky.app`，来源为 `main c5d85ed` 与当前工作区。严格签名检查通过，已安装 GUI 和 WhiskyCmd 的 SHA-256 与构建产物一致，WhiskyCmd 帮助正常，进程快照 PE 资源与源码目录中的文件一致。独立验收记录为 `/private/tmp/whisky-performance-deploy/main-verification.json`，`verified=true`。

通用打包器的验收模板包含串流分支的 helper 和 Sunshine 项；本次 main 包使用 `WhiskyProcessSnapshot.exe`，采用上述分支对应的验收记录。已启动应用并通过界面树与截图确认时间线、封面和侧栏计数正常呈现。

最终测试统计为 1,387 项 XCTest 通过、3 项环境条件跳过，以及 540 项 Swift Testing 通过。未提交源码的构建指纹与文件清单位于同目录的 `source-manifest.json`。
