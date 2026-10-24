# UI 与运行时解耦

三套前端的定位：

- **macOS 应用保持 SwiftUI。** 现有页面、交互和外观继续演进，不被替换。
- **Linux 的主路径是 GPUI（Rust）。** 它通过 `WhiskyBridge` 的协议调用 Swift 应用服务，
  复用 `WhiskyCore` 的业务模型。GPUI 的视觉与交互基准 demo 只维护在本地工作副本中
  （`demos/gpui-demo`，未纳入版本控制），仓库里没有它的副本。
- **`experimental/SwiftCrossUI` 是实验性、未完成的原型**，保留作参考：它不属于默认构建，
  不被任何 target 链接，也不在迁移路径上。

最新完整页面范围与阶段状态见 [SwiftCrossUI 迁移验收表](swiftcrossui-parity.md)；该表是冻结快照，
不是承诺。下文保留各阶段的历史验证记录。

`portability` 分支采用三层边界：

```text
SwiftUI / Combine            GPUI / Rust（Linux 主路径）        SwiftCrossUI / @State（实验性）
LibraryModel.consume(event)  WhiskyBridgeProtocol → 应用服务     LibraryBrowser.consume(event)
             │                        │                                  │
             └──── LibraryRuntime.events() / WhiskyBridge 协议事件流 ───────┘
                          │
               LibraryRuntimeController
                 WhiskyCore / Foundation
                          │
                 LibraryRuntimeDriver
                          │
             WineLibraryRuntimeDriver / WhiskyKit
               Program / Steam / GameActivityTracker
```


## 已接入生产入口的共享代码

`WhiskyCore` 是独立 Swift 6 包，依赖图只有 Swift 标准库和 Foundation。
它的 manifest 支持 SwiftPM 的各个平台；平台可用性由实际构建和运行分别确认。
macOS 的最低部署版本设为 13，以覆盖使用的 Swift 并发运行时；Linux 测试使用 Swift 6.0。

| 代码 | macOS SwiftUI 应用的实际消费者 | SwiftCrossUI 消费者（实验性） |
| --- | --- | --- |
| `LibraryEntry` / `LibrarySourceID` / `LibraryCatalogue.merge` | 固定程序、Steam 和目录游戏数据源 | 目录扫描结果与稳定行身份 |
| `FolderGameLibrary` / `LibraryVisibility` | 游戏目录扫描、显示控制、运行文件记录 | 读取现有容器和用户选择的目录 |
| `LibraryOrdering` / `LibrarySort` | `LibraryModel.sorted` | 列表排序 |
| `LibraryLaunchSnapshot` / `LibraryEntryState` | `LibraryModel.state(for:)` | 读取相同的运行状态值 |
| `LibraryRuntime` / `LibraryRuntimeController` | 异步启动、取消、超时、进程确认与结果事件 | 同一异步接口和状态机，macOS 可选择连接 Wine |
| `LibraryRuntimeDriver` / `GameActivityObservation` / `LaunchResult` | WhiskyKit 的 Wine 适配器 | 组合入口选择平台驱动，界面消费共享事件 |
| `LibraryCoverGrid` | 现有封面排布和缓存 | 可供后续封面视图使用 |
| `GameMetadata` / `GameMetadataSearch` / `FolderGameMatching` | 现有元数据提供者、搜索和自动匹配 | 可直接复用的服务接口 |
| `LauncherType` / 检测规则 | 现有启动器检测和 Wine 配置扩展 | 条目分类 |
| `ExecutablePicker` / `resolveExecutable` | 异步选取 EXE 并保存映射 | 适配 `chooseFile` 的闭包实现 |
| `ClipboardPreflight` / `ClipboardAccess` | 启动前策略判断和版本匹配清理，macOS 提供剪贴板与对话框适配 | 可注入的值快照与异步决策接口 |
| `TerminalLaunching` / `ProgramUserInteraction` | macOS 终端交接、启动模式与错误提示适配 | 可供其他平台实现的宿主契约 |
| `ArtworkProviding` / `ArtworkAsset` | 原生图标缓存输出编码图片与颜色值 | 工具包解码并显示缩略图 |
| `IconPalette` / `ArtworkPixels` | 主色提取、环境模糊和缩略图像素运算 | 相同的纯像素算法 |
| `GameActivity` / 事务方法 / `GameActivityClock` | 存储入口、会话跟踪、评分和最近游玩排序 | 平台独立的记录格式、所有权与样本规则 |
| `ProcessIdentityProviding` / `ActivityFileLocking` | 可注入的 macOS 进程身份与文件锁适配 | 其他宿主实现同一契约 |
| `LibraryDiscovery` / `LibraryContentProviding` | 内容服务负责发现提交、记录读取、可见性和容器迁移 | 共享扫描入口生成浏览结果，平台组合入口提供数据源 |

GPUI 不直接读取这些 Swift 类型：它通过 `WhiskyBridge` 的协议拿到同一份业务数据，
协议载荷与 `WhiskyCore` 的模型一一对应。因此共享层的新增能力先落在 Core，再由 Swift 应用服务暴露。

`WhiskyKit/WhiskyCore.swift` 用公开类型别名保持原有调用 API。运行时扩展继续放在
WhiskyKit，包括启动器环境配置、跨容器迁移中的程序设置和元数据文件复制。
`Bottle` 和 `Program` 的观察适配使用 Combine。

`MacOSLibraryServices.swift` 负责 `NSOpenPanel` 和 Shift 键读取。
`LibraryModel` 通过构造参数接收文件选择器和启动模式读取器；文件对话框允许异步完成。
选择成功后重新读取当前目录配置，保留对话框等待期间发生的更改。
同一条目的选择请求合并为一个任务，确认游戏进程后继续沿用现有生命周期跟踪。

原生应用继续使用现有 SwiftUI 页面；窗口外观按实际对照检查确认。`LibraryModel` 的程序启动任务、超时、Steam 订阅和进程状态管理
已迁入共享控制器与平台驱动。UI 层负责 EXE 对话框、启动模式输入、本地化和 toast。
`MacOSLibraryServices` 的组合入口注入应用级运行时和 `AppSteamClientDriver`，保留 Steam 下载监控的生命周期钩子。
页面观察任务可以结束，应用级程序启动服务继续持有当前请求。

SwiftCrossUI 通过独立的 `RuntimeComposition.swift` 组合驱动，界面源码只导入共享核心和 UI 框架。
macOS 的 `--enable-wine --bottle <路径>` 显式连接现有 WhiskyKit 运行时；默认使用具名的浏览能力驱动。
浏览数据源读取固定程序、Steam 与目录游戏，文件夹扫描排除已识别的 Steam 目录。
启用运行时后，选取 EXE 使用同一共享用例保存映射，再经相同的启动状态机运行。

## 可复现验证

```sh
swift test --package-path WhiskyCore
swift package dump-package --package-path WhiskyCore > /tmp/whisky-core-package.json
swift scripts/check-portability-boundaries.swift /tmp/whisky-core-package.json
swift test --package-path WhiskyKit \
  --filter 'Library|FolderGame|GameMetadata|GameCover|Launcher|GameActivity|Presentation'

docker run --rm \
  --mount type=bind,source="$PWD/WhiskyCore",target=/source,readonly \
  swift:6.0-noble \
  swift test --package-path /source --scratch-path /tmp/whisky-core-build

swift run --package-path experimental/SwiftCrossUI WhiskyCrossUI
swift run --package-path experimental/SwiftCrossUI WhiskyCrossUI --bottle /path/to/bottle
```

共享核心的测试覆盖排序与启动状态优先级、容器隔离、条目身份、混合封面排布、
中日文标题匹配、旧版目录 JSON、离线目录、Steam 目录排除、符号链接排除，
以及异步文件选择的缓存、取消、文件验证和并发配置更新。

`Portability.yml` 在 Linux Swift 6.0 容器和 macOS 分别构建、运行核心测试。
Linux Gtk 任务只在手动触发（`workflow_dispatch`）时运行，使用 Swift 6.4 调用原型的 `ci/check-linux.sh`，
覆盖完整原型测试产品；普通推送和 PR 不再为原型付出 Gtk 构建成本。
工作流的托管执行结果通过实际运行记录确认。

### 2026-10-21 本地验证记录

- macOS Apple Swift 6.4：核心 24 项测试通过。
- Linux aarch64，官方 `swift:6.0-noble` 容器：核心 24 项测试通过。
- WhiskyKit 游戏库、目录、元数据、启动器、活动与展示回归：126 项通过。
- WhiskyKit Steam、程序设置、容器设置与持久化回归：141 项通过。
- 完整 macOS Debug 应用与 SwiftCrossUI 原型：构建通过。
- 共享核心、原型、文件选择适配及相关视图的定向 SwiftLint，核心与原型的 SwiftFormat，许可清单和差异空白检查通过。
- 完整 WhiskyKit 测试尝试记录到剪贴板错误，并在 GPTK 部署测试的锁等待处停止。
  本轮通过上述两组定向回归确认涉及的生产调用；完整套件结果保持待核验。
- 用户选择本轮完成编译与测试；窗口交互、Linux Gtk、Windows 和托管 CI 执行结果留待后续确认。

命令输出、源码摘要和验证清单保存在本机忽略目录 `build/portability/`。

## 运行时事件契约

- `LibraryLaunchRequest` 携带条目、可选 EXE 和显式启动模式。容器 URL 使用数据源发布的同一身份。
- `LibraryRuntimeDriverSnapshot.revision` 在每次驱动发布时单调递增。控制器丢弃延迟的旧快照，
  每次活动观察按其身份处理退出，保留探测失败时的运行状态。
- 每个 `events()` 调用取得独立队列，并首先收到当前状态。结果和失败事件按顺序交付，
  任一消费者取消后释放自己的订阅；其他消费者继续接收事件。
- 程序请求具有独立 UUID 和超时任务。开始回调只作用于当前请求，进程确认后撤销等待超时；
  超时、取消和容器移除会使该请求的后续回调失效。
- `stopTracking()` 结束 UI 侧 Steam 轮询；应用级活动跟踪继续运行。
- Core 的控制器负责状态转换，Wine 驱动负责真实副作用。驱动内部的 Combine 类型保留在 WhiskyKit。

### 本轮运行时验证

核心增加 10 项异步生命周期回归，覆盖双消费者、独立取消、超时后的迟到回调、
旧快照回放、探测失败、退出后的重新启动、容器移除、已确认进程的超时撤销，以及前端订阅结束后的启动延续。
Linux Swift 6.0 的实际编译帮助修正了嵌套弱引用闭包所需的显式 `self`。
原生驱动测试通过注入程序执行器和 Steam 驱动，执行实际的适配入口并验证配置复用与事件传递。
这些测试的进程观察来自夹具；真实 Wine/Steam 游戏的手动验收保留在后续阶段。

最新记录位于 `build/portability/runtime/verification.json`：macOS 与 Linux 核心各 34 项测试，
WhiskyKit 游戏库与运行时回归 136 项、Steam 与设置回归 141 项，SwiftCrossUI 组合入口 3 项。
原生驱动的 3 项适配测试包含在上述 136 项中。macOS 应用与原型完成编译验证，GUI 与真实游戏验收保持待核验。

## 宿主服务与图片边界

剪贴板策略与判断结果移入 Core。`ClipboardAccess` 提供内容类型、大小、预览与版本快照，
`ClipboardPreflight` 统一处理阈值、启动器策略和用户决定；清理操作检查快照版本，保留等待期间替换的内容。
同步提示接口接入现有 macOS 启动入口，异步提示接口支持未来的工具包对话框。
`MacOSProgramInteraction` 集中 Shift 键、剪贴板提示和启动错误对话框，`Program` 通过接口调用它。

终端脚本生成移入 Core，原生前缀准备与临时文件跟踪继续由 WhiskyKit 承担。
`MacOSTerminalLauncher` 执行选定终端的 AppleScript；脚本路径经过 shell 与 AppleScript 两层转义。
适配测试使用包含空格、引号、反斜杠和 shell 特殊字符的文件名，执行提取的 shell 命令验证字面路径。

`ArtworkAsset` 传递编码图片与颜色值。macOS 的 `IconCache` 使用 ImageIO 和 PE 图标管线生成有尺寸上限的 PNG，
缓存键包含源文件指纹；文件替换回归验证内存缓存随源更新。其他平台的 `FileArtworkProvider` 读取现有图片文件。
SwiftCrossUI 适配层使用 ImageFormats 解码，在后台执行共享缩略图运算，再构造自己的图像对象。
Core 保持 Foundation 依赖；主色、三轮模糊和透明度加权缩略图运算使用纯像素值。

编码输入上限为 16 MiB，解码前检查尺寸与 4 Mi 像素预算，目标缩略图最长边上限为 1024。
头部检查参考 [PNG 规范](https://www.w3.org/TR/png/) 和 [WebP 格式规范](https://www.rfc-editor.org/rfc/rfc9649.html)，
负责提前限定分配预算；完整格式校验由各平台解码器承担。

### 宿主服务阶段验证记录

记录位于 `build/portability/host/verification.json`，对应本阶段源码摘要和完整命令输出：

- macOS Apple Swift 6.4 与 Linux aarch64 Swift 6.0：核心各 47 项测试通过。
- WhiskyKit 宿主适配、图标、展示、程序准备和运行时回归：49 项通过；终端测试另有 21 项通过。
- 上述 49 项中的 4 项宿主适配测试另在受限沙箱内通过，使用注入服务与临时文件。
- SwiftCrossUI 原型 4 项测试通过，覆盖运行时组合、配置保留和图片传输解码。
- 完整 macOS Debug 应用及 SwiftCrossUI 原型编译通过，定向 SwiftLint、SwiftFormat、许可与差异检查通过。

原生图像与终端发现回归在宿主权限环境完成；受限沙箱的首次图像回归出现系统图像上下文等待，
其采样和尝试日志一并保留。新增剪贴板测试使用内存夹具。实际系统剪贴板、终端窗口、游戏启动与两套 UI 交互留待手动验收。
本轮按用户选择完成编译与测试；Linux Gtk、Windows 和托管 CI 的实际执行证据继续补齐。

## Linux Gtk 编译与测试

SwiftCrossUI 原型现已通过 Linux aarch64 的实际编译和链接。环境为官方 `swift:6.4.0-noble` 镜像、
Swift 6.4、Clang 21 与 Gtk 4.14.5；源码以只读方式挂载，构建产物使用独立目录。
全部 3 项 Linux 原型测试通过，覆盖目录配置保留、浏览宿主在 Wine 请求下保留现有容器文件，
以及编码图片的工具包解码和缩略图。macOS 原型的 4 项测试再次通过。
ELF 动态库检查确认运行依赖可以解析。

本阶段暴露了当前工具链的构建范围问题：默认构建器编译了 Windows 的 `WinUIInterop`，
原生构建器的默认全量测试构建又选择了传递依赖中的 Windows 静态库。
验证通过的入口显式使用 `--build-system native`，并通过 `--test-product WhiskyCrossUIPackageTests`
构建、运行本包的完整测试产品。该选项的行为可在 [SwiftPM 6.4 源码](https://github.com/swiftlang/swift-package-manager/blob/swift-6.4.0-RELEASE/Sources/Commands/SwiftTestCommand.swift#L1877-L1921)核对。
原生构建器已有弃用提示，后续 Swift 工具链升级需要重新验证默认构建器。

Gtk 开发依赖安装的 Ubuntu Clang 与 Swift 测试索引参数存在差异；CI 显式选择 Swift 镜像附带的
`/usr/bin/clang-21`，保留测试发现需要的索引生成。上述配置已加入 `Portability.yml` 的 Linux Gtk 任务，
触发路径覆盖 Core、Kit 与原型。托管任务的实际执行结果继续等待提交后的 CI 证据。

完整输出、失败尝试、源码摘要和验证清单位于 `build/portability/linux-crossui/`。
本阶段验证编译、链接与自动化逻辑；实际窗口交互继续沿用用户选择的后续手动验收安排。

## 活动事务与宿主身份

`GameActivity`、所有者、样本令牌、记录结果和 `GameActivityClock` 已迁入 Core。
所有权交接、样本序列去重、退出时间单调更新、评分校验和历史复制使用共享值事务。
生产 `GameActivityStore` 在持锁期间调用这些方法，继续沿用现有 SHA256 文件名、JSON 字段与原子持久化流程。
历史复制保留目标记录的活动所有者、世代和最后样本令牌，后续观察可以继续提交。
WhiskyKit 的公开类型别名和 macOS 所有者初始化扩展承接原有调用入口。

`ProcessIdentityProviding` 提供当前进程身份和存活查询，出生标记按宿主约定解释。
macOS 实现保留 `proc_pidinfo` 的微秒时间标记与 `kill(pid, 0)` 探测；PID 复用由完整身份判断。
`ActivityFileLocking` 定义同步独占临界区，macOS 实现集中 `open`、`flock`、`close` 与目录创建。
存储构造器注入两个宿主服务，省略身份参数的所有权请求使用注入提供者的当前身份。
Core 的评分错误具有独立类型，macOS 存储入口将其映射为原有 Cocoa 校验错误。

本阶段验证记录位于 `build/portability/activity/verification.json`：

- macOS Swift 6.4 与 Linux Swift 6.0：核心各 55 项测试通过，含新增的 8 项活动事务回归。
- WhiskyKit 活动事务、宿主适配、会话生命周期与运行时驱动：24 项通过，含新增的 4 项宿主适配测试。
- 宿主测试验证注入身份与 PID 复用、锁失败时的文件状态、重复提交的通知次数，以及真实文件锁的并发串行更新和异常释放。
- 完整 macOS Debug 应用构建通过，SwiftCrossUI macOS 4 项、Linux Gtk 3 项原型测试通过。
- 定向 SwiftLint、SwiftFormat 与差异检查通过。

Core 继续保持 Foundation 依赖。活动文件的定位、原子写入和通知仍由 WhiskyKit 提供，
其他宿主的进程与锁实现、持久化适配和真实游戏验收继续推进。

## 内容服务与视图模型

`LibraryModel` 通过 `LibraryContentProviding` 请求目录发现、扫描结果提交、活动记录、可见性变更与条目迁移。
`WineLibraryContentService` 实现容器固定程序、程序设置、元数据与活动文件的交接；
`MacOSLibraryServices` 在组合入口注入容器解析器。视图模型保留 Combine 观察、展示排序、错误提示和请求代次管理。
目录发现结果返回后，视图模型先核验请求代次，再调用内容服务提交派生状态。

`LibraryDiscovery.scan` 是原生内容服务与 SwiftCrossUI 浏览入口共用的扫描用例。
其值快照携带条目、容器身份和扫描后的目录索引；提交规则核对根目录、指派目录和排除项，
保留等待期间更新的 EXE 映射与待匹配项。SwiftCrossUI 浏览入口继续保持配置读取语义。
`LibraryModel` 的直接活动存储、元数据复制、Steam 枚举与程序迁移实现已移至服务边界。

本阶段记录位于 `build/portability/content/verification.json`：

- 核心 macOS 与 Linux 各 58 项测试通过，包含新增的 3 项发现提交回归。
- 原生内容服务及相邻目录、活动、生命周期与运行时回归通过，含新增的 4 项内容适配测试。
  夹具验证固定程序设置、元数据、游玩记录和隐藏状态的迁移，以及目录游戏的 EXE 映射和目标所有权保留。
- 完整 macOS Debug 应用构建通过，SwiftCrossUI macOS 4 项、Linux Gtk 3 项测试通过。
- 综合游戏库与宿主组通过 148 项 Swift Testing 和 153 项 XCTest；Steam 与设置组通过 160 项 Swift Testing 和 307 项 XCTest。
  两组存在覆盖交集，验证记录按各命令输出分别计数。

`check-portability-boundaries.swift` 使用 SwiftPM 的实际 manifest 输出核对 Core 的外部包依赖，
并检查共享源码的框架导入。macOS 与 Linux Swift 6.0 上的检查均通过，临时夹具确认 UI 框架和外部包会触发失败。
Core 的两个 CI 任务已接入此检查；Linux Gtk 任务继续调用经本机容器验证的原型入口。

## Linux Gtk 实际窗口验证

原型已在 Linux aarch64 的 Xvfb 显示中实际启动，通过 AT-SPI 操作真实 Gtk 控件，
并使用 X11 完成目录位置输入。测试使用独立临时目录，保留截图、辅助功能树、应用日志和配置文件摘要。
固定配置与隐藏过滤、大小写不敏感搜索、行选择与浏览模式按钮、排序按钮可用性、目录接受和取消共 6 项检查通过。
目录夹具每轮采用唯一名称，验证实际选择的数据来源；浏览前后的配置摘要一致。

实际交互暴露了上游通用文件对话框的目录选择问题：目录请求使用文件打开动作后，
选择目录继续触发导航，对话框保持打开。Core 新增 `DirectoryPicking` 宿主接口，
Linux 的 `GtkDirectoryPicker` 显式使用目录选择动作，并管理单次请求身份、任务取消和 Gtk 资源。
界面在组合入口接收该适配器，其他后端沿用各自的工具包文件选择能力。
修复前的失败截图与日志保留在本机证据目录。

截图检查还确认了列表文字的布局修正：名称采用单行和可扩展宽度，容器名与状态保留单行，
短标题和状态可以完整显示。测试通过辅助功能选择接口验证列表；本 Gtk 版本的部分组件坐标与焦点接口
会返回零坐标或错误，探测记录一并保留。截图在 Gtk 帧发布后采集。

本阶段记录位于 `build/portability/gui-linux/verification.json`，最终截图与控件状态位于
`visual-acceptance-smoke/`。共享核心 macOS 与 Linux 各 58 项测试通过；
macOS 原型 4 项、Linux 原型 4 项测试通过，新增 Linux 取消请求回归；完整 macOS Debug 构建通过。
最终窗口测试运行期间应用保持存活，结束时由测试脚本清理进程，原生日志的 critical 与 fatal 检查通过。
Linux Gtk CI 任务已接入真实窗口检查和截图归档，托管执行结果继续等待实际 CI 运行。

## 当前验收证据

| 目标要求 | 当前证据 | 状态 |
| --- | --- | --- |
| 在 portability 分支实施 | 当前分支及源码摘要随每阶段验证记录保存，保留原有工作区改动 | 已验证 |
| 共享逻辑与 UI 观察机制分离 | Core 承担目录、排序、元数据、启动状态机与活动事务；两套前端消费共享值和接口 | 编译与自动化验证通过 |
| SwiftCrossUI 适配 | macOS 与 Linux Gtk 的编译、链接和单元测试，Linux 的实际窗口与目录对话框检查 | 本机编译、逻辑与 Gtk 窗口自动化通过 |
| 降低 macOS 耦合 | Core 的 Foundation 依赖边界；终端、剪贴板、图片、身份、锁、运行时与内容服务的宿主适配 | 边界检查及适配回归通过 |
| 为平台移植保留可复现入口 | Swift 6.0 核心、Swift 6.4 Gtk 脚本、固定依赖许可、CI 定义与迁移边界记录 | 本机验证通过，托管执行待确认 |
| 窗口与真实宿主交互 | Linux 虚拟显示中的实际 Gtk 控件已验证；macOS 窗口和真实游戏保留后续安排 | Gtk 自动化通过，人工与真实游戏验收待进行 |

## 继续推进的边界

| 边界 | 当前实现 | 后续验收证据 |
| --- | --- | --- |
| Wine 运行时 | 共享请求与状态机，WhiskyKit 驱动承载 macOS 副作用 | 真实 Wine/Steam 游戏验收、Linux Wine 驱动 |
| UI 状态观察 | 两套前端消费共享事件，Linux Gtk 窗口已验证搜索、选择和目录切换 | macOS 窗口交互与应用级生命周期验收 |
| 图片与图标 | 共享编码图片与像素接口，原生缓存适配和 SwiftCrossUI 缩略图已接入 | Linux 可执行文件图标适配、两套窗口图片验收 |
| 宿主服务 | 共享终端、剪贴板、进程身份和文件锁契约，macOS 适配与注入测试 | 其他平台实现、真实宿主交互；文件显示继续拆分 |
| 活动记录 | 共享记录格式、事务与时钟，生产存储调用共享规则 | 其他宿主的持久化适配与进程级锁验收 |
| 系统配置 | macOS 路径、Wine 图形后端和字体部署 | 显式运行时配置、平台能力查询和 Linux 默认路径 |
| 窗口与平台验收 | macOS 完整构建，原型双平台测试，Linux Gtk 实际窗口自动化 | macOS 窗口交互、Windows 核心构建、托管 CI 执行 |

SwiftCrossUI 的 `@State` / `@Published` 与 Combine 的观察类型分别属于各自框架。
共享核心传递值、异步操作和具名能力接口，前端负责观察机制和本地化字符串。
SwiftCrossUI 源码和系统后端要求见其[官方仓库](https://github.com/moreSwift/swift-cross-ui)。

## 完整 SwiftCrossUI 界面迁移阶段

用户将目标扩展为双平台完整界面复刻，并明确排除 Linux Wine 运行时。逐页范围和完成证据由
[swiftcrossui-parity.md](swiftcrossui-parity.md) 跟踪。当前主窗口已从简易列表替换为侧栏、三种游戏库布局和基础详情，
读取真实元数据、活动记录与封面，连接评分和可见性存储。原版其余页面与交互继续按表迁移。

Steam 的 VDF 解析、应用清单、目录发现与缓存图片选择迁入共享 Core，WhiskyKit 保留公开类型别名和运行时扩展。
`LibraryStorageLayout` 统一原版 SHA256 文件键；Core 的文件读取与原生存储共享这些定位规则。
新增存储键用标准向量和原生 CryptoKit 交叉核验，跨工具包读取用原生存储产生的夹具验证。

macOS 应用包具有独立身份，通过 `WhiskyDataBundleIdentifier` 显式连接原版数据目录。`BuildInfo.json` 记录实际二进制与源码摘要。
编译、单元测试、实际窗口交互、视觉接近程度和完整页面覆盖分别验收。
