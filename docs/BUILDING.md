# 统一构建入口

在 Whisky 仓库根目录运行。入口依赖 Python 3.9+ 和 Bash，Linux 构建镜像提供 Python 3.12。

```bash
./build.sh                  # 交互菜单：选目标、执行环境，再预览/检查/构建
./build.sh list             # 列出目标
./build.sh doctor whisky-macos-arm64
./build.sh plan whisky-macos-arm64 --version 0.2.0 --json
./build.sh run whisky-macos-arm64 --version 0.2.0 --build-number 12
```

`plan` 输出完整命令、工作目录、环境变量和产物路径；`run` 执行同一份计划。
每次任务使用全新目录，默认 `build/distribution/<target>/<时间-任务ID>/`。
`build-report.json` 和 `01.log` 等文件记录执行结果；Ctrl-C 保留日志与已生成文件。
菜单默认执行环境检查，选择“开始构建”后运行。

## 目标

| 名称 | 主机 / 产物 |
| --- | --- |
| `whisky-macos-arm64` | Apple Silicon + Xcode；SwiftUI ad-hoc ZIP 与源码包 |
| `whisky-macos-gpui-arm64` | Apple Silicon + Swift/Rust；GPUI 开发 `.app` |
| `whisky-linux-amd64` | Ubuntu 24.04 amd64 或 Docker；Release tar.gz、源码与许可材料 |
| `wine-macos-arm64` | macOS 27+ Apple Silicon、Rosetta、CMake/pkg-config；x86_64 Libraries 与源码包 |
| `wine-linux-amd64` | Ubuntu 24.04 amd64 或 Docker；new WoW64 runner 与源码包 |

Linux arm64 保留后续目标。公众分发规划见 [DistributionStrategy.md](DistributionStrategy.md)。

`doctor` 检查平台、基础工具与 Wine 配方；编译阶段继续检查开发库、SDK 和源码。
macOS 签名类型、Wine 的 Rosetta 要求和产品最低系统版本分别以对应脚本/manifest 为准。
当前菜单的 macOS 应用目标沿用 ad-hoc 预发布链路；Developer ID、公证和应用更新签名见分发规划。

## Linux 应用

原生构建使用 Ubuntu 24.04 amd64、Swift 6.4 和 Rust 1.99.1，开发依赖入口为
`apps/whisky-gpui/tools/install-linux-deps.sh`（管理员单独安装）。

```bash
./build.sh doctor whisky-linux-amd64
./build.sh run whisky-linux-amd64 --jobs 4
```

Docker 执行器可从 macOS 调度 amd64 构建；镜像自动缓存已安装的构建依赖。
Apple Silicon 上的 amd64 容器需要相应 CPU 转译能力，正式构建优先使用原生 amd64 机器。

```bash
./build.sh doctor whisky-linux-amd64 --executor docker
./build.sh plan whisky-linux-amd64 --executor docker --json
./build.sh run whisky-linux-amd64 --executor docker --jobs 4
```

Docker 任务将内部构建记录放在 `<output>/task/`，最终应用位于 `task/artifacts/`。
源码只读挂载；镜像构建上下文只包含配方与依赖安装脚本；用户目录和 Cargo 下载缓存在
`build/distribution-cache/docker/`。首次构建会下载基础镜像和工具链。

打包后生成 `elf-abi.json`，检查 GLIBC 2.39 上限。该检查与发行版和图形运行验收分别记录。
完整干净运行时验收沿用 `check-linux-package.py` / `linux-runtime.Dockerfile`；
它要求独立的普通用户运行时容器，CI 的 Portability 工作流提供该门槛。

## Wine

默认发现 Whisky 的同级 `ge-proton-macos-wine-poc` 仓库。
可通过 `--wine-repo /path/to/wine-recipe` 或 `WHISKY_WINE_REPO` 设置路径。
计划和构建会记录 Wine 配方仓库 commit，既有源码锁和下载哈希继续由 Wine 配方校验。

```bash
./build.sh plan wine-linux-amd64 --wine-repo ../ge-proton-macos-wine-poc --json
./build.sh run wine-linux-amd64 --jobs 4

# Apple Silicon：先构建/静态校验，记录 compile-only 产物
./build.sh run wine-linux-amd64 --executor docker --compile-only --jobs 4

# 在具备所需内核兼容入口的 amd64 环境执行完整 Wine 回归
./build.sh run wine-linux-amd64 --executor docker --jobs 4

./build.sh run wine-macos-arm64 --build-number 120 --jobs 4
```

Linux 默认顺序：源码/依赖/编译 → 探针编译 → Wine 回归 → 打包与验证 → ELF 基线报告 → 打包后回归。
`--compile-only` 跳过 Wine 运行探针，保留编译和静态校验；manifest 记录验证范围。
Docker 构建 Wine 的内核行为依赖宿主，`int 0x80` / 图形 / 音频 / 游戏的正式验收使用相应目标机器。

Wine 增量工作目录按配方摘要自动分组。已有缓存保留，变化后的配置、补丁或脚本选择新的目录。
同目录采用排他锁；并发任务会得到明确错误。
原生 Linux 可用 `--work-dir` 选择已有目录、`--archive-cache` 复用校验过的下载；
Docker 模式自动管理 `/cache/work` 目录和其中的下载。
macOS Wine 完整发布配方要求新的工作目录，版本计数沿用其 `11.0.(build-number + 1)` 规则。

## 验证构建工具

```bash
python3 -m unittest discover -s scripts/distribution -p 'test_*.py' -v
python3 scripts/distribution/audit-elf.py /path/to/Whisky \
  --glibc-max 2.39 --output /tmp/whisky-abi.json
```

ABI 检查器需要 Linux `readelf`。基础工具检查保持只读；依赖安装由管理员或 Docker 镜像完成。
