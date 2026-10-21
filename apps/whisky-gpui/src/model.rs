//! View models: live bridge entries and the demo snapshot used for design work.
//!
//! `Game` is owned because live library entries come from the bridge. The demo
//! snapshot is still compiled in and is selected with `WHISKY_GPUI_DEMO_DATA=1`;
//! regenerate its artwork with tools/import_whisky_artwork.py.
use std::path::PathBuf;
use std::sync::OnceLock;

#[derive(Clone, Debug)]
pub(crate) struct Game {
    /// Bridge entry identity (`steam:…` or `pinned:…`); `demo:N` for the demo.
    pub(crate) id: String,
    /// Existing artwork file, or `None` to use the placeholder treatment.
    pub(crate) art: Option<PathBuf>,
    pub(crate) title: String,
    /// Developer from `GameMetadata.developer`; the bridge exposes no publisher.
    pub(crate) studio: Option<String>,
    pub(crate) description: Option<String>,
    /// Release date as the bridge reports it (`YYYY-MM-DD`).
    pub(crate) release: Option<String>,
    pub(crate) landscape: bool,
    /// One-based bottle slot, matching the sidebar (`0` means no bottle).
    pub(crate) bottle: usize,
    /// Hidden by the container's visibility file.
    pub(crate) hidden: bool,
    pub(crate) rating: Option<u8>,
    /// Whole seconds of recorded play time, if any.
    pub(crate) play_time: Option<u64>,
    /// Unix seconds, if the bridge recorded a session.
    pub(crate) last_played: Option<u64>,
    /// Launching executable, when the entry is a program rather than a Store app.
    pub(crate) executable: Option<PathBuf>,
}

impl Game {
    fn from_demo(index: usize, demo: &DemoGame) -> Self {
        Self {
            id: format!("demo:{index}"),
            art: Some(art(index)),
            title: demo.title.to_owned(),
            studio: (!demo.studio.is_empty()).then(|| demo.studio.to_owned()),
            description: (!demo.description.is_empty()).then(|| demo.description.to_owned()),
            release: (!demo.release.is_empty()).then(|| demo.release.to_owned()),
            landscape: demo.landscape,
            bottle: demo.bottle,
            hidden: false,
            rating: None,
            play_time: None,
            last_played: None,
            executable: None,
        }
    }

    /// Four-digit release year, when the bridge supplied a parseable date.
    pub(crate) fn year(&self) -> Option<&str> {
        let release = self.release.as_deref()?;
        let year = release.get(..4)?;
        year.chars().all(|c| c.is_ascii_digit()).then_some(year)
    }

    pub(crate) fn studio(&self) -> &str {
        self.studio.as_deref().unwrap_or("")
    }
}

/// The bundled design snapshot. Only `WHISKY_GPUI_DEMO_DATA=1` uses it.
struct DemoGame {
    art: &'static str,
    title: &'static str,
    studio: &'static str,
    description: &'static str,
    release: &'static str,
    landscape: bool,
    bottle: usize,
}

const DEMO_GAMES: &[DemoGame] = &[

DemoGame { art: r####"astral.png"####, title: r####"Northwind Signal"####, studio: r####"Folded Atlas"####, description: r####"A quiet coastal town, a radio that only plays at night, and one winter worth staying for."####, release: r####"2024-03-12"####, landscape: true, bottle: 1 },
DemoGame { art: r####"dune.png"####, title: r####"Saltlight"####, studio: r####"Hollow Studio"####, description: r####"Two travellers cross a dry sea bed, trading stories for directions neither of them trusts."####, release: r####"2023-08-30"####, landscape: true, bottle: 1 },
DemoGame { art: r####"echo.png"####, title: r####"Quiet Frequency"####, studio: r####"Meridian Works"####, description: r####"An archivist tunes a broken transmitter and hears the answers she stopped waiting for."####, release: r####"2025-01-17"####, landscape: true, bottle: 1 },
DemoGame { art: r####"ember.png"####, title: r####"Emberline"####, studio: r####"Foxglove Interactive"####, description: r####"A forge at the edge of the district keeps its furnace lit long after the city gave up on it."####, release: r####"2022-11-04"####, landscape: true, bottle: 1 },
DemoGame { art: r####"frost.png"####, title: r####"Glass Harbour"####, studio: r####"Northgate Games"####, description: r####"Harbour lights, a borrowed boat, and the slow work of saying what should have been said."####, release: r####"2024-06-21"####, landscape: true, bottle: 1 },
DemoGame { art: r####"lumen.png"####, title: r####"Paper Lanterns"####, studio: r####"Studio Aube"####, description: r####"A festival, a list of small promises, and one evening to keep all of them."####, release: r####"2021-09-09"####, landscape: true, bottle: 1 },
DemoGame { art: r####"neon.png"####, title: r####"Neon Transit"####, studio: r####"Halfstep"####, description: r####"Late trains, brighter streets, and a map that only makes sense after midnight."####, release: r####"2025-05-02"####, landscape: true, bottle: 1 },
DemoGame { art: r####"orbit.png"####, title: r####"Orbit Café"####, studio: r####"Longform Labs"####, description: r####"A station café serves the same coffee to the same three people for a very long year."####, release: r####"2023-02-14"####, landscape: true, bottle: 1 },
DemoGame { art: r####"tide.png"####, title: r####"Tidewater"####, studio: r####"Bluecap"####, description: r####"A tide chart, an empty house, and the summer it took to decide what to keep."####, release: r####"2022-07-08"####, landscape: true, bottle: 1 },
DemoGame { art: r####"verdant.png"####, title: r####"Verdant Hours"####, studio: r####"Greenfield"####, description: r####"A greenhouse, a stubborn garden, and the neighbours who slowly become the reason to stay."####, release: r####"2024-10-25"####, landscape: true, bottle: 1 },
DemoGame { art: r####"astral.png"####, title: r####"Second Sun"####, studio: r####"Folded Atlas"####, description: r####"A long dusk over the flats, and two surveyors arguing gently about the way home."####, release: r####"2020-04-18"####, landscape: true, bottle: 2 },
DemoGame { art: r####"dune.png"####, title: r####"Dune Road"####, studio: r####"Hollow Studio"####, description: r####"One road, one broken truck, and the town at the end of it that has been waiting."####, release: r####"2021-12-03"####, landscape: true, bottle: 2 },
DemoGame { art: r####"echo.png"####, title: r####"Echo Chamber"####, studio: r####"Meridian Works"####, description: r####"A sound engineer records a room that keeps answering back, one day late."####, release: r####"2023-06-11"####, landscape: true, bottle: 2 },
DemoGame { art: r####"ember.png"####, title: r####"Ember & Ash"####, studio: r####"Foxglove Interactive"####, description: r####"Two sisters reopen the bakery their grandmother closed, one recipe at a time."####, release: r####"2019-10-29"####, landscape: true, bottle: 2 },
DemoGame { art: r####"frost.png"####, title: r####"Frostbound"####, studio: r####"Northgate Games"####, description: r####"A winter route, a stalled train, and the strangers who keep each other awake."####, release: r####"2022-01-20"####, landscape: true, bottle: 2 },
DemoGame { art: r####"lumen.png"####, title: r####"Lumen Field"####, studio: r####"Studio Aube"####, description: r####"A field station tracks a light that returns every eleven years, and so does she."####, release: r####"2024-02-08"####, landscape: true, bottle: 2 },
DemoGame { art: r####"neon.png"####, title: r####"Afterglow Drive"####, studio: r####"Halfstep"####, description: r####"A night shift, a borrowed car, and every errand that turns into a confession."####, release: r####"2025-07-16"####, landscape: true, bottle: 2 },
DemoGame { art: r####"orbit.png"####, title: r####"Low Orbit"####, studio: r####"Longform Labs"####, description: r####"A courier, a very old satellite, and the last scheduled call of the week."####, release: r####"2021-05-27"####, landscape: true, bottle: 2 },
DemoGame { art: r####"tide.png"####, title: r####"Undertow"####, studio: r####"Bluecap"####, description: r####"A swimming coach, a difficult season, and the return that nobody expected."####, release: r####"2020-11-13"####, landscape: true, bottle: 2 },
DemoGame { art: r####"verdant.png"####, title: r####"Evergreen"####, studio: r####"Greenfield"####, description: r####"A caretaker plants for the people who will arrive after he is gone."####, release: r####"2023-09-01"####, landscape: true, bottle: 2 },
];

/// A container as the sidebar renders it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct BottleVm {
    pub(crate) path: String,
    pub(crate) name: String,
    pub(crate) available: bool,
}

pub(crate) fn demo_bottles() -> Vec<BottleVm> {
    [("demo:galgame", "galgame"), ("demo:galgame-win7", "galgame-win7")]
        .into_iter()
        .map(|(path, name)| BottleVm {
            path: path.into(),
            name: name.into(),
            available: true,
        })
        .collect()
}

/// The design snapshot, selected by `WHISKY_GPUI_DEMO_DATA=1`.
pub(crate) fn demo_data() -> &'static [Game] {
    static DEMO: OnceLock<Vec<Game>> = OnceLock::new();
    DEMO.get_or_init(|| {
        DEMO_GAMES
            .iter()
            .enumerate()
            .map(|(index, demo)| Game::from_demo(index, demo))
            .collect()
    })
}

/// `1` (or `true`) opts into the bundled demo library.
pub(crate) fn demo_requested(value: Option<&str>) -> bool {
    matches!(value, Some("1") | Some("true"))
}

/// Empty-library copy. `visible_entries` is the count before the search filter:
/// zero means the selected bottle is genuinely empty, not that a query missed.
pub(crate) fn empty_library_message(
    demo: bool,
    bottles: usize,
    visible_entries: usize,
) -> &'static str {
    if demo {
        "没有找到匹配的游戏"
    } else if bottles == 0 {
        "No bottles yet"
    } else if visible_entries == 0 {
        "No games in this bottle"
    } else {
        "没有找到匹配的游戏"
    }
}

/// Whole seconds to a compact duration. Zero or absent renders nothing.
pub(crate) fn format_play_time(seconds: Option<u64>) -> Option<String> {
    let seconds = seconds?;
    let minutes = seconds.div_ceil(60);
    if minutes == 0 {
        return None;
    }
    let (hours, minutes) = (minutes / 60, minutes % 60);
    Some(match (hours, minutes) {
        (0, m) => format!("{m} 分钟"),
        (h, 0) => format!("{h} 小时"),
        (h, m) => format!("{h} 小时 {m} 分钟"),
    })
}

/// Unix seconds to `YYYY-MM-DD` in UTC. The bridge sends no time zone.
pub(crate) fn format_last_played(unix: Option<u64>) -> Option<String> {
    let days = (unix? / 86_400) as i64;
    let (year, month, day) = civil_from_days(days);
    Some(format!("{year:04}-{month:02}-{day:02}"))
}

/// Howard Hinnant's days-to-civil conversion, valid for the whole `i64` range.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if month <= 2 { year + 1 } else { year }, month, day)
}

fn asset(file: impl AsRef<std::path::Path>) -> PathBuf {
    static ROOT: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    ROOT.get_or_init(|| {
        let bundled = std::env::current_exe()
            .ok()
            .and_then(|exe| Some(exe.parent()?.parent()?.join("Resources")));
        bundled.filter(|path| path.is_dir()).unwrap_or_else(|| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("assets")
        })
    })
    .join(file)
}
pub(crate) fn art(i: usize) -> PathBuf {
    asset(DEMO_GAMES[i].art)
}
pub(crate) fn ambient(i: usize) -> PathBuf {
    asset(format!("{i}-ambient.jpg"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn demo_data_uses_the_procedural_cover_set() {
        assert_eq!(demo_data().len(), 20);
        assert_eq!(demo_data()[0].title, "Northwind Signal");
        assert_eq!(demo_data()[19].bottle, 2);
        assert_eq!(demo_data()[8].bottle, 1);
    }

    #[test]
    fn demo_flag_is_strictly_opt_in() {
        assert!(demo_requested(Some("1")));
        assert!(demo_requested(Some("true")));
        assert!(!demo_requested(None));
        assert!(!demo_requested(Some("0")));
        assert!(!demo_requested(Some("yes")));
    }

    #[test]
    fn empty_library_copy_distinguishes_missing_bottles_from_empty_bottles() {
        assert_eq!(
            empty_library_message(false, 0, 0),
            "No bottles yet"
        );
        assert_eq!(
            empty_library_message(false, 2, 0),
            "No games in this bottle"
        );
        assert_eq!(
            empty_library_message(false, 2, 5),
            "没有找到匹配的游戏"
        );
        assert_eq!(
            empty_library_message(true, 0, 0),
            "没有找到匹配的游戏"
        );
    }

    #[test]
    fn play_time_omits_zero_and_formats_hours_and_minutes() {
        assert_eq!(format_play_time(None), None);
        assert_eq!(format_play_time(Some(0)), None);
        assert_eq!(format_play_time(Some(30)).as_deref(), Some("1 分钟"));
        assert_eq!(format_play_time(Some(275 * 60)).as_deref(), Some("4 小时 35 分钟"));
        assert_eq!(format_play_time(Some(2 * 3600)).as_deref(), Some("2 小时"));
    }

    #[test]
    fn last_played_formats_unix_seconds_as_a_date() {
        assert_eq!(format_last_played(None), None);
        assert_eq!(format_last_played(Some(0)).as_deref(), Some("1970-01-01"));
        assert_eq!(
            format_last_played(Some(1_792_492_764)).as_deref(),
            Some("2026-10-20")
        );
    }

    #[test]
    fn release_year_is_derived_only_from_a_numeric_date() {
        let mut game = demo_data()[0].clone();
        assert_eq!(game.year(), Some("2024"));
        game.release = Some("unknown".into());
        assert_eq!(game.year(), None);
        game.release = None;
        assert_eq!(game.year(), None);
    }
}
