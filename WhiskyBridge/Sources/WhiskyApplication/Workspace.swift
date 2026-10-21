//
//  Workspace.swift
//  WhiskyCore
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
import WhiskyBridgeProtocol
import WhiskyCore
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public struct HostFileLock: ActivityFileLocking {
    public init() {}
    public func withExclusiveLock<T>(at url: URL, operation: () throws -> T) throws -> T {
        #if os(macOS) || os(Linux)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
        #else
        throw BridgeFailure("unsupported_platform", "Host file locking requires a platform adapter")
        #endif
    }
}

public enum HostPaths {
    /// The data identity stays fixed as the frontend's bundle identity changes.
    public static func registry(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        #if os(macOS)
        return home.appendingPathComponent("Library/Containers/com.franke.Whisky/BottleVM.plist")
        #else
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".config")
        return base.appendingPathComponent("whisky/BottleVM.plist")
        #endif
    }
}

public struct ContainerRecord: Codable, Sendable {
    public let path: String
    public let name: String
    public let available: Bool
}

public struct EntryRecord: Codable, Sendable {
    public let id: String
    public let name: String
    public let container: String
    public let source: String
    public let executable: String?
    public let steamAppID: Int?
    public let icon: String?
    public let hidden: Bool
    public let metadata: GameMetadata?
    public let activity: GameActivity
    public let cover: String?
    public let coverAspectRatio: Double?
    public init(_ entry: LibraryEntry, visibility: LibraryVisibility) throws {
        let presentation = try LibraryPresentation.load(for: entry)
        id = entry.id
        name = entry.name
        container = entry.bottleURL.path
        source = entry.source.rawValue
        switch entry.launch {
        case let .program(url): executable = url.path
            steamAppID = nil
        case let .steam(appID): executable = nil
            steamAppID = appID
        }
        icon = entry.iconURL?.path
        hidden = !visibility.includes(entry)
        metadata = presentation.metadata
        activity = presentation.activity
        cover = presentation.coverURL?.path
        coverAspectRatio = presentation.coverAspectRatio
    }
}

public final class ApplicationWorkspace: Sendable {
    public let registry: URL
    public let explicitContainers: [URL]
    public init(registry: URL = HostPaths.registry(), containers: [URL] = []) {
        self.registry = registry
        explicitContainers = containers
    }

    public static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16 * 1_024 * 1_024 + 1) ?? Data()
        guard data.count <= 16 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    public func containers() throws -> [URL] {
        struct Registry: Decodable { let paths: [URL] }
        let roots: [URL] = if !explicitContainers.isEmpty {
            explicitContainers
        } else if FileManager.default.fileExists(atPath: registry.path) {
            try PropertyListDecoder().decode(Registry.self, from: Self.read(registry)).paths
        } else {
            []
        }
        var seen = Set<String>()
        return roots.filter(\.isFileURL).map(\.standardizedFileURL)
            .filter { seen.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
    }

    public func resolve(_ params: [String: JSONValue]) throws -> URL {
        let target = try params.path("container").resolvingSymlinksInPath().standardizedFileURL
        guard let registered = try containers().first(where: {
            $0.resolvingSymlinksInPath().standardizedFileURL.path == target.path
        })
        else {
            throw BridgeFailure("unknown_container", "Container is outside this workspace")
        }
        guard try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw BridgeFailure("container_unavailable", "Container directory is unavailable", retryable: true)
        }
        return registered
    }

    public func catalogue() throws -> [ContainerRecord] {
        struct Metadata: Decodable { struct Info: Decodable { let name: String }
            let info: Info
        }
        return try containers().map { url in
            let available = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let metadata = url.appendingPathComponent("Metadata.plist")
            let name: String = if available, FileManager.default.fileExists(atPath: metadata.path) {
                try PropertyListDecoder().decode(Metadata.self, from: Self.read(metadata)).info.name
            } else {
                url.lastPathComponent
            }
            return ContainerRecord(path: url.path, name: name, available: available)
        }
    }

    public func entries(in container: URL) async throws -> [LibraryEntry] {
        let configuration = ConfigurationFile(
            url: container.appendingPathComponent("Metadata.plist"),
            locking: HostFileLock()
        )
        let pins = try await configuration.pinnedPrograms().map { $0.entry(in: container) }
        let steam = SteamLibrarySource.entries(inBottleAt: container)
        let excluded = SteamLibrary.enumerate(bottleURL: container).map(\.installURL)
            + [SteamLibrary.detectInstall(bottleURL: container)].compactMap { $0 }
        let folders = try FolderGameLibrary.load(bottleURL: container)
        return LibraryDiscovery.scan(
            in: container,
            folders: folders,
            additionalEntries: pins + steam,
            excluding: excluded
        ).entries
    }

    public func entry(_ params: [String: JSONValue]) async throws -> LibraryEntry {
        let container = try resolve(params)
        let id = try params.text("entryID")
        guard let entry = try await entries(in: container).first(where: { $0.id == id }) else {
            throw BridgeFailure("unknown_entry", "Library entry is unavailable", retryable: true)
        }
        return entry
    }

    public func setRating(_ rating: Int?, entry: LibraryEntry) throws -> GameActivity {
        let url = LibraryStorageLayout.activity(for: entry)
        return try HostFileLock().withExclusiveLock(at: url.deletingPathExtension().appendingPathExtension("lock")) {
            var activity = FileManager.default.fileExists(atPath: url.path)
                ? try JSONDecoder().decode(GameActivity.self, from: Self.read(url)) : GameActivity()
            try activity.setRating(rating)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(activity).write(to: url, options: .atomic)
            return activity
        }
    }

    public func setHidden(_ hidden: Bool, entry: LibraryEntry) throws -> LibraryVisibility {
        try HostFileLock()
            .withExclusiveLock(at: entry.bottleURL.appendingPathComponent("Library Visibility.json.lock")) {
                var visibility = try LibraryVisibility.load(bottleURL: entry.bottleURL)
                visibility.setHidden(hidden, for: entry)
                try visibility.save(bottleURL: entry.bottleURL)
                return visibility
            }
    }
}
