//
//  EffectiveBackend.swift
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
import WhiskyCore

/// The graphics backend a launch actually resolves to, once overrides,
/// launcher steering and payload availability apply.
///
/// `Wine.prepareProgramLaunch` makes this decision per launch. The launch
/// reply names the backend before the launch resolves anything, so frontends
/// predict it here with the same inputs the driver hands the launch — and the
/// launch itself resolves through
/// ``resolve(_:steeredLauncher:recommendedBackend:d3dMetalDeployed:)``, so
/// the two cannot drift.
@MainActor
public enum EffectiveBackend {
    /// The backend one launch resolves to, with the fallback it took
    /// recorded: a UI naming only `backend` tells the truth, and
    /// `unavailable` explains why it differs from what was configured.
    public struct Resolution {
        /// The backend the launch actually runs on.
        public let backend: GraphicsBackend
        /// The backend resolution picked before availability applied,
        /// present when it cannot run: D3DMetal without its GPTK payload
        /// silently runs wined3d (see
        /// ``WhiskyWineInstaller/isBackendAvailable(_:)``), so `backend` is
        /// the fallback rather than the resolution. `nil` when `backend` is
        /// exactly what steering and the resolver produced — recommended
        /// resolution and launcher steering are not fallbacks.
        public let unavailable: GraphicsBackend?

        public init(backend: GraphicsBackend, unavailable: GraphicsBackend? = nil) {
            self.backend = backend
            self.unavailable = unavailable
        }
    }

    /// The concrete backend a merged `choice` resolves to for one launch.
    ///
    /// `.recommended` resolves through ``GraphicsBackendResolver``, steered to
    /// DXVK when this launch itself is a launcher client; an explicit choice
    /// stands as configured. One fallback the launch performs only implicitly
    /// is made explicit: D3DMetal without its GPTK payload deployed silently
    /// runs on wined3d, so the effective answer — and any UI naming the
    /// backend — is wined3d.
    ///
    /// - Parameters:
    ///   - choice: The choice the launch merges: a program's override, a
    ///     launch plan's, or the bottle's setting, whichever applies.
    ///   - steeredLauncher: The launcher this launch itself is. `nil` for a
    ///     game and for `steam.exe -applaunch`, whose plan belongs to its
    ///     descendants — those resolve the way the bottle's games do.
    ///   - recommendedBackend: What `.recommended` resolves to for the
    ///     runtime's games. Defaults to the resolver's answer.
    ///   - d3dMetalDeployed: Whether the runtime's builtin D3D path is
    ///     D3DMetal's. Defaults to the deployment check launches share.
    ///   - featureGate: The engine feature policy the launch resolves under.
    ///     Defaults to all-permitted — the managed runtime's behavior; the
    ///     bottle-taking APIs substitute the selected engine's gate, so a
    ///     prediction never names a backend the engine policy drops.
    public static func resolve(
        _ choice: GraphicsBackend,
        steeredLauncher: LauncherType? = nil,
        recommendedBackend: GraphicsBackend = GraphicsBackendResolver.resolve(),
        d3dMetalDeployed: Bool = GPTKImporter.isDeployed(),
        featureGate: @escaping (WineEngineFeature) -> Bool = { _ in true }
    ) -> GraphicsBackend {
        resolveDetailed(
            choice, steeredLauncher: steeredLauncher,
            recommendedBackend: recommendedBackend, d3dMetalDeployed: d3dMetalDeployed,
            featureGate: featureGate
        ).backend
    }

    /// ``resolve(_:steeredLauncher:recommendedBackend:d3dMetalDeployed:featureGate:)``
    /// with the fallback it took spelled out in a ``Resolution``.
    public static func resolveDetailed(
        _ choice: GraphicsBackend,
        steeredLauncher: LauncherType? = nil,
        recommendedBackend: GraphicsBackend = GraphicsBackendResolver.resolve(),
        d3dMetalDeployed: Bool = GPTKImporter.isDeployed(),
        featureGate: @escaping (WineEngineFeature) -> Bool = { _ in true }
    ) -> Resolution {
        let resolved = if choice == .recommended {
            steeredLauncher.map { GraphicsBackendResolver.resolve(for: $0) } ?? recommendedBackend
        } else {
            choice
        }
        let gated = Wine.gatedBackend(resolved, gate: featureGate)
        if gated == .d3dMetal, !d3dMetalDeployed {
            return Resolution(backend: .wined3d, unavailable: .d3dMetal)
        }
        return Resolution(
            backend: gated, unavailable: gated != resolved ? resolved : nil
        )
    }

    /// The resolution a direct program launch produces: the executable's own
    /// overrides — found in the bottle's program list or persisted on disk,
    /// which is what a launch reads when the scan has not reached it — then
    /// the bottle's, steered when the executable is a launcher client. These
    /// are the inputs ``WineLibraryRuntimeDriver`` hands
    /// `Wine.prepareProgramLaunch`.
    public static func forProgram(
        executable: URL,
        bottle: Bottle,
        recommendedBackend: GraphicsBackend? = nil,
        d3dMetalDeployed: Bool? = nil,
        featureGate: ((WineEngineFeature) -> Bool)? = nil
    ) -> Resolution {
        // The same policy `prepareProgramLaunch` resolves under for this
        // bottle: recommended resolution, payload availability and the
        // feature gate all come from the selected engine unless a test
        // injects fixtures.
        let policy = Wine.backendPolicy(for: bottle)
        let overrides = bottle.programs.first { $0.url == executable }?.settings.overrides
            ?? Program.persistedOverrides(for: executable, bottleURL: bottle.url)
        return resolveDetailed(
            overrides?.graphicsBackend ?? bottle.settings.graphicsBackend,
            steeredLauncher: LauncherType.detect(from: executable),
            recommendedBackend: recommendedBackend ?? policy.recommendedBackend,
            d3dMetalDeployed: d3dMetalDeployed ?? policy.d3dMetalDeployed,
            featureGate: featureGate ?? policy.featureGate
        )
    }

    /// The resolution a Steam app launch produces: the game's launch plan —
    /// the selected program's or install's overrides merged under the GameDB
    /// variant — resolved unsteered, because `-applaunch` hands the plan to
    /// the game's own processes rather than the client it goes through.
    ///
    /// `nil` when the launch plan cannot be built; the launch fails for the
    /// same reason.
    public static func forSteamGame(
        appID: Int,
        bottle: Bottle,
        recommendedBackend: GraphicsBackend? = nil,
        d3dMetalDeployed: Bool? = nil,
        featureGate: ((WineEngineFeature) -> Bool)? = nil
    ) -> Resolution? {
        let policy = Wine.backendPolicy(for: bottle)
        guard let inputs = try? SteamLauncher.launchInputs(appId: appID, bottle: bottle, installURL: nil)
        else { return nil }
        return resolveDetailed(
            inputs.plan.overrides.graphicsBackend ?? bottle.settings.graphicsBackend,
            recommendedBackend: recommendedBackend ?? policy.recommendedBackend,
            d3dMetalDeployed: d3dMetalDeployed ?? policy.d3dMetalDeployed,
            featureGate: featureGate ?? policy.featureGate
        )
    }

    /// The resolution `runtime.launch` produces for `entry`, predicting the
    /// executable a folder entry's launch will run the way the driver does.
    ///
    /// `nil` when the launch cannot name a target — a folder entry with no
    /// recorded executable fails at launch for the same reason.
    public static func forLaunch(
        of entry: LibraryEntry,
        executable: URL?,
        bottle: Bottle,
        recommendedBackend: GraphicsBackend? = nil,
        d3dMetalDeployed: Bool? = nil,
        featureGate: ((WineEngineFeature) -> Bool)? = nil
    ) -> Resolution? {
        switch entry.launch {
        case let .steam(appID):
            return forSteamGame(
                appID: appID, bottle: bottle,
                recommendedBackend: recommendedBackend, d3dMetalDeployed: d3dMetalDeployed,
                featureGate: featureGate
            )
        case let .program(target):
            let resolved = executable ?? {
                guard entry.source == .folder else { return target }
                // A folder entry names its folder: the launch runs the
                // executable the user recorded for it, the way the driver's
                // `resolvedExecutable` finds it.
                return try? FolderGameLibrary.load(bottleURL: bottle.url)
                    .executable(for: target, bottleURL: bottle.url)
                    .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            }()
            return resolved.map {
                forProgram(
                    executable: $0, bottle: bottle,
                    recommendedBackend: recommendedBackend, d3dMetalDeployed: d3dMetalDeployed,
                    featureGate: featureGate
                )
            }
        }
    }
}
