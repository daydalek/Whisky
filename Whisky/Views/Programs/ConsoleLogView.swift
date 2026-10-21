//
//  ConsoleLogView.swift
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

import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

/// Displays console log output for a specific run with channel filtering and export actions.
///
/// Log lines are classified into channels: output (stdout), stderr, and WINEDEBUG.
/// Users can toggle visibility of each channel, copy/export filtered content, and
/// open the logs folder. For running processes, the view polls for new content.
struct ConsoleLogView: View {
    let runEntry: RunLogEntry
    let bottle: Bottle

    @State private var logLines: [ConsoleLogLine] = []
    @State private var showOutput = true
    @State private var showStderr = true
    @State private var showWineDebug = false
    @State private var currentExitCode: Int32?
    @State private var isStillRunning: Bool = false
    @State private var filteredLogLines: [ConsoleLogLine] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            logHeader
            channelFilterBar
            logContentView
            logFooter
            actionBar
        }
        .task(id: runEntry.id) { await followLog() }
        .onChange(of: showOutput) { updateFilter() }
        .onChange(of: showStderr) { updateFilter() }
        .onChange(of: showWineDebug) { updateFilter() }
    }

    // MARK: - Header

    private var logHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(runEntry.programName)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(runEntry.startTime, style: .date)
                        + Text(" ")
                        + Text(runEntry.startTime, style: .time)
                    if let duration = runEntry.duration {
                        Text(formattedDuration(duration))
                            .foregroundStyle(.secondary)
                    } else if isStillRunning {
                        Text("console.running")
                            .foregroundStyle(.green)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isStillRunning {
                liveIndicator
            } else if let exitCode = currentExitCode {
                exitCodeBadge(exitCode)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Channel Filter Bar

    private var channelFilterBar: some View {
        HStack(spacing: 8) {
            filterToggle(
                label: String(localized: "console.log.filter.stdout"),
                isOn: $showOutput,
                color: .primary
            )
            filterToggle(
                label: String(localized: "console.log.filter.stderr"),
                isOn: $showStderr,
                color: .red
            )
            if runEntry.hasWineDebugOutput {
                filterToggle(
                    label: String(localized: "console.log.filter.winedebug"),
                    isOn: $showWineDebug,
                    color: .gray
                )
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func filterToggle(label: String, isOn: Binding<Bool>, color: Color) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isOn.wrappedValue ? color.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        isOn.wrappedValue ? color.opacity(0.4) : Color.secondary.opacity(0.2),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Log Content

    private var logContentView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filteredLines.enumerated()), id: \.offset) { index, line in
                        logLineView(line)
                            .id(index)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: 300)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onChange(of: logLines.count) {
                if isStillRunning, let lastIndex = filteredLines.indices.last {
                    proxy.scrollTo(lastIndex, anchor: .bottom)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    private func logLineView(_ line: ConsoleLogLine) -> some View {
        Text(line.text)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(colorForChannel(line.channel))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func colorForChannel(_ channel: ConsoleLogChannel) -> Color {
        switch channel {
        case .output: .primary
        case .stderr: .red
        case .wineDebug: .gray
        }
    }

    var filteredLines: [ConsoleLogLine] {
        filteredLogLines
    }

    private func updateFilter() {
        filteredLogLines = logLines.filter { line in
            switch line.channel {
            case .output: showOutput
            case .stderr: showStderr
            case .wineDebug: showWineDebug
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var logFooter: some View {
        if !isStillRunning, let exitCode = currentExitCode {
            HStack {
                Text("console.exited \(exitCode)")
                    .font(.caption)
                    .foregroundStyle(exitCode == 0 ? .green : .red)
                Spacer()
                Text("\(filteredLines.count) / \(logLines.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                copyToClipboard()
            } label: {
                Label("console.log.copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .font(.caption)

            Button {
                exportToFile()
            } label: {
                Label("console.log.export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .font(.caption)

            Button {
                NSWorkspace.shared.open(Wine.logsFolder)
            } label: {
                Label("console.openLogsFolder", systemImage: "folder")
            }
            .buttonStyle(.plain)
            .font(.caption)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Shared Components

    private var liveIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
                .modifier(ConsoleLogPulseModifier())
            Text("console.log.liveIndicator")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private func exitCodeBadge(_ exitCode: Int32) -> some View {
        Text("console.exitCode \(exitCode)")
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(exitCode == 0 ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
            )
            .foregroundStyle(exitCode == 0 ? .green : .red)
    }
}

// MARK: - ConsoleLogView Data Operations

extension ConsoleLogView {
    func formattedDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    func followLog() async {
        let reader = ConsoleLogReader(url: Wine.logsFolder.appending(path: runEntry.logFileName))
        let entry = runEntry
        let bottleURL = bottle.url
        isStillRunning = entry.isRunning
        currentExitCode = entry.exitCode
        logLines = []
        var hadPartial = false
        var previousPartial: ConsoleLogLine?
        while !Task.isCancelled {
            do {
                let batch = try await reader.read()
                guard !Task.isCancelled else { return }
                apply(batch, hadPartial: &hadPartial, previousPartial: &previousPartial)
                if batch.hasMore {
                    await Task.yield()
                    continue
                }
                // A quiet log still checks the run's exit status.
                let latest = await Task.detached(priority: .utility) {
                    RunLogStore.load(for: entry.programName, in: bottleURL).entries.first { $0.id == entry.id }
                }.value
                guard !Task.isCancelled else { return }
                if let latest {
                    isStillRunning = latest.isRunning
                    currentExitCode = latest.exitCode
                }
                if !isStillRunning {
                    return
                }
                try await Task.sleep(for: .seconds(1))
            } catch is CancellationError { return } catch {
                logLines = [ConsoleLogLine(text: String(localized: "console.log.loadError"), channel: .stderr)]
                updateFilter()
                return
            }
        }
    }

    private func apply(
        _ batch: ConsoleLogReader.Batch,
        hadPartial: inout Bool,
        previousPartial: inout ConsoleLogLine?
    ) {
        if batch.reset || !batch.lines.isEmpty || batch.partial != previousPartial {
            if batch.reset {
                logLines.removeAll()
                hadPartial = false
            }
            if hadPartial, !logLines.isEmpty {
                logLines.removeLast()
            }
            logLines.append(contentsOf: batch.lines)
            if let partial = batch.partial {
                logLines.append(partial)
            }
            hadPartial = batch.partial != nil
            previousPartial = batch.partial
            updateFilter()
        }
    }

    func copyToClipboard() {
        let text = filteredLines.map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportToFile() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        let dateFormatter = ISO8601DateFormatter()
        let dateString = dateFormatter.string(from: runEntry.startTime)
        savePanel.nameFieldStringValue = "\(runEntry.programName)-\(dateString).log"

        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                var exportContent = filteredLines.map(\.text).joined(separator: "\n")
                if runEntry.hasWineDebugOutput, !showWineDebug {
                    let debugLines = logLines
                        .filter { $0.channel == .wineDebug }
                        .map(\.text)
                    if !debugLines.isEmpty {
                        exportContent += "\n\n--- WINEDEBUG Output ---\n"
                        exportContent += debugLines.joined(separator: "\n")
                    }
                }
                try exportContent.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // Best-effort export
            }
        }
    }
}
