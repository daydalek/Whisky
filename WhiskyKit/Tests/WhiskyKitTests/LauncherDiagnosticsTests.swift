//
//  LauncherDiagnosticsTests.swift
//  WhiskyKitTests
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

@testable import WhiskyKit
import XCTest

// swiftlint:disable file_length type_body_length
// Comprehensive test suite for diagnostics requires extensive test methods

/// Tests for diagnostic report generation and validation.
///
/// These tests ensure the diagnostics system doesn't crash with unexpected
/// bottle configurations and produces valid output for troubleshooting.
@MainActor
final class LauncherDiagnosticsTests: XCTestCase {
    // MARK: - Bottle Configuration Tests

    func testDiagnosticsWithDefaultBottleSettings() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)

        // Should not crash with default settings
        let settings = bottle.settings
        XCTAssertNotNil(settings, "Bottle should have valid settings")

        // Verify key default values
        XCTAssertEqual(settings.name, "Bottle")
        XCTAssertFalse(settings.launcherCompatibilityMode)
        XCTAssertEqual(settings.launcherMode, .auto)
        XCTAssertNil(settings.detectedLauncher)
    }

    func testDiagnosticsWithLauncherCompatibilityEnabled() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = true
        bottle.settings.detectedLauncher = .steam
        bottle.settings.launcherLocale = .english
        bottle.settings.gpuSpoofing = true

        // Should handle launcher-enabled configuration
        XCTAssertTrue(bottle.settings.launcherCompatibilityMode)
        XCTAssertEqual(bottle.settings.detectedLauncher, .steam)
    }

    func testDiagnosticsWithAllLauncherTypes() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)

        // Test that settings accept all launcher types without crashing
        for launcher in LauncherType.allCases {
            bottle.settings.detectedLauncher = launcher
            XCTAssertEqual(bottle.settings.detectedLauncher, launcher)

            // Verify launcher-specific properties
            XCTAssertNotNil(launcher.environmentOverrides())
            XCTAssertNotNil(launcher.recommendedLocale)
            XCTAssertFalse(launcher.fixesDescription.isEmpty)
        }
    }

    // MARK: - Environment Variable Tests

    func testEnvironmentVariablesWithLauncherCompatibility() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = true
        bottle.settings.detectedLauncher = .steam
        bottle.settings.launcherLocale = .english
        bottle.settings.gpuSpoofing = true
        bottle.settings.networkTimeout = 90_000

        var env: [String: String] = [:]
        bottle.settings.environmentVariables(wineEnv: &env)

        // Verify launcher-specific variables are set
        XCTAssertNotNil(env["STEAM_DISABLE_CEF_SANDBOX"])
        XCTAssertNotNil(env["LC_ALL"])
        XCTAssertNotNil(env["MESA_GL_VERSION_OVERRIDE"])
        XCTAssertNil(env["WINHTTP_CONNECT_TIMEOUT"])
    }

    func testEnvironmentVariablesWithoutLauncherCompatibility() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = false

        var env: [String: String] = [:]
        bottle.settings.environmentVariables(wineEnv: &env)

        // Launcher-specific variables should not be set
        XCTAssertNil(env["STEAM_DISABLE_CEF_SANDBOX"])
        // GPU spoofing should not be applied if launcher compat is off
    }

    // MARK: - Edge Cases and Error Handling

    func testDiagnosticsWithNilLauncher() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = true
        bottle.settings.detectedLauncher = nil // No launcher detected

        var env: [String: String] = [:]
        bottle.settings.environmentVariables(wineEnv: &env)

        // Should handle nil launcher gracefully without crashing
        XCTAssertTrue(true, "Should not crash with nil launcher")
    }

    func testDiagnosticsWithAllGPUVendors() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = true
        bottle.settings.gpuSpoofing = true

        // Test all GPU vendor configurations
        for vendor in GPUVendor.allCases {
            bottle.settings.gpuVendor = vendor

            var env: [String: String] = [:]
            bottle.settings.environmentVariables(wineEnv: &env)

            // Verify GPU spoofing is applied for each vendor
            XCTAssertEqual(env["MESA_GL_VERSION_OVERRIDE"], "4.6", "Spoof should apply for \(vendor.rawValue)")
            XCTAssertNil(env["GPU_VENDOR_ID"], "No shipped runtime reads GPU_VENDOR_ID")
        }
    }

    // MARK: - Settings Persistence Tests

    func testLauncherSettingsPersistence() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)

        // Configure launcher settings
        bottle.settings.launcherCompatibilityMode = true
        bottle.settings.launcherMode = .manual
        bottle.settings.detectedLauncher = .rockstar
        bottle.settings.launcherLocale = .english
        bottle.settings.gpuSpoofing = true
        bottle.settings.gpuVendor = .nvidia
        bottle.settings.networkTimeout = 90_000
        bottle.settings.autoEnableDXVK = true

        // Save settings
        bottle.saveBottleSettings()

        // Load settings from disk into new bottle instance
        let bottle2 = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)

        // Verify all launcher settings persisted correctly
        XCTAssertTrue(bottle2.settings.launcherCompatibilityMode)
        XCTAssertEqual(bottle2.settings.launcherMode, .manual)
        XCTAssertEqual(bottle2.settings.detectedLauncher, .rockstar)
        XCTAssertEqual(bottle2.settings.launcherLocale, .english)
        XCTAssertTrue(bottle2.settings.gpuSpoofing)
        XCTAssertEqual(bottle2.settings.gpuVendor, .nvidia)
        XCTAssertEqual(bottle2.settings.networkTimeout, 90_000)
        XCTAssertTrue(bottle2.settings.autoEnableDXVK)
    }

    func testLauncherSettingsDefaultsAfterDecode() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Create bottle with default settings
        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)

        // Verify launcher config defaults
        XCTAssertFalse(bottle.settings.launcherCompatibilityMode, "Should default to disabled")
        XCTAssertEqual(bottle.settings.launcherMode, .auto, "Should default to auto mode")
        XCTAssertNil(bottle.settings.detectedLauncher, "Should have no launcher detected")
        XCTAssertEqual(bottle.settings.launcherLocale, .auto, "Should default to auto locale")
        XCTAssertTrue(bottle.settings.gpuSpoofing, "Should default to enabled")
        XCTAssertEqual(bottle.settings.gpuVendor, .nvidia, "Should default to NVIDIA")
        XCTAssertEqual(bottle.settings.networkTimeout, 60_000, "Should default to 60 seconds")
        XCTAssertTrue(bottle.settings.autoEnableDXVK, "Should default to enabled")
    }

    // MARK: - GPU Validation Tests

    func testGPUSpoofingEnvironmentValidation() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = true
        bottle.settings.gpuSpoofing = true

        var env: [String: String] = [:]
        bottle.settings.environmentVariables(wineEnv: &env)

        // Verify GPU spoofing environment is valid
        XCTAssertTrue(
            GPUDetection.validateSpoofingEnvironment(env),
            "GPU spoofing environment should be valid"
        )
    }

    func testGPUSpoofingDisabled() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = true
        bottle.settings.gpuSpoofing = false

        var env: [String: String] = [:]
        bottle.settings.environmentVariables(wineEnv: &env)

        // GPU spoofing should not be applied
        XCTAssertNil(env["MESA_GL_VERSION_OVERRIDE"], "GPU spoof should not be set when spoofing disabled")
    }

    // MARK: - Locale Configuration Tests

    func testLocaleOverrideConfiguration() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = true
        bottle.settings.launcherLocale = .japanese

        var env: [String: String] = [:]
        bottle.settings.environmentVariables(wineEnv: &env)

        // Verify locale is properly applied
        XCTAssertEqual(env["LC_ALL"], "ja_JP.UTF-8")
        XCTAssertEqual(env["LANG"], "ja_JP.UTF-8")
        XCTAssertEqual(env["LC_TIME"], "C")
        XCTAssertEqual(env["LC_NUMERIC"], "C")
    }

    func testAutoLocaleDoesNotSetEnvironment() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = true
        bottle.settings.launcherLocale = .auto

        var env: [String: String] = [:]
        bottle.settings.environmentVariables(wineEnv: &env)

        // Auto locale should not set LC_ALL/LANG
        XCTAssertNil(env["LC_ALL"], "Auto locale should not set LC_ALL")
        XCTAssertNil(env["LANG"], "Auto locale should not set LANG")
    }

    func testAutoLocaleRawValueIsEmpty() {
        // Verify .auto has empty rawValue (defensive check)
        XCTAssertEqual(Locales.auto.rawValue, "", "Auto locale should have empty string as rawValue")

        // Verify the defensive check in environmentVariables prevents empty string assignment
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = true
        bottle.settings.launcherLocale = .auto // Empty rawValue

        var env: [String: String] = [:]
        bottle.settings.environmentVariables(wineEnv: &env)

        // Should not set LC_ALL/LANG to empty string (defensive check prevents this)
        XCTAssertNil(env["LC_ALL"], "Should not set LC_ALL to empty string")
        XCTAssertNil(env["LANG"], "Should not set LANG to empty string")
    }

    // MARK: - Network Timeout Tests

    // MARK: - Auto-Enable DXVK Tests

    func testAutoEnableDXVKForRockstar() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = true
        bottle.settings.detectedLauncher = .rockstar
        bottle.settings.autoEnableDXVK = true
        bottle.settings.dxvk = false // Explicitly disabled

        var env: [String: String] = [:]
        bottle.settings.environmentVariables(wineEnv: &env)

        // DXVK should be auto-enabled because Rockstar requires it
        // DLL overrides are now composed per-DLL via DLLOverrideResolver (sorted alphabetically).
        // No runtime under test means no GPTK payload, so d3d12 is left alone.
        XCTAssertEqual(env["WINEDLLOVERRIDES"], "d3d10core=n,b;d3d11=n,b;d3d9=n,b;dxgi=n,b")
    }

    func testAutoEnableDXVKNotTriggeredForSteam() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = true
        bottle.settings.detectedLauncher = .steam // Steam doesn't require DXVK
        bottle.settings.autoEnableDXVK = true
        bottle.settings.dxvk = false
        // Pin a builtin-backed backend: `.recommended` resolves via ambient
        // machine state and would add the DXVK preset through the bottle layer
        // on machines without a runtime. Auto-enable applies through the
        // launcher layer regardless of backend, so the assertion below still
        // catches Steam wrongly auto-enabling.
        bottle.settings.graphicsBackend = .d3dMetal

        var env: [String: String] = [:]
        bottle.settings.environmentVariables(wineEnv: &env)

        // DXVK should NOT be auto-enabled (Steam doesn't require it)
        XCTAssertNil(env["WINEDLLOVERRIDES"])
    }

    // MARK: - Launcher Requirements Tests

    func testRockstarRequiresDXVK() {
        XCTAssertTrue(LauncherType.rockstar.requiresDXVK)
        XCTAssertFalse(LauncherType.steam.requiresDXVK)
        XCTAssertFalse(LauncherType.eaApp.requiresDXVK)
    }

    func testRecommendedLocales() {
        for launcher in LauncherType.allCases {
            XCTAssertEqual(launcher.recommendedLocale, .auto, "\(launcher.rawValue)")
        }
    }

    // MARK: - Environment Merge Tests

    func testRuntimeEnvironmentKeepsBottlePrefixAndProgramOverrides() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        let env = Wine.constructWineEnvironment(for: bottle)
        let bin = WhiskyWineInstaller.binFolder
        XCTAssertEqual(env["WINEPREFIX"], tempURL.path)
        XCTAssertEqual(env["WINELOADER"], Wine.wineBinary.path)
        XCTAssertEqual(env["WINESERVER"], bin.appending(path: "wineserver").path)
        XCTAssertEqual(
            env["DYLD_FALLBACK_LIBRARY_PATH"],
            "\(bin.deletingLastPathComponent().appending(path: "lib").path):/usr/lib"
        )
        let custom = Wine.constructWineEnvironment(
            for: bottle, environment: ["DYLD_FALLBACK_LIBRARY_PATH": "/custom/runtime/lib:/usr/lib"]
        )
        XCTAssertEqual(custom["DYLD_FALLBACK_LIBRARY_PATH"], "/custom/runtime/lib:/usr/lib")
        XCTAssertEqual(custom["WINEPREFIX"], tempURL.path)
    }

    func testLauncherEnvironmentMergePrecedence() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = true
        bottle.settings.detectedLauncher = .steam

        // Use constructWineEnvironment to get full environment including macOS compat fixes
        let env = Wine.constructWineEnvironment(for: bottle, environment: [:])

        // Verify Steam-specific environment variables are merged
        XCTAssertEqual(env["STEAM_DISABLE_CEF_SANDBOX"], "1", "Steam-specific CEF disable from preset")
        XCTAssertEqual(env["CEF_DISABLE_SANDBOX"], "1", "Global CEF disable from MacOSCompatibility")
        XCTAssertEqual(env["STEAM_RUNTIME"], "0")
        XCTAssertEqual(env["DXVK_ASYNC"], "1")
    }

    // MARK: - macOS Compatibility Tests

    func testMacOSCompatibilityEnvironmentApplied() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)

        var env: [String: String] = [:]
        for (key, value) in Wine.constructWineEnvironment(for: bottle, environment: [:]) {
            env[key] = value
        }

        // CEF sandbox should be disabled on all macOS versions
        XCTAssertEqual(env["STEAM_DISABLE_CEF_SANDBOX"], "1")
        XCTAssertEqual(env["CEF_DISABLE_SANDBOX"], "1")

        // Base Wine environment should be set
        XCTAssertEqual(env["WINEPREFIX"], tempURL.path)
        XCTAssertEqual(env["WINEDEBUG"], "fixme-all")
    }

    // MARK: - Codable Compliance Tests

    func testBottleLauncherConfigCodable() throws {
        var config = BottleLauncherConfig()
        config.compatibilityMode = true
        config.launcherMode = .manual
        config.detectedLauncher = .steam
        config.launcherLocale = .english
        config.gpuSpoofing = true
        config.gpuVendor = .amd
        config.networkTimeout = 90_000
        config.autoEnableDXVK = false

        // Encode
        let encoder = PropertyListEncoder()
        let data = try encoder.encode(config)

        // Decode
        let decoder = PropertyListDecoder()
        let decoded = try decoder.decode(BottleLauncherConfig.self, from: data)

        // Verify all fields decoded correctly
        XCTAssertEqual(decoded.compatibilityMode, true)
        XCTAssertEqual(decoded.launcherMode, .manual)
        XCTAssertEqual(decoded.detectedLauncher, .steam)
        XCTAssertEqual(decoded.launcherLocale, .english)
        XCTAssertEqual(decoded.gpuSpoofing, true)
        XCTAssertEqual(decoded.gpuVendor, .amd)
        XCTAssertEqual(decoded.networkTimeout, 90_000)
        XCTAssertEqual(decoded.autoEnableDXVK, false)
    }

    // MARK: - Locale Preservation Tests

    func testSteamLocaleNotOverwritten() throws {
        // Verify that an explicit launcherLocale on a Steam bottle sets both LC_ALL
        // and LANG with the .UTF-8 suffix, and that custom locales (e.g. Japanese/Chinese)
        // are respected rather than clobbered to en_US.UTF-8.
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = true
        bottle.settings.detectedLauncher = .steam
        bottle.settings.launcherLocale = .english

        let env = Wine.constructWineEnvironment(for: bottle, environment: [:])
        XCTAssertEqual(env["LC_ALL"], "en_US.UTF-8", "Steam's LC_ALL must have .UTF-8 suffix")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8", "Steam's LANG must have .UTF-8 suffix")

        // User-selected CJK locale on a Steam bottle must NOT be clobbered to English
        bottle.settings.launcherLocale = .chineseSimplified
        let zhEnv = Wine.constructWineEnvironment(for: bottle, environment: [:])
        XCTAssertEqual(zhEnv["LC_ALL"], "zh_CN.UTF-8")
        XCTAssertEqual(zhEnv["LANG"], "zh_CN.UTF-8")
        XCTAssertEqual(zhEnv["LC_TIME"], "C")
        XCTAssertEqual(zhEnv["LC_NUMERIC"], "C")
    }

    func testSteamAutoLocaleUsesHostUTF8WithoutForcingLCAll() {
        var settings = BottleSettings()
        settings.launcherCompatibilityMode = true
        settings.detectedLauncher = .steam
        settings.launcherLocale = .auto

        var builder = EnvironmentBuilder()
        _ = settings.populateLauncherManagedLayer(
            builder: &builder,
            preferredLanguages: ["zh-Hans-CN", "en-US"]
        )
        let (resolved, _) = builder.resolve()

        XCTAssertNil(resolved["LC_ALL"], "Auto locale must not lock LC_ALL to English")
        XCTAssertEqual(resolved["LANG"], "zh_CN.UTF-8")
        XCTAssertEqual(resolved["LC_TIME"], "C")
        XCTAssertEqual(resolved["LC_NUMERIC"], "C")
    }

    func testNonLauncherTargetInAutoModeDoesNotReceiveSteamLauncherLayer() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        LauncherFixes.apply(to: bottle, launcher: .steam)
        bottle.settings.launcherLocale = .english

        let standaloneExe = URL(fileURLWithPath: "C:/Games/VisualNovel/game.exe")
        let standaloneEnv = Wine.constructWineEnvironment(
            for: bottle, targetURL: standaloneExe
        )

        // Standalone non-launcher executable in auto mode must not inherit Steam's locale or spoof
        XCTAssertNil(standaloneEnv["LC_ALL"])
        XCTAssertNil(standaloneEnv["LANG"])
        XCTAssertNil(standaloneEnv["MESA_GL_VERSION_OVERRIDE"])
        XCTAssertNil(standaloneEnv["WINHTTP_CONNECT_TIMEOUT"])

        // Launching Steam itself still applies the launcher layer
        let steamExe = URL(fileURLWithPath: "C:/Program Files (x86)/Steam/steam.exe")
        let steamEnv = Wine.constructWineEnvironment(
            for: bottle, targetURL: steamExe
        )
        XCTAssertEqual(steamEnv["LC_ALL"], "en_US.UTF-8")
        XCTAssertEqual(steamEnv["MESA_GL_VERSION_OVERRIDE"], "4.6")
        XCTAssertNil(steamEnv["WINHTTP_CONNECT_TIMEOUT"])

        // Manual mode forces the launcher layer even for non-launcher executables
        bottle.settings.launcherMode = .manual
        let manualEnv = Wine.constructWineEnvironment(
            for: bottle, targetURL: standaloneExe
        )
        XCTAssertEqual(manualEnv["LC_ALL"], "en_US.UTF-8")
        XCTAssertEqual(manualEnv["MESA_GL_VERSION_OVERRIDE"], "4.6")
    }

    func testEnglishLocaleIncludesUTF8() {
        // Verify the Locales.english enum has .UTF-8 suffix (consistency check)
        XCTAssertEqual(
            Locales.english.rawValue,
            "en_US.UTF-8",
            "English locale must have .UTF-8 suffix for consistency"
        )

        // Verify all non-auto locales have .UTF-8 suffix
        for locale in Locales.allCases where locale != .auto {
            if locale == .english {
                XCTAssertTrue(
                    locale.rawValue.hasSuffix(".UTF-8"),
                    "English locale must have .UTF-8 suffix"
                )
            } else {
                // All other locales should also have .UTF-8
                XCTAssertTrue(
                    locale.rawValue.hasSuffix(".UTF-8"),
                    "\(locale.rawValue) should have .UTF-8 suffix"
                )
            }
        }
    }

    // MARK: - Connection Pooling Tests

    func testConnectionPoolingEnvironmentApplied() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let bottle = Bottle(bottleUrl: tempURL, inFlight: false, isAvailable: true)
        bottle.settings.launcherCompatibilityMode = true

        var env: [String: String] = [:]
        bottle.settings.environmentVariables(wineEnv: &env)

        // These variables exist in no Wine or WineCX source; asserting their
        // absence keeps them from coming back as reassuring decoration.
        XCTAssertNil(env["WINE_MAX_CONNECTIONS_PER_SERVER"])
        XCTAssertNil(env["WINE_FORCE_HTTP11"])
        XCTAssertNil(env["WINE_ENABLE_SSL"])
        XCTAssertNil(env["WINE_SSL_VERSION_MIN"])
    }
}

// swiftlint:enable file_length type_body_length
