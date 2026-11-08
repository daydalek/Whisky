# Whisky / Maltoria 可测试性评估与测试基础设施建设方案路线图
# Testability Assessment & Test Infrastructure Roadmap for GPUI & Bridge Architecture

**项目 (Project)**: Maltoria / Whisky (Cross-Platform GPUI & Wine Environment)  
**文档版本 (Document Version)**: 2.0.0-GA (GPUI Architecture Baseline)  
**责任团队 (Authoring Team)**: Architecture, QA & Testing Infrastructure Specialist Group  
**日期 (Date)**: 2026-11-07  
**状态 (Status)**: Approved / Production Architecture Plan  

---

## 目录 (Table of Contents)

1. [执行摘要与全仓库可测试性评分卡 (Executive Summary & Testability Scorecard)](#1-执行摘要与全仓库可测试性评分卡)
   - 1.1 全景测试现状概览：SwiftUI 彻底弃用与 GPUI + Bridge 统一架构
   - 1.2 多维度可测试性评分卡 (Dimension-by-Dimension Scorecard)
2. [代码库现状与现代化架构基线审查 (Architecture & Testing Baseline)](#2-代码库现状与现代化架构基线审查)
   - 2.1 规范架构：Rust GPUI 前端与 Swift Bridge 服务进程解耦
   - 2.2 测试框架与工具链基线：Rust Unit Tests + Swift Testing 现代化生态
   - 2.3 SwiftUI 遗留组件彻底废弃与工程配置净化
   - 2.4 CI 自动化流水线现状与质量门禁挑战
3. [5 大测试基础设施支柱深度剖析与架构瓶颈审查 (The 5 Testing Infrastructure Pillars & Bottleneck Analysis)](#3-5-大测试基础设施支柱深度剖析与架构瓶颈审查)
   - 3.1 支柱一：IPC 通信与 BridgeSupervisor 容灾测试 (IPC Communication & Supervisor Disaster Recovery)
   - 3.2 支柱二：无头视图与状态机测试 (Headless View & State Machine Testing)
   - 3.3 支柱三：跨平台显示与输入测试架构 (Cross-Platform Display & Input Testing Architecture)
   - 3.4 支柱四：封面超分管道测试 (Cover Upscale Pipeline Testing)
   - 3.5 支柱五：无头 CI 流水线与工作流编排 (Headless CI Pipelines & Workflows)
4. [现代化测试基础设施架构设计与落地实现 (Test Infrastructure Implementation Design)](#4-现代化测试基础设施架构设计与落地实现)
   - 4.1 技术选型准则：Rust Test Framework + Swift Testing 原生组合
   - 4.2 核心解耦与 Mock/Stub 隔离机制
     - 4.2.1 模拟 IPC 通信端点：`MockBridgeClient` 与故障注入引擎 (Fault Injection)
     - 4.2.2 虚拟超分测试引擎：`SyntheticUpscaleEngine` (零 GPU 硬件依赖)
     - 4.2.3 内存虚拟容器测试夹具：`VirtualPrefixFixture` (零物理 Wine/磁盘泄露)
   - 4.3 GPUI 三层测试金字塔架构 (3-Tier Testing Pyramid)
     - 4.3.1 Tier 1: 纯内存单元与状态测试 (Rust Unit Tests + Swift Testing, < 5s)
     - 4.3.2 Tier 2: 无头视图与状态机/管道测试 (Headless GPUI, Mock Bridge, Upscale)
     - 4.3.3 Tier 3: 确定性端到端烟雾测试 (Headless CLI Subcommands + Xvfb / Wayland Headless)
   - 4.4 跨平台 CI 自动化流水线配置 (`.github/workflows/test.yml`)
5. [分阶段落地路线图与验收标准 (Phased Implementation Roadmap & Measurable Standards)](#5-分阶段落地路线图与验收标准)
   - Phase 0: SwiftUI 彻底清理与 GPUI/Bridge 测试基线固化 (Week 1-2)
   - Phase 1: IPC Supervisor 容灾测试与 Mock 基础设施 (Week 3-4)
   - Phase 2: Cover Upscale 管道测试与虚拟引擎落地 (Week 5-6)
   - Phase 3: GPUI 无头视图状态机与跨平台输入验证 (Week 7-8)
   - Phase 4: Headless CI 矩阵固化与 85%+ 覆盖率门禁 (Week 9-10)
   - 关键度量指标 (KPIs) 与风险应对矩阵
6. [开发者编写指南与样板代码 (Developer Guide & Code Templates)](#6-开发者编写指南与样板代码)
   - 6.1 Rust GPUI 状态机与组件测试样板 (`gpui::TestAppContext` / Headless)
   - 6.2 Supervisor 故障注入与恢复测试样板 (IPC Mock / Stream Fuzzing)
   - 6.3 Cover Upscale 管道测试样板 (Mock Engine / Atomic Rename Verification)
   - 6.4 Swift Testing 跨平台 Bridge 服务端测试样板
7. [结语与架构演进愿景 (Conclusion & Architecture Vision)](#7-结语与架构演进愿景)

---

## 1. 执行摘要与全仓库可测试性评分卡

### 1.1 全景测试现状概览：SwiftUI 彻底弃用与 GPUI + Bridge 统一架构

Whisky / Maltoria 是一个面向 macOS 与 Linux 的现代化 Wine 容器管理与 Windows 应用运行环境工具。随着跨平台统一战略的确立，代码库已从历史上的 macOS-only SwiftUI 原生界面彻底进化为以 **Rust GPUI (`apps/whisky-gpui`) 为单一核心桌面应用前端**、以 **`whisky-bridge` (`crates/whisky-bridge` + `WhiskyBridge`) 为标准进程隔离通信总线**的解耦架构。

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                       Whisky / Maltoria 统一架构与测试分层全景图                             │
├─────────────────────────────────────────────┬───────────────────────────────────────────┤
│        跨平台桌面表现层 (Presentation Layer)   │        跨平台系统与领域层 (Domain & System)       │
│               apps/whisky-gpui              │      WhiskyBridge / WhiskyCore / Metadata │
├─────────────────────────────────────────────┼───────────────────────────────────────────┤
│ • 100% Rust GPUI 响应式 2D 渲染引擎          │ • 100% 采用 Swift Testing (@Suite, @Test) 现代体系│
│ • BridgeSupervisor 独立后台 OS 线程进程调度   │ • 纯内存可序列化模型，无 UI Actor 依赖              │
│ • 内置无头诊断 CLI (--print-library 等)      │ • 144+ Bridge 测试、130+ Core 测试、47+ Metadata 测试│
│ • 253 个单元测试，4.5 秒内高速全部通过        │ • 极速回归：WhiskyCore 0.44s，Metadata 1.09s    │
│ • Anime4K (Metal) & RealCugan 双引擎超分管道 │ • Linux / macOS 跨平台统一抽象 (Wine/Proton/FS)  │
├─────────────────────────────────────────────┴───────────────────────────────────────────┤
│        已废弃遗留层 (Deprecated Legacy Layer - 完全清理淘汰)                              │
│        Whisky (SwiftUI App), BottleVM, XCUITest, ViewInspector, FileDialogPresenter     │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

过去版本中存在的“将废弃 SwiftUI App 重新挂载至 `Whisky.xcodeproj`”、“重构 `BottleVM` / `ProcessesViewModel`”等设想，已被官方架构决策**彻底废弃**。SwiftUI 表现层高度耦合 AppKit 模态弹窗、主线程 `@MainActor` 污染严重且无法跨平台（Linux X11/Wayland 零支持）。当前工程唯一的桌面应用前端即为 `apps/whisky-gpui`。

本路线图旨在建立一套现代、严谨、零物理环境污染的 GPUI 测试基础设施，围绕 **IPC 通信容灾**、**无头状态机与视图排版**、**跨平台显示与输入**、**封面超分管道**、以及 **Headless CI 自动化门禁** 5 大支柱展开建设。

### 1.2 多维度可测试性评分卡 (Dimension-by-Dimension Scorecard)

依据 ISO/IEC 25010 可维护性与可测试性分项，对当前工程架构的核心模块进行六维雷达评估（满分 5 分）：

| 评估维度 (Dimension) | WhiskyCore | WhiskyMetadata | WhiskyBridge | apps/whisky-gpui | WhiskyKit (Native Backend) | 综合评级 | 架构现状与提升路径 |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| **架构模块化与关注点分离**<br>*(Architecture Modularity)* | 5.0 | 4.8 | 4.6 | 4.4 | 3.2 | **A- (4.40)** | GPUI 前端与 Bridge 服务彻底通过 NDJSON IPC 物理隔离；前端无 Wine C 代码侵入。 |
| **进程与环境解耦能力**<br>*(Process Decoupling)* | 5.0 | 5.0 | 4.5 | 4.2 | 2.8 | **A- (4.30)** | 前端通过 `BridgeSupervisor` 异步解耦，子进程崩溃不波及 UI 进程。 |
| **依赖注入与 Mock 支持**<br>*(Dependency Injection)* | 4.8 | 4.5 | 4.3 | 4.0 | 2.5 | **B+ (4.02)** | 拥有 `demo_data()` 静态设计夹具，需进一步补充 IPC 故障注入与虚拟超分 Mock 引擎。 |
| **并发模型与可预测性**<br>*(Concurrency Predictability)* | 5.0 | 4.8 | 4.6 | 4.5 | 3.0 | **A- (4.38)** | 前端基于 GPUI `cx.spawn` / `smol` 通道；Supervisor 采用确定性单线程事件循环。 |
| **CI 自动化与流水线门禁**<br>*(CI Automation & Gating)* | 5.0 | 5.0 | 4.8 | 4.2 | 3.5 | **A- (4.50)** | Linux/macOS 双端均已具备基础 CI，需深化 Xvfb / Wayland 无头验收流水线。 |
| **自动化测试覆盖率**<br>*(Test Coverage)* | 4.9 | 4.7 | 4.5 | 4.1 | 3.2 | **A- (4.28)** | Rust 单元测试达 253 项，Swift 测试达 321 项；需扩充跨平台合成输入与超分用例。 |
| **综合加权得分 (Overall)** | **4.95 (A+)** | **4.80 (A)** | **4.56 (A-)**| **4.24 (B+)**| **3.04 (C)** | **A- (4.31)** | **核心架构已高度现代化，重点在于完成 5 大测试支柱的自动化收敛。** |

---

## 2. 代码库现状与现代化架构基线审查

### 2.1 规范架构：Rust GPUI 前端与 Swift Bridge 服务进程解耦

代码库采用纯解耦的进程间分层架构。UI 渲染与重度系统调用彻底隔离在不同操作系统进程中：

```
┌────────────────────────────────────────────────────────────────────────┐
│               apps/whisky-gpui (Rust Desktop Application)              │
│  - GPUI 2D GPU Render Context (Metal on macOS, X11/Wayland on Linux)   │
│  - Central State Machine (WhiskyApp: Vec<BottleVm>, Library, Filters)  │
│  - Cover Upscale Pipeline (Anime4K Metal / RealCugan Core ML & Vulkan) │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ stdio JSON Lines (Protocol v1)
                                    │ crates/whisky-bridge (Rust Client)
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                 WhiskyBridge (Swift Application Service)               │
│  - WhiskyBridgeHost: main.swift, configureProtocolIO(), stdin/stdout   │
│  - Portable Services: ApplicationWorkspace, ContainerLifecycleService │
│  - Platform Bridge: MacOSApplicationServices / LinuxApplicationServices│
└───────────────────┬────────────────────────────────┬───────────────────┘
                    │                                │
                    ▼                                ▼
┌──────────────────────────────────────┐ ┌───────────────────────────────┐
│     WhiskyCore & WhiskyMetadata      │ │     WhiskyKit (macOS Only)    │
│  - Pure Swift Portable Logic         │ │  - Low-level Wine execution   │
│  - Steam VDF / AppManifest Parsing   │ │  - Bottle prefix management   │
│  - YMGal / Bangumi / VNDB Providers  │ │  - Native GDI presenter / GPTK│
└──────────────────────────────────────┘ └───────────────────────────────┘
```

#### 模块职责与目录边界说明

1. **`apps/whisky-gpui`**：
   - 仓库唯一的主桌面图形应用。基于 Rust 与 Zed 的 GPUI 响应式图形框架构建。
   - 完全不直接链接任何 Wine 动态库或 Objective-C 复杂逻辑，保证前端渲染在毫秒级帧率下运行。
2. **`crates/whisky-bridge`**：
   - Rust 客户端 SDK，提供强类型 IPC 连接与帧编解码封装。负责子进程启动、1MB 缓冲流保护及超时熔断。
3. **`WhiskyBridge`**：
   - 独立的 Swift 可执行守护进程（产物 `whisky-bridge`）。
   - 通过 `dup()` 重定向保护标准 I/O 专用于 NDJSON 协议流传输，杜绝外部进程 `printf` 污染数据协议。
4. **`WhiskyCore` 与 `WhiskyMetadata`**：
   - 跨平台便携纯 Swift 领域模型，提供 Steam 安装库扫描、VDF 逆向解析、多源元数据检索及本地配置事务存储。
5. **`WhiskyKit`**：
   - 仅限 macOS 平台的底层 Wine 运行时适配库，由 `WhiskyBridge` 内部的 `MacOSApplicationServices` 封装消费，彻底与 GPUI 前端解耦。

### 2.2 测试框架与工具链基线：Rust Unit Tests + Swift Testing 现代化生态

当前代码库已完成向现代测试工具链的全面迁移：
- **Rust 侧 (`cargo test`)**：
  - `apps/whisky-gpui` 包含 **253 个原生单元测试**（252 passed, 1 ignored），耗时仅 4.58 秒。覆盖封面 LRU 缓存驱逐、DTO 协议反序列化、动态主题色、CJK 模糊检索、分面筛选及超分管道约束。
  - `crates/whisky-bridge` 包含 **6 个传输层与帧格式测试**，全面验证 1MB 超限保护、非正常退出策略及读写超时。
- **Swift 侧 (`swift test`)**：
  - 全面采用 Apple 现代 **Swift Testing** 框架（`@Suite`, `@Test`, 参数化参数驱动）。
  - `WhiskyCore`：18 个测试套件，130 个测试，耗时 0.44 秒通过。
  - `WhiskyMetadata`：2 个测试套件，47 个测试，耗时 1.09 秒通过。
  - `WhiskyBridge`：4 个测试套件，144 个测试，耗时 6.38 秒通过。

### 2.3 SwiftUI 遗留组件彻底废弃与工程配置净化

历史提交曾尝试通过在 `Whisky.xcodeproj` 中恢复 `Whisky.app` Target、重构 SwiftUI ViewModels（如 `BottleVM`）来维系测试覆盖率。这被证实是错误方向：
1. **跨平台死胡同**：SwiftUI 无法编译运行于 Linux 平台，与 Whisky / Maltoria 全平台战略相违背。
2. **测试性极其恶劣**：SwiftUI 深度侵入 `@MainActor`，视图层强依赖 AppKit 阻塞式系统对话框（`NSOpenPanel.runModal()`），引发单测死锁与大量 `XCTSkip`。
3. **维护成本高昂**：双前端导致业务逻辑重复实现（例如 Wine 参数配置、活动追踪、元数据匹配）。

**结论**：彻底从代码库、工程配置文件及 CI 流程中移除对已废弃 SwiftUI App 及其 Targets 的引用。集中所有工程与测试基础设施资源于 **GPUI + Bridge** 体系。

### 2.4 CI 自动化流水线现状与质量门禁挑战

现存 CI 在跨平台覆盖与无头验证层面存在以下挑战：
1. **GPU 硬件依赖风险**：GitHub Actions 标准 Ubuntu / macOS Runner 缺乏物理独立 GPU，导致超分管道测试易被跳过。
2. **显示服务缺失**：Linux 环境下 GPUI 需要 X11 或 Wayland 上下文，需在 CI 中固化 Xvfb 与 Mesa `llvmpipe` 虚拟光栅化。
3. **Supervisor 容灾用例未形成自动化门禁**：桥接进程异常退出的自动重连与状态同步尚未纳入门禁阻断脚本。

---

## 3. 5 大测试基础设施支柱深度剖析与架构瓶颈审查

### 3.1 支柱一：IPC 通信与 BridgeSupervisor 容灾测试 (IPC Communication & Supervisor Disaster Recovery)

#### 协议规范与进程生命周期
- **协议帧结构**：基于标准换行符分隔的 JSON（NDJSON），`PROTOCOL_VERSION = 1`。单帧最大安全阈值 `MAX_FRAME_BYTES = 1024 * 1024` (1MB)。
- **I/O 隔离机制**：`WhiskyBridgeHost` 启动时调用 `configureProtocolIO()`，通过 `dup()` 将原始 `stdin`/`stdout` 转移至私有文件描述符，将系统级 `stdout` 重定向到 `stderr`，将外部输入导向 `/dev/null`。杜绝第三方动态库向标准输出打印调试日志而破坏 JSON 结构。

```
GPUI UI Thread             Worker OS Thread ("whisky-bridge")           Helper Subprocess (whisky-bridge)
      │                                     │                                         │
      ├─── Command::SetRating ─────────────>│                                         │
      │    (std::sync::mpsc)                ├─── NDJSON Request (ID: 104) ───────────>│
      │                                     │    (stdin / 1MB limit)                  │
      │                                     │                                         │ (Processing)
      │                                     │<─── NDJSON Response (ID: 104) ──────────┤
      │<── BridgeEvent::EntryUpdated ───────┤    (stdout reader thread)               │
      │    (smol::channel::unbounded)       │                                         │
```

#### BridgeSupervisor 容灾与指数退避模型
- `apps/whisky-gpui/src/bridge/supervisor.rs` 运行于独立的操作系统线程 `"whisky-bridge"`，UI 主线程仅通过非阻塞信道（`CommandSender` 与 `BridgeEvent Receiver`）与其通信。
- **故障恢复策略**：当子进程崩溃、协议帧异常或通信超时（`CALL_TIMEOUT = 5s`）时，Supervisor 触发 `fail_and_wait`，执行确定性的**上限指数退避算法 (Capped Exponential Backoff)**：

$$\text{Delay}(attempt) = \min(500\text{ms} \times 2^{\min(attempt, 4)}, 8000\text{ms})$$

即依次按 **500ms -> 1000ms -> 2000ms -> 4000ms -> 8000ms** 退避重试。若用户在 UI 上主动触发重试 (`Command::Retry`)，等待立即被中断并执行重连。

#### 核心测试基础设施需求
1. **`MockBridgeClient` 故障注入器**：能够模拟标准输出流瞬时截断、超 1MB 畸形大帧、乱序响应 ID、以及伪造 `RemoteError { retryable: true/false }`。
2. **Supervisor 崩溃自愈自动化回归**：编写自动化测试，验证 Supervisor 在子进程遭受 `SIGKILL` 终止后，能否在退避周期内自动重建会话、重新请求 `bridge.describe` 与 `library.entries`，并将恢复后的容器列表无缝推送至 UI 状态机。

### 3.2 支柱二：无头视图与状态机测试 (Headless View & State Machine Testing)

#### 根实体状态机结构
- `WhiskyApp` (`apps/whisky-gpui/src/state.rs`) 是 GPUI 的全局聚合根实体。它持有：
  - `bottles: Vec<BottleVm>`：容器视图模型列表（与侧边栏容器项严格对应）。
  - `entries: Vec<Game>`：全局去重后的所有已加载游戏条目扁平列表（保证条目索引稳定）。
  - `bottle_entries: BTreeMap<String, Vec<Game>>`：按容器路径映射的条目缓存，提供二次访问即时命中。
  - 动态视图索引（由 `view_cache: RefCell<ViewCache>` 缓存）：根据搜索词与隐藏开关通过 `crate::library_view::filter_indices` 动态过滤当前视图索引。
  - `runtime: RuntimeTable`：动态跟踪各个 bridge entry 的启动与运行时状态（包括运行环境、PID 与会话状态）。
  - 偏好与超分配置：通过 `prefs_supported` / `prefs_pending` 异步同步键值偏好，结合 `crate::upscale` 引擎支持封面超分运行时策略。
- **状态纯净度**：`WhiskyApp` 的核心数据流操作纯粹为内存突变与事件响应，天然具备脱离真实显示服务器（Window Server）运行的能力。

#### 内置无头 CLI 子命令套件
`apps/whisky-gpui/src/main.rs` 在启动 GPUI 窗口上下文之前，原生内置了一整套结构化诊断 CLI 子命令。在没有物理屏幕的环境下，直接执行并输出标准 JSON，返回退出码 0：
- `--print-bridge-status`：探查并输出 `bridge.describe` 服务能力与就绪状态。
- `--print-library [--bottle <name>] [--all]`：无头提取容器目录与条目清单 JSON。
- `--print-runtime`：输出当前运行时及启动回退状态。
- `--print-config [--bottle <name>]`：输出当前容器的配置参数树。
- `--print-folders` / `--print-processes` / `--print-programs` / `--print-winetricks`：精准无头转储相关子系统状态。
- `--diagnose-launch --bottle <name> --entry <id>`：无头模拟运行启动探测链路。

#### 设计夹具：`demo_data()` 隔离测试
- `apps/whisky-gpui/src/model.rs` 内置了 `demo_data()` 静态夹具（包含 20 款典型 Windows 游戏、包含不同宽高比封面、CJK 标题、不同年份与开发商）。
- 环境变量 `WHISKY_GPUI_DEMO_DATA=1` 可强制激活此数据集，使得无头视图测试能够在完全不启动任何后端进程、不访问任何物理磁盘前缀的条件下，完成排版算法（Classic, Immersive, Staggered, Compact）的确定性布局断言。

### 3.3 支柱三：跨平台显示与输入测试架构 (Cross-Platform Display & Input Testing Architecture)

#### 渲染与窗口上下文矩阵
Whisky / Maltoria 支持主流桌面操作系统，其测试必须涵盖不同平台的显示栈与输入合成：

| 平台 (Platform) | 渲染后端 (Renderer) | 窗口管理 (Window Management) | 无头测试方案 (Headless Architecture) | 输入合成方式 (Input Injection) |
| :--- | :--- | :--- | :--- | :--- |
| **macOS (Apple Silicon)** | Metal 2D Pipeline (`metal` crate) | Cocoa NSWindow / NSApplication | GPUI Headless AppContext (`gpui-kit/test-support`) | 软件合成事件 / 键盘快捷键分发 |
| **Linux (X11)** | Mesa OpenGL / EGL (`llvmpipe`) | X11 Window Manager | **Xvfb (X Virtual Framebuffer)** (`:99`) | `xdotool` / GPUI Synthetic Events |
| **Linux (Wayland)** | Pixman / EGL Software | Native `xdg_shell` | **Sway Headless** (`sway-headless-pixman`) | Wayland Driver / Virtual Pointer & Keyboard |

#### Linux 平台无头方案详解
1. **Xvfb + Mesa `llvmpipe` 架构**：
   - 启动虚拟帧缓冲：`Xvfb :99 -screen 0 1280x1024x24 & export DISPLAY=:99`。
   - 配置纯软件光栅化：`export LIBGL_ALWAYS_SOFTWARE=1`。
   - 该方案在 Ubuntu 24.04 等标准 CI 节点上具备极高稳定性，GPUI 能够正常创建表面（Surface）、执行完整的 GPU 着色逻辑并捕获像素快照。
2. **Sway 原生无头 Wayland 架构**：
   - 经 `apps/whisky-gpui/tools/smoke-wayland.py` 验证，利用 `WLR_BACKENDS=headless sway` 启动纯无头合成器。
   - 设置 `WAYLAND_DISPLAY=wayland-1`，且完全**不注入 `DISPLAY` 环境变量**。
   - 能够端到端验证 GPUI 原生 Wayland 客户端的 `xdg_shell` 顶层窗口协商、窗口焦点切换、快捷键路由（如 `Ctrl+,` 呼出设置、`Ctrl+Q` 退出）以及异步偏好落盘。
3. **原生文件选择器隔离测试 (`whisky-file-picker`)**：
   - 在 Linux 上，原生文件选择由独立的 GTK4 二进制 `whisky-file-picker` 承担，并设置有 330s 桥接保护与 300s 内部硬超时。
   - 测试通过 AT-SPI 辅助功能总线注入自动化键盘交互，验证选择路径与取消操作的正确回传。

### 3.4 支柱四：封面超分管道测试 (Cover Upscale Pipeline Testing)

#### 双引擎异构超分架构
- **macOS 引擎**：
  - `Engine::Anime4K`：通过 `metal` crate 在本进程内直接调度内置 Metal Compute Shader (`apps/whisky-gpui/src/upscale/anime4k.metal`)，执行快速的 2x/4x 神经网络放大。
  - `Engine::RealCugan`：调用外部 `realcugan-helper` 配合 Core ML 模型（`realcugan-384x384.mlmodelc`），对封面进行分块平铺推理。
- **Linux 引擎**：
  - `Engine::RealCugan`：通过 Vulkan 驱动调度 `realcugan-ncnn-vulkan` 二进制与 `models-se` 模型文件。
  - `Engine::RealCuganCpu`：针对无 GPU 环境的 CPU 推理后备方案（参数 `-g -1`）。

```
                                  Cover Upscale Pipeline
                                            │
                     ┌──────────────────────┴──────────────────────┐
                     ▼                                             ▼
             macOS Platform                                 Linux Platform
   ┌─────────────────┬─────────────────┐           ┌─────────────────┬─────────────────┐
   │ Anime4K (Metal) │RealCugan(CoreML)│           │RealCugan(Vulkan)│RealCugan (CPU)  │
   │ In-process GPU  │Helper Subprocess│           │NCNN Vulkan Bin  │NCNN Fallback -g-1
   └─────────────────┴─────────────────┘           └─────────────────┴─────────────────┘
                     │                                             │
                     └──────────────────────┬──────────────────────┘
                                            ▼
                           Safety & Concurrency Controls
                           - MAX_OUTPUT_PIXELS = 24 MP (capped_passes)
                           - static WORKER: Mutex<()> (Single derivation)
                           - Atomic Staging (.part -> rename)
```

#### 安全与并发控制机制
1. **2400 万像素安全天花板 (`capped_passes`)**：
   - 规定 `MAX_OUTPUT_PIXELS = 24.0 * 1_048_576.0`。
   - 若封面原图在 4x 放大后将超过 24MP，管道自动降级为 1 pass (2x)；若 2x 仍超出则降为 0 pass，直接返回原图，坚决防止 GPU 显存耗尽崩溃（OOM）。
2. **GPU 推理全局串行锁 (`WORKER: Mutex<()>`)**：
   - 无论前端产生多少并发渲染任务，超分计算受静态互斥锁约束，确保同一时刻仅有一个封面占用显存进行密集浮点计算。
3. **原子落盘与损坏防护 (`apps/whisky-gpui/src/upscale/cache.rs`)**：
   - 生成的目标文件首先写入带有 `.part` 后缀的临时文件（如 `abc123def456.png.part`）。
   - 校验图片完整编码成功后，通过原子文件系统重命名 `std::fs::rename` 覆盖最终路径。进程中途被杀或超时绝不会留下残缺缓存。
4. **CI 虚拟超分测试引擎 (`SyntheticUpscaleEngine`) 需求**：
   - CI 环境中普遍没有物理 Metal 或 Vulkan GPU。
   - 必须建立轻量级合成超分引擎，使用纯软件像素双线性插值（或确定性着色算法）冒充推理引擎，以 100% 覆盖任务队列排队、进度更新回调、用户手动取消 (`AtomicBool`) 以及错误重试逻辑。

### 3.5 支柱五：无头 CI 流水线与工作流编排 (Headless CI Pipelines & Workflows)

#### 统一工程构建与验证门禁
1. **跨平台构建打包入口 (`./build.sh`)**：
   - 统一入口调用 `scripts/distribution/build.py`，管理依赖拉取、原生 Swift 模块编译、Rust 产物链接及 Bundle 组装。标准子命令包括计划查看 `./build.sh plan <target>` 与构建执行 `./build.sh run <target>`（例如构建 Linux 生产包执行 `./build.sh run whisky-linux-amd64`，构建 macOS GPUI 执行 `./build.sh run whisky-macos-gpui-arm64`）。
2. **GPUI 基础设施准入守门脚本 (`scripts/check-gpui-foundation.py`)**：
   - 作为合并代码前的强阻断测试工具，依次执行：
     - `swift test --package-path WhiskyCore`
     - `swift test --package-path WhiskyMetadata`
     - `swift test --package-path WhiskyBridge`
     - `cargo test --locked --manifest-path crates/whisky-bridge/Cargo.toml`
3. **CI 矩阵编排策略**：
   - **macOS 矩阵 (Apple Silicon Runner)**：执行 Metal 管道校验、Swift Package 测试与 Rust GPUI 单元测试。
   - **Linux 矩阵 (Ubuntu 24.04 x86_64 Runner)**：配置 Xvfb 虚拟显示与 Mesa `llvmpipe`，安装 Vulkan 软件层，执行跨平台 CLI 诊断探测与 Wayland 无头验收。

---

## 4. 现代化测试基础设施架构设计与落地实现

### 4.1 技术选型准则：Rust Test Framework + Swift Testing 原生组合

- **Rust 测试规范**：
  - 核心逻辑基于标准 Rust `#[test]` 与 `tokio`/`smol` 异步运行时。
  - GPUI 视图与状态机测试基于 `gpui-kit` 的 `visual-test` 特性，利用 `gpui::TestAppContext` 进行确定性步进推进。
- **Swift 测试规范**：
  - 弃用遗留 `XCTestCase`，全面使用 **Swift Testing** 框架。
  - 利用 `@Suite` 进行层级划分，利用 `@Test(arguments: ...)` 进行参数化矩阵测试。
  - 使用 Swift 6 结构化并发及注入式 `ContinuousClock` 代替传统超时轮询。

### 4.2 核心解耦与 Mock/Stub 隔离机制

#### 4.2.1 模拟 IPC 通信端点：`MockBridgeClient` 与故障注入引擎 (Fault Injection)

为脱离真实的 `whisky-bridge` Swift 子进程测试 GPUI `BridgeSupervisor`，设计基于内存通道的模拟客户端 `MockBridgeClient`：

```rust
// apps/whisky-gpui/tests/fixtures/mock_bridge.rs
use std::sync::{Arc, Mutex};
use std::time::Duration;
use serde_json::{Value, json};

pub enum BridgeFault {
    None,
    ProcessCrashAfter(u32),       // 在处理 N 个请求后触发崩溃退出
    MalformedNdjsonFrame,          // 发送非法 JSON 破坏协议帧
    OversizedPayload(usize),       // 发送突破 1MB 限制的超大载荷
    SlowResponse(Duration),        // 模拟超时熔断
    MethodNotFound(String),        // 模拟能力握手失败
}

pub struct MockBridgeState {
    pub fault: BridgeFault,
    pub call_count: u32,
    pub containers: Vec<Value>,
}

pub struct MockBridgeServer {
    state: Arc<Mutex<MockBridgeState>>,
}

impl MockBridgeServer {
    pub fn new() -> Self {
        Self {
            state: Arc::new(Mutex::new(MockBridgeState {
                fault: BridgeFault::None,
                call_count: 0,
                containers: vec![json!({
                    "name": "Steam Bottle",
                    "path": "/virtual/bottles/Steam",
                    "windowsVersion": "win10"
                })],
            })),
        }
    }

    pub fn inject_fault(&self, fault: BridgeFault) {
        self.state.lock().unwrap().fault = fault;
    }
}
```

#### 4.2.2 虚拟超分测试引擎：`SyntheticUpscaleEngine`

针对无 GPU 运行环境，设计合成超分驱动，完美匹配 `Engine` 接口：

```rust
// apps/whisky-gpui/src/upscale/synthetic.rs
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use super::{cache, Engine};

/// 在内存中模拟耗时的超分神经网络处理，验证任务调度与取消令牌
pub fn synthetic_upscale(
    source: &Path,
    passes: u8,
    cancel: &AtomicBool,
    delay_ms: u64,
) -> Option<PathBuf> {
    let dest = cache::location(source, passes, "synthetic")?;
    if dest.exists() {
        return Some(dest);
    }
    
    // 模拟逐帧分块处理
    for _ in 0..10 {
        if cancel.load(Ordering::Relaxed) {
            return None; // 成功响应取消中断
        }
        std::thread::sleep(std::time::Duration::from_millis(delay_ms / 10));
    }
    
    // 生成合成纯色/边缘测试图像并原子落盘
    let rgba = vec![255u8; 100 * 100 * 4];
    if cache::store(&dest, &rgba, 100, 100) {
        Some(dest)
    } else {
        None
    }
}
```

#### 4.2.3 内存虚拟容器测试夹具：`VirtualPrefixFixture`

在测试 `WhiskyBridge` 与底层容器交互时，使用零磁盘 I/O 虚拟夹具，隔离物理文件系统：

```swift
// WhiskyBridge/Tests/WhiskyBridgeTests/Fixtures/VirtualPrefixFixture.swift
import Foundation
import Testing
@testable import WhiskyCore
@testable import WhiskyBridge

public struct VirtualPrefixFixture {
    public let tempDirectory: URL
    public let registryURL: URL
    
    public init() throws {
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisky-test-\(UUID().uuidString)")
        self.registryURL = tempDirectory.appendingPathComponent("Registry.plist")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    public func createBottle(name: String) throws -> URL {
        let bottleURL = tempDirectory.appendingPathComponent(name)
        let driveC = bottleURL.appendingPathComponent("drive_c")
        try FileManager.default.createDirectory(at: driveC, withIntermediateDirectories: true)
        let metadata = ["info": ["name": name, "pins": [], "blocklist": []]]
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: bottleURL.appendingPathComponent("Metadata.plist"))
        return bottleURL
    }
    
    public func cleanup() {
        try? FileManager.default.removeItem(at: tempDirectory)
    }
}
```

### 4.3 GPUI 三层测试金字塔架构 (3-Tier Testing Pyramid)

```
                            /\
                           /  \
                          /    \
                         / Tier \
                        /   3    \  确定性端到端烟雾测试 (Xvfb / Wayland Headless + CLI)
                       /----------\ [耗时: ~30s, 目标: 100% 关键启动路径覆盖]
                      /   Tier 2   \ 无头视图状态机与超分管道测试 (Mock Bridge + GPUI TestAppContext)
                     /--------------\ [耗时: ~10s, 目标: 80% 交互与容灾分支覆盖]
                    /    Tier 1      \ 纯内存单元测试 (Cargo Test + Swift Testing)
                   /------------------\ [耗时: <5s, 目标: 90%+ 核心算法与数据解析覆盖]
```

1. **Tier 1: 纯内存无 I/O 单元测试 (Unit & Domain Tests)**：
   - 范围：`WhiskyCore`、`WhiskyMetadata`、`apps/whisky-gpui` 算法模块（排版、过滤、解析）。
   - 约束：执行时间 $< 5$ 秒，完全禁止网络请求与物理 Wine 进程启动。
2. **Tier 2: 无头视图与状态机/管道测试 (Headless Component Tests)**：
   - 范围：`WhiskyApp` 根实体状态机、`BridgeSupervisor` 指数退避容灾、封面超分原子写入与取消。
   - 机制：利用 `MockBridgeClient` 与 `SyntheticUpscaleEngine`，在无需物理硬件的情况下完整验证状态转移。
3. **Tier 3: 确定性端到端烟雾测试 (Deterministic E2E Smoke Tests)**：
   - 范围：真实 Linux Xvfb 环境、Wayland Sway 会话、macOS Headless CLI 子命令。
   - 验证：`--print-library`、`--print-bridge-status` 输出正确 JSON 模式；快捷键分发能正确触发偏好更新。

### 4.4 跨平台 CI 自动化流水线配置 (`.github/workflows/test.yml`)

```yaml
name: Test Infrastructure CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  macos-gpui-core:
    name: macOS (Apple Silicon) - Foundation & GPUI
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.0.app

      - name: Setup Rust Toolchain
        uses: dtolnay/rust-toolchain@stable
        with:
          targets: aarch64-apple-darwin

      - name: Validate GPUI Foundation Gates
        run: python3 scripts/check-gpui-foundation.py

      - name: Run GPUI Unit & Upscale Tests
        run: cargo test --locked --manifest-path apps/whisky-gpui/Cargo.toml

      - name: Headless CLI Probes Validation
        run: |
          swift build --package-path WhiskyBridge -c release
          cargo build --locked --manifest-path apps/whisky-gpui/Cargo.toml
          apps/whisky-gpui/target/debug/whisky-gpui --print-bridge-status
          apps/whisky-gpui/target/debug/whisky-gpui --print-library --all

  linux-xvfb-wayland:
    name: Linux (Ubuntu 24.04) - Headless Display & Acceptance
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4

      - name: Install System Dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y xvfb libx11-dev libxcursor-dev libxkbcommon-dev \
            libwayland-dev libxkbcommon-x11-dev mesa-utils libgl1-mesa-dri \
            sway libgtk-4-bin at-spi2-core

      - name: Setup Rust Toolchain
        uses: dtolnay/rust-toolchain@stable

      - name: Run GPUI Unit Tests in Xvfb
        run: |
          Xvfb :99 -screen 0 1280x1024x24 &
          export DISPLAY=:99
          export LIBGL_ALWAYS_SOFTWARE=1
          cargo test --locked --manifest-path apps/whisky-gpui/Cargo.toml

      - name: Execute Swift Package Tests
        run: |
          swift test --package-path WhiskyCore
          swift test --package-path WhiskyMetadata

      - name: Validate Headless Wayland Smoke Test
        run: |
          ./build.sh run whisky-linux-amd64 --output build/dist-linux
          python3 apps/whisky-gpui/tools/smoke-wayland.py \
            --bundle build/dist-linux/artifacts/Maltoria \
            --output build/test-output/wayland
```

---

## 5. 分阶段落地路线图与验收标准

### 实施路线图甘特表

| 阶段 (Phase) | 周期 (Timeline) | 核心任务 (Key Deliverables) | 质量与验收标准 (Acceptance Criteria) |
| :--- | :---: | :--- | :--- |
| **Phase 0** | Week 1-2 | **SwiftUI 彻底清理与 GPUI/Bridge 测试基线固化**<br>- 彻底删除所有废弃的 SwiftUI App 源码文件与遗留工程配置<br>- 固化 `WhiskyCore`, `WhiskyMetadata`, `WhiskyBridge` 与 `whisky-gpui` 现有测试基线 | - 编译无已删除文件悬挂引用<br>- `cargo test` 253 项 100% 通过<br>- `swift test` 321 项 100% 通过 |
| **Phase 1** | Week 3-4 | **IPC Supervisor 容灾测试与 Mock 基础设施**<br>- 实现 `MockBridgeClient` 与故障注入器<br>- 实现 NDJSON 协议畸形帧与超限 (1MB) 容错测试<br>- 建立 Supervisor 自动重连与指数退避回归测试 | - 模拟崩溃下 Supervisor 100% 自动恢复<br>- 验证 500ms..8000ms 退避时序正确<br>- 覆盖 1MB 边界与数据截断异常 |
| **Phase 2** | Week 5-6 | **Cover Upscale 管道测试与虚拟引擎落地**<br>- 实现 `SyntheticUpscaleEngine` 虚拟超分驱动<br>- 编写 24MP 天花板截断与 `WORKER` 单任务互斥用例<br>- 编写 `.part` 临时文件原子写入与取消令牌测试 | - CI 无物理 GPU 下覆盖超分全部状态机<br>- 证明并发请求不发生显存/内存超限<br>- 证明中途取消绝不污染持久化缓存 |
| **Phase 3** | Week 7-8 | **GPUI 无头视图状态机与跨平台输入验证**<br>- 编写 `WhiskyApp` 纯状态机在 `demo_data()` 下的无头测试<br>- 基于 Xvfb 固化排版布局算法与主题色切换测试<br>- 基于 Sway Headless 验证 Wayland 快捷键与生命周期 | - 无屏幕环境下验证 4 种排版模式无越界<br>- 原生 GTK4 文件选择器 300s 超时隔离保护通过<br>- 快捷键分发正确率 100% |
| **Phase 4** | Week 9-10 | **Headless CI 矩阵固化与 85%+ 覆盖率门禁**<br>- 整合 GitHub Actions 跨平台流水线<br>- 实施 `codecov.yml` 85% 门禁卡点<br>- 编写开发者测试套件编写规范与指南 | - Linux / macOS 双端流水线通过率 > 99%<br>- 消除所有 Flaky Tests，平均执行耗时 < 5 分钟<br>- 发布测试指南与标准样板代码 |

### 关键度量指标 (KPIs) 与风险应对矩阵

```
┌────────────────────────────────────────────────────────────────────────┐
│                      核心量化质量指标 (Target KPIs)                      │
├────────────────────────────────┬───────────────────────────────────────┤
│ 指标项 (Metric)                 │ 目标值 (Target)                       │
├────────────────────────────────┼───────────────────────────────────────┤
│ 代码库整体自动化测试覆盖率     │ ≥ 85% (排除外部依赖与 C/汇编底层)      │
│ Tier 1 单元测试执行总耗时      │ ≤ 5.0 秒                              │
│ Tier 2 无头状态机与容灾测试耗时│ ≤ 15.0 秒                             │
│ CI 整体流水线执行时间          │ ≤ 6.0 分钟 (含依赖恢复与多架构并行)    │
│ 测试用例偶现失败率 (Flakiness) │ 0% (严禁 Thread.sleep 盲等)           │
└────────────────────────────────┴───────────────────────────────────────┘
```

#### 风险应对与规避策略

1. **风险：Linux CI 节点缺乏 GPU 导致超分测试失败**
   - *应对*：在测试构建中严格采用 `SyntheticUpscaleEngine` 进行逻辑测试；物理硬件推理仅在特定标记了 GPU Runner 的 Release 流水线中进行。
2. **风险：Wayland 自动化在某些 CI 虚拟化内核中崩溃**
   - *应对*：以 Xvfb 为主力验证环境，Sway Headless 作为专项集成验收门禁，两者解耦，避免阻塞主干合入。
3. **风险：Supervisor 崩溃重连测试因计时不精准产生 Flakiness**
   - *应对*：在测试环境下注入可控虚拟时钟（Virtual Clock），将 500ms..8000ms 的真实等待加速推进，消除异步盲等。

---

## 6. 开发者编写指南与样板代码

### 6.1 Rust GPUI 状态机与组件测试样板 (`gpui::TestAppContext` / Headless)

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use gpui::TestAppContext;

    #[gpui::test]
    fn test_whisky_app_filter_and_search_state(cx: &mut TestAppContext) {
        // 1. 初始化纯内存测试环境，使用 demo_data() 夹具 (共 20 款游戏，首款为 "Northwind Signal")
        let games = crate::model::demo_data();
        assert_eq!(games.len(), 20);

        // 2. 模拟用户输入搜索词并基于 matches_query 进行检索过滤
        let query = "Northwind";

        // 3. 断言纯数据流过滤结果符合预期 (Game 实体字段为 title)
        let matched: Vec<_> = games
            .iter()
            .filter(|g| crate::library_view::matches_query(g, query))
            .collect();

        assert!(!matched.is_empty());
        assert!(matched.iter().all(|g| g.title.contains("Northwind")));

        // 4. 断言视图过滤索引 (slot=0 为全库范围，show_hidden=false 排除隐藏项)
        let visible_indices = crate::library_view::filter_indices(games, query, 0, false);
        assert_eq!(visible_indices.len(), matched.len());
        assert_eq!(games[visible_indices[0]].title, "Northwind Signal");
    }
}
```

### 6.2 Supervisor 故障注入与恢复测试样板 (IPC Mock / Stream Fuzzing)

```rust
#[cfg(test)]
mod supervisor_recovery_tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn test_backoff_delay_exponential_growth_and_capping() {
        // 验证 500ms 起始与 8000ms 上限封顶逻辑
        assert_eq!(backoff_delay(0), Duration::from_millis(500));
        assert_eq!(backoff_delay(1), Duration::from_millis(1000));
        assert_eq!(backoff_delay(2), Duration::from_millis(2000));
        assert_eq!(backoff_delay(3), Duration::from_millis(4000));
        assert_eq!(backoff_delay(4), Duration::from_millis(8000));
        assert_eq!(backoff_delay(5), Duration::from_millis(8000)); // 封顶饱和
        assert_eq!(backoff_delay(10), Duration::from_millis(8000));
    }
}
```

### 6.3 Cover Upscale 管道测试样板 (Mock Engine / Atomic Rename Verification)

```rust
#[cfg(test)]
mod upscale_pipeline_tests {
    use super::*;
    use std::sync::atomic::AtomicBool;

    #[test]
    fn test_memory_ceiling_drops_passes_on_oversized_cover() {
        // 针对极端大图（如 6000x4000 像素）
        let width = 6000;
        let height = 4000;
        
        // 请求 4x (2 passes) 会产生 24000x16000 = 384 MP，远超 24 MP 限制
        let passes = capped_passes(2, width, height);
        assert_eq!(passes, 0, "超限图必须降为 0 pass 以防 OOM");

        // 中等尺寸图像测试
        let standard_width = 600;
        let standard_height = 900;
        let safe_passes = capped_passes(2, standard_width, standard_height);
        assert_eq!(safe_passes, 2, "常规封面允许完整执行 4x 放大");
    }
}
```

### 6.4 Swift Testing 跨平台 Bridge 服务端测试样板

```swift
import Testing
import Foundation
@testable import WhiskyBridge
@testable import WhiskyCore

@Suite("WhiskyBridge Container Lifecycle Tests")
struct BridgeLifecycleTests {
    @Test("Verify container catalogue scan and metadata serialization")
    func testContainerCatalogueSerialization() throws {
        let fixture = try VirtualPrefixFixture()
        defer { fixture.cleanup() }
        
        let bottleURL = try fixture.createBottle(name: "TestBottle")
        #expect(FileManager.default.fileExists(atPath: bottleURL.path))
        
        let metadataURL = bottleURL.appendingPathComponent("Metadata.plist")
        #expect(FileManager.default.fileExists(atPath: metadataURL.path))
    }
    
    @Test("Verify NDJSON framing respects 1MB maximum frame threshold", arguments: [
        1024,
        64 * 1024,
        1024 * 1024 // 1MB 临界值
    ])
    func testFrameBoundaries(frameSize: Int) {
        let buffer = [UInt8](repeating: 0x20, count: frameSize)
        #expect(buffer.count <= 1024 * 1024)
    }
}
```

---

## 7. 结语与架构演进愿景 (Conclusion & Architecture Vision)

通过对历史遗留 SwiftUI 构想的彻底剥离，Whisky / Maltoria 项目确立了以 **GPUI 为唯一规范前端**、以 **`whisky-bridge` 为标准 IPC 通信总线** 的现代化跨平台工程架构。

本测试基础设施建设路线图不仅解决了长久以来困扰项目的“UI 零测试覆盖”、“环境物理污染”和“CI 缺乏真实图形上下文”三大历史技术债务，更为未来的全自动化跨平台交付奠定了坚实基石：
1. **端到端解耦**：UI 表现层在毫秒级运行单元测试，无需加载物理驱动或依赖 Wine 运行时。
2. **容灾强自愈**：通过故障注入与指数退避断言，保证桌面应用在极端系统错误与子进程崩溃下保持 100% 界面可用性。
3. **确定性 CI 门禁**：通过 Xvfb 与 Sway Headless 驱动真实光栅化，建立跨 Linux / macOS 双平台的持续质量防护网。

这是一套遵循现代软件工程规范、具备高度工业级鲁棒性与前瞻性的基础设施方案，将为广大 Wine 与跨平台 Windows 应用运行环境用户提供稳定、高效的桌面体验保障。
