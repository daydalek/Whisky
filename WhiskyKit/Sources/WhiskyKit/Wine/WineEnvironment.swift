// swiftlint:disable function_body_length
//
//  WineEnvironment.swift
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

// swiftlint:disable file_length

private let envLogger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "WineEnvironment")

// swiftlint:disable cyclomatic_complexity
extension Wine {
    /// Construct an environment merging the bottle values with the given values
    /// using EnvironmentBuilder with 8-layer resolution.
    ///
    /// Each Wine process launch resolves through this method, which populates
    /// an ``EnvironmentBuilder`` with base, platform, bottleManaged, launcherManaged,
    /// bottleUser, programUser, featureRuntime, and callsiteOverride layers.
    /// WINEDLLOVERRIDES is composed per-DLL via ``DLLOverrideResolver``.
    ///
    /// Invalid environment variable keys (those not matching `[A-Za-z_][A-Za-z0-9_]*`)
    /// are filtered out with a debug log message, as macOS silently ignores them.
    ///
    /// - Parameters:
    ///   - bottle: The bottle whose settings configure the environment.
    ///   - environment: Caller-provided environment variables (typically from `Program.generateEnvironment()`).
    ///   - programOverrides: Optional per-program setting overrides. `nil` fields inherit from bottle.
    ///   - recommendedBackend: What `.recommended` resolves to, for the bottle and
    ///     for a program set to it. Defaults to `nil`, which asks
    ///     ``GraphicsBackendResolver`` about the installed runtime.
    ///   - builtinD3D12IsD3DMetal: Whether the runtime's builtin `d3d12` is
    ///     D3DMetal's, which decides whether the DXVK and DXMT presets turn it
    ///     off. Defaults to whether the GPTK payload is deployed, read once so
    ///     every layer of this launch agrees. Ignored for external engines,
    ///     whose own payload answers the question.
    ///   - engine: The engine to bind paths and feature policy to. Defaults to
    ///     resolving ``BottleSettings/wineEngineID``; callers that already
    ///     resolved for this operation pass their snapshot so one launch never
    ///     mixes two engines.
    /// - Returns: The fully resolved environment dictionary for passing to a Wine process.
    /// - Throws: ``WineEngineError`` when the bottle's selected engine is not
    ///   registered or no longer usable. Callers must surface it — there is
    ///   no managed fallback.
    @MainActor
    public static func constructWineEnvironment(
        for bottle: Bottle,
        environment: [String: String] = [:],
        targetURL: URL? = nil,
        programOverrides: ProgramOverrides? = nil,
        programSettings: ProgramSettings? = nil,
        gameProfileEnvironment: [String: String] = [:],
        recommendedBackend: GraphicsBackend? = nil,
        builtinD3D12IsD3DMetal: Bool = GPTKImporter.isDeployed(),
        engine explicitEngine: WineEngine? = nil
    ) throws -> [String: String] {
        let engine = try explicitEngine ?? Self.engine(for: bottle)
        // The pinned approval snapshot when an operation is in flight:
        // mid-launch approvals or revocations never change the policy the
        // launch was prepared under.
        let approvals = featureOverrides(for: bottle)
        let gate = featureGate(for: engine, overrides: approvals)
        // `.recommended` resolves under the selected engine's policy, so a
        // bottle on an external engine is not promised a backend the engine
        // cannot deliver.
        let recommendedBackend = recommendedBackend ?? Self.recommendedBackend(
            for: engine, overrides: approvals
        )
        let builtinD3D12IsD3DMetal = engine.isManaged
            ? builtinD3D12IsD3DMetal
            : engine.payloadRoot(.d3dMetal) != nil
        var builder = EnvironmentBuilder()
        var dllResolver = DLLOverrideResolver(managed: [], bottleCustom: [], programCustom: [])

        // Layer 1: Base -- WINEPREFIX, default WINEDEBUG, GST_DEBUG
        builder.set("WINEPREFIX", bottle.url.path, layer: .base)
        // Wine's environment is constructed independently of the host environment.
        // Set an explicit root so the native helper never falls back to /tmp.
        let cacheRoot = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/com.isaacmarovitz.Whisky/GDIUpscaler")
        builder.set("WINE_GDI_CACHE_DIRECTORY", cacheRoot.path, layer: .base)
        builder.set("WINEDEBUG", "fixme-all", layer: .base)
        builder.set("GST_DEBUG", "1", layer: .base)
        builder.set("WINELOADER", engine.wineBinary.path, layer: .base)
        builder.set("WINESERVER", engine.wineserverBinary.path, layer: .base)
        // The engine's own lib holds whatever it ships — the managed tree its
        // codecs and MoltenVK, an external tree its own; nothing is borrowed.
        builder.set(
            "DYLD_FALLBACK_LIBRARY_PATH", "\(engine.libraryURL.path):/usr/lib", layer: .base
        )

        // Layer 2: Platform -- macOS compatibility fixes
        // Apply fixes from the MacOSCompatibilityFixes registry with reason strings.
        // applyMacOSCompatibilityFixes() is still called for the conditional WINEESYNC logic.
        // External engines only take the application-side fixes (CEF/Steam
        // runtime): the rest exist for the managed build's own quirks and
        // must not leak into an engine they were never verified against.
        for fix in MacOSCompatibilityFixes.activeFixes()
            where engine.isManaged || fix.category == .sandbox || fix.category == .compatibility {
            builder.set(fix.key, fix.value, layer: .platform, reason: fix.reason)
        }
        // Forward host timezone so games that read system time/date behave correctly.
        // macOS does not export TZ by default; without this, Wine sees UTC.
        if ProcessInfo.processInfo.environment["TZ"] == nil {
            builder.set(
                "TZ", TimeZone.current.identifier, layer: .platform,
                reason: "Host timezone forwarding"
            )
        }
        // Handle conditional WINEESYNC (depends on existing environment state).
        // On an external engine esync is a feature like any other: without a
        // confirmation the fallback is not injected either.
        var platformConditional: [String: String] = [:]
        applyMacOSCompatibilityFixes(to: &platformConditional)
        if let esync = platformConditional["WINEESYNC"], gate(.esync) {
            builder.set(
                "WINEESYNC", esync, layer: .platform,
                reason: "Fallback sync mode for macOS 15.4+ (esync/msync not otherwise set)"
            )
        }

        // Layer 3: Bottle managed -- settings-derived env vars (DXVK, sync, Metal, perf)
        let managedOverrides = bottle.settings.populateBottleManagedLayer(
            builder: &builder, resolvedBackend: recommendedBackend,
            builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal,
            featureGate: gate
        )
        dllResolver.managed.append(contentsOf: managedOverrides)

        // External engines: neutralize translation-DLL residue. A prefix can
        // carry native DXVK/DXMT DLLs an earlier approval deployed or the
        // user dropped in — under a backend that does not use them (the
        // WineD3D fallback an unapproved selection resolves to, say) Wine's
        // default "native, builtin" order would still load them. The entries
        // the resolved backend legitimately enabled stay native; the rest get
        // builtin overrides. Nothing is deleted — the files stay the user's.
        // Translation DLLs the effective external backend does not use. The
        // managed-layer entries below keep the composed string right for the
        // common case; `enforceExternalEnginePolicy` applies the same set
        // again after every custom layer and the raw WINEDLLOVERRIDES vote.
        var neutralizedDLLNames: Set<String> = []
        if !engine.isManaged {
            let enabledNatives = Set(
                managedOverrides
                    .filter { $0.entry.mode != .builtin }
                    .map { $0.entry.dllName.lowercased() }
            )
            let neutralized = translationDLLResetEntries(
                builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal
            ).filter { !enabledNatives.contains($0.dllName.lowercased()) }
            neutralizedDLLNames = Set(neutralized.map { $0.dllName.lowercased() })
            dllResolver.managed.append(
                contentsOf: neutralized.map { (entry: $0, source: .enginePolicy) }
            )
        }

        if let targetURL {
            builder.set(
                "WINE_GDI_CACHE_GAME",
                targetURL.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false),
                layer: .bottleManaged
            )
        }

        // DXVK reads its config from DXVK_CONFIG_FILE or the process working
        // directory, and the working directory of a launch is never the bottle
        // root the config editor writes to, so without this line the file is
        // decoration. Z: maps the host filesystem and DXVK's PE build accepts
        // forward slashes.
        let dxvkConf = bottle.url.appending(path: "dxvk.conf")
        if FileManager.default.fileExists(atPath: dxvkConf.path(percentEncoded: false)) {
            builder.set(
                "DXVK_CONFIG_FILE", "Z:\(dxvkConf.path(percentEncoded: false))",
                layer: .bottleManaged, reason: "dxvk.conf present in the bottle"
            )
        }

        // Layer 4: Launcher managed -- launcher compatibility overrides
        let launcherOverrides = bottle.settings.populateLauncherManagedLayer(
            builder: &builder, targetURL: targetURL,
            builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal,
            featureGate: gate,
            compatibilityFixesAllowed: engine.isManaged
        )
        dllResolver.managed.append(contentsOf: launcherOverrides)

        // Input compatibility (bottleManaged layer -- input settings are bottle-managed toggles)
        bottle.settings.populateInputCompatibilityLayer(builder: &builder)

        // Layer 5: Game profile -- GameDB variant environment for this launch.
        // Beats bottle/launcher defaults, loses to anything the user set.
        for (key, value) in gameProfileEnvironment {
            if isValidEnvKey(key) {
                builder.set(key, value, layer: .gameProfile, reason: "GameDB profile")
            } else {
                envLogger.debug("Skipping invalid game profile key '\(key)' in constructWineEnvironment")
            }
        }

        // Layer 6: Bottle user -- bottle-level custom env vars persisted in
        // Metadata.plist by the bridge `environment.set` handler.
        for (key, value) in bottle.settings.userEnvironment {
            if isValidEnvKey(key) {
                builder.set(key, value, layer: .bottleUser)
            } else {
                envLogger.debug("Skipping invalid bottle environment key '\(key)' in constructWineEnvironment")
            }
        }

        // A persistent profile follows the executable, including fullscreen resizes.
        if let targetURL {
            let profile = Program.upscaleRegionProfileURL(for: targetURL, bottleURL: bottle.url)
            try? FileManager.default.createDirectory(
                at: profile.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            builder.set("WINE_GDI_UPSCALER_EXCLUDE_PROFILE", profile.path(percentEncoded: false), layer: .bottleManaged)
        }

        // Layer 7: Program user (caller-provided environment dict, typically from Program.generateEnvironment())
        if !environment.isEmpty {
            for (key, value) in environment {
                if isValidEnvKey(key) {
                    builder.set(key, value, layer: .programUser)
                } else {
                    envLogger.debug("Skipping invalid environment key '\(key)' in constructWineEnvironment")
                }
            }
        }

        // Apply per-program overrides to the programUser layer
        if let overrides = programOverrides {
            applyProgramOverrides(
                overrides,
                frameGeneration: bottle.settings.frameGeneration && gate(.frameGeneration),
                recommendedBackend: recommendedBackend,
                builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal,
                featureGate: gate,
                builder: &builder,
                dllResolver: &dllResolver
            )
        }

        // Layer 8: featureRuntime -- diagnostic WINEDEBUG preset override
        if let preset = programSettings?.activeWineDebugPreset, preset != .normal {
            builder.set("WINEDEBUG", preset.winedebugValue, layer: .featureRuntime)
        }

        // Layer 9: callsiteOverride is left empty (populated by direct callers)

        // Collect bottle custom DLL overrides for the resolver
        dllResolver.bottleCustom = bottle.settings.dllOverrides

        // Resolve the builder and capture provenance for launch logging
        let (resolved, provenance) = builder.resolve()
        var result = resolved

        // Compose WINEDLLOVERRIDES from DLLOverrideResolver (outside the builder)
        // A raw `WINEDLLOVERRIDES` the user/profile/program layers voted is
        // kept for the external merge below — the resolver output otherwise
        // hides it entirely.
        let rawWINEDLLOVERRIDES = result["WINEDLLOVERRIDES"]
        let (overrideString, _) = dllResolver.resolve()
        if !overrideString.isEmpty {
            result["WINEDLLOVERRIDES"] = overrideString
        }

        // Last pass, after EVERY layer — game profiles, user variables and
        // program callsites all had their say above: an external engine's
        // path identity and feature policy cannot be voted back out. The
        // managed runtime keeps its legacy override freedom untouched.
        if !engine.isManaged {
            enforceExternalEnginePolicy(
                context: ExternalPolicyContext(
                    engine: engine,
                    bottle: bottle,
                    gate: gate,
                    neutralizedDLLNames: neutralizedDLLNames,
                    rawWINEDLLOVERRIDES: rawWINEDLLOVERRIDES
                ),
                environment: &result
            )
        }

        // Launch logging: safe summary of bottle, active layers, and whitelisted keys
        logLaunchSummary(bottleName: bottle.settings.name, provenance: provenance, environment: result)

        return result
    }

    /// Why an app-owned environment variable may exist on an external engine.
    private enum ExternalEnvPolicy {
        /// Permitted only while the feature's gate passes.
        case feature(WineEngineFeature)
        /// Permitted only while every listed gate passes.
        case allOf([WineEngineFeature])
        /// `WINEESYNC`: an approved esync sets it, and an approved msync
        /// needs it advertised — D3DM reads ESYNC to pick behavior, so the
        /// msync path has to lie that esync is on. Either approval carries it.
        case esyncOrMsyncDependency
    }

    /// Which engine feature owns an app-set environment variable, if any.
    /// Variables not listed here are user customizations and pass through.
    private static func externalEnvPolicy(for key: String) -> ExternalEnvPolicy? {
        if key == "WINEESYNC" {
            return .esyncOrMsyncDependency
        }
        if key == "WINEMSYNC" {
            return .feature(.msync)
        }
        if key == "DXVK_ASYNC" {
            return .allOf([.dxvk, .dxvkAsync])
        }
        if key.hasPrefix("DXVK_") {
            return .feature(.dxvk)
        }
        if key == "WINED3DMETAL" {
            return .feature(.d3dMetal)
        }
        if key == "CX_ACTIVE_GRAPHICS_BACKEND" {
            return .feature(.frameGeneration)
        }
        if key.hasPrefix("D3DM_") {
            return switch key {
            case "D3DM_ENABLE_METALFX": .feature(.metalFX)
            // D3DMetal-specific fields gated on the generic .metal feature:
            // they only mean anything when the D3DMetal backend itself is
            // approved too.
            case "D3DM_MTL4", "D3DM_SUPPORT_DXR": .allOf([.d3dMetal, .metal])
            default: .feature(.d3dMetal)
            }
        }
        if key == "WINE_METALFX" {
            return .feature(.gdiUpscaling)
        }
        if key == "WINE_GDI_NEURAL_MODEL" || key == "WINE_GDI_ADAPTIVE_FAST" {
            return .allOf([.gdiUpscaling, .gdiCoreML])
        }
        if key.hasPrefix("WINE_GDI") {
            return .feature(.gdiUpscaling)
        }
        if key.hasPrefix("ROSETTA") {
            return .feature(.avx)
        }
        if key.hasPrefix("MVK_CONFIG") {
            return .feature(.shadowImportedHostMemory)
        }
        switch key {
        case "MTL_HUD_ENABLED", "MTL_DEBUG_LAYER", "METAL_CAPTURE_ENABLED":
            return .feature(.metal)
        default:
            return nil
        }
    }

    /// The runtime identity and override state enforced on external engines.
    private struct ExternalPolicyContext {
        let engine: WineEngine
        let bottle: Bottle
        let gate: (WineEngineFeature) -> Bool
        let neutralizedDLLNames: Set<String>
        let rawWINEDLLOVERRIDES: String?
    }

    /// Reasserts engine ownership over the finished environment.
    ///
    /// Layers above this function are advisory: a game profile, a user
    /// variable or a program's own env could repoint `WINELOADER` at another
    /// runtime or re-add a feature variable the engine never approved. For an
    /// external engine the prefix, loader, server and library path are
    /// restored to the resolved descriptor, every feature-owned variable
    /// whose gate fails is stripped — including the always-emitted GDI
    /// cache/profile variables and `DXVK_CONFIG_FILE` — and translation DLLs
    /// the effective backend does not use are clamped to builtin after the
    /// last custom layer. Unrelated custom variables pass through untouched.
    private static func enforceExternalEnginePolicy(
        context: ExternalPolicyContext,
        environment: inout [String: String]
    ) {
        // Identity the operation was prepared for — a user- or profile-layer
        // `WINEPREFIX=other` would launch a DIFFERENT prefix while every
        // lease, lock and probe held this one.
        environment["WINEPREFIX"] = context.bottle.url.path(percentEncoded: false)
        environment["WINELOADER"] = context.engine.wineBinary.path(percentEncoded: false)
        environment["WINESERVER"] = context.engine.wineserverBinary.path(percentEncoded: false)
        environment["DYLD_FALLBACK_LIBRARY_PATH"] =
            "\(context.engine.libraryURL.path(percentEncoded: false)):/usr/lib"
        // The engine's bin leads PATH when a layer set one, so aliases and
        // child tools resolve to this runtime and not whichever runtime a
        // stray PATH names first — a present-but-later entry is promoted,
        // not trusted.
        if let path = environment["PATH"] {
            let bin = context.engine.binFolder.path(percentEncoded: false)
            let rest = path.split(separator: ":").map(String.init).filter { $0 != bin }
            environment["PATH"] = ([bin] + rest).joined(separator: ":")
        }

        // Higher-precedence library search paths can splice a second
        // runtime's objects into this engine's processes; none of Whisky's
        // own layers ever sets them, so a value here is always a user vote.
        environment.removeValue(forKey: "WINEDLLPATH")
        environment.removeValue(forKey: "DYLD_LIBRARY_PATH")
        environment.removeValue(forKey: "DYLD_FRAMEWORK_PATH")
        environment.removeValue(forKey: "DYLD_FALLBACK_FRAMEWORK_PATH")
        environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")

        for key in environment.keys {
            guard let policy = externalEnvPolicy(for: key) else { continue }
            let permitted = switch policy {
            case let .feature(feature): context.gate(feature)
            case let .allOf(features): features.allSatisfy(context.gate)
            case .esyncOrMsyncDependency: context.gate(.esync) || context.gate(.msync)
            }
            if !permitted {
                environment.removeValue(forKey: key)
            }
        }

        // The DLL clamp runs after EVERY custom layer — a bottle or program
        // custom entry, or a raw `WINEDLLOVERRIDES=d3d11=n` environment vote,
        // otherwise puts an unapproved translation layer's native DLLs back
        // on a prefix that still carries them. Composed entries and the raw
        // vote merge (raw wins per name, matching its last-layer position),
        // the neutralized names are forced to builtin, and the user's
        // unrelated entries keep their raw mode strings.
        var parsed = parseDLLOverrides(environment["WINEDLLOVERRIDES"] ?? "")
        if let rawWINEDLLOVERRIDES = context.rawWINEDLLOVERRIDES {
            for (name, mode) in parseDLLOverrides(rawWINEDLLOVERRIDES) {
                parsed[name] = mode
            }
        }
        if !context.neutralizedDLLNames.isEmpty {
            parsed = parsed.filter { !context.neutralizedDLLNames.contains($0.key.lowercased()) }
            for name in context.neutralizedDLLNames {
                parsed[name] = DLLOverrideMode.builtin.rawValue
            }
        }
        let clamped = parsed
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
        if clamped.isEmpty {
            environment.removeValue(forKey: "WINEDLLOVERRIDES")
        } else {
            environment["WINEDLLOVERRIDES"] = clamped
        }
    }

    /// Builtin-mode reset entries for every DLL any translation layer may have
    /// overridden — the union of the DXVK and DXMT presets. Used when a
    /// program-level backend override selects a builtin-backed path
    /// (D3DMetal/wined3d) and must neutralize whatever the bottle enabled.
    ///
    /// Built from the same runtime state as the presets it undoes, so `d3d12`
    /// is only reset where a preset could have turned it off.
    static func translationDLLResetEntries(builtinD3D12IsD3DMetal: Bool) -> [DLLOverrideEntry] {
        let presets = DLLOverrideResolver.dxvkPreset(builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal)
            + DLLOverrideResolver.dxmtPreset(builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal)
        return Set(presets.map(\.dllName)).sorted().map { DLLOverrideEntry(dllName: $0, mode: .builtin) }
    }

    /// Applies per-program overrides to the programUser layer of the builder.
    ///
    /// Each non-nil field in the overrides sets the corresponding environment variable(s)
    /// in the ``EnvironmentLayer/programUser`` layer, which has higher priority than
    /// bottleManaged and launcherManaged layers.
    ///
    /// `builtinD3D12IsD3DMetal` says whether the runtime's builtin `d3d12` is
    /// D3DMetal's, which decides whether the DXVK and DXMT presets turn it off
    /// and whether the reset union puts it back. Defaults to whether the GPTK
    /// payload is deployed. `recommendedBackend` is what a program set to
    /// `.recommended` gets; `nil` asks ``GraphicsBackendResolver``.
    static func applyProgramOverrides(
        _ overrides: ProgramOverrides,
        frameGeneration: Bool = false,
        recommendedBackend: GraphicsBackend? = nil,
        builtinD3D12IsD3DMetal: Bool = GPTKImporter.isDeployed(),
        featureGate: (WineEngineFeature) -> Bool = { _ in true },
        builder: inout EnvironmentBuilder,
        dllResolver: inout DLLOverrideResolver
    ) {
        let dxvkPreset = DLLOverrideResolver.dxvkPreset(builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal)
        let dxmtPreset = DLLOverrideResolver.dxmtPreset(builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal)
        let translationReset = translationDLLResetEntries(builtinD3D12IsD3DMetal: builtinD3D12IsD3DMetal)

        // Graphics backend override: replaces bottle-level backend entirely.
        // A program asking for a backend the engine policy does not permit
        // takes the neutral path — managed overrides are reset and no
        // translation-layer env leaks through, exactly as if it had asked for
        // a builtin backend.
        if let backend = overrides.graphicsBackend {
            let requested = if backend == .recommended {
                recommendedBackend ?? GraphicsBackendResolver.resolve()
            } else {
                backend
            }
            let resolved = gatedBackend(requested, gate: featureGate)
            switch resolved {
            case .d3dMetal, .recommended:
                // Undo any bottle-level DXVK/DXMT by overriding DLLs to builtin
                dllResolver.programCustom.append(contentsOf: translationReset)
                // Remove DXVK and wined3d env vars at program layer
                builder.remove("DXVK_HUD", layer: .programUser)
                builder.remove("DXVK_ASYNC", layer: .programUser)
                builder.remove("WINED3DMETAL", layer: .programUser)
                // One program on D3DMetal inside a bottle running something else
                // still has to claim scheduling itself; see the bottle layer.
                // Gated on the same setting, or turning frame generation off
                // would leave this one route still open.
                if frameGeneration {
                    builder.set("CX_ACTIVE_GRAPHICS_BACKEND", "d3dmetal", layer: .programUser)
                }

            case .dxvk:
                // Enable DXVK DLLs at program level
                dllResolver.programCustom.append(contentsOf: dxvkPreset)
                builder.remove("WINED3DMETAL", layer: .programUser)
                // CX_ACTIVE_GRAPHICS_BACKEND deliberately survives. It selects no
                // backend: win32u is the only thing in the runtime that reads it,
                // and all it does is answer KMTQAITYPE_WDDM_2_7_CAPS. Stripping it
                // here starved every child of a DXVK-steered launcher, because
                // Steam runs its games on D3DMetal (DXVK has no d3d12) while they
                // inherit Steam's environment, and Streamline then refuses DLSS
                // frame generation. D3DM_ENABLE_METALFX and D3DM_MTL4 already
                // survive this branch for the same reason.

            case .dxmt:
                // Reset the full translation-DLL union to builtin first so a DXVK
                // bottle's d3d9 (which DXMT's preset doesn't touch, and whose
                // native copy enableDXVK left in the prefix) is neutralized, then
                // layer DXMT's preset on top — last-append-wins restores n,b for
                // the DXMT trio and b for winemetal. DXVK/wined3d env must not leak.
                dllResolver.programCustom.append(contentsOf: translationReset)
                dllResolver.programCustom.append(contentsOf: dxmtPreset)
                builder.remove("DXVK_HUD", layer: .programUser)
                builder.remove("DXVK_ASYNC", layer: .programUser)
                builder.remove("WINED3DMETAL", layer: .programUser)
                // Survives for the reason given under .dxvk: DXMT translates d3d11
                // only, so d3d12 is still D3DMetal here.

            case .wined3d:
                // Force wined3d: disable D3DMetal + undo DXVK/DXMT DLLs
                builder.set("WINED3DMETAL", "0", layer: .programUser)
                // The one branch that really has no D3DMetal behind it, so the
                // capability claim would be a lie.
                builder.remove("CX_ACTIVE_GRAPHICS_BACKEND", layer: .programUser)
                dllResolver.programCustom.append(contentsOf: translationReset)
            }
        }

        // Legacy DXVK override: only honored when no explicit backend override is
        // present. The override UI historically wrote `dxvk` alongside
        // `graphicsBackend`, and since program-custom resolution is last-append-wins
        // the stale flag would silently clobber the explicit backend choice
        // (re-enabling DXVK under a D3DMetal override, or disabling DXMT).
        if let dxvk = overrides.dxvk, overrides.graphicsBackend == nil {
            if dxvk, featureGate(.dxvk) {
                // Program forces DXVK on -- add DXVK preset to program custom DLLs
                dllResolver.programCustom.append(contentsOf: dxvkPreset)
            } else {
                // Program forces DXVK off -- override each DXVK DLL to builtin
                for entry in dxvkPreset {
                    dllResolver.programCustom.append(
                        DLLOverrideEntry(dllName: entry.dllName, mode: .builtin)
                    )
                }
            }
        }

        // DXVK HUD override
        if let dxvkHud = overrides.dxvkHud {
            switch dxvkHud {
            case .full:
                if featureGate(.dxvk) {
                    builder.set("DXVK_HUD", "full", layer: .programUser)
                }
            case .partial:
                if featureGate(.dxvk) {
                    builder.set("DXVK_HUD", "devinfo,fps,frametimes", layer: .programUser)
                }
            case .fps:
                if featureGate(.dxvk) {
                    builder.set("DXVK_HUD", "fps", layer: .programUser)
                }
            case .off:
                builder.remove("DXVK_HUD", layer: .programUser)
            }
        }

        // DXVK async override — enabling needs the feature gate; the explicit
        // "0" stays, asking for less is always allowed.
        if let dxvkAsync = overrides.dxvkAsync {
            builder.set("DXVK_ASYNC", dxvkAsync && featureGate(.dxvkAsync) ? "1" : "0", layer: .programUser)
        }

        // Enhanced sync override — the affirmative modes are gated like the
        // bottle layer's; explicit "none" always removes.
        if let enhancedSync = overrides.enhancedSync {
            switch enhancedSync {
            case .none:
                // Explicit "none" choice is strictly honored across all macOS versions:
                // neither variable is set, preventing silent forced injection of ESYNC on 15.4+.
                builder.remove("WINEESYNC", layer: .programUser)
                builder.remove("WINEMSYNC", layer: .programUser)
            case .esync:
                if featureGate(.esync) {
                    builder.set("WINEESYNC", "1", layer: .programUser)
                    builder.remove("WINEMSYNC", layer: .programUser)
                }
            case .msync:
                if featureGate(.msync) {
                    builder.set("WINEMSYNC", "1", layer: .programUser)
                    builder.set("WINEESYNC", "1", layer: .programUser)
                }
            }
        }

        // Metal 4 override. `D3DMDevice::MTL4OptionEnabled` only takes that path
        // for D3D12 devices, so a D3D12 title whose renderer wedges on a fence
        // the Metal 4 submission path never signals has to be able to drop back
        // without the rest of the bottle losing it.
        if let metal4Enabled = overrides.metal4Enabled {
            if metal4Enabled, featureGate(.metal) {
                builder.set("D3DM_MTL4", "1", layer: .programUser)
            } else if !metal4Enabled {
                builder.remove("D3DM_MTL4", layer: .programUser)
            }
        }

        // GDI presentation upscaler override: same env mapping as the bottle
        // layer, including the adaptive/ESRGAN model aliases — and the same
        // engine gate, so a program override cannot enable what the bottle's
        // engine does not permit.
        if let gdiUpscaler = overrides.gdiUpscaler, featureGate(.gdiUpscaling) {
            let gdiUpscalerValue: String
            let neuralModel: String
            let adaptiveFast: String
            switch gdiUpscaler {
            case .realesrgan:
                gdiUpscalerValue = "realcugan"
                neuralModel = "animevideov3"
                adaptiveFast = "metalfx"
            case .adaptiveRealesrgan:
                gdiUpscalerValue = "adaptive"
                neuralModel = "animevideov3"
                adaptiveFast = "metalfx"
            case .adaptiveAnime4k:
                gdiUpscalerValue = "adaptive"
                neuralModel = "realcugan"
                adaptiveFast = "anime4k"
            case .adaptiveAnime4kRealesrgan:
                gdiUpscalerValue = "adaptive"
                neuralModel = "animevideov3"
                adaptiveFast = "anime4k"
            default:
                gdiUpscalerValue = gdiUpscaler.rawValue
                neuralModel = "realcugan"
                adaptiveFast = "metalfx"
            }
            builder.set("WINE_GDI_UPSCALER", gdiUpscalerValue, layer: .programUser)
            builder.set("WINE_GDI_NEURAL_MODEL", neuralModel, layer: .programUser)
            builder.set("WINE_GDI_ADAPTIVE_FAST", adaptiveFast, layer: .programUser)
            builder.set("WINE_METALFX", gdiUpscaler == .metalfx ? "spatial" : "off", layer: .programUser)
        }
        if let gdiUpscalerCache = overrides.gdiUpscalerCache, featureGate(.gdiUpscaling) {
            builder.set("WINE_GDI_CACHE_MODE", gdiUpscalerCache.rawValue, layer: .programUser)
        }

        // Shader cache override, on the variable DXVK actually reads.
        if let shaderCache = overrides.shaderCacheEnabled, featureGate(.dxvk) {
            if !shaderCache {
                builder.set("DXVK_STATE_CACHE", "0", layer: .programUser)
            } else {
                builder.remove("DXVK_STATE_CACHE", layer: .programUser)
            }
        }

        // Input override: controller compatibility SDL hints at program level
        if let controllerCompat = overrides.controllerCompatibilityMode {
            // When compat mode is overridden, control whether SDL hints are applied
            if controllerCompat {
                if let disableHIDAPI = overrides.disableHIDAPI, disableHIDAPI {
                    builder.set("SDL_JOYSTICK_HIDAPI", "0", layer: .programUser)
                }
                if let allowBG = overrides.allowBackgroundEvents, allowBG {
                    builder.set("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1", layer: .programUser)
                }
                let mapping = overrides.disableControllerMapping ?? false
                let labels = overrides.useButtonLabels ?? false
                if mapping || labels {
                    builder.set("SDL_GAMECONTROLLER_USE_BUTTON_LABELS", "1", layer: .programUser)
                } else {
                    builder.set("SDL_GAMECONTROLLER_USE_BUTTON_LABELS", "0", layer: .programUser)
                }
            } else {
                // Program overrides compat mode off: remove all SDL hints
                builder.remove("SDL_JOYSTICK_HIDAPI", layer: .programUser)
                builder.remove("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", layer: .programUser)
                builder.remove("SDL_GAMECONTROLLER_USE_BUTTON_LABELS", layer: .programUser)
            }
        }

        // Program-specific DLL overrides (structured entries)
        if let dllOverrides = overrides.dllOverrides {
            dllResolver.programCustom.append(contentsOf: dllOverrides)
        }
    }

    /// Logs a safe launch summary at info level.
    ///
    /// Only logs the bottle name, active layers, and whitelisted non-sensitive keys.
    /// Does NOT log full environment dict, WINEPREFIX paths, or user-set custom env vars.
    private static func logLaunchSummary(
        bottleName: String,
        provenance: EnvironmentProvenance,
        environment: [String: String]
    ) {
        let layerNames = provenance.activeLayers.sorted().map { layer -> String in
            switch layer {
            case .base: "base"
            case .platform: "platform"
            case .bottleManaged: "bottleManaged"
            case .launcherManaged: "launcherManaged"
            case .gameProfile: "gameProfile"
            case .bottleUser: "bottleUser"
            case .programUser: "programUser"
            case .featureRuntime: "featureRuntime"
            case .callsiteOverride: "callsiteOverride"
            }
        }

        // Non-sensitive keys allowed in the launch summary
        let allowedKeys = [
            "DXVK_ASYNC", "DXVK_HUD", "WINEESYNC", "WINEMSYNC",
            "D3DM_MTL4", "MTL_HUD_ENABLED", "WINED3DMETAL"
        ]
        let safeEntries = allowedKeys.compactMap { key -> String? in
            guard let value = environment[key] else { return nil }
            return "\(key)=\(value)"
        }

        let safeValues = safeEntries.isEmpty ? "defaults" : safeEntries.joined(separator: ", ")
        envLogger.info(
            "Launch: bottle=\(bottleName), layers=[\(layerNames.joined(separator: ","))], \(safeValues)"
        )
    }
}

// swiftlint:enable cyclomatic_complexity
// swiftlint:enable function_body_length
