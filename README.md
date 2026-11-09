<div align="center">

  # Maltoria
  *Visual Novels, Beyond Windows*

  > 本项目Fork自
  > [frankea/Whisky](https://github.com/frankea/Whisky),原本基于
  > [Isaac Marovitz (whisky-app/whisky)](https://github.com/whisky-app/whisky),并增强了作为视觉小说管理器和运行时环境的兼容性和功能.

  [![CI](https://img.shields.io/github/actions/workflow/status/daydalek/Maltoria/CI.yml?style=for-the-badge)](https://github.com/daydalek/Maltoria/actions)
  [![Releases](https://img.shields.io/github/v/release/daydalek/Maltoria?include_prereleases&style=for-the-badge)](https://github.com/daydalek/Maltoria/releases)
  [![Issues](https://img.shields.io/github/issues/daydalek/Maltoria?style=for-the-badge)](https://github.com/daydalek/Maltoria/issues)
  [![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg?style=for-the-badge)](./LICENSE)
</div>

---
## 下载和安装

目前提供面向macOS(aarch64)和Linux(x86_64)用户的安装包,点击下方链接即可直接下载最新版本

<!-- 每次发布新版本后,请同步更新下表中的版本号与直链. -->
| 平台 | 安装包 |
| --- | --- |
| macOS (Apple Silicon) | [Maltoria-0.5.0-arm64.zip](https://github.com/daydalek/Maltoria/releases/download/vn-v0.5.0/Maltoria-0.5.0-arm64.zip) |
| Linux · deb (Ubuntu 24.04) | [whisky_0.5.0_amd64.deb](https://github.com/daydalek/Maltoria/releases/download/linux-v0.5.0/whisky_0.5.0_amd64.deb) |
| Linux · rpm (Fedora 44) | [whisky-0.5.0-1.x86_64.rpm](https://github.com/daydalek/Maltoria/releases/download/linux-v0.5.0/whisky-0.5.0-1.x86_64.rpm) |
| Linux · AppImage | [Maltoria-0.5.0-x86_64.AppImage](https://github.com/daydalek/Maltoria/releases/download/linux-v0.5.0/Maltoria-0.5.0-x86_64.AppImage) |

由于缺少Apple开发者证书,目前应用以ad-hoc方式签名,打开时会提示无法验证应用安全性,请至设置-隐私与安全性中信任应用.

---

## 游戏刮削与元数据来源（Metadata Data Sources）

游戏刮削的实现参考了 [PotatoVN](https://github.com/GoldenPotato137/PotatoVN)（遵循 [Apache License 2.0](https://github.com/GoldenPotato137/PotatoVN/blob/master/LICENSE)）。

| 数据源 | 接口说明与获取内容 | 状态与使用条款说明 |
| --- | --- | --- |
| **[Bangumi 番组计划](https://bgm.tv/)** | 通过 `api.bgm.tv/v0/search/subjects`（游戏分类 `type=4`）检索作品中文名/原名、简介、发行日期及多尺寸封面图 | 默认启用|
| **[VNDB](https://vndb.org/)** | 通过 VNDB Kana API（`api.vndb.org/kana/vn`）支持关键词或 `v<id>` 直接检索多语言标题、罗马音、别名、开发商、发售日、简介与封面 | 默认启用|
| **[Steam](https://store.steampowered.com/)** | 通过 Steam Store Search 与 `appdetails` 接口检索简中商店名称、简介、开发商、发行日及 `library_600x900` 纵向封面 | 默认启用 |
| **[月幕 Galgame (YMGal)](https://www.ymgal.games/)** | 通过[月幕官方开放 API](https://www.ymgal.games/developer)（公开 OAuth 客户端凭证）提供游戏搜索、中文名/原名、发售日、封面与档案简介；开发商名称取自搜索结果提供的 `orgName`（若有） | 默认启用 |
| **[NextMoe 鲲 Galgame 论坛](https://developer.nextmoe.dev/)** | 通过 NextMoe 公开目录 API（`api.nextmoe.dev/v2/catalog`，匿名只读）检索多语言标题、封面、简介、开发商、发售日、人物与声优 | 默认启用|

---

### 存储路径与彻底卸载

- **macOS 本地存储路径**：共享运行库安装在 `~/Library/Application Support/com.daydalek.Maltoria/Libraries/`；默认容器、文件夹游戏库配置（`Folder Games.json`、`Library Visibility.json`）及刮削缓存（`Game Metadata/`）位于 `~/Library/Containers/com.daydalek.Maltoria/`（或您自定义的 Bottle 路径）下。
- **Linux 本地存储路径**：程序文件安装在 `/opt/whisky/`（启动器为 `/usr/bin/whisky`）；Wine 运行库位于 `$XDG_DATA_HOME/whisky/runtime/wine/`（默认 `~/.local/share/whisky/runtime/wine/`），默认 Bottle、游戏库配置与刮削缓存位于 `~/.local/share/whisky/Bottles/`。
- **macOS 彻底卸载**：将 `Maltoria.app` 移至废纸篓默认保留运行库与 Bottle 数据。如需彻底清除（**请先备份重要存档与容器**），可删除以下目录：

```sh
rm -rf "/Applications/Maltoria.app"
rm -rf ~/Library/Containers/com.daydalek.Maltoria
rm -rf ~/Library/Containers/com.daydalek.Maltoria.WhiskyThumbnail
rm -rf ~/Library/Application\ Support/com.daydalek.Maltoria
rm -rf ~/Library/Caches/com.daydalek.Maltoria
rm -rf ~/Library/Logs/com.daydalek.Maltoria
rm -rf ~/Library/HTTPStorages/com.daydalek.Maltoria
rm -f  ~/Library/Preferences/com.daydalek.Maltoria.plist
```

- **Linux 彻底卸载**：deb 用 `sudo apt remove whisky`、rpm 用 `sudo dnf remove whisky` 卸载（卸载保留用户数据）；AppImage 直接删除文件。如需彻底清除用户数据，可删除：

```sh
rm -rf ~/.local/share/whisky
```

## 相关文档 (Documentation)

- **[Game Metadata Integration](docs/game-metadata.md)** - 文件夹游戏发现、元数据刮削数据源、缓存机制与多语言匹配规则
- **[Steam Launch Readiness](docs/steam-launch-readiness.md)** - Steam 会话就绪检测、进程确认与保守重试机制
- **[Launcher Troubleshooting](docs/LauncherTroubleshooting.md)** / **[Steam Compatibility Guide](docs/SteamCompatibility.md)** - Steam 等启动器兼容说明与排障指南
- **[Stability Troubleshooting](docs/StabilityTroubleshooting.md)** - 崩溃、卡死与稳定性诊断说明
- **[Runtime Dependencies](docs/DEPENDENCIES.md)** - 运行库组件版本与上游来源说明

---

## 版权、许可证与源代码来源声明 
### 开源许可证与源代码来源 

完整第三方来源清单见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)，许可证原文与固定版本记录见 [ThirdParty](ThirdParty/)

- **许可证 (License)**：本项目遵循 **[GNU General Public License v3.0 (GPL-3.0-or-later)](./LICENSE)** 开源许可证发布。
- **应用源代码来源 (Application Source Attribution)**：
  - 本仓库（[daydalek/Maltoria](https://github.com/daydalek/Maltoria)）fork 自 **[frankea/Whisky](https://github.com/frankea/Whisky)**。
  - 上游项目最初由 **[Isaac Marovitz](https://github.com/IsaacMarovitz)** 创建并发布于 **[whisky-app/whisky](https://github.com/whisky-app/whisky)**。
- **Wine 运行库源代码来源 (Wine Runtime Source Attribution)**：
  - 本项目配套下载的 Wine 运行库由 **[daydalek/ge-proton-macos-wine-poc](https://github.com/daydalek/ge-proton-macos-wine-poc)** 构建并发布，基于 **CodeWeavers CrossOver Wine 26.3 开源核心** 与 **GE-Proton ([GloriousEggroll/proton-ge-custom](https://github.com/GloriousEggroll/proton-ge-custom))** 多媒体补丁移植.
- **游戏刮削设计致谢与第三方数据声明 (Metadata Design & Data Attribution)**：
  - 媒体库的多数据源独立解析器与匹配设计思路参考了 **[PotatoVN](https://github.com/GoldenPotato137/PotatoVN)**（原作者 GoldenPotato137，遵循 [Apache License 2.0](https://github.com/GoldenPotato137/PotatoVN/blob/master/LICENSE)）。
  - 游戏元数据与封面图片来源于以下接口
    - **[Bangumi 番组计划](https://bgm.tv/)**（[Bangumi Open API](https://bangumi.github.io/api/)）
    - **[VNDB (The Visual Novel Database)](https://vndb.org/)**（[VNDB Kana API](https://api.vndb.org/kana)）
    - **[Steam](https://store.steampowered.com/)**（Steam Store Web API）
    - **[月幕 Galgame](https://www.ymgal.games/)**（[官方开放 API](https://www.ymgal.games/developer))
    - **[NextMoe · 鲲 Galgame 论坛](https://developer.nextmoe.dev/)**（[NextMoe API v2](https://developer.nextmoe.dev/docs/v2))

### Credits & Acknowledgments

Maltoria is possible thanks to the magic of several projects:

- [msync](https://github.com/marzent/wine-msync) by marzent
- [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) by Gcenx and doitsujin
- [DXMT](https://github.com/3Shain/dxmt) by 3Shain
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) by KhronosGroup
- [Sparkle](https://github.com/sparkle-project/Sparkle) by sparkle-project
- [SemanticVersion](https://github.com/SwiftPackageIndex/SemanticVersion) by SwiftPackageIndex
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) by Apple
- [PostHog](https://github.com/PostHog/posthog-ios) and its bundled component authors (linked SDK; telemetry disabled in this fork)
- [Winetricks](https://github.com/Winetricks/winetricks) by Dan Kegel, Austin English, and contributors
- [cabextract / libmspack](https://www.cabextract.org.uk/) by Stuart Caie
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
        Maltoria doesn't exist without CrossOver. If you want a fully-supported commercial Wine experience on macOS, check out <a href="https://www.codeweavers.com/crossover">CrossOver</a> from CodeWeavers. (This fork has no affiliate arrangement and receives nothing from CrossOver sales.)
    </td>
  </tr>
</table>
