# Whisky SwiftCrossUI prototype

这个应用直接依赖 `WhiskyCore`，通过 SwiftCrossUI 的 AppKit / Gtk 后端显示游戏库。
当前主窗口包括容器侧栏、书架、时间线、经典卡片和游戏详情，读取原版元数据、封面与游玩记录。
评分和隐藏操作写入原版文件格式。完整页面迁移范围及状态见 [逐页验收表](../../docs/swiftcrossui-parity.md)。
容器概览、程序列表、九组基础配置、程序参数/语言/环境变量和进程页面已经接入；其余范围继续按验收表推进。

macOS 默认读取原版容器注册表并连接 WhiskyKit 运行时；`--browse-only` 提供浏览检查入口。
Linux 默认使用 `$XDG_CONFIG_HOME/whisky/BottleVM.plist`，也可以通过 `--registry` 或 `--bottle` 指定数据。
Linux Wine 运行时由用户明确排除在当前完整界面迁移范围外。

```sh
swift run --package-path experimental/SwiftCrossUI WhiskyCrossUI
swift run --package-path experimental/SwiftCrossUI WhiskyCrossUI --bottle /path/to/bottle
swift run --package-path experimental/SwiftCrossUI WhiskyCrossUI --browse-only --bottle /path/to/bottle
swift test --package-path experimental/SwiftCrossUI
# macOS：生成可双击的应用包 build/portability/WhiskyCrossUI.app
bash experimental/SwiftCrossUI/ci/package-macos.sh
```

本轮验证工具链：macOS / Apple Swift 6.4。`Package.resolved` 固定本轮解析的依赖版本；
其中的 swift-collections 和 xctest-dynamic-overlay 要求 Swift 6.4。
`WhiskyCore` 单独保持 Swift 6.0 工具版本，适合独立验证基础平台兼容性。
SwiftCrossUI 固定在 `0f3ec3958b79cdc39a1a3e604516b71ab33a9043`（v0.10.0）。

Linux Gtk 后端需要 `libgtk-4-dev`、`clang` 和 `pkg-config`，具体要求以
[上游后端文档](https://github.com/moreSwift/swift-cross-ui/blob/0f3ec3958b79cdc39a1a3e604516b71ab33a9043/Sources/SwiftCrossUI/SwiftCrossUI.docc/Backends/GtkBackend.md)为准。
Windows 的 WinUI 后端构建要求见[上游文档](https://docs.swiftcrossui.dev/documentation/swiftcrossui/winuibackend)。

Linux 构建入口使用 Swift 6.4，与本原型锁定依赖的工具版本一致。
在安装上述 Gtk 开发依赖后运行：

```sh
CC=clang-21 CXX=clang-21 bash experimental/SwiftCrossUI/ci/check-linux.sh
```

脚本使用 `build/portability/linux-crossui/swiftpm` 保存 Linux 构建产物，执行固定依赖的编译和测试。
`WHISKY_CROSSUI_BUILD_DIR` 可指定独立构建目录。`Portability.yml` 的 Linux Gtk 任务调用同一入口。
CI 使用官方 `swift:6.4.0-noble` 镜像并选择镜像附带的 Clang 21，满足 SwiftPM 测试发现的索引生成需求。
当前依赖图使用 SwiftPM `native` 构建器和完整的 `WhiskyCrossUIPackageTests` 测试产品；
Swift 6.4 的默认构建器和全量产品测试构建会引入 Windows 后端的编译单元。
`native` 在 Swift 6.4 中已有弃用提示，后续工具链升级需要重新验证默认构建器。

Linux 的真实窗口自动化检查使用 Xvfb、AT-SPI 和 X11。安装测试工具后运行：

```sh
sudo apt install xvfb xauth dbus-x11 python3-pyatspi imagemagick fonts-noto-cjk xdotool
bash experimental/SwiftCrossUI/ci/smoke-linux.sh
```

脚本创建临时目录游戏库，检查加载与隐藏过滤、搜索、行选择、浏览能力按钮、排序按钮可用性、
目录选择和取消，并核对配置文件摘要。截图、辅助功能树与 `result.json` 保存在
`build/portability/gui-linux/` 的独立运行目录；`WHISKY_GUI_OUTPUT_DIR` 可指定输出位置。
CI 的 Gtk 任务执行同一脚本，并保存测试证据。

Linux 目录选择通过 Core 的 `DirectoryPicking` 接口连接 `GtkDirectoryPicker`。
该适配器显式使用 Gtk 的目录选择动作，并管理请求取消、对话框和路径资源的生命周期。
它修复了当前上游通用文件对话框将目录请求交给文件打开模式时的交互问题。

共享层、生产调用位置与后续迁移边界见 [portability.md](../../docs/portability.md)。
应用包保留 `BuildInfo.json`，记录实际二进制与源码摘要。打包通过目录替换保留先前构建，避免覆盖正在运行的可执行文件。
依赖源码通过 SwiftPM 获取；本原型的依赖许可原文保存在 `ThirdParty/`。

`RuntimeComposition.swift` 集中平台驱动和平台数据源。`WorkspaceView.swift` 的视图通过
`LibraryRuntime` 消费 `AsyncStream` 事件，使用共享控制器处理启动超时和进程确认。
macOS 的运行时要求现有、可解码的 `Metadata.plist`；校验失败时保留浏览能力。
Linux 提供共享界面、真实配置编辑与文件读写，Wine 运行时由用户排除。Windows 后端运行保持待验证。

图片通过 `ArtworkProviding` 传输编码数据。macOS 使用原生图标缓存适配器，其他平台读取现有图片文件；
`ArtworkThumbnail.swift` 使用 ImageFormats 解码，并复用 Core 的透明度加权缩略图运算。
尺寸与输入预算检查在解码前完成，UI 图像对象由 SwiftCrossUI 适配层持有。
最新阶段 macOS 的 12 项原型测试与 Linux 的 9 项原型测试通过；包含真实文件锁并发更新，macOS 另验证原版配置编解码和程序加载入口。
Linux 窗口检查分为游戏库和容器两组；容器组使用隔离 prefix 验证固定/隐藏、程序参数、环境变量、配置保存与错误反馈。
macOS 新页面窗口交互、真实 Wine 操作和 Windows 后端运行保持待验证。

```sh
WHISKY_GUI_SCENARIO=containers bash experimental/SwiftCrossUI/ci/smoke-linux.sh
```
