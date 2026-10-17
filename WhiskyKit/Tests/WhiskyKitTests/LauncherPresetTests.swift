//
//  LauncherPresetTests.swift
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

final class LauncherPresetTests: XCTestCase {
    func testSteamPresetIncludesLocale() {
        let env = LauncherType.steam.environmentOverrides()

        // Steam preset should not force LC_ALL or LANG to en_US.UTF-8, so games
        // and user locale overrides keep their native language/encoding.
        XCTAssertNil(env["LC_ALL"])
        XCTAssertNil(env["LANG"])

        // Should force C locale for time/numeric to avoid ICU issues in steamwebhelper
        XCTAssertEqual(env["LC_TIME"], "C")
        XCTAssertEqual(env["LC_NUMERIC"], "C")
    }

    func testSteamPresetDisablesSandbox() {
        let env = LauncherType.steam.environmentOverrides()

        // Steam-specific CEF sandbox disable
        XCTAssertEqual(env["STEAM_DISABLE_CEF_SANDBOX"], "1")

        // Note: CEF_DISABLE_SANDBOX is set globally in MacOSCompatibility.swift
        // for all launchers, not in individual presets. This provides single
        // point of control for the security-sensitive setting.
        XCTAssertNil(env["CEF_DISABLE_SANDBOX"], "Should be set globally, not in preset")

        // Steam runtime causes issues under Wine
        XCTAssertEqual(env["STEAM_RUNTIME"], "0")
    }

    func testSteamPresetIncludesNetworkFixes() {
        let env = LauncherType.steam.environmentOverrides()

        // Network timeouts are now configured via bottle.settings.networkTimeout
        // instead of directly in launcher presets. This allows user customization.
        // Verify Steam preset doesn't set them (they're set by BottleSettings)
        XCTAssertNil(env["WINHTTP_CONNECT_TIMEOUT"])
        XCTAssertNil(env["WINHTTP_RECEIVE_TIMEOUT"])

        // Steam should still set other important fixes
        XCTAssertEqual(env["STEAM_DISABLE_CEF_SANDBOX"], "1")
        XCTAssertEqual(env["DXVK_ASYNC"], "1")
    }

    func testRockstarRequiresDXVK() {
        let launcher = LauncherType.rockstar

        // Rockstar Launcher requires DXVK to display logo
        XCTAssertTrue(launcher.requiresDXVK)

        // DXVK is turned on through requiresDXVK, not an environment variable
        let env = launcher.environmentOverrides()
        XCTAssertNil(env["DXVK_REQUIRED"], "No shipped runtime reads DXVK_REQUIRED")
        XCTAssertNil(env["D3DM_FORCE_D3D11"], "No shipped runtime reads D3DM_FORCE_D3D11")
        XCTAssertNil(env["LC_ALL"])
        XCTAssertEqual(env["LC_TIME"], "C")
        XCTAssertEqual(env["LC_NUMERIC"], "C")
    }

    func testEAAppPreset() {
        let env = LauncherType.eaApp.environmentOverrides()

        XCTAssertNil(env["LC_ALL"])
        XCTAssertNil(env["LANG"])
        XCTAssertEqual(env["LC_TIME"], "C")
        XCTAssertEqual(env["LC_NUMERIC"], "C")
        // GPU detection is the spoof's job (LauncherFixes turns it on); no
        // shipped runtime reads the D3DMetal feature-level keys.
        XCTAssertNil(env["D3DM_FEATURE_LEVEL_12_1"])

        // Note: CEF_DISABLE_SANDBOX is set globally in MacOSCompatibility.swift
        XCTAssertNil(env["CEF_DISABLE_SANDBOX"], "Should be set globally, not in preset")
    }

    func testEpicGamesPreset() {
        let env = LauncherType.epicGames.environmentOverrides()

        // Note: CEF_DISABLE_SANDBOX is set globally in MacOSCompatibility.swift
        XCTAssertNil(env["CEF_DISABLE_SANDBOX"], "Should be set globally, not in preset")

        // Epic-specific settings
        XCTAssertNil(env["LC_ALL"])
        XCTAssertEqual(env["LC_TIME"], "C")
        XCTAssertEqual(env["LC_NUMERIC"], "C")
        XCTAssertNil(env["WINE_DISABLE_NTDLL_THREAD_REGS"], "No shipped runtime reads it")
        XCTAssertNil(env["D3DM_FORCE_D3D11"])
    }

    func testUbisoftPreset() {
        let env = LauncherType.ubisoft.environmentOverrides()

        XCTAssertEqual(env["DXVK_ASYNC"], "1")
        XCTAssertNil(env["D3DM_FORCE_D3D11"])
    }

    func testBattleNetPreset() {
        let env = LauncherType.battleNet.environmentOverrides()

        // Note: CEF_DISABLE_SANDBOX is set globally in MacOSCompatibility.swift
        XCTAssertNil(env["CEF_DISABLE_SANDBOX"], "Should be set globally, not in preset")

        // Battle.net-specific settings
        XCTAssertNil(env["LC_ALL"])
        XCTAssertEqual(env["LC_TIME"], "C")
        XCTAssertEqual(env["LC_NUMERIC"], "C")
        XCTAssertNil(env["WINE_CPU_TOPOLOGY"], "No shipped runtime reads it")
    }

    func testParadoxPreset() {
        // The resource lookup workaround set WINE_DISABLE_FAST_PATH, which
        // no shipped runtime reads, so Paradox has no environment fix.
        XCTAssertTrue(LauncherType.paradox.environmentOverrides().isEmpty)
        XCTAssertTrue(LauncherType.paradox.fixDetails().isEmpty)
    }

    func testFixDetailsMatchEnvironmentOverrides() {
        for launcher in LauncherType.allCases {
            let details = Dictionary(uniqueKeysWithValues: launcher.fixDetails().map { ($0.key, $0.value) })
            XCTAssertEqual(details, launcher.environmentOverrides(), "\(launcher.rawValue)")
        }
    }

    func testRecommendedLocales() {
        // All launchers default to .auto so the host's language is normalized to a
        // valid UTF-8 locale without forcing the entire bottle into English.
        for launcher in LauncherType.allCases {
            XCTAssertEqual(launcher.recommendedLocale, .auto, "\(launcher.rawValue)")
        }
    }

    func testHostLocaleResolution() {
        XCTAssertEqual(Locales.hostLocale(preferredLanguages: ["zh-Hans-CN", "en-US"]), .chineseSimplified)
        XCTAssertEqual(Locales.hostLocale(preferredLanguages: ["zh-Hant-TW", "en-US"]), .chineseTraditional)
        XCTAssertEqual(Locales.hostLocale(preferredLanguages: ["zh-HK"]), .chineseTraditional)
        XCTAssertEqual(Locales.hostLocale(preferredLanguages: ["ja-JP"]), .japanese)
        XCTAssertEqual(Locales.hostLocale(preferredLanguages: ["ko-KR"]), .korean)
        XCTAssertEqual(Locales.hostLocale(preferredLanguages: ["de-DE"]), .german)
        XCTAssertEqual(Locales.hostLocale(preferredLanguages: ["fr-FR"]), .french)
        XCTAssertEqual(Locales.hostLocale(preferredLanguages: ["ru-RU"]), .russian)
        XCTAssertEqual(Locales.hostLocale(preferredLanguages: ["uk-UA"]), .ukrainian)
        XCTAssertEqual(Locales.hostLocale(preferredLanguages: ["nl-NL", "ja-JP"]), .japanese)
        XCTAssertEqual(Locales.hostLocale(preferredLanguages: ["sv-SE"]), .english)
        XCTAssertEqual(Locales.hostLocale(preferredLanguages: []), .english)
    }

    func testFixesDescription() {
        // Each launcher should have a description of fixes
        for launcher in LauncherType.allCases {
            XCTAssertFalse(
                launcher.fixesDescription.isEmpty,
                "\(launcher.rawValue) should have fixes description"
            )
        }
    }

    func testLauncherTypeIdentifiable() {
        // LauncherType conforms to Identifiable for SwiftUI
        let launcher = LauncherType.steam
        XCTAssertEqual(launcher.id, launcher.rawValue)
    }
}
