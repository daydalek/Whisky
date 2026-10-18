//
//  SettingsView.swift
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

struct SettingsView: View {
    @AppStorage(NetworkSettings.offlineModeKey) private var offlineMode = false
    @AppStorage("killOnTerminate") var killOnTerminate = true
    @AppStorage("showMenuBarExtra") var showMenuBarExtra = false
    @AppStorage("checkWhiskyWineUpdates") var checkWhiskyWineUpdates = true
    @AppStorage("defaultBottleLocation") var defaultBottleLocation = BottleData.defaultBottleDir
    @AppStorage("libraryDetailBlurredBackground") private var blurredDetailBackground = true
    @AppStorage("librarySingleLineTitles") private var singleLineTitles = false
    @AppStorage("libraryCenterWideCoverText") private var centerCoverText = false
    @AppStorage("libraryMixedCoverLayout") private var mixedCoverLayout = false
    @AppStorage("libraryCoverFillStyle") private var coverFillStyle = "blurred"
    @AppStorage("libraryBlurredCoverFill") private var blurredCoverFill = true
    @AppStorage("preferredTerminal") var preferredTerminal = "terminal"
    @AppStorage(Telemetry.consentDefaultsKey) private var telemetryConsentRaw: String = Telemetry.ConsentState
        .undecided.rawValue

    /// Mirrors the setup-flow opt-in; writing records the explicit choice.
    private var telemetryOptIn: Binding<Bool> {
        Binding(
            get: { telemetryConsentRaw == Telemetry.ConsentState.granted.rawValue },
            set: { Telemetry.setConsent(granted: $0) }
        )
    }

    var body: some View {
        Form {
            Section("settings.general") {
                Toggle("settings.toggle.kill.on.terminate", isOn: $killOnTerminate)
                Toggle("settings.toggle.menubar", isOn: $showMenuBarExtra)
                    .help("settings.toggle.menubar.help")
                Picker("settings.terminal", selection: $preferredTerminal) {
                    // installedTerminals should always include Terminal.app on macOS,
                    // but fall back to showing just Terminal if somehow empty
                    let terminals = TerminalApp.installedTerminals
                    ForEach(terminals.isEmpty ? [.terminal] : terminals) { terminal in
                        Text(terminal.displayName).tag(terminal.rawValue)
                    }
                }
                ActionView(
                    text: "settings.path",
                    subtitle: defaultBottleLocation.prettyPath(),
                    actionName: "create.browse"
                ) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = BottleData.containerDir
                    panel.begin { result in
                        if result == .OK, let url = panel.urls.first {
                            defaultBottleLocation = url
                        }
                    }
                }
            }
            Section("settings.library") {
                Toggle("library.details.blurredBackground", isOn: $blurredDetailBackground)
                    .help("library.details.blurredBackground.help")
                Toggle("settings.library.mixedCoverLayout", isOn: $mixedCoverLayout)
                    .help("settings.library.mixedCoverLayout.help")
                Toggle("settings.library.singleLineTitles", isOn: $singleLineTitles)
                    .help("settings.library.singleLineTitles.help")
                Toggle("settings.library.centerWideCoverText", isOn: $centerCoverText)
                    .help("settings.library.centerWideCoverText.help")
                Toggle("settings.library.blurredCoverFill", isOn: $blurredCoverFill)
                    .help("settings.library.blurredCoverFill.help")
                Picker("settings.library.coverFillStyle", selection: $coverFillStyle) {
                    Text("settings.library.coverFillStyle.blurred").tag("blurred")
                    Text("settings.library.coverFillStyle.theme").tag("theme")
                }
                .disabled(!blurredCoverFill)
            }
            Section("settings.updates") {
                Toggle("settings.toggle.offlineMode", isOn: $offlineMode)
                    .help("settings.toggle.offlineMode.help")
                    .onChange(of: offlineMode) { _, _ in Telemetry.networkSettingsChanged() }
                Text("settings.toggle.offlineMode.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("settings.toggle.whiskywine.updates", isOn: $checkWhiskyWineUpdates)
                    .disabled(offlineMode)
            }
            GPTKSettingsSection()
            if Telemetry.isConfigured {
                Section("settings.privacy") {
                    Toggle("settings.toggle.telemetry", isOn: telemetryOptIn)
                        .help("setup.telemetry.consent.help")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: ViewWidth.medium)
    }
}

#Preview {
    SettingsView()
}
