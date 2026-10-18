<div align="center">

  # Whisky 🥃
  *Wine but a bit stronger*

  > This fork is maintained by [@daydalek](https://github.com/daydalek), based on
  > [frankea/Whisky](https://github.com/frankea/Whisky) and originally created by
  > [Isaac Marovitz (whisky-app/whisky)](https://github.com/whisky-app/whisky), with a
  > CrossOver-based GE Wine runtime and Visual Novel library enhancements.

  [![CI](https://img.shields.io/github/actions/workflow/status/daydalek/Whisky/CI.yml?style=for-the-badge)](https://github.com/daydalek/Whisky/actions)
  [![Releases](https://img.shields.io/github/v/release/daydalek/Whisky?include_prereleases&style=for-the-badge)](https://github.com/daydalek/Whisky/releases)
  [![Issues](https://img.shields.io/github/issues/daydalek/Whisky?style=for-the-badge)](https://github.com/daydalek/Whisky/issues)
  [![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg?style=for-the-badge)](./LICENSE)
</div>

## 项目定位与核心改动

本项目是 [frankea/Whisky](https://github.com/frankea/Whisky)（衍生自 [whisky-app/whisky](https://github.com/whisky-app/whisky)）的 fork，在保留 Whisky 原生 SwiftUI 界面、Bottle 管理和程序启动能力的基础上，接入我们在 [ge-proton-macos-wine-poc](https://github.com/daydalek/ge-proton-macos-wine-poc) 中构建的定制 Wine 运行库，并新增了面向**视觉小说（Visual Novel / Galgame）**与本地游戏的**书架媒体库、游戏元数据刮削（Metadata Scraping）、Steam 启动就绪编排**以及**环境变量与区域（Locale / WineD3D）快捷配置**等功能。应用本体与 Wine 运行库分别构建、独立发布。

### 本仓库核心功能概览

1. **文件夹游戏库与书架视图（Folder Game Library & Bookshelf）**
   - 支持在经典横向卡片网格与纵向封面**书架视图（Portrait Bookshelf）**之间切换。
   - 可开启**横竖封面混合排布**：横图占两列、竖图占一列，通过局部动态规划补齐行尾；封面支持模糊填充、主题色渐变、单行标题和文字居中。
   - 游戏详情支持**自定义封面上传、缩放与位置调整**，以及兼顾文字可读性的模糊封面背景。外观选项位于「设置 → 游戏库」及游戏库排序菜单。
   - 右键游戏可选择**隐藏／取消隐藏**，工具栏眼睛按钮切换隐藏模式与全部显示；隐藏标记持久保存，游戏文件与配置保持完整。
   - 支持按 Bottle 配置**游戏扫描根目录（Game Folders）**：自动将根目录下的直接子文件夹识别为独立游戏条目（排除已知 Steam 库目录），无需递归全盘扫描。
   - **独立的启动器与元数据身份**：首次运行时弹出可执行文件（EXE）选择器并持久化记忆，后续可在右键菜单中随时更换主程序，不会丢失已绑定的封面与元数据。
   - 支持在媒体库中直接打开固定程序与 Steam 游戏的运行兼容设置（Steam 游戏配置保存在 `Steam Game Settings/<appid>.plist`，将兼容性覆盖与 `-applaunch` 解耦）。
2. **多源游戏元数据刮削（Game Metadata Scraping）**
   - 支持为尚未绑定资料且允许自动匹配的文件夹游戏自动匹配作品信息；点击 **Sync Game Details** 可再次为符合条件的条目执行匹配。游戏详情页支持手动搜索、确认及解绑作品信息（标题、原名、简介、开发商、发行日期、竖版封面），已有资料可通过手动搜索重新选择。
   - 内置包装/汉化组前缀与版本号后缀清理、繁简中文及日文新字体归一化、多语言标题优选（优先简体中文 → 繁体中文 → 原文标题，或保留有效的本地中文目录名）以及长名称模糊相似度匹配。
   - 确认后的游戏元数据保存在对应 Bottle 的 `Game Metadata/` 目录下，封面图片按 URL 哈希缓存在 `Game Metadata/Covers/` 中，离线可用且移动 Bottle 不会丢失关联。
3. **Steam 启动就绪检测与编排（Steam Launch Readiness）**
   - 媒体库与 `WhiskyCmd launch` 共享 `SteamClientReadiness` 与 `SteamGameLaunchMonitor`：启动 Steam 游戏时自动拉起目标 Bottle 内的 Windows Steam 客户端，等待当前会话完成 UI 初始化、登录或离线模式就绪后再发送 `steam.exe -applaunch <appid>`，并确认目标游戏进程实际启动。
   - 支持并发启动共享客户端预热、阶段状态展示、保守单次重试（基于控制台日志 `GameAction` 游标）以及在不终止 Steam 客户端的前提下取消等待中的启动任务。详情参阅 [docs/steam-launch-readiness.md](docs/steam-launch-readiness.md)。
4. **持久化的区域（Locale）与 WineD3D 渲染器快捷预设**
   - 在程序设置与环境变量面板中提供持久化的 `LANG` / `LC_ALL` 区域预设与 `WINE_D3D_CONFIG` 渲染器切换（Automatic / GDI `gdi` / OpenGL `gl` / Vulkan `vulkan`）。Automatic 清除 `renderer=` 配置项；GDI 预设写入 `renderer=gdi`，读取时也将 `renderer=no3d` 识别为 GDI。在修改渲染器时保留用户自定义的其他 WineD3D 参数，方便快速排障视觉小说的字体乱码与旧版 DirectX / GDI 渲染问题。

---

## 游戏刮削与元数据来源（Metadata Data Sources）

媒体库仅在用户添加扫描目录首次枚举、主动点击同步或手动搜索时，直接通过官方公开 API 查询您启用（可在全局偏好 `libraryMetadataEnabledSources` 中勾选）的数据源，不会在后台隐式上传本地库列表。各数据源带有独立的请求队列序列化、250ms 突发节流、5–10 分钟内存缓存以及 HTTP 429/503 `Retry-After` 退避冷却。详细设计与技术说明请参阅 [docs/game-metadata.md](docs/game-metadata.md)。

游戏刮削的实现参考了 [PotatoVN](https://github.com/GoldenPotato137/PotatoVN)（遵循 [Apache License 2.0](https://github.com/GoldenPotato137/PotatoVN/blob/master/LICENSE)）。

| 数据源 | 接口说明与获取内容 | 状态与使用条款说明 |
| --- | --- | --- |
| **[Bangumi 番组计划](https://bgm.tv/)** | 通过 `api.bgm.tv/v0/search/subjects`（游戏分类 `type=4`）检索作品中文名/原名、简介、发行日期及多尺寸封面图 | 默认启用；直接调用官方公开 API |
| **[VNDB](https://vndb.org/)** | 通过 VNDB Kana API（`api.vndb.org/kana/vn`）支持关键词或 `v<id>` 直接检索多语言标题、罗马音、别名、开发商、发售日、简介与封面 | 默认启用；支持多语言标题归一化与中文优先展示 |
| **[Steam](https://store.steampowered.com/)** | 通过 Steam Store Search 与 `appdetails` 接口检索简中商店名称、简介、开发商、发行日及 `library_600x900` 纵向封面 | 默认启用；列表检索使用轻量缩略图，仅在选中条目时拉取详情 |
| **[月幕 Galgame (YMGal)](https://www.ymgal.games/)** | 通过[月幕官方开放 API](https://www.ymgal.games/developer)（公开 OAuth 客户端凭证）提供游戏搜索、中文名/原名、发售日、封面与档案简介；开发商名称取自搜索结果提供的 `orgName`（若有） | 默认启用，可在源选择器中关闭；月幕 API 仅适用于非商业用途 |

---

## Wine 运行库与安装说明

### 系统要求 (System Requirements)

- **处理器 (CPU)**：Apple Silicon（M 系列芯片）
- **操作系统 (OS)**：当前 Wine 运行库要求 **macOS 27 或更高版本**
- **兼容层**：Rosetta 2

### 下载的 Wine 包含什么

当前 `Libraries.tar.gz` 使用 **CrossOver Wine 26.3 开源核心**作为基线，应用
**GE-Proton 多媒体移植补丁**，以及全屏矩形、OpenGL flush、macOS 全屏 surface 和
WoW64 present 矩形等修复。包内包括：

| 路径 | 内容 |
| --- | --- |
| `Libraries/Wine/` | Wine、wineserver、32/64 位 Windows 模块和运行依赖，包含 MoltenVK |
| `Libraries/DXVK/` | DXVK-macOS 1.10.3 的 x32/x64 DLL |
| `Libraries/GE-Media/` | 补丁、依赖锁定配置、上游说明和许可证 |
| `Libraries/WhiskyWineVersion.plist` | 本地运行库版本与组件信息 |

Wine Release 同时提供 `Libraries-sources.tar.gz`、SHA-256 摘要和构建检查报告，供源码与构建来源核验。

### 安装与更新 (Installation & Updates)

1. 从本仓库的 [Releases](https://github.com/daydalek/Whisky/releases) 下载应用压缩包 `Whisky-X.Y.Z-arm64.zip`（支持 `v*` 与 `vn-v*` 发布标签），解压后将 `Whisky.app` 拖入 `/Applications`（应用使用 ad-hoc 签名，首次打开可能需要在系统设置中允许运行）。
2. 首次启动时，应用读取 [Wine 更新清单](https://raw.githubusercontent.com/daydalek/ge-proton-macos-wine-poc/runtime-channel/WhiskyWineVersion.plist)，从我们 [Wine 仓库的 GitHub Releases](https://github.com/daydalek/ge-proton-macos-wine-poc/releases) 下载清单指定的 `Libraries.tar.gz`，校验 SHA-256 后解包安装。
3. Wine CI 在完成构建、验证和发布后更新清单。频道支持正式版与 prerelease；应用启动时比较本地运行库版本（进程内缓存清单 1 小时），发现更高版本后提示用户确认下载安装。应用本体通过手动下载 Release 升级。

### 离线运行

在 **设置 → 更新** 中关闭 **检查 WhiskyWine 更新**，启动时即可跳过 Wine 版本查询。
开启同一区域的 **离线模式** 后，Whisky 会暂停更新检查、在线游戏资料查询、封面下载、遥测与组件下载，并保留各项联网偏好。
安装好 Wine 与 Rosetta 2 后，可直接使用本地游戏库、已有资料与封面缓存，创建 Bottle 并启动本地游戏。恢复联网功能时关闭离线模式即可；游戏和启动器自身的联网行为由各自管理。

### 存储路径与彻底卸载

- **本地存储路径**：共享运行库安装在 `~/Library/Application Support/com.franke.Whisky/Libraries/`；默认容器、文件夹游戏库配置（`Folder Games.json`、`Library Visibility.json`）及刮削缓存（`Game Metadata/`）位于 `~/Library/Containers/com.franke.Whisky/`（或您自定义的 Bottle 路径）下。
- **彻底卸载**：将 `Whisky.app` 移至废纸篓默认保留运行库与 Bottle 数据。如需彻底清除（**请先备份重要存档与容器**），可删除以下目录：

```sh
rm -rf "/Applications/Whisky.app"
rm -rf ~/Library/Containers/com.franke.Whisky
rm -rf ~/Library/Containers/com.franke.Whisky.WhiskyThumbnail
rm -rf ~/Library/Application\ Support/com.franke.Whisky
rm -rf ~/Library/Caches/com.franke.Whisky
rm -rf ~/Library/Logs/com.franke.Whisky
rm -rf ~/Library/HTTPStorages/com.franke.Whisky
rm -f  ~/Library/Preferences/com.franke.Whisky.plist
```

### 遥测与诊断 (Telemetry & Diagnostics)

本 fork禁用遥测（Telemetry）：构建中移除了 PostHog token 并隐藏了遥测许可开关。诊断报告仅支持导出为本地文件，供用户自行检查并手动附到 [本仓库 Issues](https://github.com/daydalek/Whisky/issues)（上传前请检查报告中是否包含敏感本地路径或日志）。

---

## 相关文档 (Documentation)

- **[Game Metadata Integration](docs/game-metadata.md)** - 文件夹游戏发现、元数据刮削数据源、缓存机制与多语言匹配规则
- **[Steam Launch Readiness](docs/steam-launch-readiness.md)** - Steam 会话就绪检测、进程确认与保守重试机制
- **[Launcher Troubleshooting](docs/LauncherTroubleshooting.md)** / **[Steam Compatibility Guide](docs/SteamCompatibility.md)** - Steam 等启动器兼容说明与排障指南
- **[Stability Troubleshooting](docs/StabilityTroubleshooting.md)** - 崩溃、卡死与稳定性诊断说明
- **[Runtime Dependencies](docs/DEPENDENCIES.md)** - 运行库组件版本与上游来源说明

---

## 版权、许可证与源代码来源声明 (License, Copyright & Source Attribution)

### 开源许可证与源代码来源 (License & Upstream Sources)

- **许可证 (License)**：本项目遵循 **[GNU General Public License v3.0 (GPL-3.0-or-later)](./LICENSE)** 开源许可证发布。
- **应用源代码来源 (Application Source Attribution)**：
  - 本仓库（[daydalek/Whisky](https://github.com/daydalek/Whisky)）fork 自 **[frankea/Whisky](https://github.com/frankea/Whisky)**。
  - 上游项目最初由 **[Isaac Marovitz](https://github.com/IsaacMarovitz)** 创建并发布于 **[whisky-app/whisky](https://github.com/whisky-app/whisky)**。
- **Wine 运行库源代码来源 (Wine Runtime Source Attribution)**：
  - 本项目配套下载的 Wine 运行库由 **[daydalek/ge-proton-macos-wine-poc](https://github.com/daydalek/ge-proton-macos-wine-poc)** 构建并发布，基于 **CodeWeavers CrossOver Wine 26.3 开源核心** 与 **GE-Proton ([GloriousEggroll/proton-ge-custom](https://github.com/GloriousEggroll/proton-ge-custom))** 多媒体补丁移植。每个运行库 Release 均附带完整的对应源码归档（`Libraries-sources.tar.gz`）、补丁说明、许可证文件与 SHA-256 校验信息。
- **游戏刮削设计致谢与第三方数据声明 (Metadata Design & Data Attribution)**：
  - 媒体库的多数据源独立解析器与匹配设计思路参考了 **[PotatoVN](https://github.com/GoldenPotato137/PotatoVN)**（原作者 GoldenPotato137，遵循 [Apache License 2.0](https://github.com/GoldenPotato137/PotatoVN/blob/master/LICENSE)）。
  - 游戏元数据与封面图片来源于以下公开接口，版权归各自平台与原著作权人所有：
    - **[Bangumi 番组计划](https://bgm.tv/)**（[Bangumi Open API](https://bangumi.github.io/api/)）
    - **[VNDB (The Visual Novel Database)](https://vndb.org/)**（[VNDB Kana API](https://api.vndb.org/kana)）
    - **[Steam](https://store.steampowered.com/)**（Steam Store Web API）
    - **[月幕 Galgame](https://www.ymgal.games/)**（通过其[官方开放 API](https://www.ymgal.games/developer)提供搜索、封面与游戏简介）

### Credits & Acknowledgments

Whisky is possible thanks to the magic of several projects:

- [msync](https://github.com/marzent/wine-msync) by marzent
- [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) by Gcenx and doitsujin
- [DXMT](https://github.com/3Shain/dxmt) by 3Shain
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) by KhronosGroup
- [Sparkle](https://github.com/sparkle-project/Sparkle) by sparkle-project
- [SemanticVersion](https://github.com/SwiftPackageIndex/SemanticVersion) by SwiftPackageIndex
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) by Apple
- [CrossOver](https://www.codeweavers.com/crossover) by CodeWeavers and WineHQ
- [GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom) by GloriousEggroll
- D3DMetal by Apple

Special thanks to Gcenx, ohaiibuzzle, Nat Brown, [Frank](https://github.com/frankea), and [Isaac Marovitz](https://github.com/IsaacMarovitz) (original author) for their support and contributions!

---

<table>
  <tr>
    <td>
        <picture>
          <source media="(prefers-color-scheme: dark)" srcset="./images/cw-dark.png">
          <img src="./images/cw-light.png" width="500">
        </picture>
    </td>
    <td>
        Whisky doesn't exist without CrossOver. If you want a fully-supported commercial Wine experience on macOS, check out <a href="https://www.codeweavers.com/crossover">CrossOver</a> from CodeWeavers. (This fork has no affiliate arrangement and receives nothing from CrossOver sales.)
    </td>
  </tr>
</table>
