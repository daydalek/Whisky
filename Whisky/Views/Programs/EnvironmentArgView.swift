//
//  EnvironmentArgView.swift
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
import WhiskyKit

enum KeySection {
    case key, value
}

enum Focusable: Hashable {
    case row(id: UUID, section: KeySection)
}

class Key: ObservableObject, Identifiable {
    static func == (lhs: Key, rhs: Key) -> Bool {
        lhs.id == rhs.id
    }

    var id: UUID = .init()
    @Published var key: String
    @Published var value: String

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

struct EnvironmentArgView: View {
    @ObservedObject var program: Program
    @Binding var isExpanded: Bool

    @FocusState var focus: Focusable?
    @State private var environmentKeys: [Key] = []
    @State private var movedToIllegalKey = false

    var body: some View {
        Section(isExpanded: $isExpanded) {
            List(environmentKeys, id: \.id) { key in
                KeyItem(
                    focus: _focus,
                    environmentKeys: $environmentKeys,
                    key: key,
                    onChange: persistEnvironment
                )
            }
            .alternatingRowBackgrounds(.enabled)
            .onAppear {
                loadEnvironment()
            }
            .onChange(of: program.settings.environment) {
                if currentEnvironment != program.settings.environment {
                    loadEnvironment()
                }
            }
            .onChange(of: environmentKeys.map(\.id)) {
                persistEnvironment()
            }
        } header: {
            HStack {
                Text("program.env").frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                Button("environment.add", systemImage: "plus") {
                    createNewKey()
                }
                .buttonStyle(.plain)
                .labelStyle(.titleAndIcon)
                .opacity(isExpanded ? 1 : 0)
            }
        }
        .onChange(of: focus) { oldValue, newValue in
            switch oldValue {
            case let .row(id, section):
                if let key = environmentKeys.first(where: { $0.id == id }) {
                    switch newValue {
                    case let .row(newId, _):
                        // Remove empty keys
                        if key.key.isEmpty, newId != id {
                            environmentKeys.removeAll(where: { $0.id == key.id })
                            focus = nil
                            return
                        }
                    case .none: break
                    }

                    // A key with this value already exists, so its invalid
                    if environmentKeys.contains(where: { $0.key == key.key && $0.id != key.id }), !movedToIllegalKey {
                        movedToIllegalKey = true
                        focus = .row(id: key.id, section: .key)
                        return
                    }

                    movedToIllegalKey = false

                    if newValue == nil, section == .value {
                        // Value has been submitted, move ot next row
                        if var index = environmentKeys.firstIndex(where: { $0.id == id }) {
                            index += 1
                            if index >= environmentKeys.endIndex {
                                index = 0
                            }

                            let nextKey = environmentKeys[index]
                            focus = .row(id: nextKey.id, section: .key)
                        }
                    }
                }
            case .none: break
            }
        }
    }

    private var currentEnvironment: [String: String] {
        var environment: [String: String] = [:]
        for key in environmentKeys where !key.key.isEmpty {
            environment[key.key] = key.value
        }
        return environment
    }

    private func loadEnvironment() {
        environmentKeys = program.settings.environment.sorted { $0.key < $1.key }.map {
            Key(key: $0.key, value: $0.value)
        }
    }

    private func persistEnvironment() {
        if program.settings.environment != currentEnvironment {
            program.settings.environment = currentEnvironment
        }
    }

    func createNewKey() {
        if let key = environmentKeys.first(where: { $0.key.isEmpty }) {
            focus = .row(id: key.id, section: .key)
            return
        }

        let key = Key(key: "", value: "")
        environmentKeys.append(key)
        focus = .row(id: key.id, section: .key)
    }
}

struct KeyItem: View {
    @FocusState var focus: Focusable?
    @Binding var environmentKeys: [Key]
    @ObservedObject var key: Key
    var onChange: () -> Void
    @State var hovered: Bool = false

    var body: some View {
        HStack {
            TextField(String(), text: $key.key)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(maxHeight: .infinity)
                .focused($focus, equals: .row(id: key.id, section: .key))
                .onChange(of: key.key) {
                    key.key = key.key.trimmingCharacters(in: .whitespacesAndNewlines)
                    onChange()
                }
                .onSubmit {
                    // Try to move on to value
                    focus = .row(id: key.id, section: .value)
                }
            TextField(String(), text: $key.value)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(maxHeight: .infinity)
                .focused($focus, equals: .row(id: key.id, section: .value))
                .onChange(of: key.value) {
                    onChange()
                }
            Button {
                environmentKeys.removeAll(where: { $0.id == key.id })
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .help("environment.remove")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovered ? 1 : 0)
        }
        .padding(.vertical, 4)
        .onHover { hover in
            hovered = hover
        }
    }
}

struct ProgramEnvironmentPresetsView: View {
    @ObservedObject var program: Program

    var body: some View {
        Section("program.env.presets") {
            VStack(alignment: .leading, spacing: 8) {
                Text("program.env.presets.locale")
                HStack {
                    ForEach([Locales.japanese, .chineseSimplified, .chineseTraditional, .auto], id: \.self) { locale in
                        Button {
                            program.settings.applyLocalePreset(locale)
                        } label: {
                            Label(
                                locale.pretty(),
                                systemImage: localeSelected(locale) ? "checkmark.circle.fill" : "circle"
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("program.env.presets.renderer")
                HStack {
                    ForEach(WineD3DRenderer.allCases, id: \.self) { renderer in
                        Button {
                            program.settings.applyWineD3DRenderer(renderer)
                        } label: {
                            Label(
                                rendererLabel(renderer),
                                systemImage:
                                program.settings.wineD3DRenderer == renderer ? "checkmark.circle.fill" : "circle"
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Text("program.env.presets.renderer.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("program.env.presets.help")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func localeSelected(_ locale: Locales) -> Bool {
        if locale == .auto {
            return program.settings.locale == .auto
                && program.settings.environment["LANG"] == nil
                && program.settings.environment["LC_ALL"] == nil
        }
        return program.settings.locale == locale
            && program.settings.environment["LANG"] == locale.rawValue
            && program.settings.environment["LC_ALL"] == locale.rawValue
    }

    private func rendererLabel(_ renderer: WineD3DRenderer) -> String {
        switch renderer {
        case .automatic: String(localized: "program.env.presets.renderer.default")
        case .gdi: String(localized: "program.env.presets.renderer.gdi")
        case .openGL: "OpenGL"
        case .vulkan: "Vulkan"
        }
    }
}
