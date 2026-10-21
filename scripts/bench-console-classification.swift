//
//  bench-console-classification.swift
//  Whisky
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

// Standalone research benchmark. Compile with swiftc -O; see docs/animation-performance-research.md.
import Foundation

enum ConsoleLogChannel: Equatable { case output, stderr, wineDebug }
struct ConsoleLogLine: Equatable { let text: String
    let channel: ConsoleLogChannel
}

let wineDebugPatterns: [String] = [
    "^[0-9a-f]{4}:",
    "^wine:",
    "^fixme:",
    "^err:",
    "^trace:",
    "^warn:"
]
func classifyLines(_ content: String) -> [ConsoleLogLine] {
    content
        .components(separatedBy: .newlines)
        .filter { !$0.isEmpty }
        .map { line in
            if isWineDebugLine(line) {
                ConsoleLogLine(text: line, channel: .wineDebug)
            } else if isStderrLine(line) {
                ConsoleLogLine(text: line, channel: .stderr)
            } else {
                ConsoleLogLine(text: line, channel: .output)
            }
        }
}

func isWineDebugLine(_ line: String) -> Bool {
    wineDebugPatterns.contains { pattern in
        line.range(of: pattern, options: .regularExpression) != nil
    }
}

func isStderrLine(_ line: String) -> Bool {
    let stderrIndicators = ["Error:", "error:", "FAILED", "fatal:", "FATAL:", "Exception:"]
    return stderrIndicators.contains(where: { line.contains($0) })
}

let compiled = try wineDebugPatterns.map { try NSRegularExpression(pattern: $0) }
func cachedClassify(_ content: String) -> [ConsoleLogLine] {
    content.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { line in
        let range = NSRange(location: 0, length: line.utf16.count)
        if compiled.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
            return ConsoleLogLine(text: line, channel: .wineDebug)
        }
        return ConsoleLogLine(text: line, channel: isStderrLine(line) ? .stderr : .output)
    }
}

let prefixes = ["wine:", "fixme:", "err:", "trace:", "warn:"]
func prefixWineDebug(_ line: String) -> Bool {
    if prefixes.contains(where: { line.hasPrefix($0) }) {
        return true
    }
    var iterator = line.utf8.makeIterator()
    for _ in 0 ..< 4 {
        guard let byte = iterator.next(),
              (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        else { return false }
    }
    return iterator.next() == 58
}

func prefixClassify(_ content: String) -> [ConsoleLogLine] {
    content.components(separatedBy: .newlines).filter { !$0.isEmpty }.map { line in
        ConsoleLogLine(
            text: line,
            channel: prefixWineDebug(line) ? .wineDebug : (isStderrLine(line) ? .stderr : .output)
        )
    }
}

let edgeCases = [
    "",
    "abc:",
    "abcd:",
    "ABCd:",
    "0123:",
    "0123X:",
    "warn:",
    "warning:",
    " err:",
    "wine:",
    "wines:",
    "日本語",
    "😀abc:",
    "0000:",
    "ffff:",
    "fffG:",
    "00000:"
]
for line in edgeCases {
    precondition(isWineDebugLine(line) == prefixWineDebug(line))
}

var checksum = 0
for count in [10_000, 50_000] {
    let content = (0 ..< count).map { index in
        switch index % 8 {
        case 0: "00af:fixme:d3d:sample frame \(index)"
        case 1: "wine: graphics status \(index)"
        case 2: "Error: resource failed \(index)"
        default: "Game output resource loaded \(index) 日本語 中文"
        }
    }.joined(separator: "\n")
    precondition(classifyLines(content) == cachedClassify(content))
    precondition(classifyLines(content) == prefixClassify(content))
    for (name, operation) in [
        ("current", classifyLines),
        ("precompiled_regex", cachedClassify),
        ("direct_prefix", prefixClassify)
    ] {
        var times: [Double] = []
        for _ in 0 ..< 3 {
            let begin = DispatchTime.now().uptimeNanoseconds
            let lines = operation(content)
            checksum &+= lines.count
            times.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000)
        }
        times.sort()
        print(
            "lines=\(count) bytes=\(content.utf8.count) mode=\(name) median_ms=\(String(format: "%.2f", times[1]))",
            terminator: "\n"
        )
    }
}

print("checksum=\(checksum)")
