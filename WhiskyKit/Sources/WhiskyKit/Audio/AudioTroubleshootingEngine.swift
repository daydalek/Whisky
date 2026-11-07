//
//  AudioTroubleshootingEngine.swift
//  WhiskyKit
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
import os.log

/// State machine driving the symptom-driven audio troubleshooting wizard.
///
/// The engine manages the wizard lifecycle: symptom selection, running
/// diagnostic probes, presenting findings, offering ordered fixes,
/// and tracking fix attempts with bounded escalation (max 3 attempts).
///
/// Probes are injected at init for testability. The fix recommendation
/// order is defined per symptom as a static mapping. This is hardcoded
/// initially but designed for future JSON migration without changing
/// the probe/result model.
@MainActor
public final class AudioTroubleshootingEngine: ObservableObject {
    // MARK: - Wizard State

    /// The current state of the troubleshooting wizard.
    public enum WizardState: Equatable {
        /// Initial state: the user picks a symptom.
        case pickSymptom

        /// Diagnostic probes are running.
        case runningProbes

        /// Probe results and findings are displayed.
        case showingFindings

        /// A specific fix is being offered to the user.
        case offeringFix(fixDescription: String, actionId: String)

        /// A fix is currently being applied.
        case applyingFix(fixDescription: String, actionId: String)

        /// Asking the user whether the last fix resolved the issue.
        case askingDidItWork

        /// The problem has been resolved.
        case resolved

        /// Maximum fix attempts reached; offer export/advanced settings.
        case escalation
    }

    // MARK: - Published State

    /// The current wizard state.
    @Published public var wizardState: WizardState = .pickSymptom

    /// The symptom selected by the user, if any.
    @Published public var selectedSymptom: AudioSymptom?

    /// Results from the most recent probe run.
    @Published public var probeResults: [AudioProbeResult] = []

    /// Aggregated findings from the most recent probe run.
    @Published public var currentFindings: [AudioFinding] = []

    /// All fix attempts made during this troubleshooting session.
    @Published public var attemptedFixes: [TroubleshootingFixAttempt] = []

    /// Whether probes are currently executing.
    @Published public var isRunningProbe: Bool = false

    /// Records the last execution error message, if any.
    @Published public var lastFixError: String?

    // MARK: - Private State

    /// Injected probes for testability.
    private let probes: [any AudioProbe]

    /// Maximum fix attempts before escalation.
    private let maxFixAttempts = 3

    /// Executes the corrective action behind a fix action ID.
    ///
    /// The app layer supplies this so ``applyFix`` performs the real
    /// mutation (registry write, driver switch, latency change, opening
    /// System Settings). When `nil`, ``applyFix`` only records the
    /// attempt, which is reserved for tests and demos.
    public var fixExecutor: ((String) async throws -> Void)?

    private let logger = Logger(
        subsystem: "com.daydalek.Maltoria",
        category: "AudioTroubleshootingEngine"
    )

    // MARK: - Fix Recommendation Data

    /// Ordered fix action IDs per symptom. The engine tries these in order,
    /// skipping any already attempted.
    private static let fixOrderBySymptom: [AudioSymptom: [String]] = [
        .noSound: ["check-audio-driver", "set-coreaudio-driver", "reset-audio-state"],
        .crackling: ["set-stable-latency", "set-coreaudio-driver", "reset-audio-state"],
        .stutter: ["set-stable-latency", "check-audio-driver", "reset-audio-state"],
        .wrongDevice: ["reset-audio-state", "check-system-settings"],
        .menusOnly: ["set-coreaudio-driver", "check-dsound", "reset-audio-state"]
    ]

    /// Human-readable descriptions for each fix action.
    private static let fixDescriptions: [String: String] = [
        "check-audio-driver":
            "Verify the Wine audio driver is set to Auto or CoreAudio",
        "set-coreaudio-driver":
            "Set the Wine audio driver to CoreAudio explicitly",
        "reset-audio-state":
            "Clear Wine cached audio device mappings and restart",
        "set-stable-latency":
            "Increase the audio buffer size for more stable playback",
        "check-system-settings":
            "Check macOS Sound settings and ensure the correct output device is selected",
        "check-dsound":
            "Verify DirectSound configuration and buffer settings"
    ]

    // MARK: - Init

    /// Creates a new troubleshooting engine with the given diagnostic probes.
    ///
    /// - Parameter probes: The diagnostic probes to run. The app layer
    ///   constructs these with the appropriate monitor, bottle, and test
    ///   exe URL references.
    public init(probes: [any AudioProbe]) {
        self.probes = probes
    }

    // MARK: - Public Methods

    /// Selects a symptom and begins the diagnostic process.
    ///
    /// Sets the selected symptom, transitions to `.runningProbes`,
    /// and kicks off probe execution.
    public func selectSymptom(_ symptom: AudioSymptom) {
        selectedSymptom = symptom
        wizardState = .runningProbes
        Task {
            await runProbes()
        }
    }

    /// Runs all registered probes, collects results and findings,
    /// and transitions to `.showingFindings`.
    public func runProbes() async {
        isRunningProbe = true
        var results: [AudioProbeResult] = []
        var findings: [AudioFinding] = []

        for probe in probes {
            logger.info("Running probe: \(probe.displayName)")
            let result = await probe.run()
            results.append(result)
            findings.append(contentsOf: result.findings)
        }

        probeResults = results
        currentFindings = findings
        isRunningProbe = false
        wizardState = .showingFindings
    }

    /// Examines current findings and attempted fixes to offer the next
    /// untried fix for the selected symptom.
    ///
    /// If all fixes have been tried or the attempt count exceeds
    /// ``maxFixAttempts``, transitions to `.escalation`.
    public func offerNextFix() {
        guard let symptom = selectedSymptom else {
            wizardState = .escalation
            return
        }

        if attemptedFixes.count >= maxFixAttempts {
            wizardState = .escalation
            return
        }

        let fixOrder = Self.fixOrderBySymptom[symptom] ?? []
        let attemptedIds = Set(attemptedFixes.map(\.actionId))

        guard let nextActionId = fixOrder.first(where: { !attemptedIds.contains($0) }) else {
            wizardState = .escalation
            return
        }

        let description = Self.fixDescriptions[nextActionId]
            ?? "Apply fix: \(nextActionId)"

        wizardState = .offeringFix(fixDescription: description, actionId: nextActionId)
    }

    /// Performs a fix, records the attempt, and transitions to `.askingDidItWork`.
    ///
    /// When ``fixExecutor`` is set, the corrective action runs first and the
    /// attempt is only recorded once it completes. Without an executor the
    /// attempt is recorded immediately, preserving the old stub behavior for
    /// tests and demos.
    ///
    /// - Parameters:
    ///   - actionId: The fix action identifier.
    ///   - beforeValue: The setting value before the fix, if applicable.
    ///   - afterValue: The setting value after the fix, if applicable.
    public func applyFix(actionId: String, beforeValue: String? = nil, afterValue: String? = nil) {
        guard case let .offeringFix(desc, _) = wizardState else {
            return
        }
        let attempt = TroubleshootingFixAttempt(
            actionId: actionId,
            beforeValue: beforeValue,
            afterValue: afterValue
        )
        wizardState = .applyingFix(fixDescription: desc, actionId: actionId)
        lastFixError = nil

        guard let fixExecutor else {
            attemptedFixes.append(attempt)
            wizardState = .askingDidItWork
            return
        }
        Task {
            do {
                try await fixExecutor(actionId)
                attemptedFixes.append(attempt)
                wizardState = .askingDidItWork
            } catch {
                logger.error("Fix '\(actionId)' failed: \(error.localizedDescription)")
                lastFixError = error.localizedDescription
                attemptedFixes.append(attempt)
                wizardState = .askingDidItWork
            }
        }
    }

    /// Called when the user reports the problem is fixed.
    public func userReportsFixed() {
        wizardState = .resolved
    }

    /// Called when the user reports the fix did not help.
    ///
    /// If the attempt count has reached the maximum, transitions to
    /// `.escalation`. Otherwise, re-runs probes and offers the next fix.
    public func userReportsNotFixed() {
        if attemptedFixes.count >= maxFixAttempts {
            wizardState = .escalation
            return
        }

        wizardState = .runningProbes
        Task {
            await runProbes()
            offerNextFix()
        }
    }

    /// Resets all state and returns to the symptom picker.
    public func reset() {
        selectedSymptom = nil
        probeResults = []
        currentFindings = []
        attemptedFixes = []
        isRunningProbe = false
        wizardState = .pickSymptom
    }
}
