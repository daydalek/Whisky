//
//  Program+Extensions.swift
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

import Foundation
import os.log
import WhiskyCore

// MARK: - Crash Diagnosis Notification

public extension Notification.Name {
    /// Posted when a crash diagnosis is available after a Wine process exits abnormally.
    ///
    /// UserInfo keys:
    /// - `"diagnosis"`: ``CrashDiagnosis``
    /// - `"programPath"`: `String` (program URL path)
    /// - `"logFileURL"`: `URL`
    static let crashDiagnosisAvailable = Notification.Name("com.franke.Whisky.crashDiagnosisAvailable")
}

// MARK: - Crash Signature Detection

private let crashSignatures: Set<String> = [
    "Unhandled exception",
    "page fault",
    "device lost",
    "DEVICE_REMOVED",
    "DEVICE_HUNG",
    "Fatal error",
    // The head-of-log event behind "the game does nothing": a DLL the exe
    // imports could not be loaded.
    "import_dll"
]

public extension Program {
    func run(using interaction: any ProgramUserInteraction = MacOSProgramInteraction.shared) {
        if interaction.launchMode == .terminal {
            self.runInTerminal(using: interaction)
        } else {
            self.runInWine(using: interaction)
        }
    }

    /// Checks the clipboard before launching a Wine program, applying the bottle's policy.
    ///
    /// For `.needsUserDecision` results, presents a blocking alert asking the user
    /// to clear or keep the clipboard. For `.autoCleared` results, the clipboard has
    /// already been cleared by ``ClipboardManager``.
    ///
    /// - Returns: The clipboard check result after any user interaction.
    @MainActor
    func performClipboardCheck(
        clipboard: any ClipboardAccess = ClipboardManager.shared,
        interaction: any ProgramUserInteraction = MacOSProgramInteraction.shared
    ) -> ClipboardCheckResult {
        ClipboardPreflight.checkWithBlockingPrompt(
            clipboard: clipboard, launcher: bottle.settings.detectedLauncher,
            policy: bottle.settings.clipboardPolicy, threshold: bottle.settings.clipboardThreshold,
            decide: { interaction.decideClipboard($0) }
        )
    }

    /// Launches the program respecting user's modifier key preference and returns the result.
    /// - Parameter useTerminal: Whether to launch in Terminal mode (e.g., Shift was held).
    ///   **Important:** Capture `NSEvent.modifierFlags.contains(.shift)` synchronously at the call site,
    ///   before entering any async context, to avoid race conditions with key state.
    /// - Parameter onStarted: Called when the Wine subprocess starts or Terminal accepts the command.
    /// - Returns: LaunchResult indicating request delivery, terminal handoff, or failure.
    @MainActor
    func launchWithUserMode(
        useTerminal: Bool, onStarted: (@MainActor () -> Void)? = nil
    ) async -> LaunchResult {
        SettingsPersistence.shared.flush()
        // Check for terminal mode (typically shift-click)
        if useTerminal {
            do {
                try await openInTerminal()
                onStarted?()
                return .launchedInTerminal(programName: self.name)
            } catch {
                return .launchFailed(programName: self.name, errorDescription: error.localizedDescription)
            }
        }

        // Normal Wine launch with program-specific settings
        let arguments = settings.arguments.split { $0.isWhitespace }.map(String.init)

        do {
            let result = try await launch(args: arguments) { event in
                if case .started = event {
                    onStarted?()
                }
            }

            // Track the log file URL for diagnostics
            settings.lastLogFileURL = result.logFileURL

            // The exit code and the log this instant belong to the `start
            // /unix` stub, which returns seconds after launch, so this check
            // only sees failures that happen immediately. Anything later is
            // the watcher's job below.
            if result.exitCode != 0 || logContainsCrashSignatures(result.logFileURL) {
                triggerCrashClassification(
                    logFileURL: result.logFileURL,
                    exitCode: result.exitCode
                )
            } else {
                watchForLateCrash(logFileURL: result.logFileURL)
            }

            if result.exitCode != 0 {
                return .launchFailed(
                    programName: self.name,
                    errorDescription: "Wine launch request failed (\(result.exitCode))"
                )
            }
            return .launchedSuccessfully(programName: self.name)
        } catch {
            return .launchFailed(programName: self.name, errorDescription: error.localizedDescription)
        }
    }

    /// Watches for the session actually ending, then classifies its log.
    ///
    /// The bottle's wineserver going idle is the end-of-session signal, the
    /// same one Discord presence uses, and this run's log keeps growing until
    /// then because Wine's children inherit its file descriptor. Each launch
    /// has its own log file, so concurrent watchers never double-report one
    /// run. The probe is deliberately one interval late; the wineserver may
    /// not be up yet at the moment of launch.
    private func watchForLateCrash(logFileURL: URL) {
        let bottle = self.bottle
        Task {
            while true {
                try? await Task.sleep(for: .seconds(30))
                if logContainsCrashSignatures(logFileURL) {
                    triggerCrashClassification(logFileURL: logFileURL, exitCode: 1)
                    return
                }
                // Checked after the scan, so a crash written between the last
                // scan and the wineserver going down still gets one look.
                let running = await Wine.isWineserverRunning(for: bottle)
                if !running {
                    return
                }
            }
        }
    }

    /// Checks whether the log file contains crash signatures that warrant classification.
    ///
    /// Reads the tail of the log file (bounded to 64 KiB) and searches for known crash
    /// signatures. This is a lightweight heuristic before running the full classifier.
    private func logContainsCrashSignatures(_ logFileURL: URL) -> Bool {
        let maxBytes = 64 * 1_024

        guard let handle = try? FileHandle(forReadingFrom: logFileURL) else { return false }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return false }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)

        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return false }

        return crashSignatures.contains(where: { text.contains($0) })
    }

    /// Triggers background crash classification and posts a notification with the result.
    ///
    /// Classification runs on a background task (`.utility` priority) to avoid
    /// blocking the main thread. On completion, persists a ``DiagnosisHistoryEntry``
    /// and posts ``Notification.Name.crashDiagnosisAvailable``.
    private func triggerCrashClassification(logFileURL: URL, exitCode: Int32) {
        let programPath = self.url.path(percentEncoded: false)
        let programName = self.name
        let bottleName = self.bottle.settings.name
        let bottleURL = self.bottle.url
        let activePreset = self.settings.activeWineDebugPreset

        Task.detached(priority: .utility) {
            guard let diagnosis = await Wine.classifyLastRun(
                logFileURL: logFileURL,
                exitCode: exitCode
            ), !diagnosis.isEmpty
            else {
                return
            }

            // Build and persist a DiagnosisHistoryEntry
            let entry = DiagnosisHistoryEntry(
                timestamp: Date(),
                logFileRef: logFileURL.lastPathComponent,
                primaryCategory: diagnosis.primaryCategory ?? .otherUnknown,
                confidenceTier: diagnosis.primaryConfidence ?? .low,
                topSignatures: Array(diagnosis.matches.prefix(3).map(\.pattern.id)),
                remediationCardIds: diagnosis.applicableRemediationIds,
                wineDebugPreset: activePreset,
                bottleIdentifier: bottleName,
                programPath: programPath
            )

            let historyURL = bottleURL
                .appending(path: "Program Settings")
                .appending(path: programName)
                .appendingPathExtension("diagnosis-history.plist")
            var history = DiagnosisHistory.load(from: historyURL)
            history.append(entry)
            try? history.save(to: historyURL)

            // Stamp the program so the bottle's diagnostics buttons know there
            // is something to show; without it they never enable.
            await MainActor.run {
                self.settings.lastDiagnosisDate = entry.timestamp
                // Post notification for the UI to react
                NotificationCenter.default.post(
                    name: .crashDiagnosisAvailable,
                    object: nil,
                    userInfo: [
                        "diagnosis": diagnosis,
                        "programPath": programPath,
                        "logFileURL": logFileURL
                    ]
                )
            }
        }
    }

    /// Generates the terminal command to run this program via Wine.
    /// - Parameter args: Optional arguments string to use instead of saved settings.
    ///   If nil, uses `settings.arguments` from the program's saved configuration.
    /// - Returns: The full Wine command string ready for terminal execution.
    func generateTerminalCommand(args: String? = nil) -> String {
        Wine.generateRunCommand(
            at: self.url, bottle: bottle, args: args ?? settings.arguments, environment: generateEnvironment()
        )
    }

    /// Generates the terminal command to run this program via Wine with array-based arguments.
    /// - Parameter args: Array of arguments where each element is a separate argument.
    ///   Each argument is individually escaped to preserve argument boundaries.
    /// - Returns: The full Wine command string ready for terminal execution.
    func generateTerminalCommand(args: [String]) -> String {
        // Escape each argument individually to preserve argument boundaries
        // e.g., ["--name", "Player Name"] -> "--name Player\ Name" (two separate args)
        let escapedArgs = args.map(\.esc).joined(separator: " ")
        return Wine.generateRunCommand(
            at: self.url, bottle: bottle, args: escapedArgs, environment: generateEnvironment(), preEscaped: true
        )
    }

    @MainActor internal func showRunError(
        message: String, interaction: any ProgramUserInteraction = MacOSProgramInteraction.shared
    ) {
        interaction.showLaunchFailure(programName: url.lastPathComponent, message: message)
    }
}

extension Program {
    func runInWine(using interaction: any ProgramUserInteraction = MacOSProgramInteraction.shared) {
        let arguments = settings.arguments.split { $0.isWhitespace }.map(String.init)

        Task {
            do {
                let result = try await self.launch(args: arguments)

                // Track the log file URL
                settings.lastLogFileURL = result.logFileURL

                // Trigger classification on non-zero exit or crash signatures
                if result.exitCode != 0 || logContainsCrashSignatures(result.logFileURL) {
                    triggerCrashClassification(
                        logFileURL: result.logFileURL,
                        exitCode: result.exitCode
                    )
                }
            } catch {
                self.showRunError(message: error.localizedDescription, interaction: interaction)
            }
        }
    }
}
