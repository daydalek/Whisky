//
//  AudioTroubleshootingEngineTests.swift
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
import XCTest
@testable import WhiskyKit

@MainActor
final class AudioTroubleshootingEngineTests: XCTestCase {
    struct MockProbe: AudioProbe {
        let id: String
        let displayName: String
        let statusToReturn: ProbeStatus
        let findingsToReturn: [AudioFinding]

        func run() async -> AudioProbeResult {
            AudioProbeResult(
                probeId: id,
                status: statusToReturn,
                summary: "Mock summary",
                findings: findingsToReturn
            )
        }
    }

    func testInitialStateIsPickSymptom() {
        let engine = AudioTroubleshootingEngine(probes: [])
        XCTAssertEqual(engine.wizardState, .pickSymptom)
        XCTAssertNil(engine.selectedSymptom)
        XCTAssertTrue(engine.attemptedFixes.isEmpty)
    }

    func testApplyFixTransitionsToApplyingFixState() async {
        let engine = AudioTroubleshootingEngine(probes: [])
        let expectation = expectation(description: "Executor called")

        engine.wizardState = .offeringFix(
            fixDescription: "Clear Wine cached audio device mappings and restart",
            actionId: "reset-audio-state"
        )

        var observedStateDuringExecution: AudioTroubleshootingEngine.WizardState?

        engine.fixExecutor = { actionId in
            observedStateDuringExecution = engine.wizardState
            expectation.fulfill()
        }

        engine.applyFix(actionId: "reset-audio-state")

        await fulfillment(of: [expectation], timeout: 2.0)

        // Verify that during execution, state was .applyingFix
        XCTAssertEqual(
            observedStateDuringExecution,
            .applyingFix(fixDescription: "Clear Wine cached audio device mappings and restart", actionId: "reset-audio-state")
        )

        // After task completes, state transitions to askingDidItWork
        XCTAssertEqual(engine.wizardState, .askingDidItWork)
        XCTAssertEqual(engine.attemptedFixes.count, 1)
        XCTAssertEqual(engine.attemptedFixes.first?.actionId, "reset-audio-state")
    }

    func testReentrancyPreventionWhileApplyingFix() async {
        let engine = AudioTroubleshootingEngine(probes: [])
        var executionCount = 0

        engine.wizardState = .offeringFix(
            fixDescription: "Clear Wine cached audio device mappings and restart",
            actionId: "reset-audio-state"
        )

        engine.fixExecutor = { _ in
            executionCount += 1
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        // First click
        engine.applyFix(actionId: "reset-audio-state")
        XCTAssertEqual(
            engine.wizardState,
            .applyingFix(fixDescription: "Clear Wine cached audio device mappings and restart", actionId: "reset-audio-state")
        )

        // Immediate duplicate click while still applying
        engine.applyFix(actionId: "reset-audio-state")

        // Wait for execution to finish
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(executionCount, 1, "Duplicate applyFix invocation must be ignored while in .applyingFix")
    }

    func testExecutorErrorIsRecordedAndDoesNotCrash() async {
        let engine = AudioTroubleshootingEngine(probes: [])
        struct DummyError: Error, LocalizedError {
            var errorDescription: String? { "Wine server communication failure" }
        }

        engine.wizardState = .offeringFix(
            fixDescription: "Clear Wine cached audio device mappings and restart",
            actionId: "reset-audio-state"
        )

        engine.fixExecutor = { _ in
            throw DummyError()
        }

        engine.applyFix(actionId: "reset-audio-state")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(engine.lastFixError, "Wine server communication failure")
        XCTAssertEqual(engine.wizardState, .askingDidItWork)
        XCTAssertEqual(engine.attemptedFixes.count, 1)
    }
}
