<div align="center">

  # Whisky 🥃
  *Wine but a bit stronger*

  > This fork is maintained by [@daydalek](https://github.com/daydalek), based on
  > [frankea/Whisky](https://github.com/frankea/Whisky), with a CrossOver-based GE Wine runtime.

  [![CI](https://img.shields.io/github/actions/workflow/status/daydalek/Whisky/CI.yml?style=for-the-badge)](https://github.com/daydalek/Whisky/actions)
  [![Releases](https://img.shields.io/github/v/release/daydalek/Whisky?include_prereleases&style=for-the-badge)](https://github.com/daydalek/Whisky/releases)
  [![Issues](https://img.shields.io/github/issues/daydalek/Whisky?style=for-the-badge)](https://github.com/daydalek/Whisky/issues)
</div>

## 项目定位与 Wine 运行库

本项目是 [frankea/Whisky](https://github.com/frankea/Whisky) 的 fork，保留 Whisky 的
SwiftUI 界面、Bottle 管理和程序启动功能，接入我们在
[ge-proton-macos-wine-poc](https://github.com/daydalek/ge-proton-macos-wine-poc)
中构建的 Wine。主要目标是在 Apple Silicon 上提供带 GE-Proton 多媒体补丁及全屏修复的
Wine 运行环境。应用和 Wine 分别构建、分别发布。

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

Wine Release 同时提供 `Libraries-sources.tar.gz`、SHA-256 摘要和构建检查报告，供源码与
构建来源核验。当前运行库要求 **macOS 27+、Apple Silicon 和 Rosetta 2**。

### 从哪里下载、如何更新

1. 从本仓库的 [Releases](https://github.com/daydalek/Whisky/releases) 下载应用 ZIP，
   解压后将 `Whisky.app` 放入 `/Applications`。
2. 首次启动时，应用读取 [Wine 更新清单](https://raw.githubusercontent.com/daydalek/ge-proton-macos-wine-poc/runtime-channel/WhiskyWineVersion.plist)，
   从我们 [Wine 仓库的 GitHub Releases](https://github.com/daydalek/ge-proton-macos-wine-poc/releases)
   下载清单指定的 `Libraries.tar.gz`，校验 SHA-256 后解包安装。
3. Wine CI 在完成构建、验证和发布后更新清单。频道支持正式版与 prerelease；应用启动时
   比较本地运行库版本，发现更高版本后提示用户确认下载安装。应用自身通过手动下载 Release 升级。

发布标签（例如 `v0.1.1`）与运行库内部版本号分别管理；更新判断使用清单中的运行库版本。
应用进程对清单缓存一小时。

### 本地安装位置

当前应用使用 `com.franke.Whisky` 标识，运行库安装在：

```text
~/Library/Application Support/com.franke.Whisky/Libraries/
├── Wine/
│   └── bin/            # wine、wine64、wineserver
├── DXVK/
├── GE-Media/
└── WhiskyWineVersion.plist
```

游戏、Bottle 和存档由 Whisky 的 Bottle 配置管理。上述目录存放共享运行库；导出的诊断日志
由用户保存在本地，并可手动附到本 fork 的反馈中。

## Overview

Whisky provides a clean and easy-to-use graphical wrapper for Wine built in native SwiftUI. You can make and manage bottles, install and run Windows apps and games, and unlock the full potential of your Mac with no technical knowledge required.

<img width="650" alt="Whisky in action" src="./images/demo.gif">

<img width="650" alt="Config" src="./images/config-screenshot.png">

*Familiar UI that integrates seamlessly with macOS*

<div align="right">
  <img width="650" alt="New Bottle" src="./images/new-bottle-screenshot.png">

  *One-click bottle creation and management*
</div>

<img width="650" alt="debug" src="./images/debug-screenshot.png">

*Debug and profile with ease*

---

## Key Features

- **CrossOver Wine 26.3 + GE media** - Patched open-source Wine core with multimedia and fullscreen fixes
- **DXVK Graphics** - Bundled DXVK-macOS over MoltenVK; additional graphics backends depend on separately configured components
- **Launcher Compatibility** - Built-in support for Steam, Epic, EA App, Rockstar, Battle.net, and more
- **Controller Support** - SDL environment variable controls for gamepad detection and mapping issues
- **Stability Diagnostics** - One-click diagnostic reports for troubleshooting crashes and freezes
- **Native SwiftUI** - Beautiful, familiar macOS interface

## System Requirements

- **CPU**: Apple Silicon (M-series chips)
- **OS**: macOS 27 or later for the current Wine runtime
- **Compatibility layer**: Rosetta 2

## Installation

1. Download `Whisky-X.Y.Z-arm64.zip` from [Releases](https://github.com/daydalek/Whisky/releases).
2. Extract **Whisky.app** and drag it to **/Applications**.
3. Launch Whisky to download the Wine Libraries runtime.

The app is ad-hoc signed; Gatekeeper may require first-launch approval. App upgrades
are installed manually from Releases. Wine runtime updates use the separate
[Wine release channel](https://github.com/daydalek/ge-proton-macos-wine-poc/releases).
The current runtime requires macOS 27 or later and Rosetta 2.

### Migrating from the original Whisky

The original [whisky-app/whisky](https://github.com/whisky-app/whisky) was archived on **April 9, 2025** with a final maintenance notice. If you're running it today, you're on a stale build with no path forward for new fixes. This fork picks up where the upstream left off — version `3.0.1` shipped 54 requirements covering the 10 categories of upstream issue tracking (#40–#50).

To switch:

1. Install this fork using the ZIP steps above.
2. Open it and choose **File → Migrate from the Original Whisky**. It finds the bottles the original app left in `~/Library/Containers/com.isaacmarovitz.Whisky/` and imports the ones you pick. Bottles are referenced **in place** — nothing is moved or copied — so the original app keeps working if you'd like to keep it around.
3. *(Optional)* Once you're happy, remove the original app: drag **/Applications/Whisky.app** to the Trash, or `brew uninstall --cask whisky` if you installed it via Homebrew. Your bottles stay put.

The original app uses a different bundle identifier (`com.franke.Whisky` here vs. `com.isaacmarovitz.Whisky`), which is why bottles aren't shared automatically. The old **Bottle → Export** / **File → Import Bottle** route still works if you'd rather move bottles by hand or onto another Mac. With no critical bottles, you can skip migration entirely — the new app creates a fresh bottle on first launch.

## Uninstalling

Dragging **Whisky.app** to the Trash (or `brew uninstall --cask frankea/whisky/whisky`) removes the app but leaves the Wine runtime, your bottles, and app data behind — by design, so reinstalling doesn't re-download ~330 MB or lose your bottles.

> ⚠️ **Back up your bottles first if you want to keep them.** Removing the container below deletes every bottle stored in its default location. Bottles you created in a custom folder live wherever you put them — check **Bottle → Reveal in Finder** before deleting anything.

To remove Whisky **completely**, delete the app and then these paths (all under `~/Library`):

```sh
# 1. The app itself
rm -rf "/Applications/Whisky.app"          # or: brew uninstall --cask frankea/whisky/whisky

# 2. Bottles + bottle list (default bottle location is inside this container)
rm -rf ~/Library/Containers/com.franke.Whisky
rm -rf ~/Library/Containers/com.franke.Whisky.WhiskyThumbnail

# 3. The Wine runtime (~330 MB) and other app support
rm -rf ~/Library/Application\ Support/com.franke.Whisky

# 4. Caches, logs, preferences, and saved state
rm -rf ~/Library/Caches/com.franke.Whisky
rm -rf ~/Library/Logs/com.franke.Whisky
rm -rf ~/Library/HTTPStorages/com.franke.Whisky
rm -f  ~/Library/Preferences/com.franke.Whisky.plist
```

If you also installed bottles in a **custom location**, delete those folders too. Migrated bottles that still belong to the original app live under `~/Library/Containers/com.isaacmarovitz.Whisky` and are left untouched by the steps above.

## Telemetry and diagnostics

Telemetry is disabled in this fork: the build omits the PostHog project token and
hides telemetry consent controls. Diagnostics are exported to local files for
manual submission to [our Issues](https://github.com/daydalek/Whisky/issues).
Review exported reports before attaching them; they can contain local paths and
Wine process output.

## Documentation

- **[Support](docs/SUPPORT.md)** - Where to file bugs and what to expect from a single-maintainer fork
- **[Governance & continuity](docs/GOVERNANCE.md)** - Who maintains this and the honest bus-factor situation
- **[Runtime dependencies](docs/DEPENDENCIES.md)** - The bundled Wine/DXVK/D3DMetal/DXMT versions and their upstream sources

WhiskyKit, the core framework powering Whisky, has comprehensive API documentation:

- **[WhiskyKit API Documentation](https://frankea.github.io/Whisky/documentation/whiskykit/)** - Full API reference with usage examples
- **[Getting Started Guide](https://frankea.github.io/Whisky/documentation/whiskykit/gettingstarted)** - Learn how to integrate WhiskyKit
- **[Architecture Overview](https://frankea.github.io/Whisky/documentation/whiskykit/architecture)** - Understand how WhiskyKit components work together

### Troubleshooting

- **[Launcher Troubleshooting](docs/LauncherTroubleshooting.md)** - Fix issues with Steam, Epic, Battle.net, etc.
- **[Steam Compatibility Guide](docs/SteamCompatibility.md)** - Detailed guide for Steam on Whisky
- **[Stability Troubleshooting](docs/StabilityTroubleshooting.md)** - Diagnose crashes, freezes, reboots, and kernel panics
- **Controller Issues** - Enable "Controller Compatibility Mode" in Bottle Config → Controller & Input
- **[Game Configurations](https://github.com/frankea/Whisky/blob/main/WhiskyKit/Sources/WhiskyKit/GameDatabase/Resources/GameDB.json)** - 80+ curated per-game compatibility configs, also browsable in-app under Game Configurations

### Upstream issue audit

Per-issue accounting of how this fork addresses the open issues from the
archived upstream repo. Read [docs/AUDIT.md](docs/AUDIT.md) for the
methodology — including how to read the `addressed-direct` vs
`addressed-categorical` distinction and what `unverified` GameDB entries
actually mean.

### Test coverage

The Coverage badge above is scoped to the **`whiskykit` flag** — line
coverage of the framework that holds the bottle, Wine, GameDB, and
PE-parser logic, measured by `swift test --enable-code-coverage` per
[`.github/workflows/CI.yml`](.github/workflows/CI.yml). The blended
project-wide number on the [Codecov dashboard](https://codecov.io/gh/frankea/Whisky)
reads much lower because it averages in the SwiftUI app target, which
only receives best-effort UI-test coverage. Read the badge as
"WhiskyKit unit-test coverage," not full-app coverage.

WhiskyUITests gives behavioural coverage of the SwiftUI surface (toolbar,
create-bottle sheet, fixture-dependent flows). CI now runs them with
`-enableCodeCoverage YES` and uploads the resulting app-target coverage to
Codecov under a separate `whiskyapp` flag (best-effort — the upload never gates
CI). Because UI tests exercise far less of the app than the unit tests do of
WhiskyKit, expect the app-target number to read lower than the WhiskyKit badge
above.

---

## Credits & Acknowledgments

Whisky is possible thanks to the magic of several projects:

- [msync](https://github.com/marzent/wine-msync) by marzent
- [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) by Gcenx and doitsujin
- [DXMT](https://github.com/3Shain/dxmt) by 3Shain
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) by KhronosGroup
- [Sparkle](https://github.com/sparkle-project/Sparkle) by sparkle-project
- [SemanticVersion](https://github.com/SwiftPackageIndex/SemanticVersion) by SwiftPackageIndex
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) by Apple
- [CrossOver](https://www.codeweavers.com/crossover) by CodeWeavers and WineHQ
- D3DMetal by Apple

Special thanks to Gcenx, ohaiibuzzle, Nat Brown, and [Isaac Marovitz](https://github.com/IsaacMarovitz) (original author) for their support and contributions!

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
