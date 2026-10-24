# 面向公众的分发与构建策略

调研日期：2026-10-24。范围：macOS Apple Silicon、Linux amd64；Linux arm64 保留为后续目标。
本文将当前已实现的构建入口、现有发布链路和待实施的分发方案分别列明。

## 推荐路线

| 平台 / 人群 | 第一阶段 | 后续渠道 | 发布前验收 |
| --- | --- | --- | --- |
| macOS arm64 普通用户 | Developer ID 签名、公证并装订票据的 DMG；ZIP 用于更新 | Homebrew Cask 和应用内签名更新 | 浏览器下载后首次启动、Gatekeeper、下载后的 Wine、最低系统版本 |
| Ubuntu 24.04 amd64 | 基于现有 tar.gz 产物制作 `.deb`，由包管理器安装宿主依赖 | APT 仓库 | 干净系统安装、卸载保留 Bottle、升级、X11/Wayland、真实 GPU/Wine |
| Debian / Fedora / Arch / openSUSE amd64 | 依赖封装完成后的 AppImage；保留解压版 tar.gz | 按需求补 `.deb` / `.rpm` 和发行版维护配方 | 同一 payload 在各发行版实测，记录支持版本 |
| 不可变桌面系统 | 单独评估 AppImage 或 Flatpak | Flatpak / Flathub | Portal、外置游戏目录、终端、进程跟踪和桌面快捷方式 |
| Linux arm64 | 保留共享代码与测试 | 独立构建和运行时策略 | ARM GUI、x86 Windows 转译、WoW64 系统调用和图形栈 |

当前 macOS SwiftUI ZIP 发布继续作为预发布渠道。新的构建菜单按现有签名能力描述产物。
公众稳定版的 Developer ID、公证和更新签名流程列入下一阶段。
Apple 要求直接分发的软件使用相应签名，并为公证采用 Hardened Runtime 和安全时间戳；
公证票据可通过 `notarytool` / `stapler` 集成到脚本。
来源：[Apple 公证文档](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。

## 当前仓库的实际边界

- `scripts/build-app-release.sh` 构建 arm64 SwiftUI 应用，生成 ad-hoc ZIP、源码包、构建记录和校验和。
  `AppRelease.yml` 使用这条链路。`scripts/release.sh` 保留 Developer ID / DMG / 公证流程；
  其团队 ID、版本传递、证书和更新签名配置需要在接入公众稳定渠道时统一。
- `apps/whisky-gpui/tools/package-app.sh` 是 GPUI 开发包入口。本次修正了 Retina 图标的目标文件名、
  固定离线构建行为和覆盖旧产物的问题，并接入独立输出目录。
- `build-linux-release.sh` 在 Swift 6.4 Ubuntu 24.04 工具链下构建 GPUI 与 Swift helper。
  `package-linux.py` 携带 Swift 动态库、资源、源码和许可证，GTK、图形驱动、字体及部分主机工具由系统提供。
- `linux-runtime-packages.txt` 是 Ubuntu 包名清单，发行版适配需要单独维护逻辑依赖与包名映射。
- Wine 仓库当前 Linux 目标为 Ubuntu 24.04 x86_64，new WoW64 包含 i386/x86_64 Windows 模块；
  FFmpeg 随包发布，GnuTLS、音频、窗口和设备库仍有宿主依赖。
- 当前 macOS Wine 构建要求 macOS 27+ Apple Silicon 主机，核心为 x86_64，通过 Rosetta 执行。
  应用声明的 macOS 15 基线和现有 Wine 的 macOS 27 基线需要在下载页分别显示；
  使用当前 Wine 的整体产品要求取二者较高值。

以上结论来自当前分支的脚本和两个仓库的实际配方。此前的 Linux 窗口验收主要覆盖 ARM64 Ubuntu；
公众 amd64 的首次完整 Release 构建、实体桌面和 GPU 验收仍列入发布门槛。

## Linux 多发行版兼容性：先定义 payload 的边界

构建环境决定 ELF 的最低符号版本。将同一目录改装为 AppImage、deb 或 rpm 后，这些要求继续存在。
AppImage 官方建议在目标中最老的系统构建、携带目标系统缺少的依赖，并实际测试各目标系统。
来源：[AppImage 最佳实践](https://docs.appimage.org/reference/best-practices.html)。

本次新增 `scripts/distribution/audit-elf.py`，扫描真正导入的 GLIBC / GLIBCXX 符号、直接 SONAME 和 RUNPATH。
它以 `2.39` 为当前 glibc 上限，遇到超过基线、GLIBC_PRIVATE 或空 payload 时返回失败。
该报告覆盖静态导入；`dlopen` 的图形/音频插件、桌面服务和运行时行为需要发行版验收补充。

本机已有产物的实际审计结果：

| 已检查的产物 | ELF 数量 | 实际最高 GLIBC 导入 | 说明 |
| --- | ---: | --- | --- |
| 此前的 ARM64 Ubuntu 应用验证包 | 21 | 2.39 | 包含 Swift 库；amd64 Release 构建需生成自己的报告 |
| 真实 `v0.1.6-linux-amd64` Wine 发布包 | 42 | 2.38 | 宿主依赖和内核要求仍需检查 |

报告保存在 `build/portability/wine-update/distribution-elf-abi.json` 与
`distribution-wine-elf-abi.json`。因此当前联合分发以 Ubuntu 24.04 为起点。
Debian 12 的 libc6 为 2.36，覆盖该目标需要重新选择更低基线的工具链和依赖构建环境。
来源：[Debian 12 libc6](https://packages.debian.org/bookworm/libc6)。

### 依赖处理

| 类别 | 建议处理 |
| --- | --- |
| Swift、应用资源、固定版本的用户态库 | 随应用封装；审计 transitive SONAME、插件目录、许可证与源代码 |
| GTK / GLib / GIO、图像加载器 | AppImage 携带相容的依赖闭包及插件；deb/rpm 声明各发行版依赖 |
| Wine 的 FFmpeg / GnuTLS / 用户态依赖 | 建立自己的 runner payload；记录依赖闭包与 ABI，同应用基线协调 |
| Vulkan / OpenGL 驱动、GPU ICD、设备 | 对接宿主驱动；在 Intel / AMD / NVIDIA 和 X11 / Wayland 分别验收 |
| 字体、终端、D-Bus / Portal、音频服务 | 使用宿主服务和明确的降级能力；为中文/日文建立字体验收样例 |
| glibc / ELF loader | 第一阶段采用明确的宿主基线；扩大覆盖时重建更低基线或引入专用运行环境 |

AppImage 的 FUSE 依赖还需要准备解压运行入口，验证对应 runtime 的 `--appimage-extract-and-run`
或 `--appimage-extract` 流程。来源：[AppImage FUSE 文档](https://docs.appimage.org/user-guide/troubleshooting/fuse.html)。
AppImage 桌面快捷方式应保存外层 `.AppImage` 的持久路径（运行时可由 `APPIMAGE` 获得），
并在移动应用后支持重新登记。Wine 与 Bottle 保存在 XDG 数据目录；启动 Wine 时单独设置
runner 的库环境，避免 GUI 的 GTK/图像插件路径进入 Wine。两部分资产分别更新和回滚。
Swift Static Linux SDK 使用 musl 和全静态依赖模型；现有 GTK/动态库集成适合继续使用动态发布路线。
来源：[Swift Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html)。

### 格式选择

| 格式 | 优先级 | 适用场景与工作量 |
| --- | --- | --- |
| tar.gz | 当前工程基底 | 便于重定位、审计和故障定位；用户需要准备宿主依赖 |
| deb | 第一阶段 | Ubuntu amd64 的友好安装入口；复用 payload，声明 Depends，安装 desktop/icon |
| AppImage | 跨发行版主渠道 | 一个可运行文件；要求封装依赖闭包、处理 FUSE 和持久安装路径 |
| rpm | 后续按需 | 为 Fedora/openSUSE/RHEL 系分别测试构建基线和依赖映射 |
| Flatpak | 单独适配后引入 | 提供集中 runtime 和软件中心分发；需要调整应用与宿主交互 |

Whisky 会读取 `/proc`、启动 Wine 与宿主终端、处理游戏目录和桌面项。
Flatpak 使用沙箱与独立的进程视图，宿主命令需要相应 D-Bus 接口/权限；文件选择可以使用 Portal。
因此 Flatpak 阶段需建立 host-services 适配层，并复测进程跟踪和终端生命周期。
来源：[Flatpak 介绍](https://docs.flatpak.org/en/latest/introduction.html)、
[沙箱与 Portal](https://docs.flatpak.org/en/latest/sandbox-permissions.html)、
[flatpak-spawn](https://docs.flatpak.org/en/latest/flatpak-command-reference.html#flatpak-spawn)。

## Wine 的分发策略

应用和 Wine 保持独立版本、独立资产、独立回滚。应用包保持较小，首次运行按平台和能力下载 runner。
Linux 现有 `run`、`bin/wine`、`bin/wineserver` 入口和 `win64` prefix 约定继续作为 producer/consumer 合同。
Docker 用于构建隔离；用户运行游戏使用安装在本机的 Wine 与图形栈。

短期保留现有 `wine-linux-amd64.tar.gz` 资产名，明确 Ubuntu 基线。兼容性扩展阶段增加版本化字段：
`schemaVersion`、`os`、`hostArchitecture`、`minGlibc`、`cpuBaseline`、`runtimeFamily`、
`entrypoints`、`systemSonames`、`kernelRequirements`、`validationMode`。
消费者按能力匹配 manifest；新增不同 ABI 家族时为资产和渠道使用明确标识。
为现有客户端保留兼容字段和迁移窗口。

当前更新器接受符合约定的 Linux prerelease。公众发布前应加入 `stable` / `beta` 选择，
将 `compile-only` 产物限定到测试渠道；稳定渠道要求运行探针和指定桌面/GPU 验收完成。
渠道元数据建议使用内置公钥验证的独立签名，并把 SHA-256、不可变版本和回滚记录一并保留。

aarch64 Linux 的 x86 Wine 转译属于单独运行能力，延后规划。
Linux amd64 的 new WoW64 路线可减少宿主 32 位库的部署负担；当前 CrossOver 核心仍要求
Linux i386 `int 0x80` 兼容入口。实体 amd64、虚拟机、容器和 CPU 转译环境分别记录结果。

长期可评估 Steam Linux Runtime / pressure-vessel 类型的稳定用户态环境，统一 Wine 的宿主依赖。
接入前需要验证当前 CrossOver/GE 配方、显卡驱动导入、桌面集成、下载体积及独立分发条件。
来源：[Valve Steam Runtime](https://github.com/ValveSoftware/steam-runtime)。

## 已落地的构建优化

入口为仓库根目录 `./build.sh`，菜单和 CI CLI 使用同一份计划执行器。
完整用法见 [BUILDING.md](BUILDING.md)。

- `list`、`doctor`、`plan`、`run` 和终端菜单；计划输出 JSON，预览阶段保持只读。
- 五个目标覆盖 SwiftUI macOS、GPUI macOS、GPUI Linux amd64、两个 Wine 平台；Linux arm64 显示后续状态。
- 独立任务目录、逐阶段日志、耗时和失败记录；失败停止后续任务，取消终止子进程。
- Linux Docker 目标固定 `linux/amd64`，源码只读挂载，输出采用调用用户 UID/GID；构建上下文仅包含 Dockerfile 和依赖脚本。
- 镜像按配方摘要命名，Wine 工作目录按配置/补丁/脚本摘要隔离；同目录构建使用排他锁。
- Linux Wine 默认运行探针和打包后回归，`--compile-only` 显式记录静态验证范围。
- Linux 应用和 Wine 包加入 glibc 上限检查；原有锁定下载、补丁清单、源码包和哈希流程继续执行。
- macOS GPUI 构建支持联网解析锁定依赖，`WHISKY_BUILD_OFFLINE=1` 启用离线模式；各应用脚本支持统一输出与并行度。

本次采用 Whisky 仓库作为跨仓库调度入口，Wine 仓库源码保持原状。
Wine 的 macOS 完整配方沿用全新工作目录要求；Linux 完整配方支持受锁保护的增量构建。
macOS Wine 的版本计数器沿用原脚本规则 `11.0.(build-number + 1)`；正式渠道使用 CI 单调计数器。

## 后续发布工程顺序

1. 完成第一份原生 amd64 Ubuntu Release、干净运行时和真实桌面/GPU/Wine 验收；制作 Ubuntu `.deb`。
2. 将“依赖的逻辑名称—各发行版包名—SONAME—最低版本”集中到版本化配置，封装 AppImage 依赖闭包。
3. 对 Ubuntu 24.04 / 后续受支持 LTS、Debian 13、Fedora 受支持版本、Arch 固定快照和 openSUSE 建立矩阵。
   Debian 12 / Ubuntu 22.04 作为降低 ABI 基线后的独立目标。
4. 为 macOS 应用与动态下载 Wine 分别完成 Developer ID、公证、Hardened Runtime 和真实下载启动验证。
   接入独立 stable/beta 渠道、更新签名和可追溯的源码/构建记录。
5. 稳定重复构建后缓存工具链镜像、校验过的下载和编译缓存；CI 使用同一个 `build.sh`，按 tag 执行发布门槛。

每个平台发布记录应附：两个仓库 commit、工具链/镜像版本、CPU/ABI 基线、依赖报告、
应用/runner 资产摘要、源码与许可材料，以及自动回归和桌面/GPU/游戏验收范围。

## 本次验证范围

构建入口在 macOS Python 3.9 和 Ubuntu Python 3.12 执行回归，覆盖计划只读、特殊路径、
失败中断、重复产物保护、Wine 并发锁及取消后的子进程清理。
ELF 检查器使用真实编译的测试程序和已有应用/Wine 发布包验证。
Linux 10 项回归全部通过；macOS 通过 8 项，另外 2 项 ELF 用例在 Linux 执行。
两个 Dockerfile 通过 BuildKit `--check`；实际 Docker 挂载验证覆盖逗号、引号、中文和 `$HOME` 字面量。
交互菜单在真实终端完成目标选择、计划预览和环境检查；修正后的图标输入通过系统 `iconutil` 编译。
本次完整产品重编译、Developer ID 公证、AppImage/deb/rpm 生成及多发行版实体桌面验收列入上述实施阶段。
