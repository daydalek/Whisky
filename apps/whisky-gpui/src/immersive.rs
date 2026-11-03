//! Selection logic for the immersive library presentation (the Apple TV-style
//! game shelf). Everything here is pure: it ranks and buckets the already
//! filtered/sorted index list, so the view only has to draw what it is given.

use crate::model::Game;

/// Featured carousel size.
pub(crate) const FEATURED_LIMIT: usize = 6;
/// The "继续游玩" row caps at twenty entries, like the shelf's own rows.
const RESUME_LIMIT: usize = 20;

/// The bridge's recency key: `GameActivity.lastSessionEndedAt` first, the
/// older `lastPlayed` as fallback — the same key the `recent` sort uses.
fn last_activity(game: &Game) -> Option<u64> {
    game.last_session_ended_at.or(game.last_played)
}

/// Hero slide order, as indices into `games`.
///
/// Non-launchers only. Recently played entries come first (most recent
/// first), then entries with recorded play time (most played first), then
/// everything else in `ordered` order. Entries with artwork are preferred:
/// an art-less entry joins the carousel only when fewer than `limit`
/// entries have art.
pub(crate) fn featured(games: &[Game], ordered: &[usize], limit: usize) -> Vec<usize> {
    if limit == 0 {
        return Vec::new();
    }
    let playable: Vec<usize> = ordered
        .iter()
        .copied()
        .filter(|&i| games.get(i).is_some_and(|game| !game.is_launcher))
        .collect();
    let mut recent: Vec<usize> = playable
        .iter()
        .copied()
        .filter(|&i| last_activity(&games[i]).is_some())
        .collect();
    recent.sort_by(|a, b| last_activity(&games[*b]).cmp(&last_activity(&games[*a])));
    let mut played: Vec<usize> = playable
        .iter()
        .copied()
        .filter(|&i| last_activity(&games[i]).is_none() && games[i].play_time.unwrap_or(0) > 0)
        .collect();
    played.sort_by(|a, b| games[*b].play_time.cmp(&games[*a].play_time));
    let mut ranked: Vec<usize> = Vec::with_capacity(playable.len());
    ranked.extend(recent);
    ranked.extend(played);
    for index in playable {
        if !ranked.contains(&index) {
            ranked.push(index);
        }
    }
    let mut chosen: Vec<usize> = ranked
        .iter()
        .copied()
        .filter(|&i| games[i].art.is_some())
        .take(limit)
        .collect();
    for index in ranked {
        if chosen.len() >= limit {
            break;
        }
        if !chosen.contains(&index) {
            chosen.push(index);
        }
    }
    chosen
}

/// Stable identity for one strip, folded into element ids and the scroll
/// handle map so the same card can live in two rows without collisions.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RowKey {
    Resume,
    /// One-based bottle slot, matching `Game::bottle` and the sidebar.
    Bottle(usize),
    All,
    Launchers,
}

impl RowKey {
    pub(crate) fn name(self) -> String {
        match self {
            RowKey::Resume => "resume".to_owned(),
            RowKey::Bottle(slot) => format!("bottle-{slot}"),
            RowKey::All => "all".to_owned(),
            RowKey::Launchers => "launchers".to_owned(),
        }
    }
}

/// One horizontally scrolling strip on the immersive page.
pub(crate) struct Row {
    pub(crate) key: RowKey,
    pub(crate) title: String,
    pub(crate) indices: Vec<usize>,
}

/// The sections under the hero, in display order:
///
/// 1. "继续游玩" — non-launchers with a recorded session, most recent first
///    (max 20, omitted when empty).
/// 2. Whole-library view with more than one bottle: one row per bottle,
///    holding that bottle's non-launchers in `ordered` order. Otherwise a
///    single "全部游戏" row. Empty sections are skipped.
/// 3. "启动器" — storefront clients, always last (omitted when empty).
pub(crate) fn rows(
    games: &[Game],
    ordered: &[usize],
    selected_bottle: Option<usize>,
    bottles_count: usize,
    bottle_name: impl Fn(usize) -> String,
) -> Vec<Row> {
    let mut out = Vec::new();
    let mut resume: Vec<usize> = ordered
        .iter()
        .copied()
        .filter(|&i| {
            games
                .get(i)
                .is_some_and(|game| !game.is_launcher && last_activity(game).is_some())
        })
        .collect();
    resume.sort_by(|a, b| last_activity(&games[*b]).cmp(&last_activity(&games[*a])));
    resume.truncate(RESUME_LIMIT);
    if !resume.is_empty() {
        out.push(Row {
            key: RowKey::Resume,
            title: "继续游玩".to_owned(),
            indices: resume,
        });
    }
    if selected_bottle.is_none() && bottles_count > 1 {
        for slot in 1..=bottles_count {
            let indices: Vec<usize> = ordered
                .iter()
                .copied()
                .filter(|&i| {
                    games
                        .get(i)
                        .is_some_and(|game| !game.is_launcher && game.bottle == slot)
                })
                .collect();
            if !indices.is_empty() {
                out.push(Row {
                    key: RowKey::Bottle(slot),
                    title: bottle_name(slot),
                    indices,
                });
            }
        }
    } else {
        let indices: Vec<usize> = ordered
            .iter()
            .copied()
            .filter(|&i| games.get(i).is_some_and(|game| !game.is_launcher))
            .collect();
        if !indices.is_empty() {
            out.push(Row {
                key: RowKey::All,
                title: "全部游戏".to_owned(),
                indices,
            });
        }
    }
    let launchers: Vec<usize> = ordered
        .iter()
        .copied()
        .filter(|&i| games.get(i).is_some_and(|game| game.is_launcher))
        .collect();
    if !launchers.is_empty() {
        out.push(Row {
            key: RowKey::Launchers,
            title: "启动器".to_owned(),
            indices: launchers,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::{featured, last_activity, rows, RowKey};
    use crate::model::{demo_data, Game};

    fn game(index: usize) -> Game {
        demo_data()[index % 20].clone()
    }

    #[test]
    fn featured_ranks_recency_then_play_time_then_library_order() {
        // Recency outranks play time, which outranks plain library order.
        let mut games: Vec<Game> = (0..5).map(game).collect();
        games[0].play_time = Some(600);
        games[2].play_time = Some(3_600);
        games[4].last_session_ended_at = Some(100);
        games[1].last_played = Some(200);
        games[3].last_session_ended_at = Some(300);
        let ordered = [0, 1, 2, 3, 4];
        assert_eq!(featured(&games, &ordered, 6), vec![3, 1, 4, 2, 0]);
    }

    #[test]
    fn featured_excludes_launchers_and_respects_the_limit() {
        let mut games: Vec<Game> = (0..5).map(game).collect();
        games[0].is_launcher = true;
        games[0].last_played = Some(999);
        let ordered = [0, 1, 2, 3, 4];
        assert_eq!(featured(&games, &ordered, 3), vec![1, 2, 3]);
    }

    #[test]
    fn featured_prefers_entries_with_artwork() {
        // With only two covers, the third slide is the best-ranked art-less
        // entry rather than a third coverless pick ahead of the art.
        let mut games: Vec<Game> = (0..5).map(game).collect();
        games[0].art = None;
        games[1].art = None;
        games[2].art = None;
        games[0].last_played = Some(500);
        games[3].last_played = Some(400);
        games[4].last_played = Some(300);
        let ordered = [0, 1, 2, 3, 4];
        assert_eq!(featured(&games, &ordered, 3), vec![3, 4, 0]);
    }

    #[test]
    fn featured_keeps_rank_order_when_enough_entries_have_art() {
        let mut games: Vec<Game> = (0..4).map(game).collect();
        games[0].art = None;
        games[0].last_played = Some(900);
        games[1].last_played = Some(800);
        let ordered = [0, 1, 2, 3];
        assert_eq!(featured(&games, &ordered, 3), vec![1, 2, 3]);
    }

    #[test]
    fn featured_never_duplicates_an_entry() {
        let mut games: Vec<Game> = (0..3).map(game).collect();
        games[0].last_played = Some(10);
        games[0].play_time = Some(60);
        games[1].play_time = Some(30);
        let ordered = [0, 1, 2];
        let chosen = featured(&games, &ordered, 6);
        assert_eq!(chosen.len(), 3);
        let mut deduped = chosen.clone();
        deduped.dedup();
        let mut sorted = chosen.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(chosen.len(), sorted.len());
        assert_eq!(deduped, chosen);
    }

    #[test]
    fn rows_groups_by_bottle_when_the_whole_library_is_visible() {
        // The demo snapshot: ten games in bottle 1, ten in bottle 2.
        let games = demo_data();
        let ordered: Vec<usize> = (0..games.len()).collect();
        let names = |slot: usize| format!("bottle {slot}");
        let sections = rows(games, &ordered, None, 2, names);
        assert_eq!(sections.len(), 2);
        assert_eq!(sections[0].key, RowKey::Bottle(1));
        assert_eq!(sections[0].title, "bottle 1");
        assert_eq!(sections[0].indices.len(), 10);
        assert_eq!(sections[1].key, RowKey::Bottle(2));
        assert_eq!(sections[1].indices.len(), 10);
    }

    #[test]
    fn rows_falls_back_to_all_games_for_a_single_bottle_scope() {
        let games = demo_data();
        let ordered: Vec<usize> = (0..games.len()).filter(|&i| games[i].bottle == 2).collect();
        let sections = rows(games, &ordered, Some(1), 2, |slot| format!("bottle {slot}"));
        assert_eq!(sections.len(), 1);
        assert_eq!(sections[0].key, RowKey::All);
        assert_eq!(sections[0].title, "全部游戏");
        assert_eq!(sections[0].indices.len(), 10);
        // A one-bottle library shows the same single row.
        let sections = rows(games, &ordered, None, 1, |slot| format!("bottle {slot}"));
        assert_eq!(sections.len(), 1);
        assert_eq!(sections[0].key, RowKey::All);
    }

    #[test]
    fn rows_puts_recent_games_first_and_launchers_last() {
        let mut games: Vec<Game> = (0..5).map(game).collect();
        games[0].last_played = Some(50);
        games[2].last_session_ended_at = Some(80);
        games[4].is_launcher = true;
        let ordered = [0, 1, 2, 3, 4];
        let sections = rows(&games, &ordered, None, 1, |_| "only".to_owned());
        assert_eq!(sections.len(), 3);
        assert_eq!(sections[0].key, RowKey::Resume);
        // Most recent first.
        assert_eq!(sections[0].indices, vec![2, 0]);
        assert_eq!(sections[1].key, RowKey::All);
        assert_eq!(sections[1].indices, vec![0, 1, 2, 3]);
        assert_eq!(sections[2].key, RowKey::Launchers);
        assert_eq!(sections[2].indices, vec![4]);
    }

    #[test]
    fn rows_omits_empty_sections() {
        let games: Vec<Game> = (0..3).map(game).collect();
        assert!(games.iter().all(|game| last_activity(game).is_none()));
        let sections = rows(&games, &[0, 1, 2], None, 1, |_| "only".to_owned());
        assert_eq!(sections.len(), 1);
        assert_eq!(sections[0].key, RowKey::All);
        // An empty library produces no rows at all.
        assert!(rows(&games, &[], None, 1, |_| "only".to_owned()).is_empty());
    }

    #[test]
    fn resume_row_caps_at_twenty_entries() {
        let mut games: Vec<Game> = (0..25).map(game).collect();
        for (index, game) in games.iter_mut().enumerate() {
            game.last_played = Some(index as u64);
        }
        let ordered: Vec<usize> = (0..games.len()).collect();
        let sections = rows(&games, &ordered, None, 1, |_| "only".to_owned());
        assert_eq!(sections[0].indices.len(), 20);
        // Most recent (index 24) leads.
        assert_eq!(sections[0].indices[0], 24);
    }
}
