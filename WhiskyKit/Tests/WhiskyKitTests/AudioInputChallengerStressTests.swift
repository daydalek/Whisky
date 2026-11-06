// swiftlint:disable file_length
//
//  AudioInputChallengerStressTests.swift
//  WhiskyKitTests
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
import Testing
@testable import WhiskyKit

@Suite("Milestone 1 Empirical Challenger Stress Suite: Audio & Input")
// swiftlint:disable:next type_body_length
struct AudioInputChallengerStressTests {
    // MARK: - Helpers

    private func makeBottleDir() -> (url: URL, cleanup: () -> Void) {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return (tempDir, { try? FileManager.default.removeItem(at: tempDir) })
    }

    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Int = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }

        @discardableResult
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            _value += 1
            return _value
        }
    }

    private final class AsyncWineserverCallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [[String]] = []

        func record(args: [String]) {
            lock.lock()
            defer { lock.unlock() }
            calls.append(args)
        }

        var recordedCalls: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    // MARK: - Challenge 1: AudioTroubleshootingEngine Rapid Concurrent applyFix Re-entrancy

    @Test("AudioTroubleshootingEngine: 50 concurrent applyFix calls execute exactly once and serialize cleanly")
    @MainActor
    func rapidConcurrentApplyFixExecutesExactlyOnce() async {
        let engine = AudioTroubleshootingEngine(probes: [])
        let counter = AtomicCounter()

        engine.wizardState = .offeringFix(
            fixDescription: "Reset Wine audio state",
            actionId: "reset-audio-state"
        )

        engine.fixExecutor = { _ in
            counter.increment()
            // Simulate asynchronous I/O delay
            try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
        }

        // Fire 50 concurrent tasks attempting applyFix
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 50 {
                group.addTask { @MainActor in
                    engine.applyFix(actionId: "reset-audio-state")
                }
            }
        }

        // Wait for asynchronous fixExecutor to finish
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(counter.value == 1, "Executor must be invoked exactly once despite 50 concurrent calls")
        #expect(engine.attemptedFixes.count == 1, "Exactly one attempt must be recorded")
        #expect(engine.attemptedFixes.first?.actionId == "reset-audio-state")
        #expect(engine.wizardState == .askingDidItWork, "Final state must transition to askingDidItWork")
        #expect(engine.lastFixError == nil)
    }

    @Test("AudioTroubleshootingEngine: applyFix with different action IDs while in .applyingFix is rejected")
    @MainActor
    func applyFixRejectsDifferentActionIdsWhileApplying() async {
        let engine = AudioTroubleshootingEngine(probes: [])
        let executedActionIds = AtomicCounter()

        engine.wizardState = .offeringFix(
            fixDescription: "Original fix",
            actionId: "fix-A"
        )

        engine.fixExecutor = { _ in
            executedActionIds.increment()
            try? await Task.sleep(nanoseconds: 60_000_000)
        }

        // Start primary fix
        engine.applyFix(actionId: "fix-A")
        #expect(
            engine.wizardState == .applyingFix(fixDescription: "Original fix", actionId: "fix-A"),
            "State must transition synchronously to .applyingFix"
        )

        // Attempt competing fixes while fix-A is in flight
        for index in 0 ..< 10 {
            engine.applyFix(actionId: "competing-fix-\(index)")
        }

        // Wait up to 2 seconds for fix-A to complete execution and transition state under parallel test load
        let deadline = ContinuousClock.now + .seconds(2)
        while engine.wizardState != .askingDidItWork && ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(executedActionIds.value == 1, "Only fix-A should execute; competing calls must be dropped")
        #expect(engine.attemptedFixes.count == 1)
        #expect(engine.attemptedFixes.first?.actionId == "fix-A")
        #expect(engine.wizardState == .askingDidItWork)
    }

    @Test("AudioTroubleshootingEngine: Executor throwing error records lastFixError and preserves flow")
    @MainActor
    func applyFixExecutorErrorPreservesStateFlow() async {
        let engine = AudioTroubleshootingEngine(probes: [])
        struct SimulatedWineError: LocalizedError {
            var errorDescription: String? { "Wine server socket timeout" }
        }

        engine.wizardState = .offeringFix(
            fixDescription: "Set CoreAudio driver",
            actionId: "set-coreaudio-driver"
        )

        engine.fixExecutor = { _ in
            throw SimulatedWineError()
        }

        engine.applyFix(actionId: "set-coreaudio-driver")
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(engine.lastFixError == "Wine server socket timeout", "Localized error must be recorded")
        #expect(engine.wizardState == .askingDidItWork, "Must still advance to askingDidItWork to allow retry/feedback")
        #expect(engine.attemptedFixes.count == 1)
        #expect(engine.attemptedFixes.first?.actionId == "set-coreaudio-driver")
    }

    @Test("AudioTroubleshootingEngine: Bounded escalation enforces max 3 attempts across all symptoms")
    @MainActor
    func boundedEscalationEnforcesMaxThreeAttempts() async {
        for symptom in AudioSymptom.allCases {
            let engine = AudioTroubleshootingEngine(probes: [])
            engine.selectedSymptom = symptom

            // Step 1: Offer fix 1
            engine.offerNextFix()
            guard case let .offeringFix(_, actionId1) = engine.wizardState else {
                Issue.record("Expected offeringFix for symptom \(symptom), got \(engine.wizardState)")
                continue
            }
            engine.applyFix(actionId: actionId1)
            #expect(engine.attemptedFixes.count == 1)

            // Step 2: Offer fix 2
            engine.offerNextFix()
            guard case let .offeringFix(_, actionId2) = engine.wizardState else {
                Issue.record("Expected offeringFix for symptom \(symptom), got \(engine.wizardState)")
                continue
            }
            engine.applyFix(actionId: actionId2)
            #expect(engine.attemptedFixes.count == 2)

            // Step 3: Offer fix 3 (or escalation if symptom had fewer fixes)
            engine.offerNextFix()
            if case let .offeringFix(_, actionId3) = engine.wizardState {
                engine.applyFix(actionId: actionId3)
                #expect(engine.attemptedFixes.count == 3)

                // Step 4: Next fix attempt must strictly escalate
                engine.offerNextFix()
                #expect(engine.wizardState == .escalation, "4th attempt for \(symptom) must escalate")

                // Step 5: userReportsNotFixed at limit must also escalate
                engine.userReportsNotFixed()
                #expect(engine.wizardState == .escalation)
            } else {
                #expect(engine.wizardState == .escalation, "Exhausted fixes must escalate")
            }
        }
    }

    @Test("AudioTroubleshootingEngine: reset completely clears state machine")
    @MainActor
    func resetClearsAllStateMachineFields() {
        let engine = AudioTroubleshootingEngine(probes: [])
        engine.selectedSymptom = .crackling
        engine.probeResults = [
            AudioProbeResult(probeId: "p1", status: .warning, summary: "sum", evidence: ["e1"])
        ]
        engine.currentFindings = [
            AudioFinding(id: "f1", description: "desc", confidence: .high, evidence: "ev")
        ]
        engine.attemptedFixes = [
            TroubleshootingFixAttempt(actionId: "reset-audio-state")
        ]
        engine.wizardState = .askingDidItWork
        engine.isRunningProbe = true

        engine.reset()

        #expect(engine.wizardState == .pickSymptom)
        #expect(engine.selectedSymptom == nil)
        #expect(engine.probeResults.isEmpty)
        #expect(engine.currentFindings.isEmpty)
        #expect(engine.attemptedFixes.isEmpty)
        #expect(engine.isRunningProbe == false)
    }

    // MARK: - Challenge 2: WineAudioRegistry Two-Stage Shutdown & Error Resilience

    @Test("WineAudioRegistry: resetAudioState executes -k then -w even if reg delete fails")
    @MainActor
    func resetAudioStateResilientToRegDeleteFailure() async throws {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        let bottle = Bottle(bottleUrl: dir, inFlight: false, isAvailable: true)
        let recorder = AsyncWineserverCallRecorder()

        // Bind mock wineserver async runner
        await Wine.$wineserverAsyncRunner.withValue({ args, _ in
            recorder.record(args: args)
            return ""
        }) {
            // Even in an empty folder without Wine prefix or registry, resetAudioState must succeed
            try? await Wine.resetAudioState(bottle: bottle)
        }

        let calls = recorder.recordedCalls
        #expect(calls.count == 2, "Expected exactly two wineserver calls (-k and -w)")
        #expect(calls.first == ["-k"], "First call must be wineserver -k")
        #expect(calls.last == ["-w"], "Second call must be wineserver -w")

        // Factory default marker must be stamped
        let loadedMarker = AudioRegistryState.load(from: dir)
        #expect(loadedMarker == .factoryDefault, "Must stamp factoryDefault marker")
    }

    @Test("WineAudioRegistry: syncAudioRegistry detects divergence across all driver and latency settings")
    @MainActor
    func syncAudioRegistryDetectsAllDivergenceVariants() {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        let bottle = Bottle(bottleUrl: dir, inFlight: false, isAvailable: true)

        for driver in AudioDriverMode.allCases {
            for preset in AudioLatencyPreset.allCases {
                bottle.settings.audioDriver = driver
                bottle.settings.audioLatencyPreset = preset

                let desired = AudioRegistryState.desired(for: bottle)
                #expect(desired.driver == driver.rawValue)
                #expect(desired.helBuflen == preset.helBuflenValue)

                // Stamped factory default
                try? AudioRegistryState.factoryDefault.save(to: dir)

                let isDivergent = desired != AudioRegistryState.load(from: dir)
                let shouldDiverge = (driver != .auto || preset != .defaultPreset)
                #expect(isDivergent == shouldDiverge, "Divergence mismatch for driver=\(driver), preset=\(preset)")
            }
        }
    }

    // MARK: - Challenge 3: InputRegistryState Cache Idempotency & Marker Resilience

    @Test("InputRegistryState: 50 concurrent saves and loads maintain data integrity")
    func inputRegistryStateConcurrentSaveAndLoadStress() async throws {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 50 {
                group.addTask {
                    let state = InputRegistryState(commandActsAsControl: i % 2 == 0)
                    try? state.save(to: dir)
                    _ = InputRegistryState.load(from: dir)
                }
            }
        }

        // Final save
        let expectedState = InputRegistryState(commandActsAsControl: true)
        try expectedState.save(to: dir)
        let loaded = InputRegistryState.load(from: dir)
        #expect(loaded == expectedState)
    }

    @Test("InputRegistryState: Corrupted marker self-heals upon saving desired state")
    @MainActor
    func corruptedInputMarkerSelfHeals() throws {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        let markerURL = InputRegistryState.markerURL(in: dir)

        // Write corrupt garbage to marker
        try Data("GARBAGE_NOT_A_PLIST_BINARY_DATA_\(UUID().uuidString)".utf8).write(to: markerURL)
        #expect(InputRegistryState.load(from: dir) == nil, "Corrupted file must load as nil")

        let bottle = Bottle(bottleUrl: dir, inFlight: false, isAvailable: true, cleanInvalidPins: false)
        bottle.settings.commandActsAsControl = true

        let desired = InputRegistryState.desired(for: bottle)
        let applied = InputRegistryState.load(from: dir)
        #expect(desired != applied, "Desired must diverge from nil applied state")

        // Self-heal by writing desired
        try desired.save(to: dir)
        #expect(InputRegistryState.load(from: dir) == desired, "Marker must successfully self-heal")
    }

    @Test("InputRegistryState: Matching marker renders syncInputRegistry an idempotent no-op")
    @MainActor
    func syncInputRegistryIsStrictlyIdempotent() async throws {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        let bottle = Bottle(bottleUrl: dir, inFlight: false, isAvailable: true, cleanInvalidPins: false)
        bottle.settings.commandActsAsControl = true

        // Initial save
        try InputRegistryState.desired(for: bottle).save(to: dir)
        let markerURL = InputRegistryState.markerURL(in: dir)
        let initialData = try Data(contentsOf: markerURL)

        // Execute 20 sequential syncs
        for _ in 0 ..< 20 {
            await Wine.syncInputRegistry(bottle: bottle)
        }

        let afterData = try Data(contentsOf: markerURL)
        #expect(initialData == afterData, "Marker file content must remain completely untouched on matching state")
    }

    // MARK: - Challenge 4: BottleInputConfig Exhaustive Property Matrix & Migration

    @Test("BottleInputConfig: Exhaustive 16-state boolean permutations preserve bidirectional sync")
    func bottleInputConfigExhaustiveBooleanPermutations() {
        let bools = [false, true]
        for compat in bools {
            for hidapi in bools {
                for bg in bools {
                    for labels in bools {
                        var config = BottleInputConfig()
                        config.controllerCompatibilityMode = compat
                        config.disableHIDAPI = hidapi
                        config.allowBackgroundEvents = bg
                        config.useButtonLabels = labels

                        // Invariant: disableControllerMapping == useButtonLabels
                        #expect(config.disableControllerMapping == labels)

                        // Mutate alias
                        config.disableControllerMapping = !labels
                        #expect(config.useButtonLabels == !labels)

                        // Restore
                        config.useButtonLabels = labels
                        #expect(config.disableControllerMapping == labels)
                    }
                }
            }
        }
    }

    @Test("BottleInputConfig: Legacy plist migration truth table")
    func legacyMigrationTruthTable() throws {
        let cases: [(legacy: Bool?, modern: Bool?, expected: Bool)] = [
            (legacy: nil, modern: nil, expected: false),
            (legacy: false, modern: false, expected: false),
            (legacy: true, modern: false, expected: true),
            (legacy: false, modern: true, expected: true),
            (legacy: true, modern: true, expected: true),
            (legacy: true, modern: nil, expected: true),
            (legacy: false, modern: nil, expected: false)
        ]

        for (legacy, modern, expected) in cases {
            var dict: [String: Any] = [:]
            if let legacy { dict["disableControllerMapping"] = legacy }
            if let modern { dict["useButtonLabels"] = modern }

            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            let decoded = try PropertyListDecoder().decode(BottleInputConfig.self, from: data)

            #expect(
                decoded.useButtonLabels == expected,
                "Migration failed for legacy=\(String(describing: legacy)), modern=\(String(describing: modern))"
            )
            #expect(decoded.disableControllerMapping == expected)
        }
    }

    @Test("BottleInputConfig: Serialization strictly excludes legacy disableControllerMapping key")
    func serializationExcludesLegacyKey() throws {
        var config = BottleInputConfig()
        config.useButtonLabels = true
        config.controllerCompatibilityMode = true

        let data = try PropertyListEncoder().encode(config)
        let dict = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]

        #expect(dict?["useButtonLabels"] as? Bool == true)
        #expect(dict?["disableControllerMapping"] == nil, "disableControllerMapping must NEVER appear in serialized output")
    }

    @Test("BottleInputConfig: Environment variables generation matches SDL specifications")
    func environmentVariablesGenerationMatchesSDLSpecs() {
        var settings = BottleSettings()

        // When compat mode is OFF: all SDL vars must be nil
        settings.controllerCompatibilityMode = false
        settings.disableHIDAPI = true
        settings.allowBackgroundEvents = true
        settings.useButtonLabels = true

        var envOff: [String: String] = [:]
        settings.environmentVariables(wineEnv: &envOff)
        #expect(envOff["SDL_JOYSTICK_HIDAPI"] == nil)
        #expect(envOff["SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS"] == nil)
        #expect(envOff["SDL_GAMECONTROLLER_USE_BUTTON_LABELS"] == nil)

        // When compat mode is ON:
        settings.controllerCompatibilityMode = true

        // Sub-case 1: all on
        var envOn: [String: String] = [:]
        settings.environmentVariables(wineEnv: &envOn)
        #expect(envOn["SDL_JOYSTICK_HIDAPI"] == "0")
        #expect(envOn["SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS"] == "1")
        #expect(envOn["SDL_GAMECONTROLLER_USE_BUTTON_LABELS"] == "1")

        // Sub-case 2: all off
        settings.disableHIDAPI = false
        settings.allowBackgroundEvents = false
        settings.useButtonLabels = false

        var envDefault: [String: String] = [:]
        settings.environmentVariables(wineEnv: &envDefault)
        #expect(envDefault["SDL_JOYSTICK_HIDAPI"] == nil)
        #expect(envDefault["SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS"] == nil)
        #expect(envDefault["SDL_GAMECONTROLLER_USE_BUTTON_LABELS"] == "0")
    }

    // MARK: - Challenge 5: AudioTestCheck DI Outcome Mapping & Parameter Configurations

    @Test("AudioTestCheck: Outcome and confidence mapping for all ProbeStatus values")
    func audioTestCheckExhaustiveOutcomeMapping() {
        let expectations: [(ProbeStatus, CheckOutcome, ConfidenceTier)] = [
            (.passed, .pass, .high),
            (.warning, .fail, .high),
            (.error, .error, .high),
            (.skipped, .unknown, .low)
        ]

        for (status, expectedOutcome, expectedConfidence) in expectations {
            #expect(AudioTestCheck.outcome(for: status) == expectedOutcome)

            let probeResult = AudioProbeResult(
                probeId: "test-probe",
                status: status,
                summary: "Status is \(status)"
            )
            let checkResult = AudioTestCheck.checkResult(from: probeResult)
            #expect(checkResult.outcome == expectedOutcome)
            #expect(checkResult.confidence == expectedConfidence)
            #expect(checkResult.evidence["status"] == status.rawValue)
        }
    }

    @Test("AudioTestCheck: Evidence detail and findings multi-line joining and empty omissions")
    func audioTestCheckEvidenceFormatting() {
        // Test case 1: Multiple evidence lines and multiple findings
        let finding1 = AudioFinding(id: "f1", description: "First finding", confidence: .high, evidence: "e1")
        let finding2 = AudioFinding(id: "f2", description: "Second finding", confidence: .medium, evidence: "e2")
        let multiResult = AudioProbeResult(
            probeId: "wine-audio-test",
            status: .warning,
            summary: "Multiple issues",
            evidence: ["Line 1: waveOut failed", "Line 2: DirectSound buffer error"],
            findings: [finding1, finding2]
        )

        let checkResult = AudioTestCheck.checkResult(from: multiResult)
        #expect(checkResult.evidence["detail"] == "Line 1: waveOut failed\nLine 2: DirectSound buffer error")
        #expect(checkResult.evidence["findings"] == "First finding\nSecond finding")

        // Test case 2: Empty evidence and empty findings
        let emptyResult = AudioProbeResult(
            probeId: "wine-audio-test",
            status: .passed,
            summary: "All good",
            evidence: [],
            findings: []
        )
        let emptyCheck = AudioTestCheck.checkResult(from: emptyResult)
        #expect(emptyCheck.evidence["detail"] == nil, "detail key must be omitted when evidence is empty")
        #expect(emptyCheck.evidence["findings"] == nil, "findings key must be omitted when findings are empty")
    }

    private final class ThreadSafeBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T?

        init(_ value: T? = nil) {
            self._value = value
        }

        var value: T? {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }

        func set(_ newValue: T?) {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }

    @Test("AudioTestCheck: DI runner execution with custom testExePath parameter")
    func audioTestCheckDIRunnerWithCustomExePath() async {
        let (dir, cleanup) = makeBottleDir()
        defer { cleanup() }

        let preflight = PreflightData(
            bottleURL: dir,
            bottleName: "TestBottle",
            programName: nil,
            launcherType: nil,
            isWineserverRunning: false,
            processCount: 0,
            graphicsBackend: "dxmt"
        )
        let context = CheckContext(
            bottleURL: dir,
            bottleName: "TestBottle",
            programName: nil,
            preflight: preflight,
            session: TroubleshootingSession(bottleURL: dir)
        )

        let recordedURLBox = AtomicCounter()
        let receivedPathBox = ThreadSafeBox<String>()

        let check = AudioTestCheck(probeRunner: { exeURL in
            recordedURLBox.increment()
            receivedPathBox.set(exeURL?.path)
            return AudioProbeResult(
                probeId: "wine-audio-test",
                status: .passed,
                summary: "Probe executed custom exe",
                evidence: ["Custom exe path: \(exeURL?.path ?? "")"]
            )
        })

        let result = await check.run(
            params: ["testExePath": "/custom/tools/WhiskyAudioTest.exe"],
            context: context
        )

        #expect(recordedURLBox.value == 1)
        #expect(receivedPathBox.value == "/custom/tools/WhiskyAudioTest.exe")
        #expect(result.outcome == .pass)
        #expect(result.confidence == .high)
        #expect(result.summary == "Probe executed custom exe")
    }
}
// swiftlint:enable file_length
