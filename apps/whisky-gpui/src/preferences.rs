//! Preference keys shared with the SwiftUI app.
//!
//! The names are copied verbatim from the `@AppStorage` declarations in
//! `/Whisky/Views` so both frontends read and write the same `UserDefaults`
//! entry. Only a subset of them exists in `preferences.schema` (see
//! `PreferencesService.flags` in `WhiskyBridge`); a key that is not advertised
//! there cannot be persisted and the view keeps it in memory for the session.
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

pub(crate) const DISPLAY_MODE: &str = "libraryDisplayMode";
pub(crate) const SHOW_HIDDEN: &str = "libraryShowHiddenGames";
pub(crate) const SORT: &str = "librarySort";
pub(crate) const SINGLE_LINE_TITLES: &str = "librarySingleLineTitles";
pub(crate) const MIXED_COVER_LAYOUT: &str = "libraryMixedCoverLayout";
pub(crate) const REFRESH_AFTER_EXIT: &str = "libraryRefreshAfterExit";
pub(crate) const DEFAULT_BOTTLE_LOCATION: &str = "defaultBottleLocation";

/// SwiftUI defaults, used before the bridge answers and for keys the bridge
/// does not expose.
pub(crate) const DEFAULT_MODE: &str = "covers";
pub(crate) const DEFAULT_SORT: &str = "recent";
pub(crate) const DEFAULT_SHOW_HIDDEN: bool = false;
pub(crate) const DEFAULT_SINGLE_LINE_TITLES: bool = false;
pub(crate) const DEFAULT_MIXED_COVER_LAYOUT: bool = true;
pub(crate) const DEFAULT_REFRESH_AFTER_EXIT: bool = true;

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
    }

    #[test]
    fn value_sets_match_the_swift_enums() {
        // LibraryDisplayMode, LibraryView.swift:26.
        assert_eq!(MODE_VALUES, ["covers", "timeline", "classic"]);
        // LibrarySort, WhiskyCore/LibraryOrdering.swift:21.
        assert_eq!(SORT_VALUES, ["recent", "name", "bottle"]);
        assert_eq!(mode_index("timeline"), Some(1));
        assert_eq!(sort_index("bottle"), Some(2));
        assert_eq!(mode_index("grid"), None);
        assert_eq!(mode_value(9), DEFAULT_MODE);
        assert_eq!(sort_value(9), DEFAULT_SORT);
    }

    #[test]
    fn defaults_match_the_swiftui_declarations() {
        assert_eq!(DEFAULT_MODE, "covers");
        assert_eq!(DEFAULT_SORT, "recent");
        assert!(!DEFAULT_SHOW_HIDDEN);
        assert!(!DEFAULT_SINGLE_LINE_TITLES);
        assert!(DEFAULT_MIXED_COVER_LAYOUT);
        assert!(DEFAULT_REFRESH_AFTER_EXIT);
    }
}
