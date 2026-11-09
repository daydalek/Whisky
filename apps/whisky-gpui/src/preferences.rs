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
//!
//! `libraryCoverWidth` has no SwiftUI declaration: the cover size control is
//! GPUI-only, and the bridge stores it as a number so both backends round-trip
//! it unchanged.

/// The presentations, in `LibraryDisplayMode` declaration order plus the
/// GPUI-only modes, which the SwiftUI enum has no case for (the bridge stores
/// any string and SwiftUI falls back to covers for them).
pub(crate) const MODE_VALUES: [&str; 6] = [
    "covers",
    "timeline",
    "classic",
    "immersive",
    "gallery",
    "staggered",
];
/// The staggered two-column timeline's mode index. It shares the 列表 picker
/// entry — the toolbar's column toggle moves between it and mode 1.
pub(crate) const STAGGERED_MODE: usize = 5;
/// The picker's parent mode for a hidden timeline variant.
pub(crate) fn picker_mode(mode: usize) -> usize {
    if mode == STAGGERED_MODE { 1 } else { mode }
}
pub(crate) const VISIBLE_MODES: [(usize, &str, &str, &str); 4] = [
    (0, "library-big", "网格", "紧凑排列，快速浏览全部封面"),
    (1, "rows-3", "列表", "按行查看游戏与游玩记录"),
    (3, "tv-minimal-play", "沉浸", "大幅精选画面与分类游戏架"),
    (4, "panel-left", "画廊", "封面墙与游戏详情并排呈现"),
];
/// `LibrarySort` raw values (`WhiskyCore/LibraryOrdering.swift:21`).
pub(crate) const SORT_VALUES: [&str; 3] = ["recent", "name", "bottle"];
/// `TerminalApp` raw values (`WhiskyKit/Utils/TerminalApp.swift`).
#[cfg(not(target_os = "linux"))]
pub(crate) const TERMINAL_VALUES: [&str; 3] = ["terminal", "iterm", "warp"];
#[cfg(target_os = "linux")]
pub(crate) const TERMINAL_VALUES: [&str; 5] =
    ["auto", "x-terminal-emulator", "gnome-terminal", "xterm", "foot"];
/// `libraryCoverFillStyle` tags (`SettingsView.swift:92`).
pub(crate) const COVER_FILL_VALUES: [&str; 2] = ["blurred", "theme"];
/// `LibraryDetailLayoutStyle` raw values (`LibraryGameSheet.swift:25`).
pub(crate) const DETAIL_LAYOUT_VALUES: [&str; 2] = ["hero", "split"];
/// Backdrop blur level names, indexed by the `libraryBackdropBlur` level.
pub(crate) const BACKDROP_BLUR_NAMES: [&str; crate::artwork::BLUR_LEVELS as usize] =
    ["清晰", "轻微", "中等", "较强", "最强"];

pub(crate) const DISPLAY_MODE: &str = "libraryDisplayMode";
pub(crate) const SHOW_HIDDEN: &str = "libraryShowHiddenGames";
pub(crate) const SORT: &str = "librarySort";
pub(crate) const SINGLE_LINE_TITLES: &str = "librarySingleLineTitles";
pub(crate) const MIXED_COVER_LAYOUT: &str = "libraryMixedCoverLayout";
pub(crate) const COVER_WIDTH: &str = "libraryCoverWidth";
/// Cover upscaling factor: `off`, `x2` or `x4` (see `upscale::Factor`).
pub(crate) const COVER_UPSCALE: &str = "libraryCoverUpscale";
/// Cover upscaling engine: `anime4k`, `realcugan` or Linux `realcugan-cpu`.
pub(crate) const COVER_UPSCALE_ENGINE: &str = "libraryCoverUpscaleEngine";
pub(crate) const REFRESH_AFTER_EXIT: &str = "libraryRefreshAfterExit";
pub(crate) const DETAIL_BLURRED_BACKGROUND: &str = "libraryDetailBlurredBackground";
pub(crate) const CENTER_WIDE_COVER_TEXT: &str = "libraryCenterWideCoverText";
pub(crate) const BLURRED_COVER_FILL: &str = "libraryBlurredCoverFill";
pub(crate) const SCRAPE_CHARACTERS: &str = "libraryMetadataScrapeCharacters";
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
/// The library sidebar's presentation; GPUI-only like `libraryCoverWidth`.
pub(crate) const SIDEBAR_MODE: &str = "librarySidebarMode";
/// Which collapsed presentation (`icons` or `hidden`) the collapse action
/// and `ToggleSidebar` use; remembered across launches.
pub(crate) const SIDEBAR_COLLAPSED_STYLE: &str = "librarySidebarCollapsedStyle";
/// Whether the ambient backdrop fills the window with the hovered artwork.
/// GPUI-only like `libraryCoverWidth`.
pub(crate) const BACKDROP_FILL: &str = "libraryBackdropFill";
/// Backdrop blur level: 0 draws the sharp image, `artwork::BLUR_LEVELS - 1`
/// the heaviest. GPUI-only like `libraryCoverWidth`.
pub(crate) const BACKDROP_BLUR: &str = "libraryBackdropBlur";

/// SwiftUI defaults, used before the bridge answers and for keys the bridge
/// does not expose.
pub(crate) const DEFAULT_MODE: &str = "covers";
pub(crate) const DEFAULT_SORT: &str = "recent";
pub(crate) const DEFAULT_SHOW_HIDDEN: bool = false;
pub(crate) const DEFAULT_SINGLE_LINE_TITLES: bool = false;
pub(crate) const DEFAULT_MIXED_COVER_LAYOUT: bool = true;
/// Zero is the automatic shelf: covers divide the row, as before the control.
pub(crate) const DEFAULT_COVER_WIDTH: f32 = crate::library_layout::AUTOMATIC_COVER_WIDTH;
/// Covers are upscaled only when asked for: the pass costs a GPU burst and a
/// cached PNG per cover.
pub(crate) const DEFAULT_COVER_UPSCALE: &str = "off";
/// Real-CUGAN has the better line work for cover art; the app falls back to
/// Anime4K on macOS, or CPU inference on Linux, if acceleration fails.
pub(crate) const DEFAULT_COVER_UPSCALE_ENGINE: &str = "realcugan";
pub(crate) const DEFAULT_REFRESH_AFTER_EXIT: bool = true;
pub(crate) const DEFAULT_DETAIL_BLURRED_BACKGROUND: bool = true;
pub(crate) const DEFAULT_CENTER_WIDE_COVER_TEXT: bool = false;
pub(crate) const DEFAULT_BLURRED_COVER_FILL: bool = true;
pub(crate) const DEFAULT_SCRAPE_CHARACTERS: bool = true;
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
pub(crate) const DEFAULT_BACKDROP_FILL: bool = true;
/// Mid-range: text stays legible while the art still reads as art.
pub(crate) const DEFAULT_BACKDROP_BLUR: u8 = 2;

/// Index of a `LibraryDisplayMode` raw value; unknown values keep the default.
pub(crate) fn mode_index(raw: &str) -> Option<usize> {
    MODE_VALUES.iter().position(|value| *value == raw)
}

/// Classic remains a shared SwiftUI preference, but is hidden in GPUI.
/// "immersive" is GPUI-only and stays visible.
pub(crate) fn visible_mode_index(raw: &str) -> Option<usize> {
    mode_index(raw).map(|index| if index == 2 { 0 } else { index })
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
        assert_eq!(BACKDROP_FILL, "libraryBackdropFill");
        assert_eq!(BACKDROP_BLUR, "libraryBackdropBlur");
    }

    #[test]
    fn value_sets_match_the_swift_enums() {
        // LibraryDisplayMode, LibraryView.swift:26, plus the GPUI-only modes.
        assert_eq!(
            MODE_VALUES,
            [
                "covers",
                "timeline",
                "classic",
                "immersive",
                "gallery",
                "staggered"
            ]
        );
        // LibrarySort, WhiskyCore/LibraryOrdering.swift:21.
        assert_eq!(SORT_VALUES, ["recent", "name", "bottle"]);
        // TerminalApp, WhiskyKit/Utils/TerminalApp.swift.
        #[cfg(not(target_os = "linux"))]
        assert_eq!(TERMINAL_VALUES, ["terminal", "iterm", "warp"]);
        #[cfg(target_os = "linux")]
        assert_eq!(
            TERMINAL_VALUES,
            ["auto", "x-terminal-emulator", "gnome-terminal", "xterm", "foot"]
        );
        assert_eq!(COVER_FILL_VALUES, ["blurred", "theme"]);
        assert_eq!(DETAIL_LAYOUT_VALUES, ["hero", "split"]);
        assert_eq!(mode_index("timeline"), Some(1));
        assert_eq!(mode_index("immersive"), Some(3));
        assert_eq!(visible_mode_index("covers"), Some(0));
        assert_eq!(visible_mode_index("timeline"), Some(1));
        assert_eq!(visible_mode_index("classic"), Some(0));
        assert_eq!(visible_mode_index("immersive"), Some(3));
        assert_eq!(visible_mode_index("unknown"), None);
        assert_eq!(mode_index("gallery"), Some(4));
        assert_eq!(mode_value(4), "gallery");
        assert_eq!(visible_mode_index(mode_value(4)), Some(4));
        assert_eq!(visible_mode_index("gallery"), Some(4));
        assert_eq!(mode_index("staggered"), Some(STAGGERED_MODE));
        assert_eq!(mode_value(STAGGERED_MODE), "staggered");
        assert_eq!(visible_mode_index("staggered"), Some(STAGGERED_MODE));
        assert_eq!(
            VISIBLE_MODES
                .iter()
                .map(|(index, ..)| *index)
                .collect::<Vec<_>>(),
            vec![0, 1, 3, 4]
        );
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
        assert!(DEFAULT_BACKDROP_FILL);
        assert_eq!(DEFAULT_BACKDROP_BLUR, 2);
    }
}
