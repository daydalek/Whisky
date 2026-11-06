//
//  AudioConfigSection.swift
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

import AppKit
import SwiftUI
import WhiskyKit

/// The main Audio section composing status, test buttons, settings, and findings.
///
/// Placed in ConfigView between Graphics and Performance, matching the
/// section-per-subsystem pattern established in Phase 4.
struct AudioConfigSection: View {
    @ObservedObject var bottle: Bottle

    @AppStorage("audioAdvancedMode") private var advancedMode: Bool = false
    @State private var monitor = AudioDeviceMonitor()

    @State private var audioStatus: AudioStatus = .unknown
    @State private var probeResults: [AudioProbeResult] = []
    @State private var lastTestedDate: Date?
    @State private var deviceHistory = AudioDeviceHistory()
    @State private var fixError: String? = nil
    @State private var applyingFixActionId: String? = nil

    /// Debounce timer for Bluetooth device change events.
    @State private var debounceTask: Task<Void, Never>?

    /// The wizard and its engine, created when it opens. Item-based so the
    /// sheet is built from the engine that presents it; with a flag plus a
    /// separate optional the content closure could run before the engine
    /// landed and show an empty sheet.
    @State private var wizardPresentation: AudioWizardPresentation?

    var body: some View {
        Section("Audio") {
            // 1. Status line
            AudioStatusView(
                audioStatus: audioStatus,
                lastTestedDate: lastTestedDate,
                defaultDeviceName: monitor.defaultOutputDevice()?.name,
                transportType: monitor.defaultOutputDevice()?.transportType,
                sampleRate: monitor.defaultOutputDevice()?.sampleRate,
                channelCount: monitor.defaultOutputDevice()?.outputChannelCount
            )

            // 2. Test buttons row
            AudioTestButtonsView(
                bottle: bottle,
                onStatusUpdate: { status in
                    audioStatus = status
                    lastTestedDate = Date()
                },
                onTestComplete: { results in
                    probeResults = results
                },
                testExeURL: Bundle.main.url(forResource: "WhiskyAudioTest", withExtension: "exe")
            )

            // 3. Simple/Advanced toggle
            Picker("", selection: $advancedMode) {
                Text("Simple").tag(false)
                Text("Advanced").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // 4. Settings
            AudioSettingsView(bottle: bottle, advancedMode: advancedMode)

            // 5. Badge if advanced overrides in Simple mode
            if !advancedMode, hasAdvancedAudioOverrides {
                advancedOverridesBadge
            }

            // 6. Findings (if any from last test)
            if !currentFindings.isEmpty {
                AudioFindingsView(
                    findings: currentFindings,
                    applyingActionId: applyingFixActionId,
                    onApplyFix: handleApplyFix
                )
            }

            // 7. Advanced device views
            if advancedMode {
                advancedDeviceViews
            }

            // 8. Troubleshooting link
            Button("Audio Troubleshooting\u{2026}") {
                openTroubleshootingWizard()
            }
        }
        .alert("Fix Application Failed", isPresented: Binding(
            get: { fixError != nil },
            set: { if !$0 { fixError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(fixError ?? "")
        }
        .animation(.default, value: advancedMode)
        .onAppear {
            startDeviceListening()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAudioTroubleshooting)) { _ in
            openTroubleshootingWizard()
        }
        .sheet(item: $wizardPresentation) { presentation in
            AudioTroubleshootingWizardView(
                engine: presentation.engine,
                onDismiss: {
                    wizardPresentation = nil
                },
                onOpenAdvanced: {
                    advancedMode = true
                }
            )
        }
    }
}

// MARK: - Computed Properties

extension AudioConfigSection {
    /// True if any advanced-only audio settings differ from defaults.
    private var hasAdvancedAudioOverrides: Bool {
        bottle.settings.audioDriver != .auto
            || bottle.settings.audioLatencyPreset != .defaultPreset
    }

    /// Aggregated findings from the most recent probe results.
    private var currentFindings: [AudioFinding] {
        probeResults.flatMap(\.findings)
    }
}

// MARK: - Advanced Overrides Badge

extension AudioConfigSection {
    private var advancedOverridesBadge: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text("Advanced audio settings active")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Show") {
                advancedMode = true
            }
            .font(.caption)
        }
    }
}

// MARK: - Advanced Device Views

extension AudioConfigSection {
    private var advancedDeviceViews: some View {
        Group {
            DisclosureGroup(String(localized: "audio.devices.title")) {
                AudioDeviceListView(devices: monitor.allOutputDevices())
            }

            DisclosureGroup(String(localized: "audio.history.title")) {
                AudioDeviceHistoryView(history: deviceHistory)
            }
        }
    }
}

// MARK: - Fix Application

extension AudioConfigSection {
    private func handleApplyFix(_ actionId: String) {
        applyingFixActionId = actionId
        Task { @MainActor in
            defer { applyingFixActionId = nil }
            do {
                try await performFix(actionId)
            } catch {
                fixError = error.localizedDescription
            }
        }
    }

    /// Performs the corrective action behind a fix action ID.
    ///
    /// Called from the findings list Fix buttons and supplied to the
    /// troubleshooting wizard as ``AudioTroubleshootingEngine/fixExecutor``.
    @MainActor
    private func performFix(_ actionId: String) async throws {
        switch actionId {
        case "check-audio-driver":
            // Ensure a usable driver: a disabled driver gets set back to Auto.
            if bottle.settings.audioDriver == .disabled {
                bottle.settings.audioDriver = .auto
            }
            try await Wine.setAudioDriver(bottle: bottle, driver: bottle.settings.audioDriver)
            try? AudioRegistryState.desired(for: bottle).save(to: bottle.url)
        case "set-coreaudio-driver":
            bottle.settings.audioDriver = .coreaudio
            try await Wine.setAudioDriver(bottle: bottle, driver: .coreaudio)
            try? AudioRegistryState.desired(for: bottle).save(to: bottle.url)
        case "set-stable-latency":
            bottle.settings.audioLatencyPreset = .stable
            try await Wine.setDirectSoundBuffer(
                bottle: bottle,
                helBuflen: AudioLatencyPreset.stable.helBuflenValue
            )
            try? AudioRegistryState.desired(for: bottle).save(to: bottle.url)
        case "check-dsound":
            // Re-applies the configured DirectSound buffer to the registry.
            await Wine.syncAudioRegistry(bottle: bottle)
        case "reset-audio-state":
            try await Wine.resetAudioState(bottle: bottle)
        case "check-system-settings":
            openSystemSoundSettings()
        default:
            break
        }
    }

    private func openSystemSoundSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Sound-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Troubleshooting Wizard

extension AudioConfigSection {
    private func openTroubleshootingWizard() {
        let probes: [any AudioProbe] = [
            CoreAudioDeviceProbe(monitor: monitor),
            WineRegistryAudioProbe(bottle: bottle),
            WineAudioTestProbe(
                bottle: bottle,
                testExeURL: Bundle.main.url(forResource: "WhiskyAudioTest", withExtension: "exe")
            )
        ]
        let engine = AudioTroubleshootingEngine(probes: probes)
        engine.fixExecutor = { actionId in
            try await performFix(actionId)
        }
        wizardPresentation = AudioWizardPresentation(engine: engine)
    }
}

// MARK: - Device Listening

extension AudioConfigSection {
    private func startDeviceListening() {
        // AudioDeviceMonitor dispatches on DispatchQueue.main.
        // The @Sendable closure annotation causes a compiler warning,
        // but mutation is main-thread-safe since the callback runs on main queue.
        monitor.startListening { event in
            // Record event in session history
            deviceHistory.append(event)

            // Debounce status update for Bluetooth connections (2-3 second delay)
            // to avoid spurious state changes during BT negotiation.
            debounceTask?.cancel()
            debounceTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                audioStatus = .unknown
            }
        }
    }
}

/// What the audio troubleshooting sheet is built from.
struct AudioWizardPresentation: Identifiable {
    let id = UUID()
    let engine: AudioTroubleshootingEngine
}
