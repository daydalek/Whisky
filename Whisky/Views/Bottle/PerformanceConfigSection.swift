//
//  PerformanceConfigSection.swift
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

import SwiftUI
import WhiskyKit

struct PerformanceConfigSection: View {
    @ObservedObject var bottle: Bottle
    @Binding var isExpanded: Bool

    @State private var isInstallingVCRedist = false
    @State private var vcRedistInstallFailed = false

    var body: some View {
        Section("config.title.performance", isExpanded: $isExpanded) {
            Toggle(isOn: $bottle.settings.shaderCacheEnabled) {
                VStack(alignment: .leading) {
                    Text("config.shaderCache")
                    Text("config.shaderCache.info")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Toggle(isOn: $bottle.settings.disableAppNap) {
                VStack(alignment: .leading) {
                    Text("config.disableAppNap")
                    Text("config.disableAppNap.info")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            // Install VC++ Runtime button (needed for Unity IL2CPP and other C++ games)
            if !bottle.settings.vcRedistInstalled {
                Button {
                    vcRedistInstallFailed = false
                    isInstallingVCRedist = true
                    Task {
                        var succeeded = false
                        for await progress in Winetricks.installVerb("vcrun2019", for: bottle) {
                            if case let .completed(exitCode) = progress {
                                succeeded = exitCode == 0
                            }
                        }
                        isInstallingVCRedist = false
                        if succeeded {
                            bottle.settings.vcRedistInstalled = true
                        } else {
                            vcRedistInstallFailed = true
                        }
                    }
                } label: {
                    HStack {
                        if isInstallingVCRedist {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "wrench.and.screwdriver")
                        }
                        VStack(alignment: .leading) {
                            Text("config.installVcRedist")
                            Text("config.installVcRedist.info")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if vcRedistInstallFailed {
                                Text("config.installVcRedist.failed")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
                .disabled(isInstallingVCRedist)
            } else {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("config.vcRedistInstalled")
                }
            }
        }
        .task(id: bottle.id) {
            isInstallingVCRedist = false
            vcRedistInstallFailed = false
            if !bottle.settings.vcRedistInstalled {
                bottle.synchronizeVCRedistStatus()
            }
        }
    }
}
