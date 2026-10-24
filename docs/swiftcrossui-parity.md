# SwiftCrossUI 完整界面迁移验收表（冻结快照）

> **这是一份冻结的状态快照，不是承诺，也不是路线图。**
> 记录于 2026-10-21，对应当时的工作区。下表中的「待迁移」只是当时的实际状态：
> 该原型**未完成且处于实验阶段**，后续不会按这张表继续推进。
>
> 当前方向：macOS 应用保持 SwiftUI；Linux 的主路径是 GPUI（Rust，经 `WhiskyBridge` 调用 Swift 应用服务）。
> `experimental/SwiftCrossUI` 仅作参考保留：不属于默认构建，不被任何 target 链接，不在迁移路径上。
> GPUI 的视觉基准 demo 只维护在本地工作副本中（`demos/gpui-demo`，未纳入版本控制）。

历史目标（当时记录）：在 macOS AppKit 与 Linux Gtk 上复刻当前 Whisky 的完整页面、布局和操作，并连接真实共享逻辑与宿主服务。用户明确将 Linux Wine 运行时排除在本阶段范围外，其余功能继续按完整程度验收。

基准：`portability` 当前 SwiftUI 工作区；每次验收记录源码摘要、构建产物、窗口截图、实际操作与持久化结果。
原生 SwiftUI 应用继续作为对照。编译、逻辑回归、实际服务调用、窗口操作与视觉一致性分别记录。

## 必须覆盖的功能

| 范围 | 要求 | 当前迁移状态 |
| --- | --- | --- |
| 应用外壳 | 侧栏、容器切换、工具栏、返回导航、搜索、窗口尺寸、菜单 | 实现中 |
| 游戏库 | 书架混合封面、时间线、经典卡片、排序、隐藏、刷新与滚动保持 | 实现中 |
| 游戏详情 | 资料、封面、活动、评分、元数据搜索/关联/解除、自定义封面、布局设置 | 待迁移 |
| 游戏操作 | 启动、EXE 选择、取消、停止、程序设置、容器迁移、文件显示 | 共享服务已存在，完整界面接入待完成 |
| 容器 | 创建、导入、迁移、重命名、复制、移除、固定程序与运行文件 | 待迁移 |
| 容器配置 | Wine、启动器、输入、图形、音频、Discord、分辨率、性能、DLL、依赖、清理 | 九组基础字段已接入文件保存；DPI、Retina、DLL、依赖、诊断和完整视觉仍待迁移 |
| 程序 | 列表、固定、隐藏、区域、参数、环境变量、DLL、快捷方式、运行历史与控制台 | 扫描、固定、隐藏恢复、区域、参数及环境变量已接入；其余待迁移 |
| 进程 | 枚举、刷新、单独结束、容器结束与关闭策略 | macOS 接入原版 Wine 枚举和结束命令；实际运行验收、完整布局与关闭策略待补 |
| 游戏配置库 | 搜索、详情、版本选择、预览、应用与回退 | 待迁移 |
| 诊断 | 日志、报告、历史、导出、修复、验证、向导与恢复会话 | 待迁移 |
| 音频工具 | 设备列表、状态、发现、测试、设置、历史与诊断向导 | 待迁移 |
| 安装与设置 | 引导、运行时安装、依赖安装、Winetricks、应用设置、网络与隐私 | 待迁移 |
| 系统整合 | 文件打开/拖放、托盘/菜单栏、快捷方式、更新与平台能力说明 | 待迁移 |
| 双平台运行 | macOS 实际 Wine/Steam；两端持久化、图标和宿主实现；Linux Wine 运行时由用户排除 | 待接入/验收 |
| 视觉与交互 | 每页同数据对照、空态、加载、失败、长文本、缩放、暗色、键盘和辅助功能 | 待双平台完整验收 |

## 当前实现边界

- 主窗口已接入真实容器注册表、固定程序、Steam 与目录游戏；包含搜索、排序、书架、时间线、经典卡片和基础详情。
- 两套前端共用 Steam VDF/ACF 解析与目录发现；元数据、活动记录和封面缓存沿用原版布局。
- 详情的评分与隐藏操作已连接真实存储；回归验证评分变更保留活动所有者、样本令牌和累计时长。
- macOS 按钮通过独立 AppKit 适配提供原生文字、键盘焦点和辅助功能；Gtk 使用工具包按钮。
- 这部分仍处于逐项复刻阶段：原版工具栏图标、时间轴连接线、封面环境效果、完整详情菜单与全部其他页面继续迁移。
- macOS 侧栏与旧原版侧栏的 5 项计数差来自 Steam：旧侧栏计数代码只合并固定程序和已知目录；新侧栏包含实际发现的 5 个 Steam 游戏。

主窗口检查与基础详情检查覆盖真实资料浏览、按需封面缓存，以及隔离夹具中的逻辑回归。真实游戏启动与全部页面的最终对照保留独立证据。

## 原生源文件清单

此表保留完整范围；相关组件可合并为一个等价页面，但需要逐项给出对应实现和双平台证据。

| 原生文件 | SwiftCrossUI 对应实现 | macOS | Linux |
| --- | --- | --- | --- |
| `Whisky/Views/Audio/AudioAlertTracker.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Audio/AudioDeviceHistoryView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Audio/AudioDeviceListView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Audio/AudioFindingsView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Audio/AudioSettingsView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Audio/AudioStatusView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Audio/AudioTestButtonsView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Audio/AudioTroubleshootingWizardView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Bottle/AudioConfigSection.swift` | `ContainerConfiguration` 基础字段；完整交互与视觉待补 | 编译/配置格式互通通过 | 部分窗口检查通过 |
| `Whisky/Views/Bottle/BackendPickerView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Bottle/BottleActionBar.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Bottle/BottleCreationView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Bottle/BottleListEntry.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Bottle/BottleView.swift` | `ContainerOverview`；生命周期、游戏配置库与其他底栏入口待补 | 编译通过；窗口待验证 | 概览/返回/固定重读通过 |
| `Whisky/Views/Bottle/CleanupConfigSection.swift` | `ContainerConfiguration` 基础字段；完整交互与视觉待补 | 编译/配置格式互通通过 | 部分窗口检查通过 |
| `Whisky/Views/Bottle/ConfigView.swift` | `ContainerConfigurationView` / `ConfigurationEditor`；基础字段，完整范围见上表 | 编译及原版配置互通通过 | 基础配置编辑通过 |
| `Whisky/Views/Bottle/DLLOverrideConfigSection.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Bottle/DLLOverrideEditor.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Bottle/DPIConfigSheetView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Bottle/DXVKSettingsView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Bottle/DependencyConfigSection.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Bottle/DiscordConfigSection.swift` | `ContainerConfiguration` 基础字段；完整交互与视觉待补 | 编译/配置格式互通通过 | 部分窗口检查通过 |
| `Whisky/Views/Bottle/GraphicsConfigSection.swift` | `ContainerConfiguration` 基础字段；完整交互与视觉待补 | 编译/配置格式互通通过 | 部分窗口检查通过 |
| `Whisky/Views/Bottle/InputConfigSection.swift` | `ContainerConfiguration` 基础字段；完整交互与视觉待补 | 编译/配置格式互通通过 | 部分窗口检查通过 |
| `Whisky/Views/Bottle/LauncherConfigSection.swift` | `ContainerConfiguration` 基础字段；完整交互与视觉待补 | 编译/配置格式互通通过 | 部分窗口检查通过 |
| `Whisky/Views/Bottle/MetalConfigSection.swift` | `ContainerConfiguration` 基础字段；完整交互与视觉待补 | 编译/配置格式互通通过 | 部分窗口检查通过 |
| `Whisky/Views/Bottle/PerformanceConfigSection.swift` | `ContainerConfiguration` 基础字段；完整交互与视觉待补 | 编译/配置格式互通通过 | 部分窗口检查通过 |
| `Whisky/Views/Bottle/Pins/PinAddView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Bottle/Pins/PinCreationView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Bottle/Pins/PinView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Bottle/ResolutionConfigSection.swift` | `ContainerConfiguration` 基础字段；完整交互与视觉待补 | 编译/配置格式互通通过 | 部分窗口检查通过 |
| `Whisky/Views/Bottle/RunningProcessesView.swift` | `ContainerProcessesView`；macOS 原版 Wine 服务 | 编译通过；实际进程操作待验收 | 平台能力页通过；Wine 由用户排除 |
| `Whisky/Views/Bottle/SettingItemView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Bottle/WineConfigSection.swift` | Windows/增强同步/AVX 字段；版本信息、Retina 与 DPI 待补 | 编译/配置格式互通通过；注册表操作待验收 | 配置开关保存通过 |
| `Whisky/Views/Bottle/WinetricksView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Common/ActionView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Common/BottomBar.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Common/LaunchTimeBanner.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Common/RenameView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Common/StatusToast.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/ContentView+Sidebar.swift` | `WorkspaceView.sidebar`；容器操作待补 | 基础切换通过 | 基础切换通过 |
| `Whisky/Views/ContentView.swift` | `WorkspaceView` 基础外壳；完整导航待补 | 部分窗口通过 | 部分窗口通过 |
| `Whisky/Views/Diagnostics/DiagnosisHistoryView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Diagnostics/DiagnosticExportSheet.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Diagnostics/DiagnosticLogRenderer.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Diagnostics/DiagnosticsView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Diagnostics/LogViewerView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Diagnostics/RemediationCardView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/DiagnosticsPickerSheet.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/FileOpenView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/GameDB/GameConfigBannerView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/GameDB/GameConfigPreviewSheet.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/GameDB/GameConfigurationView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/GameDB/GameEntryDetailView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/GameDB/GameEntryRowView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/GameDB/GameVariantPickerView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Install/DependencyInstallSheet.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Library/LibraryCard.swift` | `WorkspaceLibrary.classicCards`；菜单待补 | 基础布局检查 | 基础布局检查 |
| `Whisky/Views/Library/LibraryGameSheet.swift` | `WorkspaceGameDetail`；资料编辑与封面设置待补 | 基础详情检查 | 基础详情检查 |
| `Whisky/Views/Library/LibraryView.swift` | `WorkspaceLibrary`；完整选项与视觉细节待补 | 三种布局检查 | 三种布局检查 |
| `Whisky/Views/MenuBar/WhiskyMenuBarView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/MigrateBottlesSheet.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Programs/ConsoleLogView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Programs/ConsoleRunHistoryView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Programs/EnvironmentArgView.swift` | `ProgramSettingsPage` 环境变量编辑器；布局对照待补 | 编译通过；窗口待验证 | 真实文件保存通过 |
| `Whisky/Views/Programs/ProgramMenuView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Programs/ProgramOverrideSettingsView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Programs/ProgramView.swift` | `ProgramSettingsPage`；基础配置与环境，其他分组待补 | 编译及原版程序设置互通通过 | 参数/环境保存通过 |
| `Whisky/Views/Programs/ProgramsView.swift` | `ContainerProgramsView`；批量选择、菜单与布局待补 | 编译通过；窗口待验证 | 扫描/固定/隐藏恢复通过 |
| `Whisky/Views/Settings/GPTKSettingsSection.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Settings/SettingsView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Setup/RosettaView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Setup/SetupView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Setup/WelcomeView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Setup/WhiskyWineDownloadFormatting.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Setup/WhiskyWineDownloadView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Setup/WhiskyWineInstallView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/SparkleView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Troubleshooting/BranchExplanationView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Troubleshooting/EscalationView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Troubleshooting/FixPreviewView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Troubleshooting/FixVerifyView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Troubleshooting/ProgressRailView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Troubleshooting/SessionResumeView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Troubleshooting/StepCardView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Troubleshooting/SymptomPickerView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Troubleshooting/TroubleshootingEntryBanner.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Troubleshooting/TroubleshootingHistoryView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Troubleshooting/TroubleshootingTargetPicker.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/Troubleshooting/TroubleshootingWizardView.swift` | 待迁移 | 待验证 | 待验证 |
| `Whisky/Views/WhiskyApp.swift` | 待迁移 | 待验证 | 待验证 |

## 本阶段验证记录

证据位于本机 `build/portability/crossui-parity/verification.json`。共享核心 macOS 与 Linux Swift 6.0 各 97 项测试通过；
SwiftCrossUI 两端各 8 项测试通过；原生 Steam、资料与活动回归通过 67 项 Swift Testing 和 6 项 XCTest。
Gtk 的 6 项实际窗口检查通过，截图确认三种布局；macOS 已操作搜索、基础详情和视图切换，并确认经典卡片修复后同一进程保持存活。
最终 macOS 包完成编译、签名与源码摘要核对，最后一轮窗口对照遇到锁屏，保留待验证。完整界面验收仍按上表逐页推进。

最新检查应用：`build/portability/WhiskyCrossUI-Review.app`。旁边的 `.build.json` 保存签名后摘要；
包内 `BuildInfo.json` 保存编译输出摘要和源码摘要，两者分别对应签名处理前后的产物。

## 容器与程序阶段

证据位于 `build/portability/crossui-containers/verification.json`，后续构建分别记录源码与二进制摘要。

- 真正的容器侧栏进入概览、程序列表、配置和进程页；普通游戏目录继续进入游戏库。概览读取真实固定程序，程序扫描复用从原版抽出的 `InstalledPrograms`。
- 配置与固定/隐藏更新在文件锁内重读最新 plist、局部修改并原子保存，保留未知字段、原 plist 格式和旧程序设置。符号链接按实际文件去重，同时保留固定程序原始路径。
- 程序设置采用原版共享身份；旧文件只在首次编辑时复制到身份路径。语言区域同时更新 LANG/LC_ALL，环境变量按单个键更新。
- 配置中的 Windows 版本、虚拟桌面和分辨率接到 macOS 原版注册表服务；其他基础字段供原版启动入口使用。旧 DXVK 配置按原版规则读取。选择器初始化时保持现有值。
- macOS 进程操作先核对当前 PID 与映像名称，执行原版命令并检查退出码；命令等待上限为 30 秒。Linux 显示平台能力说明。实际 macOS Wine 操作仍待验收。
- 本阶段增加了导航和基础编辑能力。完整视觉对照、容器生命周期、程序覆盖设置/快捷方式/日志、DLL/依赖、游戏配置库、诊断、音频工具、安装与应用设置继续按完整范围推进。

本阶段核心测试 macOS 与 Linux Swift 6.0 各 104 项通过，SwiftCrossUI 原型两端分别 12 项、9 项通过。
原版定向回归通过 49 项 XCTest 与 7 项 Swift Testing。Linux 游戏库 6 项、容器 8 项实际窗口检查通过，使用同一个最终 ELF 二进制；
容器检查包含旧 DXVK 读取、数字输入错误反馈、文件写入范围、返回后开关状态与固定程序重读。
macOS 新页面完成编译、签名和源码摘要核对，窗口及真实 Wine 操作因锁屏保留待验收。完整目标继续保持进行中。
