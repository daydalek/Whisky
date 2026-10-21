//
//  ContainerConfiguration.swift
//  WhiskyCrossUI
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation

public struct ConfigurationSection: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let fields: [ConfigurationField]
    public init(id: String, title: String, fields: [ConfigurationField]) {
        self.id = id
        self.title = title
        self.fields = fields
    }
}

public enum ContainerConfiguration {
    public static let sections: [ConfigurationSection] = [
        .init(id: "wine", title: "Wine", fields: [
            choice("windowsVersion", "Windows 版本", "wineConfig.windowsVersion", "win10", [
                ("winxp64", "Windows XP"), ("win7", "Windows 7"), ("win8", "Windows 8"),
                ("win81", "Windows 8.1"), ("win10", "Windows 10"), ("win11", "Windows 11")
            ]),
            choice("enhancedSync", "增强同步", "wineConfig.enhancedSync", "msync", [
                ("none", "关闭"), ("esync", "ESync"), ("msync", "MSync")
            ], tagged: true),
            toggle("avxEnabled", "AVX 支持", "wineConfig.avxEnabled", false)
        ]),
        .init(id: "launcher", title: "启动器兼容性", fields: [
            toggle("launcherCompatibilityMode", "启动器兼容模式", "launcherConfig.compatibilityMode", false),
            choice(
                "launcherMode",
                "检测模式",
                "launcherConfig.launcherMode",
                "auto",
                [("auto", "自动检测"), ("manual", "手动选择")]
            ),
            ConfigurationField(
                "detectedLauncher",
                "启动器类型",
                path: "launcherConfig.detectedLauncher",
                input: .choice([ConfigurationChoice("", "自动检测")] + LauncherType.allCases.map { .init(
                    $0.rawValue,
                    $0.rawValue
                ) }),
                defaultValue: .text(""),
                removesEmptyText: true
            ),
            choice("launcherLocale", "启动器语言区域", "launcherConfig.launcherLocale", "", locales),
            toggle("gpuSpoofing", "GPU 伪装", "launcherConfig.gpuSpoofing", true),
            choice(
                "gpuVendor",
                "GPU 厂商",
                "launcherConfig.gpuVendor",
                "NVIDIA",
                [("NVIDIA", "NVIDIA"), ("AMD", "AMD"), ("Intel", "Intel")]
            ),
            toggle("autoEnableDXVK", "为 Rockstar 启动器使用 DXVK", "launcherConfig.autoEnableDXVK", true)
        ]),
        .init(id: "input", title: "输入与控制器", fields: [
            toggle("controllerCompatibilityMode", "控制器兼容模式", "inputConfig.controllerCompatibilityMode", false),
            toggle("disableHIDAPI", "停用 HIDAPI", "inputConfig.disableHIDAPI", false),
            toggle("allowBackgroundEvents", "允许后台输入", "inputConfig.allowBackgroundEvents", false),
            toggle("disableControllerMapping", "停用控制器映射", "inputConfig.disableControllerMapping", false),
            toggle("useButtonLabels", "使用原生按钮标签", "inputConfig.useButtonLabels", false),
            toggle("commandActsAsControl", "将 Command 映射为 Windows Ctrl", "inputConfig.commandActsAsControl", false)
        ]),
        .init(id: "graphics", title: "图形", fields: [
            choice("graphicsBackend", "图形后端", "graphicsConfig.backend", "recommended", [
                ("recommended", "推荐"), ("d3dMetal", "D3DMetal"), ("dxvk", "DXVK"), ("dxmt", "DXMT"), (
                    "wined3d",
                    "WineD3D"
                )
            ]),
            toggle("metalFX", "MetalFX 超分辨率", "graphicsConfig.metalFX", true),
            toggle("frameGeneration", "帧生成", "graphicsConfig.frameGeneration", false),
            toggle("metal4Enabled", "Metal 4", "metalConfig.metal4Enabled", true),
            toggle("metalHud", "Metal 性能面板", "metalConfig.metalHud", false),
            toggle("metalTrace", "Metal 跟踪", "metalConfig.metalTrace", false),
            toggle("dxrEnabled", "DirectX 光线追踪", "metalConfig.dxrEnabled", false),
            toggle("metalValidation", "Metal 验证", "metalConfig.metalValidation", false),
            toggle("dxvkAsync", "DXVK 异步编译", "dxvkConfig.dxvkAsync", true),
            choice("dxvkHud", "DXVK 性能面板", "dxvkConfig.dxvkHud", "off", [
                ("off", "关闭"), ("fps", "帧率"), ("partial", "简要"), ("full", "完整")
            ], tagged: true)
        ]),
        .init(id: "audio", title: "音频", fields: [
            choice(
                "audioDriver",
                "音频驱动",
                "audioConfig.audioDriver",
                "auto",
                [("auto", "自动"), ("coreaudio", "CoreAudio"), ("disabled", "关闭")]
            ),
            choice("audioLatencyPreset", "延迟预设", "audioConfig.latencyPreset", "defaultPreset", [
                ("defaultPreset", "默认"), ("lowLatency", "低延迟"), ("stable", "稳定")
            ]),
            choice(
                "outputDeviceMode",
                "输出设备",
                "audioConfig.outputDeviceMode",
                "followSystem",
                [("followSystem", "跟随系统"), ("pinned", "指定设备")]
            ),
            ConfigurationField(
                "pinnedDeviceName",
                "指定设备名称",
                path: "audioConfig.pinnedDeviceName",
                input: .text,
                defaultValue: .text(""),
                removesEmptyText: true
            )
        ]),
        .init(id: "discord", title: "Discord", fields: [
            toggle("discordPresence", "发布当前游戏状态", "discordConfig.presence", false),
            toggle("discordBridge", "转发游戏 Rich Presence", "discordConfig.bridge", false)
        ]),
        .init(id: "display", title: "显示", fields: [
            toggle("virtualDesktopEnabled", "虚拟桌面", "displayConfig.virtualDesktopEnabled", false),
            choice("resolutionPreset", "分辨率", "displayConfig.resolutionPreset", "r1920x1080", [
                ("r1280x720", "1280 × 720"), ("r1600x900", "1600 × 900"), ("r1920x1080", "1920 × 1080"),
                ("r2560x1440", "2560 × 1440"), ("r3840x2160", "3840 × 2160"), ("matchDisplay", "匹配显示器"), (
                    "custom",
                    "自定义"
                )
            ]),
            number("customResolutionWidth", "自定义宽度", "displayConfig.customWidth", 1_920, 640 ... 7_680),
            number("customResolutionHeight", "自定义高度", "displayConfig.customHeight", 1_080, 480 ... 4_320)
        ]),
        .init(id: "performance", title: "性能", fields: [
            toggle("shaderCacheEnabled", "着色器缓存", "performanceConfig.shaderCacheEnabled", true),
            toggle("disableAppNap", "防止 App Nap 限制性能", "performanceConfig.disableAppNap", false)
        ]),
        .init(id: "cleanup", title: "退出与清理", fields: [
            choice("clipboardPolicy", "剪贴板策略", "cleanupConfig.clipboardPolicy", "auto", [
                ("auto", "自动"), ("warn", "始终询问"), ("clear", "始终清理"), ("never", "保留内容")
            ]),
            number("clipboardThreshold", "剪贴板大小阈值（字节）", "cleanupConfig.clipboardThreshold", 10_240, 0 ... 16_777_216),
            choice("killOnQuit", "退出时结束进程", "cleanupConfig.killOnQuit", "inherit", [
                ("inherit", "跟随应用设置"), ("always", "始终结束"), ("never", "保留进程")
            ]),
            choice("closeWithProcessesPolicy", "关闭容器时的进程处理", "cleanupConfig.closeWithProcessesPolicy", "ask", [
                ("ask", "询问"), ("keepRunning", "继续运行"), ("stop", "结束进程")
            ])
        ])
    ]

    public static let locales: [(String, String)] = [
        ("", "自动"),
        ("ja_JP.UTF-8", "日本語"),
        ("zh_CN.UTF-8", "简体中文"),
        ("zh_TW.UTF-8", "繁體中文"),
        ("en_US.UTF-8", "English"),
        (
            "de_DE.UTF-8",
            "Deutsch"
        ),
        ("fr_FR.UTF-8", "Français"),
        ("es_ES.UTF-8", "Español"),
        (
            "it_IT.UTF-8",
            "Italiano"
        ),
        ("ko_KR.UTF-8", "한국어"),
        ("ru_RU.UTF-8", "Русский"),
        (
            "uk_UA.UTF-8",
            "Українська"
        ),
        ("th_TH.UTF-8", "ไทย")
    ]

    public static var fields: [ConfigurationField] {
        sections.flatMap(\.fields)
    }

    public static func toggle(_ id: String, _ title: String, _ path: String, _ value: Bool) -> ConfigurationField {
        .init(id, title, path: path, input: .toggle, defaultValue: .boolean(value))
    }

    public static func choice(
        _ id: String,
        _ title: String,
        _ path: String,
        _ value: String,
        _ options: [(String, String)],
        tagged: Bool = false
    ) -> ConfigurationField {
        .init(
            id,
            title,
            path: path,
            input: .choice(options.map { .init($0.0, $0.1) }),
            defaultValue: .text(value),
            taggedEnum: tagged
        )
    }

    public static func number(
        _ id: String,
        _ title: String,
        _ path: String,
        _ value: Int,
        _ range: ClosedRange<Int>
    ) -> ConfigurationField {
        .init(id, title, path: path, input: .number(range), defaultValue: .integer(value))
    }
}
