//! Pure library browsing: aggregation, query matching, and sort order.
//!
//! Nothing here touches a window or the bridge, so the rules can be tested
//! headlessly. The view layer only supplies the loaded entries and bottle
//! names, and caches the resulting index lists instead of recomputing them per
//! frame.

use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};

use crate::model::{BottleVm, Game};

/// Merge per-bottle caches in sidebar order.
///
/// Internal identity is `(container, entry id)`: the caches keep every bottle's
/// records separate. Bridge ids are themselves bottle-scoped (`pinned:` and
/// `steam:` both embed the path), so an id-only rule would never collapse a
/// cross-bottle duplicate. The display list is therefore de-duplicated on
/// `(title, artwork)` exactly as specified: the artwork key is its path
/// relative to the bottle, which is identical for the Steam cache and in-bottle
/// icons of the same game while remaining distinct for a separate install.
/// The first bottle in sidebar order wins.
pub(crate) fn merge_bottles(
    bottles: &[BottleVm],
    caches: &BTreeMap<String, Vec<Game>>,
) -> Vec<Game> {
    let mut seen: BTreeSet<(String, Option<String>)> = BTreeSet::new();
    let mut merged = Vec::new();
    for bottle in bottles {
        for game in caches.get(&bottle.path).into_iter().flatten() {
            if seen.insert((game.title.clone(), artwork_key(game))) {
                merged.push(game.clone());
            }
        }
    }
    merged
}

/// Artwork identity without the bottle prefix: `None` when there is no art.
fn artwork_key(game: &Game) -> Option<String> {
    let art = game.art.as_ref()?;
    let path = art.to_string_lossy();
    let container = game.container.trim_end_matches('/');
    if !container.is_empty()
        && let Some(relative) = path.strip_prefix(container)
    {
        return Some(relative.trim_start_matches('/').to_owned());
    }
    // Artwork outside the bottle (a test fixture, or a future shared cache):
    // the file name is the only stable part.
    art.file_name()
        .map(|name| name.to_string_lossy().into_owned())
}

/// `LibrarySort` (`WhiskyCore/LibraryOrdering.swift:21`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Sort {
    Recent,
    Name,
    Bottle,
}

impl Sort {
    pub(crate) fn from_index(index: usize) -> Self {
        match index {
            1 => Self::Name,
            2 => Self::Bottle,
            _ => Self::Recent,
        }
    }
}

/// Clicking the current star clears the rating; any other star selects it.
pub(crate) fn next_rating(current: Option<u8>, star: u8) -> Option<u8> {
    if current == Some(star) { None } else { Some(star) }
}

/// Case-insensitive match over the name, developer, and release year.
pub(crate) fn matches_query(game: &Game, query: &str) -> bool {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return true;
    }
    game.title.to_lowercase().contains(&query)
        || game.studio().to_lowercase().contains(&query)
        || game
            .year()
            .is_some_and(|year| year.to_lowercase().contains(&query))
}

/// Indices in the visible scope, before ordering. `slot` is one-based and `0`
/// means the whole library.
pub(crate) fn filter_indices(
    games: &[Game],
    query: &str,
    slot: usize,
    show_hidden: bool,
) -> Vec<usize> {
    (0..games.len())
        .filter(|&index| {
            let game = &games[index];
            (slot == 0 || game.bottle == slot)
                && (show_hidden || !game.hidden)
                && matches_query(game, query)
        })
        .collect()
}

/// Order `indices` in place. The tie-break is always the name, matching
/// `LibraryOrdering.byName`, so the result is deterministic.
pub(crate) fn sort_indices(
    games: &[Game],
    indices: &mut [usize],
    sort: Sort,
    bottles: &[BottleVm],
) {
    indices.sort_by(|&first, &second| {
        compare(games, bottles, sort, first, second).then_with(|| first.cmp(&second))
    });
}

fn compare(
    games: &[Game],
    bottles: &[BottleVm],
    sort: Sort,
    first: usize,
    second: usize,
) -> Ordering {
    let first_game = &games[first];
    let second_game = &games[second];
    let primary = match sort {
        // `recent` puts the newest confirmed session first and dated entries
        // before undated ones (`LibraryOrdering.sorted`, case `.recent`).
        Sort::Recent => match (
            first_game.last_session_ended_at,
            second_game.last_session_ended_at,
        ) {
            (Some(lhs), Some(rhs)) if lhs != rhs => rhs.cmp(&lhs),
            (Some(_), None) => Ordering::Less,
            (None, Some(_)) => Ordering::Greater,
            _ => Ordering::Equal,
        },
        // `bottle` compares the bottle name, then the container path.
        Sort::Bottle => {
            match natural_cmp(bottle_name(first_game, bottles), bottle_name(second_game, bottles)) {
                Ordering::Equal => first_game.container.cmp(&second_game.container),
                ordering => ordering,
            }
        }
        Sort::Name => Ordering::Equal,
    };
    if primary != Ordering::Equal {
        return primary;
    }
    match natural_cmp(&first_game.title, &second_game.title) {
        Ordering::Equal => match first_game.container.cmp(&second_game.container) {
            Ordering::Equal => first_game.id.cmp(&second_game.id),
            ordering => ordering,
        },
        ordering => ordering,
    }
}

fn bottle_name<'a>(game: &Game, bottles: &'a [BottleVm]) -> &'a str {
    game.bottle
        .checked_sub(1)
        .and_then(|index| bottles.get(index))
        .map_or("", |bottle| bottle.name.as_str())
}

/// Finder-style comparison: case-insensitive and numeric-aware. The Swift app
/// uses `localizedStandardCompare`; for the ASCII and CJK titles in the
/// library this matches it, with the documented difference that collation is
/// by scalar value rather than the user's locale.
pub(crate) fn natural_cmp(first: &str, second: &str) -> Ordering {
    let first: Vec<char> = first.to_lowercase().chars().collect();
    let second: Vec<char> = second.to_lowercase().chars().collect();
    let (mut left, mut right) = (0, 0);
    while left < first.len() && right < second.len() {
        if first[left].is_ascii_digit() && second[right].is_ascii_digit() {
            let first_start = left;
            while left < first.len() && first[left].is_ascii_digit() {
                left += 1;
            }
            let second_start = right;
            while right < second.len() && second[right].is_ascii_digit() {
                right += 1;
            }
            let first_number: String = first[first_start..left].iter().collect();
            let second_number: String = second[second_start..right].iter().collect();
            let first_trimmed = first_number.trim_start_matches('0');
            let second_trimmed = second_number.trim_start_matches('0');
            let ordering = first_trimmed
                .len()
                .cmp(&second_trimmed.len())
                .then_with(|| first_trimmed.cmp(second_trimmed))
                .then_with(|| first_number.len().cmp(&second_number.len()));
            if ordering != Ordering::Equal {
                return ordering;
            }
            continue;
        }
        match first[left].cmp(&second[right]) {
            Ordering::Equal => {
                left += 1;
                right += 1;
            }
            ordering => return ordering,
        }
    }
    first.len().cmp(&second.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bottle(name: &str) -> BottleVm {
        BottleVm {
            path: format!("/bottles/{name}"),
            name: name.into(),
            available: true,
        }
    }

    fn game(
        id: &str,
        title: &str,
        studio: &str,
        release: &str,
        slot: usize,
        container: &str,
    ) -> Game {
        Game {
            id: id.into(),
            art: Some(std::path::PathBuf::from(format!("/covers/{title}.jpg"))),
            title: title.into(),
            studio: (!studio.is_empty()).then(|| studio.into()),
            description: None,
            release: (!release.is_empty()).then(|| release.into()),
            landscape: false,
            bottle: slot,
            hidden: false,
            rating: None,
            play_time: None,
            last_played: None,
            executable: None,
            needs_executable: false,
            container: container.into(),
            last_session_ended_at: None,
        }
    }

    #[test]
    fn aggregation_tags_two_bottles_and_only_de_duplicates_identical_cards() {
        let bottles = [bottle("galgame"), bottle("galgame-win7")];
        let same_art = std::path::PathBuf::from("/covers/Same.jpg");
        let mut first = game("steam:10", "Same", "Key", "2000-01-01", 1, &bottles[0].path);
        first.art = Some(same_art.clone());
        let unique = game("steam:11", "Unique", "", "", 1, &bottles[0].path);
        let mut duplicate = game("steam:10", "Same", "Key", "2000-01-01", 2, &bottles[1].path);
        duplicate.art = Some(same_art.clone());
        let mut separate = game("steam:10", "Same", "Key", "2000-01-01", 2, &bottles[1].path);
        separate.art = Some(std::path::PathBuf::from("/covers/Other.jpg"));

        let mut caches = BTreeMap::new();
        caches.insert(bottles[0].path.clone(), vec![first.clone(), unique.clone()]);
        caches.insert(bottles[1].path.clone(), vec![duplicate, separate.clone()]);

        let merged = merge_bottles(&bottles, &caches);
        assert_eq!(merged.len(), 3);
        assert_eq!(merged[0].title, "Same");
        assert_eq!(merged[0].container, bottles[0].path, "first bottle wins");
        assert_eq!(merged[1].title, "Unique");
        assert_eq!(merged[1].container, bottles[0].path);
        // Different artwork means a genuinely separate install: both rows stay.
        assert_eq!(merged[2].container, bottles[1].path);

        // Rebuilding from the same caches is idempotent (no duplicate cards).
        let refreshed = merge_bottles(&bottles, &caches);
        assert_eq!(refreshed.len(), merged.len());
        assert_eq!(
            refreshed
                .iter()
                .map(|game| (&game.id, &game.container))
                .collect::<Vec<_>>(),
            merged
                .iter()
                .map(|game| (&game.id, &game.container))
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn the_same_steam_game_in_two_bottles_shows_once_even_though_ids_and_paths_differ() {
        // Real ids embed the bottle path (`steam:<path>:<appID>`), and Steam's
        // artwork lives inside each bottle, so only the bottle-relative path
        // identifies the same cover.
        let bottles = [bottle("galgame"), bottle("galgame-win7")];
        let mut first = game(
            &format!("steam:{}/drive_c/Steam:10", bottles[0].path),
            "Same Game",
            "Key",
            "2000-01-01",
            1,
            &bottles[0].path,
        );
        first.art = Some(std::path::PathBuf::from(format!(
            "{}/drive_c/Steam/appcache/librarycache/10/library_600x900.jpg",
            bottles[0].path
        )));
        let mut second = game(
            &format!("steam:{}/drive_c/Steam:10", bottles[1].path),
            "Same Game",
            "Key",
            "2000-01-01",
            2,
            &bottles[1].path,
        );
        second.art = Some(std::path::PathBuf::from(format!(
            "{}/drive_c/Steam/appcache/librarycache/10/library_600x900.jpg",
            bottles[1].path
        )));

        let mut caches = BTreeMap::new();
        caches.insert(bottles[0].path.clone(), vec![first]);
        caches.insert(bottles[1].path.clone(), vec![second]);

        let merged = merge_bottles(&bottles, &caches);
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].container, bottles[0].path);
    }

    #[test]
    fn an_entry_belongs_to_the_bottle_that_reported_it() {
        let bottles = [bottle("one"), bottle("two")];
        let mut caches = BTreeMap::new();
        caches.insert(
            bottles[1].path.clone(),
            vec![game("pinned:/a", "A", "", "", 2, &bottles[1].path)],
        );
        let merged = merge_bottles(&bottles, &caches);
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0].bottle, 2);
        assert_eq!(merged[0].container, bottles[1].path);
    }

    #[test]
    fn search_matches_name_developer_and_year_for_cjk_and_ascii() {
        let spring = game("a", "春之回声", "Sample Studio", "2004-07-23", 1, "/b");
        let air = game("b", "Northwind Signal", "Folded Atlas", "2000-09-08", 1, "/b");

        assert!(matches_query(&spring, " 春之回声 "));
        assert!(matches_query(&spring, "SAMPLE STUDIO"));
        assert!(matches_query(&spring, "2004"));
        assert!(matches_query(&spring, "  200 "));

        assert!(matches_query(&air, "northwind"));
        assert!(matches_query(&air, "folded atlas"));
        assert!(matches_query(&air, "2000"));

        // An empty or whitespace-only query matches everything.
        assert!(matches_query(&air, ""));
        assert!(matches_query(&air, "   "));

        assert!(!matches_query(&air, "sample studio"));
        assert!(!matches_query(&spring, "northwind"));
        assert!(!matches_query(&spring, "1999"));
    }

    #[test]
    fn hidden_entries_leave_the_grid_and_reappear_under_the_filter() {
        let games = [
            game("a", "Visible", "", "", 1, "/b"),
            game("b", "Hidden", "", "", 1, "/b"),
        ];
        let mut hidden = games[1].clone();
        hidden.hidden = true;
        let games = [games[0].clone(), hidden];

        assert_eq!(filter_indices(&games, "", 1, false), vec![0]);
        assert_eq!(filter_indices(&games, "", 1, true), vec![0, 1]);
        // The whole-library scope sees the same hidden state.
        assert_eq!(filter_indices(&games, "", 0, false), vec![0]);
        // A bottle scope still applies the slot filter.
        assert!(filter_indices(&games, "", 2, true).is_empty());
    }

    fn sorted(games: &[Game], sort: Sort, bottles: &[BottleVm]) -> Vec<String> {
        let mut indices: Vec<usize> = (0..games.len()).collect();
        sort_indices(games, &mut indices, sort, bottles);
        indices
            .into_iter()
            .map(|index| games[index].title.clone())
            .collect()
    }

    #[test]
    fn recent_orders_by_confirmed_session_then_name() {
        let bottles = [bottle("galgame")];
        let mut alpha = game("a", "Alpha", "", "", 1, &bottles[0].path);
        alpha.last_session_ended_at = Some(100);
        let mut beta = game("b", "Beta", "", "", 1, &bottles[0].path);
        beta.last_session_ended_at = Some(300);
        let delta = game("c", "Delta", "", "", 1, &bottles[0].path);
        let charlie = game("d", "Charlie", "", "", 1, &bottles[0].path);

        let games = [alpha, beta, delta, charlie];
        assert_eq!(
            sorted(&games, Sort::Recent, &bottles),
            ["Beta", "Alpha", "Charlie", "Delta"]
        );
    }

    #[test]
    fn name_is_case_insensitive_and_numeric_aware() {
        let bottles = [bottle("galgame")];
        let games = [
            game("a", "Game 10", "", "", 1, &bottles[0].path),
            game("b", "game 2", "", "", 1, &bottles[0].path),
            game("c", "Game 1", "", "", 1, &bottles[0].path),
        ];
        assert_eq!(
            sorted(&games, Sort::Name, &bottles),
            ["Game 1", "game 2", "Game 10"]
        );
        assert_eq!(natural_cmp("Sample", "sample"), Ordering::Equal);
        assert_eq!(natural_cmp("a", "B"), Ordering::Less);
    }

    #[test]
    fn bottle_sorts_by_bottle_name_then_entry_name() {
        let bottles = [bottle("alpha"), bottle("beta")];
        let games = [
            game("a", "Zeta", "", "", 1, &bottles[0].path),
            game("b", "Alpha", "", "", 2, &bottles[1].path),
            game("c", "Beta", "", "", 1, &bottles[0].path),
        ];
        assert_eq!(
            sorted(&games, Sort::Bottle, &bottles),
            ["Beta", "Zeta", "Alpha"]
        );
    }

    #[test]
    fn clicking_the_current_star_clears_the_rating() {
        assert_eq!(next_rating(None, 3), Some(3));
        assert_eq!(next_rating(Some(2), 3), Some(3));
        assert_eq!(next_rating(Some(3), 3), None);
        // The panel only offers 1..=5.
        assert_eq!(next_rating(Some(5), 1), Some(1));
    }

    #[test]
    fn sort_indices_map_to_the_swift_option_order() {
        // The toolbar stores indices in `LibrarySort` declaration order:
        // recent (0), name (1), bottle (2).
        assert_eq!(Sort::from_index(0), Sort::Recent);
        assert_eq!(Sort::from_index(1), Sort::Name);
        assert_eq!(Sort::from_index(2), Sort::Bottle);
        assert_eq!(Sort::from_index(99), Sort::Recent);
    }
}
