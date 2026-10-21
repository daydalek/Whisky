//
//  ConsoleLogReader.swift
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

public enum ConsoleLogChannel: Sendable {
    case output, stderr, wineDebug
}

public struct ConsoleLogLine: Equatable, Sendable {
    public let text: String
    public let channel: ConsoleLogChannel
    public init(text: String, channel: ConsoleLogChannel) {
        self.text = text
        self.channel = channel
    }
}

/// Bounded file reads, UTF-8 fragments and classification stay on this actor.
public actor ConsoleLogReader {
    public struct Batch: Sendable {
        public let lines: [ConsoleLogLine]
        public let partial: ConsoleLogLine?
        public let reset: Bool
        public let hasMore: Bool
    }

    private let url: URL
    private var offset: UInt64 = 0
    private var identity: UInt64?
    private var pending = Data()

    public init(url: URL) {
        self.url = url
    }

    public func read(maxBytes: Int = 262_144) throws -> Batch {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let reset = offset > size || (identity != nil && identity != inode)
        if reset {
            offset = 0
            pending.removeAll(keepingCapacity: true)
        }
        identity = inode
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: max(1, maxBytes)) ?? Data()
        offset += UInt64(data.count)
        pending.append(data)
        let hasMore = offset < size
        var lines: [ConsoleLogLine] = []
        if let boundary = pending.lastIndex(where: { $0 == 10 || $0 == 13 }) {
            let end = pending.index(after: boundary)
            // Preserve readable output when a process writes mixed encodings.
            // swiftlint:disable:next optional_data_string_conversion
            lines = Self.classify(String(decoding: pending[..<end], as: UTF8.self))
            pending = Data(pending[end...])
        }
        // A provisional final row becomes a complete row when the next newline arrives.
        let partial = !hasMore && !pending.isEmpty ? String(data: pending, encoding: .utf8).map(Self.classify) : nil
        if let partial, partial.count > 1 {
            lines.append(contentsOf: partial.dropLast())
            let text = partial.last?.text ?? ""
            pending = Data(text.utf8)
        }
        return Batch(lines: lines, partial: partial?.last, reset: reset, hasMore: hasMore)
    }

    public nonisolated static func classify(_ text: String) -> [ConsoleLogLine] {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { line in
            let channel: ConsoleLogChannel
            if isWineDebug(line) {
                channel = .wineDebug
            } else {
                let indicators = ["Error:", "error:", "FAILED", "fatal:", "FATAL:", "Exception:"]
                channel = indicators.contains(where: { line.contains($0) }) ? .stderr : .output
            }
            return ConsoleLogLine(text: line, channel: channel)
        }
    }

    private nonisolated static func isWineDebug(_ line: String) -> Bool {
        if ["wine:", "fixme:", "err:", "trace:", "warn:"].contains(where: { line.hasPrefix($0) }) {
            return true
        }
        var bytes = line.utf8.makeIterator()
        for _ in 0 ..< 4 {
            guard let byte = bytes.next(),
                  (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
            else { return false }
        }
        return bytes.next() == 58
    }
}
