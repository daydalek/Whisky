//
//  MacOSApplicationServices+Diagnostics.swift
//  WhiskyNativeBridge
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
import WhiskyApplication
import WhiskyBridgeProtocol
import WhiskyCore
import WhiskyKit

// MARK: - Stability diagnostics and the audio stack probe

extension MacOSApplicationServices {
    /// `bottle.diagnostics`, `bottle.exportDiagnostics` and `audio.test` are
    /// jobs: reading logs and starting Wine can outlast one request timeout.
    func diagnosticsCall(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        let container = try workspace.resolve(params)
        guard let bottle = bottle(container) else {
            throw BridgeFailure("invalid_container", "Wine settings are unreadable")
        }
        switch method {
        case "bottle.diagnostics":
            return try jobs.start(name: "bottle.diagnostics") { _ in
                let report = await StabilityDiagnostics.generateDiagnosticReport(for: bottle)
                return .object(["report": .string(report)])
            }
        case "bottle.exportDiagnostics":
            let destination = try params.path("destination")
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw BridgeFailure("destination_exists", "A file already exists at the destination")
            }
            return try jobs.start(name: "bottle.exportDiagnostics") { _ in
                let report = await StabilityDiagnostics.generateDiagnosticReport(for: bottle)
                try report.write(to: destination, atomically: true, encoding: .utf8)
                return .object(["path": .string(destination.path)])
            }
        case "bottle.checks":
            return try jobs.start(name: "bottle.checks") { progress in
                progress(.object(["stage": .string("preflight")]))
                let preflight = await PreflightCollector.collect(bottle: bottle, program: nil)
                let context = CheckContext.create(
                    bottle: bottle,
                    program: nil,
                    preflight: preflight,
                    session: TroubleshootingSession()
                )
                let registry = CheckRegistry()
                let checks: [(String, [String: String])] = [
                    ("crash.log_classify", [:]),
                    ("launcher.type_check", [:]),
                    ("process.running_check", [:]),
                    ("audio.device_check", [:]),
                    ("audio.driver_check", ["expected": "auto"]),
                    ("game.config_available", [:]),
                    ("diagnostics.can_enhance", [:])
                ]
                var results: [JSONValue] = []
                for (index, (checkID, params)) in checks.enumerated() {
                    try Task.checkCancellation()
                    progress(.object([
                        "stage": .string("checking"),
                        "check": .string(checkID),
                        "completed": .integer(Int64(index)),
                        "total": .integer(Int64(checks.count))
                    ]))
                    let result = await registry.run(
                        checkId: checkID,
                        params: params,
                        context: context
                    )
                    results.append(.object([
                        "checkID": .string(checkID),
                        "outcome": .string(result.outcome.rawValue),
                        "summary": .string(result.summary),
                        "evidence": .object(result.evidence.mapValues(JSONValue.string))
                    ]))
                }
                return .object(["checks": .array(results)])
            }
        case "audio.test":
            let beep = params["beep"] == nil ? true : try params.flag("beep")
            guard let executable = Self.audioTestExecutable() else {
                throw BridgeFailure("runtime_missing", "WhiskyAudioTest.exe is not bundled")
            }
            return try jobs.start(name: "audio.test") { _ in
                let probe = WineAudioTestProbe(bottle: bottle, testExeURL: executable)
                let result = beep ? await probe.runWithBeep() : await probe.run()
                return .object([
                    "status": .string(result.status.rawValue),
                    "summary": .string(result.summary),
                    "evidence": .array(result.evidence.map(JSONValue.string)),
                    "findings": .array(result.findings.map { finding in
                        .object([
                            "id": .string(finding.id),
                            "description": .string(finding.description),
                            "suggestedAction": finding.suggestedAction.map(JSONValue.string) ?? .null
                        ])
                    })
                ])
            }
        default:
            throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
    }

    /// The helper is unbundled in development and lives in Contents/Resources
    /// in a packaged app; look beside it before falling back to the bundle.
    private static func audioTestExecutable() -> URL? {
        var candidates: [URL] = []
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent("WhiskyAudioTest.exe"))
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(executable.deletingLastPathComponent().appendingPathComponent("WhiskyAudioTest.exe"))
        candidates.append(
            Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent("Resources/WhiskyAudioTest.exe")
        )
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
