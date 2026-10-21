//
//  check-portability-boundaries.swift
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

import Foundation

// Pass the output of swift package dump-package --package-path WhiskyCore.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let sources = root.appendingPathComponent("WhiskyCore/Sources")
var issues: [String] = []
let pattern = #"^\s*(?:(?:@\w+(?:\([^)]*\))?|public|internal|package)\s+)*import\s+"#
    + #"(?:(?:struct|class|enum|func|let|var|protocol|typealias)\s+)?(\w+)"#

do {
    guard CommandLine.arguments.count == 2 else {
        throw NSError(domain: "PortabilityBoundaryCheck", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Pass the path to the WhiskyCore package manifest JSON."
        ])
    }
    let manifestData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
          let dependencies = manifest["dependencies"] as? [Any]
    else { throw CocoaError(.fileReadCorruptFile) }
    if !dependencies.isEmpty {
        issues.append("WhiskyCore declares external package dependencies.")
    }
    let imports = try NSRegularExpression(pattern: pattern)
    guard let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
        throw CocoaError(.fileReadNoSuchFile)
    }
    var count = 0
    for case let file as URL in enumerator where file.pathExtension == "swift" {
        count += 1
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            guard let match = imports.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line)
            else { continue }
            let module = String(line[range])
            if !["Foundation", "Swift", "_Concurrency"].contains(module) {
                issues.append("\(file.path):\(index + 1): shared core imports \(module).")
            }
        }
    }
    if count == 0 {
        issues.append("WhiskyCore source inventory is empty.")
    }
    if issues.isEmpty {
        print("Portability boundaries verified: \(count) shared source files; Foundation and Swift standard library.")
    }
} catch {
    issues.append(error.localizedDescription)
}

if !issues.isEmpty {
    FileHandle.standardError.write(Data((issues.joined(separator: "\n") + "\n").utf8))
    exit(1)
}
