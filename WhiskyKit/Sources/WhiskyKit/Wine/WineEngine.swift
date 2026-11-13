//
//  WineEngine.swift
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

import CryptoKit
import Foundation
import os.log

private let engineLogger = Logger(subsystem: Bundle.whiskyBundleIdentifier, category: "WineEngine")

/// A Wine feature that depends on the engine build, not just on a setting.
///
/// Raw values are the stable identifiers the bridge wire protocol and the
/// persisted per-bottle ``BottleWineConfig/featureOverrides`` map use; rename
/// them and stored confirmations stop matching.
public enum WineEngineFeature: String, Codable, Sendable, CaseIterable {
    /// DXVK DLL payload deployed per bottle.
    case dxvk
    /// DXMT (Direct3D 11 to Metal) translation layer.
    case dxmt
    /// Apple's D3DMetal layer inside the engine's `lib/external`.
    case d3dMetal
    /// `WINEESYNC` eventfd synchronization.
    case esync
    /// `WINEMSYNC` shared-memory synchronization (patched builds).
    case msync
    /// `ROSETTA_ADVERTISE_AVX` AVX advertisement under Rosetta.
    case avx
    /// `WINE_GDI_UPSCALER` family of presentation upscalers (patched builds).
    case gdiUpscaling
    /// Core ML neural backend for the GDI upscaler.
    case gdiCoreML
    /// D3DMetal-family Metal options (`D3DM_MTL4`, `MTL_HUD_ENABLED`, DXR, validation).
    case metal
    /// `D3DM_ENABLE_METALFX` DLSS-to-MetalFX bridge.
    case metalFX
    /// `CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal` frame-generation claim.
    case frameGeneration
    /// `MVK_CONFIG_SHADOW_IMPORTED_HOST_MEMORY` MoltenVK workaround.
    case shadowImportedHostMemory
    /// `DXVK_ASYNC` async shader compilation.
    case dxvkAsync
}

/// Whether the engine can run a feature, and whether the user may force it.
public enum WineEngineFeatureState: String, Codable, Sendable {
    /// Verified to work; usable without confirmation.
    case supported
    /// The engine may or may not honour it; usable only after the user
    /// confirms against the current engine fingerprint.
    case unverified
    /// A hard prerequisite is missing; confirmation cannot enable it.
    case unavailable
}

/// One feature's status on one engine, as `wine.engines.*` reports it.
public struct WineEngineFeatureStatus: Codable, Sendable, Equatable {
    public let feature: WineEngineFeature
    public let state: WineEngineFeatureState
    /// Human-readable explanation for `unverified`/`unavailable`; `nil` when supported.
    public let reason: String?
    /// Whether an explicit user confirmation may enable this feature.
    public let canOverride: Bool

    public init(
        feature: WineEngineFeature,
        state: WineEngineFeatureState,
        reason: String? = nil,
        canOverride: Bool = false
    ) {
        self.feature = feature
        self.state = state
        self.reason = reason
        self.canOverride = canOverride
    }
}

/// Errors describing why a directory is not a usable Wine engine, or why a
/// registered engine cannot be resolved.
public enum WineEngineError: LocalizedError, Equatable {
    /// The path is missing or not a directory.
    case missingRoot(String)
    /// No `bin/wine64` or `bin/wine` loader was found.
    case missingLoader(String)
    /// No `bin/wineserver` was found.
    case missingServer(String)
    /// No `lib` directory was found.
    case missingLibrary(String)
    /// A binary is not executable.
    case notExecutable(String)
    /// A binary is not a Mach-O executable for a usable architecture
    /// (script, ELF, truncated or i386-only).
    case invalidBinary(String)
    /// Loader and server carry no common executable slice.
    case architectureMismatch(String)
    /// The engine id is not in the registry.
    case unknownEngine(String)
    /// The `managed` engine cannot be modified or removed.
    case managedImmutable
    /// The engine is still referenced by a registered container.
    case engineInUse(String)
    /// The registry file is unreadable or fails schema validation.
    case registryCorrupted(String)
    /// The selected engine could not be resolved for an operation.
    case engineUnavailable(String)
    /// A conflicting Wine operation or engine reselection is in progress.
    case operationBusy(String)

    public var errorDescription: String? {
        switch self {
        case let .missingRoot(detail),
             let .missingLoader(detail),
             let .missingServer(detail),
             let .missingLibrary(detail),
             let .notExecutable(detail),
             let .invalidBinary(detail),
             let .architectureMismatch(detail),
             let .unknownEngine(detail),
             let .engineInUse(detail),
             let .registryCorrupted(detail),
             let .engineUnavailable(detail),
             let .operationBusy(detail):
            detail
        case .managedImmutable:
            "The managed Whisky Wine engine cannot be modified or removed"
        }
    }
}

/// A Wine runtime a bottle can bind to: the managed Whisky Wine install or a
/// user-registered external tree.
///
/// External trees are read-only: Whisky never installs into, updates, or
/// deploys payloads (DXVK, DXMT, GPTK) onto them. Registration is static
/// detection only — no executable in the tree is launched to detect it.
public struct WineEngine: Sendable, Equatable {
    /// Identifier of the managed runtime ``WhiskyWineInstaller`` owns.
    public static let managedID = "managed"

    /// Stable identifier persisted in ``BottleWineConfig/engineID``.
    public let id: String
    /// Display name (user-provided or derived from the directory).
    public let name: String
    /// Canonical root of the Wine tree — the directory holding `bin/` and `lib/`.
    public let rootURL: URL
    /// Executable loader used for every Wine invocation (`wine64` preferred, else `wine`).
    public let wineBinary: URL
    /// Executable `wineserver`.
    public let wineserverBinary: URL
    /// The `lib/` directory of the tree (payload libraries live under it).
    public let libraryURL: URL
    /// Optional surrounding payload root (e.g. a `Libraries/` folder containing
    /// this tree plus `DXVK/`/`DXMT/` siblings); `nil` for a bare Wine tree.
    public let librariesURL: URL?
    /// Whether this is the managed runtime Whisky installs and updates.
    public let isManaged: Bool
    /// Deterministic content fingerprint: canonical root plus identity/change
    /// metadata of the loader, server and detected payload markers. It changes
    /// when the engine is replaced or upgraded in place, which is exactly when
    /// stored feature confirmations must stop applying. It does not hash
    /// payload contents, so swapping payload *files* in place is not detected —
    /// a documented limit, not a security boundary.
    public let fingerprint: String
    /// Detected executable architectures, e.g. `["arm64", "x86_64"]`.
    public let architectures: [String]
    /// Why the engine is unusable right now, or `nil` when it can be launched.
    public let availabilityError: String?
    /// Wine version string when metadata exists; `nil` means unprobed/unknown —
    /// detection never launches the engine to ask it.
    public let version: String?

    public init(
        id: String,
        name: String,
        rootURL: URL,
        wineBinary: URL,
        wineserverBinary: URL,
        libraryURL: URL,
        librariesURL: URL?,
        isManaged: Bool,
        fingerprint: String,
        architectures: [String],
        availabilityError: String?,
        version: String?
    ) {
        self.id = id
        self.name = name
        self.rootURL = rootURL
        self.wineBinary = wineBinary
        self.wineserverBinary = wineserverBinary
        self.libraryURL = libraryURL
        self.librariesURL = librariesURL
        self.isManaged = isManaged
        self.fingerprint = fingerprint
        self.architectures = architectures
        self.availabilityError = availabilityError
        self.version = version
    }

    /// `bin/` directory of this engine — rebuilt so `path` carries no
    /// trailing slash (`deletingLastPathComponent` and `fileURLWithPath`'s
    /// directory sniffing both produce one, which leaks into PATH entries).
    public var binFolder: URL {
        var path = wineBinary.deletingLastPathComponent().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    /// Whether the engine can currently launch processes.
    public var isAvailable: Bool {
        availabilityError == nil
    }

    /// The minimal environment the engine's own binaries need to run: its
    /// loader, server and library paths, so a probe (version, `wineserver
    /// -k0`) resolves the same pieces a launch would and never falls back
    /// onto another runtime's libraries.
    var probeEnvironment: [String: String] {
        [
            "WINELOADER": wineBinary.path(percentEncoded: false),
            "WINESERVER": wineserverBinary.path(percentEncoded: false),
            "DYLD_FALLBACK_LIBRARY_PATH": "\(libraryURL.path(percentEncoded: false)):/usr/lib"
        ]
    }

    /// CPU slices this host can actually execute: the native architecture plus
    /// `x86_64` when Rosetta 2 is installed. Structural Mach-O validation is
    /// deliberately separate — an engine can be well-formed and still not run
    /// on this machine (arm64-only on Intel, x86-only on Apple Silicon
    /// without Rosetta). Tests override ``hostArchitecturesOverride``.
    static var hostExecutableArchitectures: Set<String> {
        hostArchitecturesOverride
            ?? (HostArchitecture.isAppleSilicon
                ? (Rosetta2.isRosettaInstalled ? ["arm64", "x86_64"] : ["arm64"])
                : ["x86_64"])
    }

    /// Test seam: pins the executable slice set ``hostExecutableArchitectures``
    /// reports. `nil` restores the real host probe. Tests write it before any
    /// detection runs; it is never mutated concurrently in production.
    nonisolated(unsafe) static var hostArchitecturesOverride: Set<String>?

    /// Test seam: overrides ``managed``'s install check so tests never depend
    /// on — or write into — the real managed runtime under Application
    /// Support. `nil` restores the real ``WhiskyWineInstaller`` probe.
    ///
    /// This is a process-global for the sequential XCTest harness only —
    /// legacy XCTest cases set it in `setUp` and restore it in `tearDown`.
    /// Swift Testing suites run in parallel and MUST use
    /// ``scopedManagedInstallOverride`` instead.
    nonisolated(unsafe) static var managedInstallOverride: Bool?

    /// Task-local managed-install override for Swift Testing: each
    /// `.withValue` scope sees its own availability, so parallel suites can
    /// never reset a flag out from under another test's async operation.
    /// Takes precedence over the legacy ``managedInstallOverride``.
    @TaskLocal static var scopedManagedInstallOverride: Bool?
}

// MARK: - Managed engine

public extension WineEngine {
    /// The managed runtime descriptor. Its paths mirror the static
    /// ``Wine/wineBinary`` layout; availability mirrors
    /// ``WhiskyWineInstaller/isWhiskyWineInstalled()``.
    static var managed: WineEngine {
        let wineRoot = WhiskyWineInstaller.libraryFolder.appending(path: "Wine")
        let bin = wineRoot.appending(path: "bin")
        let wineBinary = bin.appending(path: "wine64")
        let wineserver = bin.appending(path: "wineserver")
        let installed = scopedManagedInstallOverride
            ?? managedInstallOverride
            ?? WhiskyWineInstaller.isWhiskyWineInstalled()
        return WineEngine(
            id: managedID,
            name: "Whisky Wine",
            rootURL: wineRoot,
            wineBinary: wineBinary,
            wineserverBinary: wineserver,
            libraryURL: wineRoot.appending(path: "lib"),
            librariesURL: WhiskyWineInstaller.libraryFolder,
            isManaged: true,
            fingerprint: fingerprint(
                root: wineRoot,
                markers: [wineBinary, wineserver]
            ),
            architectures: ["x86_64"],
            availabilityError: installed ? nil : "The managed Wine runtime is not installed",
            version: WhiskyWineInstaller.whiskyWineVersion().map { "\($0)" }
        )
    }
}

// MARK: - Detection

public extension WineEngine {
    /// Errors surfaced through ``WineEngineError``.
    ///
    /// Detects an external Wine engine at `url` without launching anything in
    /// it. Accepts the standard layout `bin/{wine64|wine}` + `bin/wineserver` +
    /// `lib`, or a `Libraries/`-style root holding a `Wine/` child with that
    /// layout (the managed install's shape), or the `Wine/` directory itself.
    /// There is deliberately no `.app` bundle recursion and no wrapper-script
    /// execution.
    ///
    /// - Parameters:
    ///   - url: Directory to inspect. Symlinks in the path are resolved.
    ///   - id: Identifier for the descriptor (the store assigns UUIDs).
    ///   - name: Display name; defaults to the root directory name.
    /// - Returns: A descriptor, or throws ``WineEngineError`` describing the
    ///   first rejected prerequisite.
    static func detect(at url: URL, id: String = UUID().uuidString, name: String? = nil) throws -> WineEngine {
        let fileManager = FileManager.default
        guard url.isFileURL else { throw WineEngineError.missingRoot("Engine path must be a local directory") }
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw WineEngineError.missingRoot("Wine engine directory does not exist: \(root.path)")
        }

        let layout = try normalizedLayout(of: root, fileManager: fileManager)
        let wineRoot = layout.wineRoot
        let libraries = layout.libraries
        let (wineBinary, wineserver) = try requiredBinaries(
            in: wineRoot, fileManager: fileManager
        )
        let library = try requiredLibrary(in: wineRoot, fileManager: fileManager)

        let loaderArches = try machOArchitectures(of: wineBinary)
        let serverArches = try machOArchitectures(of: wineserver)
        let commonArches = loaderArches.intersection(serverArches)
        guard !commonArches.isEmpty else {
            throw WineEngineError.architectureMismatch(
                "wine loader (\(loaderArches.sorted().joined(separator: ", "))) and wineserver "
                    + "(\(serverArches.sorted().joined(separator: ", "))) share no executable slice"
            )
        }
        // Structural validity alone is not launchability: the common slices
        // must intersect what this host can execute (native or Rosetta).
        let availabilityError = commonArches.isDisjoint(with: hostExecutableArchitectures)
            ? "No executable slice this host can run (host: "
            + hostExecutableArchitectures.sorted().joined(separator: ", ")
            + "; engine: \(commonArches.sorted().joined(separator: ", ")))"
            : nil

        return WineEngine(
            id: id,
            name: name ?? wineRoot.lastPathComponent,
            rootURL: wineRoot,
            wineBinary: wineBinary,
            wineserverBinary: wineserver,
            libraryURL: library,
            librariesURL: libraries,
            isManaged: false,
            fingerprint: fingerprint(root: wineRoot, markers: fingerprintMarkers(
                wineRoot: wineRoot, libraries: libraries
            )),
            architectures: commonArches.sorted(),
            availabilityError: availabilityError,
            version: nil
        )
    }

    /// The accepted tree shapes normalized to (wine root, payload root?):
    /// `root/bin` directly, or `root/Wine/bin` with `root` carrying payloads.
    private static func normalizedLayout(
        of root: URL, fileManager: FileManager
    ) throws -> (wineRoot: URL, libraries: URL?) {
        let hasBin = { (candidate: URL) in
            fileManager.fileExists(
                atPath: candidate.appending(path: "bin").path(percentEncoded: false)
            )
        }
        if hasBin(root) {
            // A bare tree never borrows payloads from wherever it happens to
            // live — `OtherWine` next to a managed `Libraries/` folder must
            // not silently inherit managed DXVK/DXMT. Only a root literally
            // named `Wine` may be the engine child of a `Libraries`-style
            // package (the managed install's shape), and then only when the
            // parent actually carries payload folders.
            if root.lastPathComponent == "Wine" {
                let parent = root.deletingLastPathComponent()
                if parentHasPayloads(parent) {
                    return (root, parent)
                }
            }
            return (root, nil)
        }
        let nested = root.appending(path: "Wine")
        guard hasBin(nested) else {
            throw WineEngineError.missingLoader(
                "No bin/wine64 or bin/wine loader under \(root.path)"
            )
        }
        return (nested, root)
    }

    /// The loader (`wine64` preferred, then `wine`) and `wineserver` an engine
    /// must carry under `bin/`.
    private static func requiredBinaries(
        in wineRoot: URL, fileManager: FileManager
    ) throws -> (wine: URL, wineserver: URL) {
        let bin = wineRoot.appending(path: "bin")
        guard let wineBinary = ["wine64", "wine"]
            .map({ bin.appending(path: $0) })
            .first(where: { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) })
        else {
            throw WineEngineError.missingLoader("No wine64 or wine loader under \(bin.path)")
        }
        let wineserver = bin.appending(path: "wineserver")
        guard fileManager.fileExists(atPath: wineserver.path(percentEncoded: false)) else {
            throw WineEngineError.missingServer("No bin/wineserver under \(bin.path)")
        }
        return (wineBinary, wineserver)
    }

    /// The `lib/` directory an engine must carry.
    private static func requiredLibrary(
        in wineRoot: URL, fileManager: FileManager
    ) throws -> URL {
        let library = wineRoot.appending(path: "lib")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: library.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw WineEngineError.missingLibrary("No lib directory under \(wineRoot.path)")
        }
        return library
    }

    /// Whether `directory` looks like a payload root — it carries at least one
    /// of the optional payload folders Whisky deploys per bottle.
    private static func parentHasPayloads(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        return ["DXVK", "DXMT"].contains {
            fileManager.fileExists(
                atPath: directory.appending(path: $0).path(percentEncoded: false)
            )
        }
    }

    /// Files whose identity metadata feeds the fingerprint: the binaries,
    /// cheap lib identity (immediate children of `lib/` and `lib/wine/` — a
    /// rebuild confined to `lib` must still invalidate confirmations), and
    /// every payload marker feature detection depends on. Directory listings
    /// only; no file contents are read. Entries beyond the first 256 per
    /// directory are a documented limit of the cheap-identity approach.
    private static func fingerprintMarkers(wineRoot: URL, libraries: URL?) -> [URL] {
        let bin = wineRoot.appending(path: "bin")
        var markers = [
            bin.appending(path: "wine64"),
            bin.appending(path: "wine"),
            bin.appending(path: "wineserver")
        ]
        let fileManager = FileManager.default
        for directory in [
            wineRoot.appending(path: "lib"),
            wineRoot.appending(path: "lib/wine")
        ] {
            let children = (try? fileManager.contentsOfDirectory(
                atPath: directory.path(percentEncoded: false)
            )) ?? []
            for child in children.sorted().prefix(256) where !child.hasPrefix(".") {
                markers.append(directory.appending(path: child))
            }
        }
        for base in payloadSearchRoots(wineRoot: wineRoot, libraries: libraries) {
            let dxvk = base.appending(path: "DXVK")
            markers.append(dxvk.appending(path: "x64/d3d11.dll"))
            markers.append(dxvk.appending(path: "x32/d3d11.dll"))
            let dxmt = base.appending(path: "DXMT")
            for arch in ["x64", "x32"] {
                for name in Wine.dxmtPrefixDLLs {
                    markers.append(dxmt.appending(path: "\(arch)/\(name)"))
                }
            }
        }
        // Critical modules whose in-place replacement must invalidate
        // approvals: editing `lib/wine/x86_64-unix/*.so` leaves the parent
        // directory entries' metadata untouched.
        let unixLib = wineRoot.appending(path: "lib/wine/x86_64-unix")
        markers.append(unixLib.appending(path: "ntdll.so"))
        markers.append(unixLib.appending(path: "win32u.so"))
        markers.append(unixLib.appending(path: "winegdi.so"))
        let external = wineRoot.appending(path: "lib/external")
        markers.append(external.appending(path: "D3DMetal.framework"))
        markers.append(external.appending(path: "D3DMetal.framework/D3DMetal"))
        markers.append(external.appending(path: "libd3dshared.dylib"))
        let upscalers = wineRoot.appending(path: "lib/wine/x86_64-unix/gdi-upscalers")
        markers.append(upscalers.appending(path: "libwinegdiupscalers.dylib"))
        markers.append(upscalers.appending(path: "winegdi-coreml-helper"))
        markers.append(upscalers.appending(path: "coreml/manifest.json"))
        // Model names + metadata, never model contents.
        let coreml = upscalers.appending(path: "coreml")
        for model in ((try? fileManager.contentsOfDirectory(
            atPath: coreml.path(percentEncoded: false)
        )) ?? []).sorted() where model.hasSuffix(".mlmodelc") {
            markers.append(coreml.appending(path: model))
        }
        return markers
    }

    /// Directories searched for optional payloads (`DXVK/`, `DXMT/`).
    /// The surrounding `Libraries/` root comes first, then the Wine root
    /// itself for bare trees that carry payloads next to `bin/`.
    static func payloadSearchRoots(wineRoot: URL, libraries: URL?) -> [URL] {
        var roots: [URL] = []
        if let libraries {
            roots.append(libraries)
        }
        if !roots.contains(wineRoot) {
            roots.append(wineRoot)
        }
        return roots
    }

    /// Deterministic fingerprint over the canonical root path and the
    /// root-relative path + size/mtime/inode of each marker that exists.
    /// Cheap: attributes only, never file contents. Replacing a marker's
    /// bytes in place without touching mtime or inode is a documented limit.
    static func fingerprint(root: URL, markers: [URL]) -> String {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
            .path(percentEncoded: false)
        var material = canonical
        for marker in markers {
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: marker.resolvingSymlinksInPath().path(percentEncoded: false)
            )
            guard let attributes else {
                continue
            }
            let full = marker.resolvingSymlinksInPath().standardizedFileURL
                .path(percentEncoded: false)
            let relative = full.hasPrefix(canonical + "/")
                ? String(full.dropFirst(canonical.count + 1))
                : full
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            material += "\n\(relative):\(size):\(mtime):\(inode)"
        }
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Mach-O validation

extension WineEngine {
    /// Mach-O constants used by the validator.
    private enum MachO {
        /// `MH_MAGIC` / `MH_MAGIC_64` as stored little-endian on disk.
        static let thinMagicLE32: UInt32 = 0xFEED_FACE
        static let thinMagicLE64: UInt32 = 0xFEED_FACF
        /// `MH_CIGAM` / `MH_CIGAM_64` — big-endian thin headers, seen
        /// little-endian (vanishingly rare; parsed in matching byte order).
        static let thinMagicBE32: UInt32 = 0xCEFA_EDFE
        static let thinMagicBE64: UInt32 = 0xCFFA_EDFE
        /// `FAT_MAGIC` / `FAT_MAGIC_64` are stored big-endian on disk, so a
        /// little-endian read yields the byte-swapped constants.
        static let fatMagic32: UInt32 = 0xBEBA_FECA
        static let fatMagic64: UInt32 = 0xBFBA_FECA
        /// `MH_EXECUTE` — the only accepted filetype. Objects, dylibs,
        /// bundles and scripts are rejected outright.
        static let fileTypeExecute: UInt32 = 2
        /// Smallest possible thin header (`mach_header` is 28 bytes).
        static let thinHeaderMinimum = 28
        /// `sizeof(mach_header_64)`.
        static let thinHeader64 = 32
        /// `sizeof(struct fat_arch)` / `sizeof(struct fat_arch_64)`.
        static let fatEntry32 = 20
        static let fatEntry64 = 32
        /// Bound on `nfat_arch` — real universal binaries have a handful.
        static let fatEntryLimit: UInt32 = 64
    }

    /// Executable CPU types in a Mach-O file (thin or fat).
    ///
    /// Validates structure, not just the magic word: every accepted slice is
    /// a complete `MH_EXECUTE` thin header physically inside the file, and fat
    /// entry tables must be fully present with bounded, in-file,
    /// non-overlapping slice ranges whose referenced headers agree with the
    /// table's CPU type. Scripts, ELF, truncated files, wrong-filetype
    /// binaries and i386-only slices throw ``WineEngineError``.
    static func machOArchitectures(of url: URL) throws -> Set<String> {
        let resolved = url.resolvingSymlinksInPath()
        let path = resolved.path(percentEncoded: false)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            throw WineEngineError.invalidBinary("Missing executable: \(path)")
        }
        guard fileManager.isExecutableFile(atPath: path) else {
            throw WineEngineError.notExecutable("Not executable: \(path)")
        }
        let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?
            .uint64Value ?? 0
        guard size >= UInt64(MachO.thinHeaderMinimum) else {
            throw WineEngineError.invalidBinary("Truncated or unreadable binary: \(path)")
        }
        let reader = try MachOReader(
            handle: FileHandle(forReadingFrom: resolved), size: size, path: path
        )
        defer { try? reader.handle.close() }

        let head = try reader.read(at: 0, count: MachO.thinHeader64)
        let magic = try reader.u32(head, 0, bigEndian: false)

        let slices: Set<String> = if magic == MachO.fatMagic32 || magic == MachO.fatMagic64 {
            try fatSliceArchitectures(
                fat64: magic == MachO.fatMagic64, fileSize: size, path: path, reader: reader
            )
        } else {
            try [thinSliceArchitecture(
                header: head, magic: magic, path: path, reader: reader
            )]
        }
        let usable = slices.intersection(["x86_64", "arm64"])
        guard !usable.isEmpty else {
            throw WineEngineError.invalidBinary(
                "No x86_64 or arm64 executable slice in \(path)"
                    + " (found: \(slices.sorted().joined(separator: ", ")))"
            )
        }
        return usable
    }

    /// CPU name of one thin Mach-O header — magic, `MH_EXECUTE` filetype and
    /// CPU type must all check out.
    private static func thinSliceArchitecture(
        header: Data, magic: UInt32, path: String, reader: MachOReader
    ) throws -> String {
        let bigEndian: Bool
        switch magic {
        case MachO.thinMagicLE32, MachO.thinMagicLE64:
            bigEndian = false
        case MachO.thinMagicBE32, MachO.thinMagicBE64:
            bigEndian = true
        default:
            throw WineEngineError.invalidBinary(
                "Not a Mach-O executable (script, ELF or unknown format): \(path)"
            )
        }
        let is64 = magic == MachO.thinMagicLE64 || magic == MachO.thinMagicBE64
        guard header.count >= (is64 ? MachO.thinHeader64 : MachO.thinHeaderMinimum) else {
            throw WineEngineError.invalidBinary("Truncated Mach-O header in \(path)")
        }
        let filetype = try reader.u32(header, 12, bigEndian: bigEndian)
        guard filetype == MachO.fileTypeExecute else {
            throw WineEngineError.invalidBinary(
                "Not a Mach-O executable (filetype \(filetype)) in \(path)"
            )
        }
        return try cputypeName(reader.u32(header, 4, bigEndian: bigEndian))
    }

    /// One validated fat-arch entry: CPU type plus its in-file slice range.
    private struct FatSlice {
        let cputype: UInt32
        let offset: UInt64
        let size: UInt64
    }

    /// The already-read fat header context slice entries decode against.
    private struct FatHeader {
        let fat64: Bool
        let table: Data
        let fileSize: UInt64
        let path: String
    }

    /// Decode one fat-arch table entry, rejecting ranges outside the file.
    private static func fatSliceEntry(
        header: FatHeader, index: Int, reader: MachOReader
    ) throws -> FatSlice {
        let stride = header.fat64 ? MachO.fatEntry64 : MachO.fatEntry32
        let base = 8 + index * stride
        let cputype = try reader.u32(header.table, base, bigEndian: true)
        let offset: UInt64
        let size: UInt64
        if header.fat64 {
            offset = try UInt64(reader.u32(header.table, base + 8, bigEndian: true)) << 32
                | UInt64(reader.u32(header.table, base + 12, bigEndian: true))
            size = try UInt64(reader.u32(header.table, base + 16, bigEndian: true)) << 32
                | UInt64(reader.u32(header.table, base + 20, bigEndian: true))
        } else {
            offset = try UInt64(reader.u32(header.table, base + 8, bigEndian: true))
            size = try UInt64(reader.u32(header.table, base + 12, bigEndian: true))
        }
        guard size >= UInt64(MachO.thinHeaderMinimum),
              offset <= header.fileSize, size <= header.fileSize - offset
        else {
            throw WineEngineError.invalidBinary(
                "Fat Mach-O slice \(index) points outside the file in \(header.path)"
            )
        }
        return FatSlice(cputype: cputype, offset: offset, size: size)
    }

    /// CPU names of the slices a fat header describes, after validating the
    /// entry table and every referenced thin header inside the file.
    private static func fatSliceArchitectures(
        fat64: Bool, fileSize: UInt64, path: String, reader: MachOReader
    ) throws -> Set<String> {
        let count = try reader.u32(reader.read(at: 0, count: 8), 4, bigEndian: true)
        guard count >= 1, count <= MachO.fatEntryLimit else {
            throw WineEngineError.invalidBinary(
                "Unreasonable fat Mach-O slice count \(count) in \(path)"
            )
        }
        let stride = fat64 ? MachO.fatEntry64 : MachO.fatEntry32
        let tableLength = 8 + Int(count) * stride
        let header = try FatHeader(
            fat64: fat64,
            table: reader.read(at: 0, count: tableLength),
            fileSize: fileSize,
            path: path
        )
        let entries = try (0 ..< Int(count)).map { index in
            try fatSliceEntry(header: header, index: index, reader: reader)
        }
        // Real fat slices are non-overlapping ranges.
        let sorted = entries.sorted(by: { $0.offset < $1.offset })
        for (previous, next) in zip(sorted, sorted.dropFirst())
            where previous.offset + previous.size > next.offset {
            throw WineEngineError.invalidBinary(
                "Overlapping fat Mach-O slices in \(path)"
            )
        }

        var archs = Set<String>()
        for entry in entries {
            let header = try reader.read(at: entry.offset, count: MachO.thinHeader64)
            let magic = try reader.u32(header, 0, bigEndian: false)
            let arch = try thinSliceArchitecture(
                header: header, magic: magic, path: path, reader: reader
            )
            guard arch == cputypeName(entry.cputype) else {
                throw WineEngineError.invalidBinary(
                    "Fat Mach-O slice CPU disagrees with its header in \(path)"
                )
            }
            archs.insert(arch)
        }
        return archs
    }

    /// Bounded, offset-based access to one binary: every read is range-checked
    /// against the real file size so a malformed header can never drive a read
    /// past EOF.
    private struct MachOReader {
        let handle: FileHandle
        let size: UInt64
        let path: String

        func read(at offset: UInt64, count: Int) throws -> Data {
            guard offset <= size, UInt64(count) <= size - offset else {
                throw WineEngineError.invalidBinary("Truncated Mach-O structures in \(path)")
            }
            do {
                try handle.seek(toOffset: offset)
            } catch {
                throw WineEngineError.invalidBinary("Cannot read \(path): \(error.localizedDescription)")
            }
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw WineEngineError.invalidBinary("Truncated Mach-O structures in \(path)")
            }
            return data
        }

        func u32(_ data: Data, _ offset: Int, bigEndian: Bool) throws -> UInt32 {
            guard offset + 4 <= data.count else {
                throw WineEngineError.invalidBinary("Truncated Mach-O structures in \(path)")
            }
            let raw = data[offset ..< offset + 4].withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self)
            }
            return bigEndian ? raw.bigEndian : raw
        }
    }

    /// Maps a Mach-O `cputype` field to a readable architecture name.
    private static func cputypeName(_ raw: UInt32) -> String {
        // CPU_ARCH_ABI64 is 0x0100_0000; plain i386 has no ABI64 bit.
        switch raw {
        case 0x0100_0007: "x86_64"
        case 0x0100_000C: "arm64"
        case 0x0000_0007: "i386"
        case 0x0000_000C: "arm"
        default: "cpu\(raw)"
        }
    }
}

// MARK: - Payload detection and feature status

public extension WineEngine {
    /// Optional payloads detectable inside an engine tree.
    enum Payload: String, Sendable {
        case dxvk = "DXVK"
        case dxmt = "DXMT"
        case d3dMetal = "D3DMetal"
        case gdiCoreML = "GDICoreML"
    }

    /// First payload root (of ``payloadSearchRoots(wineRoot:libraries:)``)
    /// containing payload `payload`, or `nil`.
    func payloadRoot(_ payload: Payload) -> URL? {
        let roots = Self.payloadSearchRoots(wineRoot: rootURL, libraries: librariesURL)
        let fileManager = FileManager.default
        func exists(_ url: URL) -> Bool {
            fileManager.fileExists(atPath: url.path(percentEncoded: false))
        }
        switch payload {
        case .dxvk:
            return roots.first {
                exists($0.appending(path: "DXVK").appending(path: "x64").appending(path: "d3d11.dll"))
            }.map { $0.appending(path: "DXVK") }
        case .dxmt:
            return roots.first {
                exists($0.appending(path: "DXMT").appending(path: "x64").appending(path: "d3d11.dll"))
            }.map { $0.appending(path: "DXMT") }
        case .d3dMetal:
            let external = libraryURL.appending(path: "external")
            return exists(external.appending(path: "D3DMetal.framework"))
                || exists(external.appending(path: "libd3dshared.dylib")) ? external : nil
        case .gdiCoreML:
            let upscalers = libraryURL.appending(path: "wine")
                .appending(path: "x86_64-unix").appending(path: "gdi-upscalers")
            let manifest = upscalers.appending(path: "coreml").appending(path: "manifest.json")
            let helper = upscalers.appending(path: "winegdi-coreml-helper")
            return exists(manifest) && exists(helper) ? upscalers : nil
        }
    }

    /// Whether the payload is complete enough that deployment/runtime would
    /// not hit a missing file halfway through. Completeness is a hard
    /// prerequisite — confirmation can never substitute for missing files —
    /// but it still says nothing about engine support, which always stays
    /// `unverified` on external engines.
    func payloadComplete(_ payload: Payload) -> Bool {
        guard let root = payloadRoot(payload) else { return false }
        let fileManager = FileManager.default
        func exists(_ relative: String, isDirectory: Bool = false) -> Bool {
            var flag: ObjCBool = false
            let path = root.appending(path: relative).path(percentEncoded: false)
            return fileManager.fileExists(atPath: path, isDirectory: &flag)
                && flag.boolValue == isDirectory
        }
        switch payload {
        case .dxvk:
            // Deployment copies x64 into system32 and x32 into syswow64 —
            // the whole preset's DLL set must be present and be real PE
            // binaries (readable MZ/PE header, not a builtin marker), or the
            // prefix gets a half-installed layer Wine silently falls back on.
            // `dxgi` is NOT required: DXVK-macOS ships no dxgi.dll and the
            // launcher deliberately pairs the selected runtime's builtin
            // (`reconcileDXGIForDXVK`). A shipped dxgi is still validated.
            let dxvkDLLs = ["d3d9", "d3d10core", "d3d11"]
            return ["x64", "x32"].allSatisfy { arch in
                dxvkDLLs.allSatisfy { name in
                    exists("\(arch)/\(name).dll")
                        && (try? Wine.isNativePE(root.appending(path: "\(arch)/\(name).dll"))) == true
                }
            } && ["x64", "x32"].allSatisfy { arch in
                !exists("\(arch)/dxgi.dll")
                    || (try? Wine.isNativePE(
                        root.appending(path: "\(arch)/dxgi.dll")
                    )) == true
            }
        case .dxmt:
            // The x64 files must be real PE DLLs (not .dylib placeholders —
            // a `.dylib` in system32 crashes the whole process), and both
            // arch tiers must carry the full file set deployment consumes.
            return ["x64", "x32"].allSatisfy { arch in
                Wine.dxmtPrefixDLLs.allSatisfy { exists("\(arch)/\($0)") }
            }
                && Wine.dxmtNativeTrio.allSatisfy {
                    (try? Wine.isNativePE(root.appending(path: "x64/\($0)"))) == true
                }
        case .d3dMetal:
            // The D3DMetal bridge and the PE-side shared library.
            return exists("D3DMetal.framework", isDirectory: true)
                && exists("libd3dshared.dylib")
        case .gdiCoreML:
            // The packaged layout: the executable helper sits next to
            // `libwinegdiupscalers.dylib` at the gdi-upscalers root, and the
            // manifest + compiled `*.mlmodelc` models live under `coreml/`.
            let coreml = root.appending(path: "coreml")
            let models = (try? fileManager.contentsOfDirectory(
                atPath: coreml.path(percentEncoded: false)
            )) ?? []
            return exists("coreml/manifest.json")
                && fileManager.isExecutableFile(
                    atPath: root.appending(path: "winegdi-coreml-helper")
                        .path(percentEncoded: false)
                )
                && models.contains { $0.hasSuffix(".mlmodelc") }
        }
    }

    /// Status of every feature for this engine.
    ///
    /// The managed engine mirrors existing behavior and capability checks —
    /// nothing is newly gated there. An external engine assumes no patched-in
    /// features from a version string; payload-bound features are supported
    /// only when the payload physically exists (missing payload cannot be
    /// overridden), and everything else is `unverified`, needing an explicit
    /// user confirmation before it is allowed to run.
    func featureStatuses() -> [WineEngineFeatureStatus] {
        if isManaged {
            return managedFeatureStatuses()
        }
        return externalFeatureStatuses()
    }

    /// Status of one feature.
    func status(of feature: WineEngineFeature) -> WineEngineFeatureStatus {
        featureStatuses().first { $0.feature == feature }
            ?? WineEngineFeatureStatus(feature: feature, state: .unavailable, reason: "unknown feature")
    }

    /// Central policy: whether `feature` may actually take effect for launches
    /// under `overrides` (`feature` raw id → approved fingerprint).
    ///
    /// - `supported` features are enabled outright.
    /// - `unverified` features are enabled only when the persisted approval
    ///   matches this engine's *current* fingerprint — replacing or updating
    ///   the engine invalidates the confirmation.
    /// - `unavailable` features can never run; confirmation cannot bypass a
    ///   missing payload.
    /// Payload-backed parent a subordinate feature can never outrun: Metal
    /// options only exist under D3DMetal, DXVK async and shadow-imported
    /// memory only under DXVK. Confirming the parent never enables a child —
    /// each keeps its own fingerprint-bound approval — but a child can never
    /// be enabled while its parent is not.
    private static let featureParents: [WineEngineFeature: WineEngineFeature] = [
        .metalFX: .d3dMetal,
        .frameGeneration: .d3dMetal,
        .shadowImportedHostMemory: .dxvk,
        .dxvkAsync: .dxvk
    ]

    /// The payload-backed parent `feature` can never outrun, if any.
    static func featureParent(of feature: WineEngineFeature) -> WineEngineFeature? {
        featureParents[feature]
    }

    /// The requirement chain `feature` closes over, deepest prerequisite
    /// first: `dxvkAsync` requires `dxvk` before it can itself be confirmed.
    /// Used so a request for a child surfaces its missing parent as the
    /// actionable blocker instead of re-asking for the child forever.
    static func featureRequirements(of feature: WineEngineFeature) -> [WineEngineFeature] {
        var chain: [WineEngineFeature] = []
        var current: WineEngineFeature? = feature
        var seen: Set<WineEngineFeature> = []
        while let node = current, seen.insert(node).inserted {
            chain.insert(node, at: 0)
            current = featureParents[node]
        }
        return chain
    }

    func isFeatureEnabled(_ feature: WineEngineFeature, overrides: [String: String] = [:]) -> Bool {
        if !isManaged, let parent = Self.featureParents[feature],
           !isFeatureEnabled(parent, overrides: overrides) {
            return false
        }
        switch status(of: feature).state {
        case .supported:
            return true
        case .unverified:
            return overrides[feature.rawValue] == fingerprint
        case .unavailable:
            return false
        }
    }

    private func managedFeatureStatuses() -> [WineEngineFeatureStatus] {
        func supported(_ feature: WineEngineFeature) -> WineEngineFeatureStatus {
            WineEngineFeatureStatus(feature: feature, state: .supported)
        }
        var statuses = WineEngineFeature.allCases.map(supported)
        if !Wine.isDXMTRuntimeNative() {
            statuses[WineEngineFeature.dxmt.index] = WineEngineFeatureStatus(
                feature: .dxmt, state: .unavailable,
                reason: "The managed runtime has no usable DXMT payload"
            )
        }
        if !WhiskyWineInstaller.isGDICoreMLInstalled() {
            statuses[WineEngineFeature.gdiCoreML.index] = WineEngineFeatureStatus(
                feature: .gdiCoreML, state: .unavailable,
                reason: "The managed runtime has no Core ML upscaler payload"
            )
        }
        return statuses
    }

    /// External engines never report a feature `supported`: files in the tree
    /// prove nothing about the engine build actually honouring a feature
    /// (D3DMetal additionally needs Wine's personality-unwind patch, patch
    /// features need the patch — none of it is verifiable statically).
    /// Complete physical prerequisites make a feature `unverified` and
    /// confirmable; missing or incomplete prerequisites make it `unavailable`
    /// and unconfirmable.
    private func externalUnavailable(
        _ feature: WineEngineFeature, _ reason: String
    ) -> WineEngineFeatureStatus {
        WineEngineFeatureStatus(feature: feature, state: .unavailable, reason: reason)
    }

    private func externalUnverified(
        _ feature: WineEngineFeature, _ reason: String? = nil
    ) -> WineEngineFeatureStatus {
        WineEngineFeatureStatus(
            feature: feature, state: .unverified,
            reason: reason
                ?? "This external engine has not been verified to support this feature",
            canOverride: true
        )
    }

    private func payloadBound(
        _ feature: WineEngineFeature, _ payload: Payload, _ payloadName: String
    ) -> WineEngineFeatureStatus {
        payloadComplete(payload)
            ? externalUnverified(
                feature,
                "The engine carries a \(payloadName) payload but "
                    + "support has not been verified — confirm to attempt it"
            )
            : externalUnavailable(feature, "The engine tree has no complete \(payloadName) payload")
    }

    /// A feature that only means something when a payload-backed parent
    /// feature exists (D3DMetal-path options, MoltenVK tweaks, DXVK async).
    private func dependent(
        _ feature: WineEngineFeature, on payload: Payload, _ payloadName: String
    ) -> WineEngineFeatureStatus {
        payloadComplete(payload)
            ? externalUnverified(
                feature,
                "Requires \(payloadName); support has not "
                    + "been verified — confirm to attempt it"
            )
            : externalUnavailable(
                feature,
                "Requires a \(payloadName) payload the engine "
                    + "tree does not carry"
            )
    }

    private func externalFeatureStatuses() -> [WineEngineFeatureStatus] {
        let dxvkStatus = payloadBound(.dxvk, .dxvk, "DXVK")
        return [
            dxvkStatus,
            payloadBound(.dxmt, .dxmt, "DXMT"),
            payloadBound(.d3dMetal, .d3dMetal, "D3DMetal"),
            externalUnverified(.esync),
            externalUnverified(.msync),
            externalUnverified(.avx),
            externalUnverified(.gdiUpscaling),
            payloadBound(.gdiCoreML, .gdiCoreML, "Core ML upscaler"),
            // Metal HUD/trace/validation are generic Metal runtime toggles —
            // DXMT drives Metal too — so `.metal` is not bound to the
            // D3DMetal payload. The D3DMetal-specific fields that share the
            // gate (`D3DM_MTL4`, `D3DM_SUPPORT_DXR`) still require D3DMetal
            // approval at the environment layer.
            externalUnverified(.metal),
            dependent(.metalFX, on: .d3dMetal, "D3DMetal"),
            dependent(.frameGeneration, on: .d3dMetal, "D3DMetal"),
            dependent(.shadowImportedHostMemory, on: .dxvk, "DXVK"),
            dxvkStatus.state == .unverified
                ? externalUnverified(.dxvkAsync)
                : externalUnavailable(.dxvkAsync, "Requires a DXVK payload in the engine tree")
        ]
    }
}

private extension WineEngineFeature {
    /// Position inside ``WineEngineFeature/allCases``; used to patch managed statuses.
    var index: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}
