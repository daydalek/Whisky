//! Preference keys shared with the SwiftUI app.
//!
//! The names are copied verbatim from the `@AppStorage` declarations in
//! `/Whisky/Views` so both frontends read and write the same `UserDefaults`
//! entry. `preferences.schema` (see `PreferencesService.flags` in
//! `WhiskyBridge`) advertises every key below; one it does not advertise cannot
//! be persisted and the view keeps it in memory for the session.
//!
//! Swift references:
//! - `libraryDisplayMode` — `LibraryView.swift:57` (default `.covers`)
//! - `libraryShowHiddenGames` — `LibraryView.swift:58` (default `false`)
//! - `librarySort` — `LibraryView.swift:59` (default `.recent`)
//! - `librarySingleLineTitles` — `LibraryView.swift:60` (default `false`)
//! - `libraryMixedCoverLayout` — `LibraryView.swift:61` (default `true`)
//! - `libraryRefreshAfterExit` — `LibraryView.swift:67` (default `true`)

/// The three presentations, in `LibraryDisplayMode` declaration order.
pub(crate) const MODE_VALUES: [&str; 3] = ["covers", "timeline", "classic"];
/// `LibrarySort` raw values (`WhiskyCore/LibraryOrdering.swift:21`).
pub(crate) const SORT_VALUES: [&str; 3] = ["recent", "name", "bottle"];
/// `TerminalApp` raw values (`WhiskyKit/Utils/TerminalApp.swift`).
#[cfg(not(target_os = "linux"))]
pub(crate) const TERMINAL_VALUES: [&str; 3] = ["terminal", "iterm", "warp"];
#[cfg(target_os = "linux")]
pub(crate) const TERMINAL_VALUES: [&str; 4] =
    ["auto", "x-terminal-emulator", "gnome-terminal", "xterm"];
/// `libraryCoverFillStyle` tags (`SettingsView.swift:92`).
pub(crate) const COVER_FILL_VALUES: [&str; 2] = ["blurred", "theme"];
/// `LibraryDetailLayoutStyle` raw values (`LibraryGameSheet.swift:25`).
pub(crate) const DETAIL_LAYOUT_VALUES: [&str; 2] = ["hero", "split"];

pub(crate) const DISPLAY_MODE: &str = "libraryDisplayMode";
pub(crate) const SHOW_HIDDEN: &str = "libraryShowHiddenGames";
pub(crate) const SORT: &str = "librarySort";
pub(crate) const SINGLE_LINE_TITLES: &str = "librarySingleLineTitles";
pub(crate) const MIXED_COVER_LAYOUT: &str = "libraryMixedCoverLayout";
pub(crate) const REFRESH_AFTER_EXIT: &str = "libraryRefreshAfterExit";
pub(crate) const DETAIL_BLURRED_BACKGROUND: &str = "libraryDetailBlurredBackground";
pub(crate) const CENTER_WIDE_COVER_TEXT: &str = "libraryCenterWideCoverText";
pub(crate) const BLURRED_COVER_FILL: &str = "libraryBlurredCoverFill";
pub(crate) const COVER_FILL_STYLE: &str = "libraryCoverFillStyle";
pub(crate) const DETAIL_LAYOUT_STYLE: &str = "libraryDetailLayoutStyle";
#[cfg(not(target_os = "linux"))]
pub(crate) const PREFERRED_TERMINAL: &str = "preferredTerminal";
#[cfg(target_os = "linux")]
pub(crate) const PREFERRED_TERMINAL: &str = "preferredLinuxTerminal";
pub(crate) const KILL_ON_TERMINATE: &str = "killOnTerminate";
pub(crate) const SHOW_MENU_BAR_EXTRA: &str = "showMenuBarExtra";
pub(crate) const OFFLINE_MODE: &str = "offlineMode";
pub(crate) const CHECK_UPDATES: &str = "checkWhiskyWineUpdates";
pub(crate) const DEFAULT_BOTTLE_LOCATION: &str = "defaultBottleLocation";

/// SwiftUI defaults, used before the bridge answers and for keys the bridge
/// does not expose.
pub(crate) const DEFAULT_MODE: &str = "covers";
pub(crate) const DEFAULT_SORT: &str = "recent";
pub(crate) const DEFAULT_SHOW_HIDDEN: bool = false;
pub(crate) const DEFAULT_SINGLE_LINE_TITLES: bool = false;
pub(crate) const DEFAULT_MIXED_COVER_LAYOUT: bool = true;
pub(crate) const DEFAULT_REFRESH_AFTER_EXIT: bool = true;
pub(crate) const DEFAULT_DETAIL_BLURRED_BACKGROUND: bool = true;
pub(crate) const DEFAULT_CENTER_WIDE_COVER_TEXT: bool = false;
pub(crate) const DEFAULT_BLURRED_COVER_FILL: bool = true;
pub(crate) const DEFAULT_COVER_FILL_STYLE: &str = "blurred";
pub(crate) const DEFAULT_DETAIL_LAYOUT_STYLE: &str = "hero";
#[cfg(not(target_os = "linux"))]
pub(crate) const DEFAULT_PREFERRED_TERMINAL: &str = "terminal";
#[cfg(target_os = "linux")]
pub(crate) const DEFAULT_PREFERRED_TERMINAL: &str = "auto";
pub(crate) const DEFAULT_KILL_ON_TERMINATE: bool = true;
pub(crate) const DEFAULT_SHOW_MENU_BAR_EXTRA: bool = false;
pub(crate) const DEFAULT_OFFLINE_MODE: bool = false;
pub(crate) const DEFAULT_CHECK_UPDATES: bool = true;

/// Index of a `LibraryDisplayMode` raw value; unknown values keep the default.
pub(crate) fn mode_index(raw: &str) -> Option<usize> {
    MODE_VALUES.iter().position(|value| *value == raw)
}

/// Index of a `LibrarySort` raw value.
pub(crate) fn sort_index(raw: &str) -> Option<usize> {
    SORT_VALUES.iter().position(|value| *value == raw)
}

/// The persisted value for a presentation index.
pub(crate) fn mode_value(index: usize) -> &'static str {
    MODE_VALUES.get(index).copied().unwrap_or(DEFAULT_MODE)
}

/// The persisted value for a sort index.
pub(crate) fn sort_value(index: usize) -> &'static str {
    SORT_VALUES.get(index).copied().unwrap_or(DEFAULT_SORT)
}

/// Whether `raw` is one of the accepted terminal raw values.
pub(crate) fn terminal_index(raw: &str) -> Option<usize> {
    TERMINAL_VALUES.iter().position(|value| *value == raw)
}

/// Whether `raw` is one of the accepted cover fill tags.
pub(crate) fn cover_fill_index(raw: &str) -> Option<usize> {
    COVER_FILL_VALUES.iter().position(|value| *value == raw)
}

/// Whether `raw` is one of the accepted detail layouts.
pub(crate) fn detail_layout_index(raw: &str) -> Option<usize> {
    DETAIL_LAYOUT_VALUES.iter().position(|value| *value == raw)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The literals below are copied from the Swift `@AppStorage` strings and
    /// from `LibrarySort`'s raw values; changing one side alone must fail.
    #[test]
    fn key_names_match_the_swift_appstorage_literals() {
        assert_eq!(DISPLAY_MODE, "libraryDisplayMode"); // LibraryView.swift:57
        assert_eq!(SHOW_HIDDEN, "libraryShowHiddenGames"); // LibraryView.swift:58
        assert_eq!(SORT, "librarySort"); // LibraryView.swift:59
        assert_eq!(SINGLE_LINE_TITLES, "librarySingleLineTitles"); // LibraryView.swift:60
        assert_eq!(MIXED_COVER_LAYOUT, "libraryMixedCoverLayout"); // LibraryView.swift:61
        assert_eq!(REFRESH_AFTER_EXIT, "libraryRefreshAfterExit"); // LibraryView.swift:67
        assert_eq!(DETAIL_BLURRED_BACKGROUND, "libraryDetailBlurredBackground");
        assert_eq!(CENTER_WIDE_COVER_TEXT, "libraryCenterWideCoverText");
        assert_eq!(BLURRED_COVER_FILL, "libraryBlurredCoverFill");
        assert_eq!(COVER_FILL_STYLE, "libraryCoverFillStyle");
        assert_eq!(DETAIL_LAYOUT_STYLE, "libraryDetailLayoutStyle");
        assert_eq!(
            PREFERRED_TERMINAL,
            if cfg!(target_os = "linux") {
                "preferredLinuxTerminal"
            } else {
                "preferredTerminal"
            }
        );
        assert_eq!(KILL_ON_TERMINATE, "killOnTerminate");
        assert_eq!(SHOW_MENU_BAR_EXTRA, "showMenuBarExtra");
        assert_eq!(OFFLINE_MODE, "offlineMode");
        assert_eq!(CHECK_UPDATES, "checkWhiskyWineUpdates");
        assert_eq!(DEFAULT_BOTTLE_LOCATION, "defaultBottleLocation");
    }

    #[test]
    fn value_sets_match_the_swift_enums() {
        // LibraryDisplayMode, LibraryView.swift:26.
        assert_eq!(MODE_VALUES, ["covers", "timeline", "classic"]);
        // LibrarySort, WhiskyCore/LibraryOrdering.swift:21.
        assert_eq!(SORT_VALUES, ["recent", "name", "bottle"]);
        // TerminalApp, WhiskyKit/Utils/TerminalApp.swift.
        #[cfg(not(target_os = "linux"))]
        assert_eq!(TERMINAL_VALUES, ["terminal", "iterm", "warp"]);
        #[cfg(target_os = "linux")]
        assert_eq!(
            TERMINAL_VALUES,
            ["auto", "x-terminal-emulator", "gnome-terminal", "xterm"]
        );
        assert_eq!(COVER_FILL_VALUES, ["blurred", "theme"]);
        assert_eq!(DETAIL_LAYOUT_VALUES, ["hero", "split"]);
        assert_eq!(mode_index("timeline"), Some(1));
        assert_eq!(sort_index("bottle"), Some(2));
        assert_eq!(mode_index("grid"), None);
        assert_eq!(mode_value(9), DEFAULT_MODE);
        assert_eq!(sort_value(9), DEFAULT_SORT);
        assert_eq!(
            terminal_index(if cfg!(target_os = "linux") {
                "gnome-terminal"
            } else {
                "warp"
            }),
            Some(2)
        );
        assert_eq!(terminal_index("kitty"), None);
        assert_eq!(cover_fill_index("theme"), Some(1));
        assert_eq!(detail_layout_index("split"), Some(1));
    }

    #[test]
    fn defaults_match_the_swiftui_declarations() {
        assert_eq!(DEFAULT_MODE, "covers");
        assert_eq!(DEFAULT_SORT, "recent");
        assert!(!DEFAULT_SHOW_HIDDEN);
        assert!(!DEFAULT_SINGLE_LINE_TITLES);
        assert!(DEFAULT_MIXED_COVER_LAYOUT);
        assert!(DEFAULT_REFRESH_AFTER_EXIT);
        assert!(DEFAULT_DETAIL_BLURRED_BACKGROUND);
        assert!(!DEFAULT_CENTER_WIDE_COVER_TEXT);
        assert!(DEFAULT_BLURRED_COVER_FILL);
        assert_eq!(DEFAULT_COVER_FILL_STYLE, "blurred");
        assert_eq!(DEFAULT_DETAIL_LAYOUT_STYLE, "hero");
        assert_eq!(
            DEFAULT_PREFERRED_TERMINAL,
            if cfg!(target_os = "linux") {
                "auto"
            } else {
                "terminal"
            }
        );
        assert!(DEFAULT_KILL_ON_TERMINATE);
        assert!(!DEFAULT_SHOW_MENU_BAR_EXTRA);
        assert!(!DEFAULT_OFFLINE_MODE);
        assert!(DEFAULT_CHECK_UPDATES);
    }
}
