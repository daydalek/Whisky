//
//  MacOSApplicationServices+Winetricks.swift
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

// MARK: - Winetricks verbs

extension MacOSApplicationServices {
    func winetricksCall(
        _ method: String,
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) async throws -> JSONValue {
        switch method {
        case "winetricks.catalog":
            return try catalogPayload()
        case "winetricks.installed":
            let bottle = try winetricksBottle(params: params, workspace: workspace)
            let known = try knownVerbs()
            let result = await WinetricksService.loadInstalledVerbs(for: bottle)
            // `winetricks list-installed` writes its banner and warnings to
            // stdout too, so keep only names the catalog actually knows.
            return .object([
                "verbs": .array(result.verbs.intersection(known).sorted().map(JSONValue.string)),
                "fromCache": .bool(result.fromCache)
            ])
        case "winetricks.install":
            let bottle = try winetricksBottle(params: params, workspace: workspace)
            let verbs = try requestedVerbs(params)
            let known = try knownVerbs()
            if let unknown = verbs.first(where: { !known.contains($0) }) {
                throw BridgeFailure("invalid_params", "Unknown winetricks verb: \(unknown)")
            }
            return try jobs.start(name: "winetricks.install") { progress in
                try await self.install(verbs, for: bottle, known: known, emit: progress)
            }
        default:
            throw BridgeFailure("method_unavailable", "Native method is unavailable")
        }
    }

    private func winetricksBottle(
        params: [String: JSONValue],
        workspace: ApplicationWorkspace
    ) throws -> Bottle {
        let container = try workspace.resolve(params)
        guard let bottle = bottle(container) else {
            throw BridgeFailure("invalid_container", "Wine settings are unreadable")
        }
        return bottle
    }

    private func catalogPayload() throws -> JSONValue {
        let categories = try catalog()
        let encoded: [JSONValue] = categories.map { category in
            .object([
                "id": .string(category.category.rawValue),
                "verbs": .array(category.verbs.map { verb in
                    .object([
                        "name": .string(verb.name),
                        "description": .string(verb.description)
                    ])
                })
            ])
        }
        return .object(["categories": .array(encoded)])
    }

    private func catalog() throws -> [WinetricksCategory] {
        do {
            return try WinetricksService.catalog()
        } catch {
            throw BridgeFailure(
                "resource_missing",
                "The winetricks verb catalog is unavailable: \(error.localizedDescription)"
            )
        }
    }

    private func knownVerbs() throws -> Set<String> {
        let verbs = try catalog().flatMap(\.verbs).map(\.name)
        return Set(verbs)
    }

    /// Requested verbs are deduplicated in request order and bounded so one
    /// call cannot queue an unbounded installation.
    private func requestedVerbs(_ params: [String: JSONValue]) throws -> [String] {
        guard case let .array(values)? = params["verbs"] else {
            throw BridgeFailure("invalid_params", "Expected an array of winetricks verbs")
        }
        var seen = Set<String>()
        var verbs: [String] = []
        for value in values {
            guard let name = value.string,
                  !name.isEmpty,
                  name.utf8.count <= 128,
                  !name.contains(where: { $0.isWhitespace || $0 == "\0" })
            else {
                throw BridgeFailure("invalid_params", "Winetricks verbs must be nonempty names")
            }
            if seen.insert(name).inserted {
                verbs.append(name)
            }
        }
        guard !verbs.isEmpty, verbs.count <= 64 else {
            throw BridgeFailure("invalid_params", "Install between 1 and 64 winetricks verbs")
        }
        return verbs
    }

    /// Installs sequentially, streaming the latest line per verb. A nonzero
    /// exit or a failed stream is recorded per verb; later verbs still run,
    /// matching `WinetricksService.installVerbs`.
    private func install(
        _ verbs: [String],
        for bottle: Bottle,
        known: Set<String>,
        emit: @escaping BridgeJobStore.Progress
    ) async throws -> JSONValue {
        let total = verbs.count
        var succeeded: [String] = []
        var failed: [[String: JSONValue]] = []
        var exitCodes: [String: JSONValue] = [:]

        for (offset, verb) in verbs.enumerated() {
            try Task.checkCancellation()
            let outcome = try await installVerb(
                verb,
                offset: offset,
                total: total,
                for: bottle,
                emit: emit
            )
            if let exitCode = outcome.exitCode {
                exitCodes[verb] = .integer(Int64(exitCode))
            }
            if outcome.succeeded {
                succeeded.append(verb)
            } else {
                let reason = outcome.failure ?? "winetricks ended without reporting a result"
                failed.append([
                    "verb": .string(verb),
                    "reason": .string(reason)
                ])
            }
        }

        let current = await WinetricksService.loadInstalledVerbs(for: bottle)
        return .object([
            "verbs": .array(verbs.map(JSONValue.string)),
            "installed": .array(current.verbs.intersection(known).sorted().map(JSONValue.string)),
            "succeeded": .array(succeeded.map(JSONValue.string)),
            "failed": .array(failed.map(JSONValue.object)),
            "exitCodes": .object(exitCodes)
        ])
    }

    private struct VerbOutcome {
        var succeeded = false
        var failure: String?
        var exitCode: Int32?
    }

    private func installVerb(
        _ verb: String,
        offset: Int,
        total: Int,
        for bottle: Bottle,
        emit: @escaping BridgeJobStore.Progress
    ) async throws -> VerbOutcome {
        var outcome = VerbOutcome()
        for await event in WinetricksService.installVerb(verb, for: bottle) {
            try Task.checkCancellation()
            switch event {
            case .preparing:
                emit(progress(stage: "preparing", verb: verb, offset: offset, total: total))
            case let .output(line):
                emit(progress(
                    stage: "output",
                    verb: verb,
                    offset: offset,
                    total: total,
                    line: String(line.prefix(2_048))
                ))
            case let .completed(exitCode):
                outcome.exitCode = exitCode
                outcome.succeeded = exitCode == 0
                if exitCode != 0 {
                    outcome.failure = "winetricks exited with code \(exitCode)"
                }
                emit(progress(
                    stage: exitCode == 0 ? "installed" : "failed",
                    verb: verb,
                    offset: offset,
                    total: total,
                    exitCode: exitCode
                ))
            case let .failed(message):
                outcome.failure = message
                emit(progress(
                    stage: "failed",
                    verb: verb,
                    offset: offset,
                    total: total,
                    line: String(message.prefix(2_048))
                ))
            }
        }
        try Task.checkCancellation()
        return outcome
    }

    private func progress(
        stage: String,
        verb: String,
        offset: Int,
        total: Int,
        line: String? = nil,
        exitCode: Int32? = nil
    ) -> JSONValue {
        var payload: [String: JSONValue] = [
            "stage": .string(stage),
            "verb": .string(verb),
            "index": .integer(Int64(offset + 1)),
            "total": .integer(Int64(total))
        ]
        if let line {
            payload["line"] = .string(line)
        }
        if let exitCode {
            payload["exitCode"] = .integer(Int64(exitCode))
        }
        return .object(payload)
    }
}
