//
//  AudioTestProbeTests.swift
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

final class AudioTestProbeTests: XCTestCase {
    func testAudioTestCheckOutcomeMapping() {
        // Verify production mapping of ProbeStatus to CheckOutcome via AudioTestCheck
        let mapping: [(ProbeStatus, CheckOutcome)] = [
            (.passed, .pass),
            (.warning, .fail),
            (.error, .error),
            (.skipped, .unknown)
        ]

        for (status, expectedOutcome) in mapping {
            let outcome = AudioTestCheck.outcome(for: status)
            XCTAssertEqual(
                outcome,
                expectedOutcome,
                "AudioTestCheck.outcome(for: \(status)) must map to \(expectedOutcome)"
            )
        }
    }

    func testAudioTestCheckDirectEvaluationOfProbeResults() {
        let check = AudioTestCheck()

        // 1. Passed probe result -> .pass, high confidence, evidence preserved
        let passedProbe = AudioProbeResult(
            probeId: "wine-audio-test",
            status: .passed,
            summary: "Wine audio stack is functional (waveOut)",
            evidence: ["API: waveOut", "Sample rate: 44100 Hz", "Channels: 2"]
        )
        let passCheck = check.checkResult(from: passedProbe)
        XCTAssertEqual(passCheck.outcome, .pass)
        XCTAssertEqual(passCheck.confidence, .high)
        XCTAssertEqual(passCheck.summary, "Wine audio stack is functional (waveOut)")
        XCTAssertEqual(passCheck.evidence["status"], "passed")
        XCTAssertEqual(
            passCheck.evidence["detail"],
            "API: waveOut\nSample rate: 44100 Hz\nChannels: 2"
        )
        XCTAssertNil(passCheck.evidence["findings"])

        // 2. Warning probe result with findings -> .fail, high confidence
        let finding = AudioFinding(
            id: "wine-audio-test-error",
            description: "Wine audio test failed via waveOut",
            confidence: .high,
            evidence: "Error code: 32",
            suggestedAction: "Check Wine audio driver configuration",
            fixActionId: "reset-audio-state"
        )
        let warningProbe = AudioProbeResult(
            probeId: "wine-audio-test",
            status: .warning,
            summary: "Wine audio test failed: waveOut error 32",
            evidence: ["API: waveOut", "Error code: 32"],
            findings: [finding]
        )
        let warnCheck = check.checkResult(from: warningProbe)
        XCTAssertEqual(warnCheck.outcome, .fail)
        XCTAssertEqual(warnCheck.confidence, .high)
        XCTAssertEqual(warnCheck.evidence["status"], "warning")
        XCTAssertEqual(warnCheck.evidence["detail"], "API: waveOut\nError code: 32")
        XCTAssertEqual(warnCheck.evidence["findings"], finding.description)

        // 3. Error probe result -> .error, high confidence
        let errorProbe = AudioProbeResult(
            probeId: "wine-audio-test",
            status: .error,
            summary: "Failed to launch audio test",
            evidence: ["Error launching Wine process"]
        )
        let errCheck = check.checkResult(from: errorProbe)
        XCTAssertEqual(errCheck.outcome, .error)
        XCTAssertEqual(errCheck.confidence, .high)
        XCTAssertEqual(errCheck.evidence["status"], "error")
        XCTAssertEqual(errCheck.evidence["detail"], "Error launching Wine process")

        // 4. Skipped probe result -> .unknown, low confidence
        let skippedProbe = AudioProbeResult(
            probeId: "wine-audio-test",
            status: .skipped,
            summary: "Audio test helper not available",
            evidence: ["WhiskyAudioTest.exe not found in app bundle"]
        )
        let skipCheck = check.checkResult(from: skippedProbe)
        XCTAssertEqual(skipCheck.outcome, .unknown)
        XCTAssertEqual(skipCheck.confidence, .low)
        XCTAssertEqual(skipCheck.evidence["status"], "skipped")
        XCTAssertEqual(skipCheck.evidence["detail"], "WhiskyAudioTest.exe not found in app bundle")
    }

    private final class ProbeInvocationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _capturedURL: URL?

        var capturedURL: URL? {
            lock.lock()
            defer { lock.unlock() }
            return _capturedURL
        }

        func record(url: URL?) {
            lock.lock()
            defer { lock.unlock() }
            _capturedURL = url
        }
    }

    func testAudioTestCheckRunInvokesProbeRunnerWithParsedExeURL() async {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let preflight = PreflightData(
            bottleURL: tempDir,
            bottleName: "TestBottle",
            programName: nil,
            launcherType: nil,
            isWineserverRunning: false,
            processCount: 0,
            graphicsBackend: "dxmt"
        )
        let context = CheckContext(
            bottleURL: tempDir,
            bottleName: "TestBottle",
            programName: nil,
            preflight: preflight,
            session: TroubleshootingSession(bottleURL: tempDir)
        )

        let recorder = ProbeInvocationRecorder()
        let check = AudioTestCheck(probeRunner: { exeURL in
            recorder.record(url: exeURL)
            return AudioProbeResult(
                probeId: "wine-audio-test",
                status: .passed,
                summary: "Mock audio stack ok",
                evidence: ["Mock API: waveOut"]
            )
        })

        let result = await check.run(
            params: ["testExePath": "/custom/path/to/WhiskyAudioTest.exe"],
            context: context
        )

        XCTAssertEqual(recorder.capturedURL?.path, "/custom/path/to/WhiskyAudioTest.exe")
        XCTAssertEqual(result.outcome, .pass)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.summary, "Mock audio stack ok")
        XCTAssertEqual(result.evidence["status"], "passed")
        XCTAssertEqual(result.evidence["detail"], "Mock API: waveOut")
    }

    func testAudioTestCheckWithCustomExePathInParams() async {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let preflight = PreflightData(
            bottleURL: tempDir,
            bottleName: "TestBottle",
            programName: nil,
            launcherType: nil,
            isWineserverRunning: false,
            processCount: 0,
            graphicsBackend: "dxmt"
        )
        let context = CheckContext(
            bottleURL: tempDir,
            bottleName: "TestBottle",
            programName: nil,
            preflight: preflight,
            session: TroubleshootingSession(bottleURL: tempDir)
        )

        let check = AudioTestCheck()
        // When non-existent path is provided in params, probe handles gracefully
        let result = await check.run(params: ["testExePath": "/nonexistent/test.exe"], context: context)
        XCTAssertEqual(result.outcome, .unknown)
    }

    func testAudioTestResultJSONParsing() throws {
        let validJSON = """
        {"status":"ok","api":"waveOut","sampleRate":44100,"channels":2,"beep":false}
        """
        let data = try XCTUnwrap(validJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(AudioTestResult.self, from: data)

        XCTAssertEqual(decoded.status, "ok")
        XCTAssertEqual(decoded.api, "waveOut")
        XCTAssertEqual(decoded.sampleRate, 44100)
        XCTAssertEqual(decoded.channels, 2)
        XCTAssertEqual(decoded.beep, false)
    }

    func testAudioTestResultErrorJSONParsing() throws {
        let errorJSON = """
        {"status":"error","api":"waveOut","code":32}
        """
        let data = try XCTUnwrap(errorJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(AudioTestResult.self, from: data)

        XCTAssertEqual(decoded.status, "error")
        XCTAssertEqual(decoded.api, "waveOut")
        XCTAssertEqual(decoded.code, 32)
    }
}
