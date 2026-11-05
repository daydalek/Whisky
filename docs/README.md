# Documentation Index

Whisky 仓库的文档索引。语言说明：部分文档为英文、部分为中文（以各篇标题为准）。

## Getting started / 入门

| Doc | 内容 |
| --- | --- |
| [BUILDING.md](BUILDING.md) | 统一构建入口（`build.sh`）、命令行与 CI 用法（中文） |
| [SUPPORT.md](SUPPORT.md) | 用户支持与提问前自查（English） |
| [GOVERNANCE.md](GOVERNANCE.md) | 维护者与发布流程（English） |
| [DEPENDENCIES.md](DEPENDENCIES.md) | 运行时依赖清单（English） |

## Architecture / 架构

| Doc | 内容 |
| --- | --- |
| [portability.md](portability.md) | UI 与运行时解耦、三套界面（SwiftUI / GPUI / SwiftCrossUI）的定位（中文） |
| [gpui-port/PLAN.md](gpui-port/PLAN.md) | GPUI 移植总纲（English） |
| [gpui-port/LINUX.md](gpui-port/LINUX.md) | Linux 适配与无头验证（English） |
| [gpui-port/LINUX_PARITY.md](gpui-port/LINUX_PARITY.md) | Linux 功能对齐修复记录（中文） |
| [gpui-port/LINUX_WINE_UPDATES.md](gpui-port/LINUX_WINE_UPDATES.md) | Linux Wine 下载与更新契约（English） |
| [swiftcrossui-parity.md](swiftcrossui-parity.md) | SwiftCrossUI 迁移验收表（**冻结快照**，不再推进） |
| [GEWineFork.md](GEWineFork.md) | 定制 GE Wine fork 的补丁与基线（English） |

## Features / 功能

| Doc | 内容 |
| --- | --- |
| [game-metadata.md](game-metadata.md) | 游戏元数据刮削集成（English） |
| [MetadataScraping.md](MetadataScraping.md) | 元数据与人物刮削细节（English） |
| [steam-launch-readiness.md](steam-launch-readiness.md) | Steam 启动就绪编排（English） |
| [SteamCompatibility.md](SteamCompatibility.md) | Steam 兼容性指南（English） |
| [LauncherCompatibilityImplementation.md](LauncherCompatibilityImplementation.md) | 启动器兼容系统实现（English） |
| [LauncherSecurityNotes.md](LauncherSecurityNotes.md) | 启动器兼容安全考量（English） |
| [LauncherTroubleshooting.md](LauncherTroubleshooting.md) | 启动器故障排查（English） |
| [LibraryPresentationUpdates.md](LibraryPresentationUpdates.md) | 媒体库状态、更新与封面缓存（English） |
| [animation-performance-research.md](animation-performance-research.md) | 游戏库滚动与布局切换性能调研（中文） |

## Troubleshooting / 排障

| Doc | 内容 |
| --- | --- |
| [StabilityTroubleshooting.md](StabilityTroubleshooting.md) | 稳定性故障排查（English） |
| [VulkanHostMemoryCompatibility.md](VulkanHostMemoryCompatibility.md) | 32 位 Vulkan 内存导入兼容（中文） |
| [WoW64UnityCrashFix.md](WoW64UnityCrashFix.md) | 32 位 WoW64 Unity 崩溃修复专案（English） |

## Release & process / 发布与流程

| Doc | 内容 |
| --- | --- |
| [ReleaseWorkflow.md](ReleaseWorkflow.md) | 发布流程（English） |
| [DISTRIBUTION.md](DISTRIBUTION.md) | 分发与可发现性手册（English） |
| [DistributionStrategy.md](DistributionStrategy.md) | 面向公众的分发与构建策略（中文） |
| [AUDIT.md](AUDIT.md) | 上游 issue 审计（English） |

## Testing / 测试

| Doc | 内容 |
| --- | --- |
| [E2ETestInfrastructure.md](E2ETestInfrastructure.md) | E2E 测试基础设施规格（English） |
| [E2ETestResults.md](E2ETestResults.md) | E2E 测试结果（English） |
