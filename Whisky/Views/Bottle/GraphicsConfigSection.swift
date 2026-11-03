//
//  GraphicsConfigSection.swift
//  Whisky
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

import Metal
import SwiftUI
import WhiskyKit

struct GraphicsConfigSection: View {
    @ObservedObject var bottle: Bottle
    @AppStorage("graphicsAdvancedMode") var advancedMode: Bool = false
    @State var hasRunningProcesses: Bool = false

    private var resolvedBackend: GraphicsBackend {
        if bottle.settings.graphicsBackend == .recommended {
            return GraphicsBackendResolver.resolve()
        }
        return bottle.settings.graphicsBackend
    }

    var body: some View {
        Section("config.title.graphics") {
            // Simple/Advanced segmented control
            Picker("", selection: $advancedMode) {
                Text("config.graphics.simple").tag(false)
                Text("config.graphics.advanced").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Backend picker -- always visible
            BackendPickerView(
                selection: $bottle.settings.graphicsBackend,
                resolvedBackend: resolvedBackend,
                isBackendAvailable: { backend in
                    WhiskyWineInstaller.isBackendAvailable(backend)
                }
            )

            // Said once, after an update put a bottle the old Steam profile had
            // switched to DXVK back on Recommended (#276).
            if bottle.settings.launcherBackendResetNotice {
                launcherBackendResetNotice
            }

            // A bottle explicitly set to D3DMetal without its payload silently
            // degrades to WineD3D at launch — say so instead (issue #146).
            if bottle.settings.graphicsBackend == .d3dMetal,
               !WhiskyWineInstaller.isBackendAvailable(.d3dMetal) {
                d3dMetalMissingWarning
            }

            // Running process warning banner
            if hasRunningProcesses {
                runningProcessWarning
            }

            Picker(selection: $bottle.settings.gdiUpscaler) {
                ForEach(GDIUpscaler.allCases, id: \.self) { algorithm in
                    Text(verbatim: algorithm.title).tag(algorithm)
                }
            } label: {
                VStack(alignment: .leading) {
                    Text(verbatim: "GDI 超分算法")
                    Text(verbatim: "传统 GDI Galgame · Retina 超分；重启游戏后生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if bottle.settings.gdiUpscaler == .adaptive {
                Text(verbatim: "变化时使用 MetalFX；画面稳定 250 毫秒后使用后台 Real-CUGAN 结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if bottle.settings.gdiUpscaler == .realcugan {
                Text(verbatim: "Real-CUGAN 后台增强静止画面，自动选择可用的推理加速。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if bottle.settings.gdiUpscaler == .adaptiveRealesrgan {
                Text(verbatim: "变化时使用 MetalFX；画面稳定 250 毫秒后使用后台 AnimeVideo-v3 结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if bottle.settings.gdiUpscaler == .realesrgan {
                Text(verbatim: "AnimeVideo-v3 后台增强静止画面，自动选择可用的推理加速。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker(selection: $bottle.settings.gdiUpscalerCache) {
                ForEach(GDIUpscalerCacheMode.allCases, id: \.self) { mode in
                    Text(verbatim: mode.title).tag(mode)
                }
            } label: {
                VStack(alignment: .leading) {
                    Text(verbatim: "GDI 超分缓存")
                    Text(verbatim: "会话内容缓存；持久化默认每游戏 256 MiB 内存 + 4 GiB 磁盘，LRU。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: "仅 CoreML 神经后端（Real-CUGAN／AnimeVideo-v3）；重启游戏生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MetalFX rides on D3DMetal's DLSS bridge and Metal 4 is D3DMetal's
            // own command-encoding backend, so both are meaningless under any
            // other backend rather than merely inactive.
            if resolvedBackend == .d3dMetal {
                Toggle(isOn: $bottle.settings.metalFX) {
                    VStack(alignment: .leading) {
                        Text("config.metalFX")
                        Text("config.metalFX.info")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $bottle.settings.metal4Enabled) {
                    VStack(alignment: .leading) {
                        Text("config.metal4")
                        Text("config.metal4.info")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // Frame generation reaches MetalFX through the same DLSS bridge
                // as upscaling, so it has nothing to switch on without it.
                Toggle(isOn: $bottle.settings.frameGeneration) {
                    VStack(alignment: .leading) {
                        Text("config.frameGeneration")
                        Text("config.frameGeneration.info")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!bottle.settings.metalFX)
            }

            Toggle(isOn: $bottle.settings.shadowImportedHostMemory) {
                VStack(alignment: .leading) {
                    Text("32 位 Vulkan 内存导入兼容")
                    Text("适用于导入内存时黑屏或设备丢失的游戏；额外复制缓冲区会增加开销。重启 Steam 和游戏生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // The Sequoia compatibility toggle is gone: everything it set is a
            // platform-layer fix applied on every supported macOS, so the
            // switch changed nothing in either position.

            // "Advanced settings active" badge in Simple mode
            if !advancedMode, hasAdvancedSettingsConfigured {
                advancedSettingsBadge
            }

            // Per-program override note in Simple mode
            if !advancedMode, !programsWithGraphicsOverrides.isEmpty {
                programOverridesBadge
            }

            // Advanced mode content
            if advancedMode {
                // DXVK settings subsection
                DXVKSettingsView(
                    bottle: bottle,
                    resolvedBackend: resolvedBackend,
                    bottleURL: bottle.url
                )

                // Metal settings subsection (migrated from MetalConfigSection)
                VStack(alignment: .leading, spacing: 8) {
                    Text("config.metal.title")
                        .font(.headline)
                    Toggle(isOn: $bottle.settings.metalHud) {
                        Text("config.metalHud")
                    }
                    Toggle(isOn: $bottle.settings.metalTrace) {
                        Text("config.metalTrace")
                        Text("config.metalTrace.info")
                    }
                    if let device = MTLCreateSystemDefaultDevice() {
                        if device.supportsFamily(.apple9) {
                            Toggle(isOn: $bottle.settings.dxrEnabled) {
                                Text("config.dxr")
                                Text("config.dxr.info")
                            }
                        }
                    }
                    Toggle(isOn: $bottle.settings.metalValidation) {
                        Text("config.metalValidation")
                    }
                }

                // Per-program override info
                if !programsWithGraphicsOverrides.isEmpty {
                    programOverridesInfo
                }
            }
        }
        .animation(.default, value: advancedMode)
        .onChange(of: bottle.settings.graphicsBackend) {
            // Picking a backend answers the notice.
            if bottle.settings.launcherBackendResetNotice {
                bottle.settings.launcherBackendResetNotice = false
            }
        }
        .task {
            await checkRunningProcesses()
        }
    }
}
