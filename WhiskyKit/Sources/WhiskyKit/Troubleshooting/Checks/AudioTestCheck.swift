//
//  AudioTestCheck.swift
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

/// Wraps the Wine audio test probe for in-bottle audio playback verification.
///
/// Delegates to ``WineAudioTestProbe`` running the bundled
/// `WhiskyAudioTest.exe` inside the bottle. If the executable is absent from
/// the host app's bundle (e.g. when running from a different host), the probe
/// reports `.skipped`, which maps to `.unknown`.
public struct AudioTestCheck: TroubleshootingCheck {
    public let checkId = "audio.test_play"

    /// Closure type for executing an audio probe against a test executable URL.
    public typealias ProbeRunner = @Sendable (URL?) async -> AudioProbeResult

    private let probeRunner: ProbeRunner?

    public init(probeRunner: ProbeRunner? = nil) {
        self.probeRunner = probeRunner
    }

    /// Maps a probe outcome status to a normalized flow check outcome.
    public static func outcome(for status: ProbeStatus) -> CheckOutcome {
        switch status {
        case .passed: .pass
        case .warning: .fail
        case .error: .error
        case .skipped: .unknown
        }
    }

    /// Transforms an `AudioProbeResult` into a normalized `CheckResult`.
    public static func checkResult(from result: AudioProbeResult) -> CheckResult {
        let outcome = outcome(for: result.status)

        var evidence = ["status": result.status.rawValue]
        if !result.evidence.isEmpty {
            evidence["detail"] = result.evidence.joined(separator: "\n")
        }
        if !result.findings.isEmpty {
            evidence["findings"] = result.findings.map(\.description).joined(separator: "\n")
        }

        return CheckResult(
            outcome: outcome,
            evidence: evidence,
            summary: result.summary,
            confidence: outcome == .unknown ? .low : .high
        )
    }

    /// Instance helper to transform an `AudioProbeResult` into a normalized `CheckResult`.
    public func checkResult(from result: AudioProbeResult) -> CheckResult {
        Self.checkResult(from: result)
    }

    public func run(params: [String: String], context: CheckContext) async -> CheckResult {
        let exeURL = params["testExePath"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "WhiskyAudioTest", withExtension: "exe")

        let result: AudioProbeResult
        if let probeRunner {
            result = await probeRunner(exeURL)
        } else {
            let bottle = await Bottle(bottleUrl: context.bottleURL, cleanInvalidPins: false)
            let probe = WineAudioTestProbe(
                bottle: bottle,
                testExeURL: exeURL
            )
            result = await probe.run()
        }

        return checkResult(from: result)
    }
}
