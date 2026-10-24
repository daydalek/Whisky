# Linux 功能对齐修复记录

日期：2026-10-24。基线：`5713362`。本记录区分实际实现、能力限制与验收范围。

## 已修复的执行链路

- 退出策略：Linux 读取全局 `killOnTerminate` 和 Bottle `killOnQuit`，执行并检查 wineserver 退出。失败通过桥接返回，GPUI 保留窗口并允许重试；连接释放继续保留游戏进程。
- 单游戏停止：普通程序采用 SwiftUI 的运行能力边界。进程页面提供明确的单 PID 终止与整瓶终止；调用错误、超时均返回失败。
- 虚拟桌面：程序覆盖转换为 `explorer /desktop=...` 参数；Bottle 修改通过 UTF-16LE 注册表导入执行，失败保持原配置。Linux 选项覆盖固定和自定义分辨率。
- 音频延迟与 GPU 伪装：启动前同步 DirectSound `HelBuflen` 和 WineD3D PCI 标识，注册表导入及状态标记在同一把锁内更新，失败可以重试。DXVK 显式选择会检查前缀 DLL，并提供缺少组件的错误。
- 启动取消：取消启动等待会终止该次启动进程并完成失败历史。
- 运行观察：按真实 Windows 进程名称、游戏目录内可执行文件集合和启动选择匹配条目；同瓶无关进程与后台 wineserver 独立于目标游戏状态。
- 活动记录：使用共享 `GameActivityClock`、跨进程文件锁和观察者租约保存游戏时长、最近游玩及会话结束；启动器参与观察，活动写入覆盖游戏条目。
- 运行历史：库启动和直接运行均写入原生兼容的 run-history plist，保留退出码与独立日志。
- 程序设置：Linux 的图形、同步与分辨率选项按平台过滤；导入的 macOS 设置在界面映射到 Linux 的有效选项。隐藏的 Metal 字段保存在原文档中。

## 当前能力边界

以下功能仍需要独立的 Linux 实现，界面和配置 schema 采取能力限制：

- Steam 专用登录就绪、游戏启动编排及下载状态。
- Discord presence/IPC、指定音频设备、启动前剪贴板策略、自动启动器检测与 Rockstar 后端自动部署。
- AVX 模拟开关、MSync、D3DMetal/DXMT/Metal 4、自动匹配显示器尺寸。
- 游戏条目跨 Bottle 移动、Wine 音频探针、修复/缓存维护等缺少服务的方法。
- GameDB 继续提供带 macOS 来源标记的配置参考。
- GPUI 的菜单栏、完整本地化和部分 SwiftUI 外观能力。

容器创建/导入/移动/复制/删除/导出、元数据与封面、文件选择器、终端、桌面快捷方式和 Wine 下载更新继续使用已有实际服务。

## 验证

`LinuxParityTests.swift` 使用隔离前缀和真实子进程脚本，在生产服务入口注入 Wine 返回码，覆盖注册表失败、退出策略、进程错误、取消、状态匹配、活动及历史持久化。

Linux Swift 桥接回归、GPUI Rust 回归、Rust SDK 传输和真实 helper 集成，以及 macOS 共享/原生桥接回归均纳入此次验证。Xvfb 中的生产窗口完成程序参数编辑、保存、重载和退出，并保留截图。

证据目录：`build/portability/wine-update/parity-fixes/`；日志：同级 `parity-fixes-*.log`。Linux 本机容器为 ARM64，Wine 命令回归采用隔离脚本；真实 amd64 Wine、GPU、音频与游戏验收仍需单独执行。

本轮结果：Linux Core 116、Bridge 128、GPUI 129 项通过；macOS Bridge 128、原生适配器 12、GPUI 128 项通过。Rust SDK 的 2 项单元、4 项传输回归和 1 项真实 helper 集成通过。

生产窗口额外验证了注入退出清理失败后窗口保持打开、错误可见、用户可显式退出。该场景已接入 Portability 工作流，线上执行结果需由后续 CI 提供。

新增 Swift 文件及运行驱动通过定向严格 lint；仓库既有大文件、复杂度等 lint 问题保留在原文件中。
