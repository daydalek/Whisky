//! View-model types and the static presentation snapshot used until M1b.
//!
//! Regenerate the snapshot with tools/import_whisky_artwork.py. Sample play
//! times/ratings are supplied by the demo, not exported from the app.
use std::path::PathBuf;

#[derive(Clone, Copy)]
pub(crate) struct Game {
    pub(crate) art: &'static str,
    pub(crate) title: &'static str,
    pub(crate) studio: &'static str,
    pub(crate) description: &'static str,
    pub(crate) release: &'static str,
    pub(crate) landscape: bool,
    pub(crate) bottle: usize,
}

const GAMES: &[Game] = &[

Game { art: r####"astral.png"####, title: r####"Northwind Signal"####, studio: r####"Folded Atlas"####, description: r####"A quiet coastal town, a radio that only plays at night, and one winter worth staying for."####, release: r####"2024-03-12"####, landscape: true, bottle: 1 },
Game { art: r####"dune.png"####, title: r####"Saltlight"####, studio: r####"Hollow Studio"####, description: r####"Two travellers cross a dry sea bed, trading stories for directions neither of them trusts."####, release: r####"2023-08-30"####, landscape: true, bottle: 1 },
Game { art: r####"echo.png"####, title: r####"Quiet Frequency"####, studio: r####"Meridian Works"####, description: r####"An archivist tunes a broken transmitter and hears the answers she stopped waiting for."####, release: r####"2025-01-17"####, landscape: true, bottle: 1 },
Game { art: r####"ember.png"####, title: r####"Emberline"####, studio: r####"Foxglove Interactive"####, description: r####"A forge at the edge of the district keeps its furnace lit long after the city gave up on it."####, release: r####"2022-11-04"####, landscape: true, bottle: 1 },
Game { art: r####"frost.png"####, title: r####"Glass Harbour"####, studio: r####"Northgate Games"####, description: r####"Harbour lights, a borrowed boat, and the slow work of saying what should have been said."####, release: r####"2024-06-21"####, landscape: true, bottle: 1 },
Game { art: r####"lumen.png"####, title: r####"Paper Lanterns"####, studio: r####"Studio Aube"####, description: r####"A festival, a list of small promises, and one evening to keep all of them."####, release: r####"2021-09-09"####, landscape: true, bottle: 1 },
Game { art: r####"neon.png"####, title: r####"Neon Transit"####, studio: r####"Halfstep"####, description: r####"Late trains, brighter streets, and a map that only makes sense after midnight."####, release: r####"2025-05-02"####, landscape: true, bottle: 1 },
Game { art: r####"orbit.png"####, title: r####"Orbit Café"####, studio: r####"Longform Labs"####, description: r####"A station café serves the same coffee to the same three people for a very long year."####, release: r####"2023-02-14"####, landscape: true, bottle: 1 },
Game { art: r####"tide.png"####, title: r####"Tidewater"####, studio: r####"Bluecap"####, description: r####"A tide chart, an empty house, and the summer it took to decide what to keep."####, release: r####"2022-07-08"####, landscape: true, bottle: 1 },
Game { art: r####"verdant.png"####, title: r####"Verdant Hours"####, studio: r####"Greenfield"####, description: r####"A greenhouse, a stubborn garden, and the neighbours who slowly become the reason to stay."####, release: r####"2024-10-25"####, landscape: true, bottle: 1 },
Game { art: r####"astral.png"####, title: r####"Second Sun"####, studio: r####"Folded Atlas"####, description: r####"A long dusk over the flats, and two surveyors arguing gently about the way home."####, release: r####"2020-04-18"####, landscape: true, bottle: 2 },
Game { art: r####"dune.png"####, title: r####"Dune Road"####, studio: r####"Hollow Studio"####, description: r####"One road, one broken truck, and the town at the end of it that has been waiting."####, release: r####"2021-12-03"####, landscape: true, bottle: 2 },
Game { art: r####"echo.png"####, title: r####"Echo Chamber"####, studio: r####"Meridian Works"####, description: r####"A sound engineer records a room that keeps answering back, one day late."####, release: r####"2023-06-11"####, landscape: true, bottle: 2 },
Game { art: r####"ember.png"####, title: r####"Ember & Ash"####, studio: r####"Foxglove Interactive"####, description: r####"Two sisters reopen the bakery their grandmother closed, one recipe at a time."####, release: r####"2019-10-29"####, landscape: true, bottle: 2 },
Game { art: r####"frost.png"####, title: r####"Frostbound"####, studio: r####"Northgate Games"####, description: r####"A winter route, a stalled train, and the strangers who keep each other awake."####, release: r####"2022-01-20"####, landscape: true, bottle: 2 },
Game { art: r####"lumen.png"####, title: r####"Lumen Field"####, studio: r####"Studio Aube"####, description: r####"A field station tracks a light that returns every eleven years, and so does she."####, release: r####"2024-02-08"####, landscape: true, bottle: 2 },
Game { art: r####"neon.png"####, title: r####"Afterglow Drive"####, studio: r####"Halfstep"####, description: r####"A night shift, a borrowed car, and every errand that turns into a confession."####, release: r####"2025-07-16"####, landscape: true, bottle: 2 },
Game { art: r####"orbit.png"####, title: r####"Low Orbit"####, studio: r####"Longform Labs"####, description: r####"A courier, a very old satellite, and the last scheduled call of the week."####, release: r####"2021-05-27"####, landscape: true, bottle: 2 },
Game { art: r####"tide.png"####, title: r####"Undertow"####, studio: r####"Bluecap"####, description: r####"A swimming coach, a difficult season, and the return that nobody expected."####, release: r####"2020-11-13"####, landscape: true, bottle: 2 },
Game { art: r####"verdant.png"####, title: r####"Evergreen"####, studio: r####"Greenfield"####, description: r####"A caretaker plants for the people who will arrive after he is gone."####, release: r####"2023-09-01"####, landscape: true, bottle: 2 },
];

/// The demo library. M1b replaces this with `library.entries` bridge data.
pub(crate) fn demo_data() -> &'static [Game] {
    GAMES
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
    asset(demo_data()[i].art)
}
pub(crate) fn ambient(i: usize) -> PathBuf {
    asset(format!("{i}-ambient.jpg"))
}
