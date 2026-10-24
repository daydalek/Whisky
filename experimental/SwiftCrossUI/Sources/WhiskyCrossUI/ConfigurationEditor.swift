//
//  ConfigurationEditor.swift
//  WhiskyCrossUI
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
import SwiftCrossUI
import WhiskyCore

struct ConfigurationEditor: View {
    let file: ConfigurationFile
    let sections: [ConfigurationSection]
    var refreshID = 0
    var beforeSave: @MainActor (ConfigurationField, ConfigurationValue, [String: ConfigurationValue]) async throws
        -> Void = { _, _, _ in }
    var changed: @MainActor () async -> Void = {}
    @State private var values: [String: ConfigurationValue] = [:]
    @State private var expanded: Set<String> = ["wine", "performance", "program"]
    @State private var busy = false
    @State private var loaded = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !message.isEmpty {
                Text(message).foregroundColor(WhiskyStyle.secondary)
            }
            if loaded {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        WorkspaceButton("\(expanded.contains(section.id) ? "⌄" : "›")  \(section.title)") {
                            if expanded.contains(section.id) {
                                expanded.remove(section.id)
                            } else {
                                expanded.insert(section.id)
                            }
                        }
                        .buttonStyle(.plain).font(.system(size: 14, weight: .semibold))
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        if expanded.contains(section.id) {
                            ForEach(section.fields) { field in
                                Color.gray.opacity(0.15).frame(height: 1)
                                ConfigurationControl(
                                    field: field,
                                    value: values[field.id] ?? field.defaultValue
                                ) { value in
                                    guard values[field.id] != value else { return }
                                    values[field.id] = value
                                    Task { await save(field, value: value) }
                                }.disabled(busy).padding(14)
                            }
                        }
                    }.background(WhiskyStyle.surface).cornerRadius(10)
                }
            } else {
                Text("正在读取配置…")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: refreshID) {
            do { values = try await file.values(for: sections.flatMap(\.fields))
                loaded = true
            } catch { message = error.localizedDescription }
        }
    }

    private func save(_ field: ConfigurationField, value: ConfigurationValue) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try field.validate(value)
            let current = try await file.values(for: sections.flatMap(\.fields))
            guard current[field.id] != value else { return }
            try await beforeSave(field, value, current)
            try await file.update(field, to: value)
            values = try await file.values(for: sections.flatMap(\.fields))
            message = "已保存：\(field.title)"
            await changed()
        } catch {
            message = "保存失败：\(error.localizedDescription)"
            if let actual = try? await file.values(for: sections.flatMap(\.fields)) {
                values = actual
            }
        }
    }
}

private struct ConfigurationControl: View {
    let field: ConfigurationField
    let value: ConfigurationValue
    let save: @MainActor @Sendable (ConfigurationValue) -> Void
    @State private var draft = ""
    @State private var editing = false

    var body: some View {
        HStack(spacing: 16) {
            Text(field.title).frame(maxWidth: .infinity, alignment: .leading)
            switch field.input {
            case .toggle:
                Toggle("", isOn: Binding(get: { value == .boolean(true) }, set: { save(.boolean($0)) }))
                    .toggleStyle(.switch)
            case let .choice(options):
                Picker(of: options, selection: Binding<ConfigurationChoice?>(
                    get: { options.first { value == .text($0.id) } },
                    set: {
                        if let choice = $0 {
                            save(.text(choice.id))
                        }
                    }
                )).pickerStyle(.menu).frame(width: 230)
            case .text, .number:
                TextField(field.title, text: Binding(get: { editing ? draft : textValue }, set: { draft = $0
                    editing = true
                }))
                .frame(width: 230)
                WhiskyAction("保存") {
                    switch field.input {
                    case .number:
                        let text = editing ? draft : textValue
                        save(Int(text).map(ConfigurationValue.integer) ?? .text(text))
                        editing = false
                    default: save(.text(editing ? draft : textValue))
                        editing = false
                    }
                }
            }
        }
    }

    private var textValue: String {
        switch value {
        case let .text(text): text
        case let .integer(number): String(number)
        case let .boolean(flag): String(flag)
        }
    }
}

struct ContainerConfigurationView: View {
    let container: WorkspaceContainer
    let refreshID: Int
    let changed: @MainActor () async -> Void
    var body: some View {
        ScrollView {
            ConfigurationEditor(
                file: ConfigurationFile(
                    url: container.url.appendingPathComponent("Metadata.plist"),
                    locking: WorkspaceFileLock()
                ),
                sections: ContainerConfiguration.sections,
                refreshID: refreshID,
                beforeSave: { field, value, current in
                    try await WorkspaceHost.applyConfiguration(
                        field,
                        value: value,
                        values: current,
                        container: container.url
                    )
                },
                changed: { WorkspaceHost.invalidate(container.url)
                    await changed()
                }
            ).padding(24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
