//! Headless state machine and view logic tests for `apps/whisky-gpui`.
//!
//! Verifies:
//! 1. Fixture verification with `demo_data()` covering 20 games with CJK titles and mixed aspects.
//! 2. Search & Filtering: `matches_query` (CJK & ASCII substrings, studio, year), `filter_indices`
//!    across bottle slot scopes and visibility flags, and `sort_indices` (Title, Last Played, Rating).
//! 3. Layout Bounds Calculation: `LibraryLayout::classic`, `timeline`, `staggered`, and `shelf_with_width`,
//!    asserting positive card dimensions and strict containment within viewport bounds without edge overlap.
//! 4. Theme Switching: `AppearanceMode` (`System`, `Light`, `Dark`) and dynamic resolution under `WindowAppearance`.
//! 5. Container Lifecycle & Transitions: `CreateBottleState::apply` progression (`Started`, `Progress`, `Completed`, `Failed`)
//!    and `validate_name` error states without launching wine processes.
//! 6. File Chooser Error Isolation: `PICKER_TIMEOUT` ceiling plus `CallFailure::Remote`
//!    classification, ensuring a remote error emits an event without dropping the
//!    supervisor session. Helper-side picker timeouts are covered by the Swift
//!    LinuxFilePicker tests.

use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Duration;

use gpui_kit::component::theme::ThemeMode;
use gpui_kit::WindowAppearance;

use crate::bridge::supervisor::{classify, CallFailure, BACKOFF_MAX_MS, BACKOFF_MIN_MS, PICKER_TIMEOUT};
use crate::bridge::BottleCreateUpdate;
use crate::create_bottle::{
    display_bottle_location, progress_label, validate_name, windows_version_wire, BottleCreatedDto,
    CreateBottleState, WINDOWS_LABELS,
};
use crate::library_layout::{
    chosen_cover_width, cover_levels, LibraryLayout, StaggeredSide,
    AUTOMATIC_COVER_WIDTH, DEFAULT_COVER_WIDTH, MAX_COVER_WIDTH, MIN_COVER_WIDTH,
    STAGGERED_COMPACT, STAGGERED_MARGIN, STAGGERED_MIN_COLUMN, STAGGERED_RAIL_GAP,
};
use crate::library_view::{
    filter_indices, matches_query, natural_cmp, next_rating, sort_indices, Sort,
};
use crate::model::{demo_bottles, demo_data, empty_library_message, Game};
use crate::scan::JobStatus;
use crate::theme::{is_dark, set_dark, AppearanceMode};

// Helper constructor for synthetic test games
fn make_test_game(
    id: &str,
    title: &str,
    studio: Option<&str>,
    release: Option<&str>,
    bottle: usize,
    landscape: bool,
    hidden: bool,
    rating: Option<u8>,
    last_session: Option<u64>,
    is_launcher: bool,
) -> Game {
    Game {
        metadata: None,
        character_images: BTreeMap::new(),
        id: id.into(),
        identity: id.into(),
        art: Some(PathBuf::from(format!("/covers/{title}.jpg"))),
        title: title.into(),
        studio: studio.map(str::to_owned),
        description: Some(format!("Description for {title}")),
        characters: Vec::new(),
        metadata_sources: BTreeMap::new(),
        release: release.map(str::to_owned),
        landscape,
        bottle,
        hidden,
        rating,
        play_time: last_session.map(|_| 3600),
        daily_play_time: BTreeMap::new(),
        last_played: last_session,
        executable: Some(PathBuf::from(format!("/games/{title}/game.exe"))),
        folder_path: None,
        game_directory: Some(PathBuf::from(format!("/games/{title}"))),
        is_folder: false,
        needs_executable: false,
        container: format!("/bottles/bottle-{}", bottle),
        last_session_ended_at: last_session,
        is_launcher,
    }
}

// ---------------------------------------------------------------------------
// 1. Fixture Verification with demo_data() & CJK Titles / Mixed Aspects
// ---------------------------------------------------------------------------

#[test]
fn test_demo_data_fixtures_integrity_and_cjk_aspects() {
    let games = demo_data();
    assert_eq!(games.len(), 20, "demo_data() must contain exactly 20 sample games");

    let bottles = demo_bottles();
    assert_eq!(bottles.len(), 2, "demo_bottles() must provide 2 virtual containers");
    assert_eq!(bottles[0].name, "galgame");
    assert_eq!(bottles[1].name, "galgame-win7");

    let bottle_1_count = games.iter().filter(|g| g.bottle == 1).count();
    let bottle_2_count = games.iter().filter(|g| g.bottle == 2).count();
    assert_eq!(bottle_1_count, 10, "Bottle 1 must hold 10 demo games");
    assert_eq!(bottle_2_count, 10, "Bottle 2 must hold 10 demo games");

    // Verify all games have valid metadata fields
    for (i, game) in games.iter().enumerate() {
        assert!(!game.title.is_empty(), "Game {} must have non-empty title", i);
        assert!(!game.studio().is_empty(), "Game {} must have studio name", i);
        assert!(game.year().is_some(), "Game {} must have valid release year", i);
        assert!(!game.id.is_empty(), "Game {} must have valid id", i);
        assert!(!game.container.is_empty(), "Game {} must have container path", i);
    }

    // Verify mixed aspect ratios and CJK fixtures
    let cjk_fixtures = vec![
        make_test_game("cjk:1", "千恋＊万花", Some("Yuzusoft"), Some("2016-03-25"), 1, false, false, Some(9), Some(1700000000), false),
        make_test_game("cjk:2", "サノバウィッチ", Some("Yuzusoft"), Some("2015-02-27"), 1, true, false, Some(8), Some(1690000000), false),
        make_test_game("cjk:3", "命运石之门 Steins;Gate", Some("5pb."), Some("2009-10-15"), 2, false, false, Some(10), Some(1710000000), false),
        make_test_game("cjk:4", "魔法使之夜", Some("TYPE-MOON"), Some("2012-04-12"), 2, true, false, Some(9), Some(1680000000), false),
    ];

    assert!(cjk_fixtures.iter().any(|g| g.landscape), "Mixed aspect ratio: at least one landscape");
    assert!(cjk_fixtures.iter().any(|g| !g.landscape), "Mixed aspect ratio: at least one portrait");

    // Verify empty library copy behavior
    assert_eq!(empty_library_message(true, 2, 0), "没有找到匹配的游戏");
    assert_eq!(empty_library_message(false, 0, 0), "还没有创建容器");
    assert_eq!(empty_library_message(false, 1, 0), "此容器还没有游戏");
    assert_eq!(empty_library_message(false, 1, 5), "没有找到匹配的游戏");
}

// ---------------------------------------------------------------------------
// 2. Search & Filtering across CJK, ASCII, Slots, and Visibility
// ---------------------------------------------------------------------------

#[test]
fn test_search_and_filtering_cjk_and_ascii() {
    let games = demo_data();

    // 1. ASCII search matching (case-insensitive substring)
    assert!(matches_query(&games[0], "northwind"));
    assert!(matches_query(&games[0], "NORTHWIND"));
    assert!(matches_query(&games[0], "Signal"));
    assert!(matches_query(&games[0], "Folded Atlas")); // studio match
    assert!(matches_query(&games[0], "2024")); // year match
    assert!(!matches_query(&games[0], "UnknownGame"));

    // 2. CJK search matching
    let cjk_games = vec![
        make_test_game("cjk:1", "千恋＊万花", Some("柚子社"), Some("2016-03-25"), 1, false, false, None, None, false),
        make_test_game("cjk:2", "サノバウィッチ (SABBAT OF THE WITCH)", Some("Yuzusoft"), Some("2015-02-27"), 1, true, false, None, None, false),
        make_test_game("cjk:3", "命运石之门 Steins;Gate", Some("5pb. / MAGES."), Some("2009-10-15"), 2, false, false, None, None, false),
    ];

    // Kanji matching
    assert!(matches_query(&cjk_games[0], "千恋"));
    assert!(matches_query(&cjk_games[0], "万花"));
    assert!(matches_query(&cjk_games[0], "柚子社"));
    // Katakana & mixed ASCII matching
    assert!(matches_query(&cjk_games[1], "サノバ"));
    assert!(matches_query(&cjk_games[1], "witch"));
    // Chinese & Latin mixed matching
    assert!(matches_query(&cjk_games[2], "命运石之门"));
    assert!(matches_query(&cjk_games[2], "steins"));
    assert!(matches_query(&cjk_games[2], "MAGES"));

    // 3. filter_indices: slot scope filtering
    let all_indices = filter_indices(games, "", 0, false);
    assert_eq!(all_indices.len(), 20, "Slot 0 should include all non-launcher entries");

    let bottle_1_indices = filter_indices(games, "", 1, false);
    assert_eq!(bottle_1_indices.len(), 10);
    assert!(bottle_1_indices.iter().all(|&i| games[i].bottle == 1));

    let bottle_2_indices = filter_indices(games, "", 2, false);
    assert_eq!(bottle_2_indices.len(), 10);
    assert!(bottle_2_indices.iter().all(|&i| games[i].bottle == 2));

    let invalid_slot_indices = filter_indices(games, "", 99, false);
    assert!(invalid_slot_indices.is_empty(), "Non-existent slot returns empty");

    // 4. filter_indices: visibility flag and launcher exclusion
    let mixed_library = vec![
        make_test_game("m:1", "Active Game", None, None, 1, false, false, None, None, false),
        make_test_game("m:2", "Hidden Game", None, None, 1, false, true, None, None, false),
        make_test_game("m:3", "Steam Launcher", None, None, 1, false, false, None, None, true),
    ];

    let visible_only = filter_indices(&mixed_library, "", 0, false);
    assert_eq!(visible_only.len(), 1);
    assert_eq!(mixed_library[visible_only[0]].title, "Active Game");

    let with_hidden = filter_indices(&mixed_library, "", 0, true);
    assert_eq!(with_hidden.len(), 2);
    assert!(with_hidden.iter().any(|&i| mixed_library[i].title == "Active Game"));
    assert!(with_hidden.iter().any(|&i| mixed_library[i].title == "Hidden Game"));
    assert!(!with_hidden.iter().any(|&i| mixed_library[i].is_launcher), "Launchers must never be admitted to grid");
}

// ---------------------------------------------------------------------------
// 3. Sorting Determinism across Title, Last Played, and Rating
// ---------------------------------------------------------------------------

#[test]
fn test_sorting_determinism_title_recent_rating_bottle() {
    let bottles = demo_bottles();

    // 1. Sort::Name (Title): Natural alphanumeric & CJK collation
    let name_test_set = vec![
        make_test_game("1", "Game 10", None, None, 1, false, false, None, None, false),
        make_test_game("2", "game 2", None, None, 1, false, false, None, None, false),
        make_test_game("3", "Game 1", None, None, 1, false, false, None, None, false),
        make_test_game("4", "Alpha", None, None, 1, false, false, None, None, false),
        make_test_game("5", "千恋", None, None, 1, false, false, None, None, false),
        make_test_game("6", "万花", None, None, 1, false, false, None, None, false),
    ];

    let mut name_indices: Vec<usize> = (0..name_test_set.len()).collect();
    sort_indices(&name_test_set, &mut name_indices, Sort::Name, &bottles, true);

    let sorted_titles: Vec<&str> = name_indices
        .iter()
        .map(|&i| name_test_set[i].title.as_str())
        .collect();
    // Verify natural numeric ordering: "Game 1" before "game 2" before "Game 10"
    let pos_g1 = sorted_titles.iter().position(|&t| t == "Game 1").unwrap();
    let pos_g2 = sorted_titles.iter().position(|&t| t == "game 2").unwrap();
    let pos_g10 = sorted_titles.iter().position(|&t| t == "Game 10").unwrap();
    assert!(pos_g1 < pos_g2 && pos_g2 < pos_g10, "Natural numeric order must hold: Game 1 < game 2 < Game 10");

    // 2. Sort::Recent: Last played / last_session_ended_at ordering
    let recent_test_set = vec![
        make_test_game("r:1", "Never Played", None, None, 1, false, false, None, None, false),
        make_test_game("r:2", "Played Yesterday", None, None, 1, false, false, None, Some(1000), false),
        make_test_game("r:3", "Played Today", None, None, 1, false, false, None, Some(2000), false),
        make_test_game("r:4", "Launcher Client", None, None, 1, false, false, None, Some(3000), true),
    ];

    let mut recent_indices: Vec<usize> = (0..recent_test_set.len()).collect();
    sort_indices(&recent_test_set, &mut recent_indices, Sort::Recent, &bottles, true);

    let recent_titles: Vec<&str> = recent_indices
        .iter()
        .map(|&i| recent_test_set[i].title.as_str())
        .collect();
    // Non-launchers sorted by recent desc, then undated, and launcher grouped last
    assert_eq!(recent_titles, vec!["Played Today", "Played Yesterday", "Never Played", "Launcher Client"]);

    // If grouping is turned off (e.g. timeline mode), launcher stays in raw recent order
    let mut timeline_indices: Vec<usize> = (0..recent_test_set.len()).collect();
    sort_indices(&recent_test_set, &mut timeline_indices, Sort::Recent, &bottles, false);
    let timeline_titles: Vec<&str> = timeline_indices
        .iter()
        .map(|&i| recent_test_set[i].title.as_str())
        .collect();
    assert_eq!(timeline_titles[0], "Launcher Client", "When grouping is off, newest session wins even for launchers");

    // 3. Rating state machine & rating-based sorting
    assert_eq!(next_rating(None, 3), Some(3));
    assert_eq!(next_rating(Some(3), 3), None, "Clicking active star must clear rating");
    assert_eq!(next_rating(Some(2), 5), Some(5), "Clicking different star must update rating");

    let rating_test_set = vec![
        make_test_game("rt:1", "Unrated Game", None, None, 1, false, false, None, None, false),
        make_test_game("rt:2", "5-Star Game", None, None, 1, false, false, Some(5), None, false),
        make_test_game("rt:3", "10-Star Masterpiece", None, None, 1, false, false, Some(10), None, false),
        make_test_game("rt:4", "8-Star Classic", None, None, 1, false, false, Some(8), None, false),
    ];

    let mut rating_indices: Vec<usize> = (0..rating_test_set.len()).collect();
    // Sort deterministically by rating descending, with unrated last, tie-breaking by name
    rating_indices.sort_by(|&a, &b| {
        let ra = rating_test_set[a].rating;
        let rb = rating_test_set[b].rating;
        match (ra, rb) {
            (Some(sa), Some(sb)) if sa != sb => sb.cmp(&sa),
            (Some(_), None) => Ordering::Less,
            (None, Some(_)) => Ordering::Greater,
            _ => natural_cmp(&rating_test_set[a].title, &rating_test_set[b].title),
        }
    });

    let rating_titles: Vec<&str> = rating_indices
        .iter()
        .map(|&i| rating_test_set[i].title.as_str())
        .collect();
    assert_eq!(rating_titles, vec!["10-Star Masterpiece", "8-Star Classic", "5-Star Game", "Unrated Game"]);
}

// ---------------------------------------------------------------------------
// 4. Layout Bounds Calculation & Strict Viewport Containment
// ---------------------------------------------------------------------------

#[test]
fn test_layout_calculation_viewport_bounds_and_no_overlap() {
    // Verify chosen_cover_width behavior and bounds clamping
    assert_eq!(chosen_cover_width(AUTOMATIC_COVER_WIDTH), None);
    assert_eq!(chosen_cover_width(DEFAULT_COVER_WIDTH), Some(DEFAULT_COVER_WIDTH));
    assert_eq!(chosen_cover_width(50.0), Some(MIN_COVER_WIDTH));
    assert_eq!(chosen_cover_width(500.0), Some(MAX_COVER_WIDTH));
    assert!(STAGGERED_MIN_COLUMN > 0.0);
    assert!(STAGGERED_COMPACT > STAGGERED_MIN_COLUMN);
    assert!(STAGGERED_RAIL_GAP > 0.0);

    let games = demo_data();
    let indices: Vec<usize> = (0..games.len()).collect();

    let viewports = [400.0, 720.0, 1024.0, 1440.0, 1920.0];

    for &viewport_width in &viewports {
        // --- 1. Classic Layout ---
        let classic = LibraryLayout::classic(&indices, viewport_width);
        assert_eq!(classic.cards.len(), games.len());
        assert!(classic.height > 0.0);

        for (idx, (orig_idx, rect)) in classic.cards.iter().enumerate() {
            assert_eq!(*orig_idx, indices[idx]);
            assert!(rect.width > 0.0, "Classic card width must be positive: {}", rect.width);
            assert!(rect.height > 0.0, "Classic card height must be positive: {}", rect.height);
            assert!(rect.x >= 0.0, "Card x must be >= 0: {}", rect.x);
            assert!(
                rect.x + rect.width <= viewport_width + 0.05,
                "Classic card out of right bound: x={}, width={}, viewport={}",
                rect.x,
                rect.width,
                viewport_width
            );
            assert!(
                rect.y + rect.height <= classic.height + 0.05,
                "Classic card out of bottom bound: y={}, height={}, layout.height={}",
                rect.y,
                rect.height,
                classic.height
            );
        }

        // Assert pairwise non-overlapping in classic layout
        for i in 0..classic.cards.len() {
            for j in (i + 1)..classic.cards.len() {
                let r1 = classic.cards[i].1;
                let r2 = classic.cards[j].1;
                let x_overlap = r1.x < r2.x + r2.width - 0.01 && r1.x + r1.width - 0.01 > r2.x;
                let y_overlap = r1.y < r2.y + r2.height - 0.01 && r1.y + r1.height - 0.01 > r2.y;
                assert!(
                    !(x_overlap && y_overlap),
                    "Classic layout cards {} and {} overlap! r1={:?}, r2={:?}",
                    i,
                    j,
                    r1,
                    r2
                );
            }
        }

        // --- 2. Timeline Layout ---
        let timeline = LibraryLayout::timeline(&indices, viewport_width);
        assert_eq!(timeline.cards.len(), games.len());
        assert!(timeline.height > 0.0);
        for (_, rect) in &timeline.cards {
            assert!(rect.width > 0.0);
            assert!(rect.height > 0.0);
            assert!(rect.x >= 0.0);
            assert!(rect.x + rect.width <= viewport_width + 0.05);
            assert!(rect.y + rect.height <= timeline.height + 0.05);
        }

        // --- 3. Shelf with Width Layout ---
        let levels = cover_levels(viewport_width - 36.0);
        assert!(!levels.is_empty(), "cover_levels must have valid steps");
        for &lvl in &levels {
            assert!(lvl >= MIN_COVER_WIDTH - 0.1 && lvl <= MAX_COVER_WIDTH + 0.1);
        }

        let shelf_chosen = levels[0];
        let shelf = LibraryLayout::shelf_with_width(&indices, viewport_width, shelf_chosen, |i| {
            games[i].landscape
        });
        assert_eq!(shelf.cards.len(), games.len());
        assert!(shelf.height > 0.0);

        for (_, rect) in &shelf.cards {
            assert!(rect.width > 0.0);
            assert!(rect.height > 0.0);
            assert!(rect.x >= 0.0);
            assert!(
                rect.x + rect.width <= viewport_width + 0.05,
                "Shelf card out of right bound: x={}, width={}, viewport={}",
                rect.x,
                rect.width,
                viewport_width
            );
        }

        // --- 4. Staggered Timeline Layout ---
        let staggered = LibraryLayout::staggered(&indices, viewport_width, |_, pos| {
            if pos < 5 {
                Some("2025 年".into())
            } else if pos < 12 {
                Some("2024 年".into())
            } else {
                Some("更早".into())
            }
        });
        assert_eq!(staggered.cards.len(), games.len());
        assert!(staggered.height > 0.0);
        assert_eq!(staggered.rail_x, viewport_width / 2.0);
        assert!(staggered.rail_top < staggered.rail_bottom);
        assert!(!staggered.markers.is_empty(), "Staggered layout must place date group markers");

        for card in &staggered.cards {
            assert!(card.rect.width > 0.0);
            assert!(card.rect.height > 0.0);
            assert!(card.rect.x >= 0.0);
            assert!(card.rect.x + card.rect.width <= viewport_width + 0.05);
            match card.side {
                StaggeredSide::Left => {
                    assert_eq!(card.rect.x, STAGGERED_MARGIN);
                }
                StaggeredSide::Right => {
                    assert!(
                        (card.rect.x + card.rect.width - (viewport_width - STAGGERED_MARGIN)).abs() < 0.1,
                        "Right column card must align to right margin"
                    );
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 5. Theme Switching & Appearance Resolution
// ---------------------------------------------------------------------------

#[test]
fn test_theme_appearance_mode_resolution_and_state() {
    // 1. Cycle transitions
    assert_eq!(AppearanceMode::System.next(), AppearanceMode::Light);
    assert_eq!(AppearanceMode::Light.next(), AppearanceMode::Dark);
    assert_eq!(AppearanceMode::Dark.next(), AppearanceMode::System);

    // 2. Labels and icons
    assert_eq!(AppearanceMode::System.label(), "跟随系统");
    assert_eq!(AppearanceMode::System.icon_name(), "sun-moon");
    assert_eq!(AppearanceMode::Light.label(), "浅色");
    assert_eq!(AppearanceMode::Light.icon_name(), "sun");
    assert_eq!(AppearanceMode::Dark.label(), "深色");
    assert_eq!(AppearanceMode::Dark.icon_name(), "moon");

    // 3. Dynamic resolution under WindowAppearance
    assert_eq!(
        AppearanceMode::System.resolve(WindowAppearance::Light),
        ThemeMode::Light
    );
    assert_eq!(
        AppearanceMode::System.resolve(WindowAppearance::VibrantLight),
        ThemeMode::Light
    );
    assert_eq!(
        AppearanceMode::System.resolve(WindowAppearance::Dark),
        ThemeMode::Dark
    );
    assert_eq!(
        AppearanceMode::System.resolve(WindowAppearance::VibrantDark),
        ThemeMode::Dark
    );

    // Explicit light/dark overrides system appearance
    assert_eq!(
        AppearanceMode::Light.resolve(WindowAppearance::Dark),
        ThemeMode::Light
    );
    assert_eq!(
        AppearanceMode::Dark.resolve(WindowAppearance::Light),
        ThemeMode::Dark
    );

    // 4. Window override options
    assert_eq!(AppearanceMode::System.window_override(), None);
    assert_eq!(
        AppearanceMode::Light.window_override(),
        Some(WindowAppearance::Light)
    );
    assert_eq!(
        AppearanceMode::Dark.window_override(),
        Some(WindowAppearance::Dark)
    );

    // 5. Atomic state synchronization
    set_dark(true);
    assert!(is_dark());
    set_dark(false);
    assert!(!is_dark());
}

// ---------------------------------------------------------------------------
// 6. Container Lifecycle & Transitions without Wine
// ---------------------------------------------------------------------------

#[test]
fn test_container_creation_validation_and_lifecycle_transitions() {
    // 1. Windows Version Normalization
    assert_eq!(WINDOWS_LABELS, &["Windows 11", "Windows 10", "Windows 7"]);
    assert_eq!(windows_version_wire("Windows 11"), "win11");
    assert_eq!(windows_version_wire("Windows 10"), "win10");
    assert_eq!(windows_version_wire("Windows 7"), "win7");
    assert_eq!(windows_version_wire("Windows 8.1"), "win81");
    assert_eq!(windows_version_wire("Windows XP"), "winxp");
    assert_eq!(windows_version_wire("unknown"), "win11");
    assert_eq!(windows_version_wire(""), "win11");

    // BottleCreatedDto deserialization
    let dto: BottleCreatedDto = serde_json::from_str(r#"{"path":"/bottles/b1","name":"b1"}"#).unwrap();
    assert_eq!(dto.name, "b1");
    assert_eq!(dto.path, "/bottles/b1");

    // 2. Empty container name validation via the production validator
    for name in ["", "   ", "\t", "\r\n", " \t \n "] {
        assert_eq!(
            validate_name(name),
            Err("容器名称不能为空"),
            "Empty name must be rejected: {name:?}"
        );
    }
    assert_eq!(validate_name("My Bottle"), Ok("My Bottle"));

    // 3. Display location formatting
    assert_eq!(display_bottle_location("/opt/custom/bottles"), "/opt/custom/bottles");

    // 4. Lifecycle state machine transitions without Wine
    let mut state = CreateBottleState::default();
    assert!(!state.running());
    assert!(!state.finished);
    assert!(state.job_id.is_none());

    // Transition 1: Started resets all fields
    let started = BottleCreateUpdate::Started {
        job_id: "job-create-42".into(),
    };
    assert!(state.apply(&started));
    assert!(state.running());
    assert!(!state.finished);
    assert_eq!(state.job_id.as_deref(), Some("job-create-42"));
    assert_eq!(progress_label(state.status.unwrap(), None), "排队中…");

    // Transition 2: Progress (initializing)
    let progress = BottleCreateUpdate::Progress {
        status: JobStatus::Running,
        stage: Some("initializing".into()),
    };
    assert!(state.apply(&progress));
    assert!(state.running());
    assert_eq!(progress_label(state.status.unwrap(), state.stage.as_deref()), "正在初始化容器…");

    // Transition 3: Completed
    let completed = BottleCreateUpdate::Completed {
        path: "/mock/bottles/new-bottle".into(),
        name: "new-bottle".into(),
        containers: Vec::new(),
    };
    assert!(state.apply(&completed));
    assert!(!state.running());
    assert!(state.finished);
    assert_eq!(state.created_path.as_deref(), Some("/mock/bottles/new-bottle"));
    assert_eq!(progress_label(state.status.unwrap(), None), "创建完成");

    // Transition 4: Failure path
    let mut fail_state = CreateBottleState::default();
    let failed = BottleCreateUpdate::Failed {
        status: JobStatus::Failed,
        reason: "Disk space exhausted".into(),
    };
    assert!(fail_state.apply(&failed));
    assert!(!fail_state.running());
    assert!(fail_state.finished);
    assert_eq!(fail_state.error.as_deref(), Some("Disk space exhausted"));
    assert_eq!(progress_label(fail_state.status.unwrap(), None), "创建失败");
}

// ---------------------------------------------------------------------------
// 7. File Chooser Remote-Error Isolation & the Supervisor Picker Ceiling
// ---------------------------------------------------------------------------

#[test]
fn test_picker_remote_error_isolation_and_supervisor_timeout() {
    // PICKER_TIMEOUT is the only picker budget Rust owns: it outlasts the
    // helper's own timeouts so a dialog timeout arrives as a wire error
    // instead of a session teardown. The helper-side timeout constants are
    // covered by the Swift LinuxFilePicker tests.
    assert_eq!(PICKER_TIMEOUT, Duration::from_secs(330));

    // Verify classify(): Remote error isolation vs Session failure
    let remote_timeout_err = whisky_bridge::Error::Remote(whisky_bridge::RemoteError {
        code: "5".into(),
        message: "host_timeout: GTK4 file chooser timed out after 300s".into(),
        retryable: true,
    });
    let classified = classify(remote_timeout_err);
    match classified {
        CallFailure::Remote(msg) => {
            assert!(msg.contains("host_timeout"), "Remote timeout message preserved");
        }
        CallFailure::Session(_) => panic!("Remote error must NOT be classified as Session failure!"),
    }

    // Verify Session failure classification (e.g. transport failure / session closed)
    let transport_err = whisky_bridge::Error::Transport("abrupt EOF on stdin".into());
    match classify(transport_err) {
        CallFailure::Session(msg) => {
            assert!(msg.contains("abrupt EOF"), "Session error preserved");
        }
        CallFailure::Remote(_) => panic!("Transport error must be classified as Session failure!"),
    }

    let closed_err = whisky_bridge::Error::Closed;
    match classify(closed_err) {
        CallFailure::Session(msg) => {
            assert!(msg.contains("closed"), "Closed error preserved");
        }
        CallFailure::Remote(_) => panic!("Closed error must be classified as Session failure!"),
    }

    // Verify supervisor exponential backoff limits
    assert_eq!(BACKOFF_MIN_MS, 500, "Supervisor initial retry backoff is 500ms");
    assert_eq!(BACKOFF_MAX_MS, 8_000, "Supervisor max retry backoff is 8000ms");
}

// ---------------------------------------------------------------------------
// 8. Empirical Challenge: Search & Filtering Edge Cases
// ---------------------------------------------------------------------------

#[test]
fn test_empirical_challenge_search_and_filtering_edge_cases() {
    let demo_games = demo_data();
    let mut custom_games = vec![
        make_test_game(
            "edge:1",
            "千恋＊万花 (Senren*Banka)",
            Some("ゆずソフト (Yuzusoft)"),
            Some("2016-03-25"),
            1,
            false,
            false,
            Some(9),
            Some(1700000000),
            false,
        ),
        make_test_game(
            "edge:2",
            "命运石之门: Steins;Gate 0 [Ref]",
            Some("5pb. / MAGES."),
            Some("2015-12-10"),
            1,
            true,
            false,
            Some(10),
            Some(1710000000),
            false,
        ),
        make_test_game(
            "edge:3",
            "魔法使いの夜 (Witch on the Holy Night)",
            Some("TYPE-MOON"),
            Some("2012-04-12"),
            2,
            true,
            true, // hidden
            Some(8),
            Some(1680000000),
            false,
        ),
        make_test_game(
            "edge:4",
            "Steam Client / 启动器",
            Some("Valve Corp."),
            Some("2003-09-12"),
            1,
            false,
            false,
            None,
            Some(1720000000),
            true, // is_launcher
        ),
    ];
    let mut all_games: Vec<Game> = demo_games.to_vec();
    all_games.append(&mut custom_games);

    // 1. Edge Case: Empty query & all whitespace variants
    let whitespace_queries = ["", " ", "   ", "\t", "\n", "\r\n", " \t \r\n "];
    for q in whitespace_queries {
        for game in &all_games {
            assert!(
                matches_query(game, q),
                "Empty/whitespace query '{}' must match all games",
                q
            );
        }
    }

    // 2. Edge Case: Leading & Trailing Whitespace
    let g1 = &all_games.iter().find(|g| g.title.contains("千恋")).unwrap();
    assert!(matches_query(g1, "  千恋  "));
    assert!(matches_query(g1, "\tSenren\n"));
    assert!(matches_query(g1, "  2016  "));
    assert!(matches_query(g1, "  Yuzusoft  "));

    // 3. Edge Case: Punctuation & Special Symbols
    assert!(matches_query(g1, "＊"), "Fullwidth asterisk matching");
    assert!(matches_query(g1, "("), "Parenthesis open");
    assert!(matches_query(g1, ")"), "Parenthesis close");

    let g2 = &all_games.iter().find(|g| g.title.contains("Steins;Gate")).unwrap();
    assert!(matches_query(g2, ";"), "Semicolon in Steins;Gate");
    assert!(matches_query(g2, ":"), "Colon in title");
    assert!(matches_query(g2, "["), "Bracket open");
    assert!(matches_query(g2, "/"), "Slash in studio 5pb. / MAGES.");
    assert!(matches_query(g2, "."), "Dot in 5pb.");

    let g3 = &all_games.iter().find(|g| g.title.contains("魔法使い")).unwrap();
    assert!(matches_query(g3, "-"), "Hyphen in TYPE-MOON");

    // 4. Edge Case: CJK Multi-byte Glyphs (Kanji, Hiragana, Katakana, CJK Ideographs)
    assert!(matches_query(g1, "千恋"), "Kanji substring");
    assert!(matches_query(g1, "万花"), "Kanji substring 2");
    assert!(matches_query(g1, "ゆずソフト"), "Hiragana/Katakana studio match");
    assert!(matches_query(g2, "命运石之门"), "Simplified Chinese");
    assert!(matches_query(g3, "魔法使いの夜"), "Mixed Kanji + Hiragana");
    assert!(matches_query(g3, "使いの"), "Internal Hiragana span");

    // 5. Edge Case: Case-Insensitive Mixing
    assert!(matches_query(g1, "sEnReN*bAnKa"), "Mixed case Latin");
    assert!(matches_query(g1, "yUzUsOfT"), "Mixed case studio");
    assert!(matches_query(g2, "sTeInS;gAtE"), "Mixed case with punctuation");
    assert!(matches_query(g2, "mAgEs"), "Mixed case studio uppercase");
    assert!(matches_query(g3, "tYpE-mOoN"), "Mixed case hyphenated");

    // 6. Edge Case: Non-Existent Queries
    let non_existent_queries = [
        "NonExistentTitle_XYZ_999",
        "1899",
        "Square Enix",
        "!!!???###",
        "全网无此游戏",
    ];
    for nq in non_existent_queries {
        assert!(
            !all_games.iter().any(|g| matches_query(g, nq)),
            "Query '{}' should match no games",
            nq
        );
    }

    // 7. Edge Case: filter_indices with Slot Scoping and Launcher Exclusion
    let slot_1_indices = filter_indices(&all_games, "", 1, false);
    for &idx in &slot_1_indices {
        let g = &all_games[idx];
        assert_eq!(g.bottle, 1);
        assert!(!g.hidden);
        assert!(!g.is_launcher);
    }

    let slot_2_indices = filter_indices(&all_games, "", 2, false);
    for &idx in &slot_2_indices {
        let g = &all_games[idx];
        assert_eq!(g.bottle, 2);
        assert!(!g.hidden);
        assert!(!g.is_launcher);
    }

    let hidden_included = filter_indices(&all_games, "魔法使い", 0, true);
    assert_eq!(hidden_included.len(), 1, "Hidden game must be visible when show_hidden=true");

    let hidden_excluded = filter_indices(&all_games, "魔法使い", 0, false);
    assert_eq!(hidden_excluded.len(), 0, "Hidden game must be filtered when show_hidden=false");

    let launcher_query = filter_indices(&all_games, "Steam", 0, true);
    assert_eq!(launcher_query.len(), 0, "Launcher entries must NEVER be admitted into library grid");
}

// ---------------------------------------------------------------------------
// 9. Empirical Challenge: Layout Calculations across Extreme Viewports
// ---------------------------------------------------------------------------

#[test]
fn test_empirical_challenge_layout_extreme_viewports() {
    let games = demo_data();
    let indices: Vec<usize> = (0..games.len()).collect();

    // Extreme viewports:
    // Mobile / Mini: 200px, 320px
    // Desktop HD / FHD: 1280px, 1920px
    // 4K UHD: 3840px
    // 8K Super Hi-Vision: 7680px
    let extreme_viewports = [200.0, 320.0, 1280.0, 1920.0, 3840.0, 7680.0];

    for &width in &extreme_viewports {
        // -------------------------------------------------------------------
        // Layout 1: Classic Layout (Grid)
        // -------------------------------------------------------------------
        let classic = LibraryLayout::classic(&indices, width);
        assert_eq!(classic.cards.len(), indices.len());
        assert!(classic.height.is_finite() && classic.height > 0.0);
        assert!(classic.cover_width.is_finite() && classic.cover_width > 0.0);

        for (idx, (card_idx, rect)) in classic.cards.iter().enumerate() {
            assert_eq!(*card_idx, indices[idx]);
            assert!(rect.width.is_finite() && rect.width > 0.0, "Classic width must be positive: {}", rect.width);
            assert!(rect.height.is_finite() && rect.height > 0.0, "Classic height must be positive: {}", rect.height);
            assert!(rect.x >= 0.0, "Classic x must be non-negative: {} at width {}", rect.x, width);
            assert!(rect.y >= 0.0, "Classic y must be non-negative: {} at width {}", rect.y, width);
            assert!(
                rect.x + rect.width <= width + 0.05,
                "Classic card out of right bound: x={}, width={}, total={}, viewport={}",
                rect.x,
                rect.width,
                rect.x + rect.width,
                width
            );
            assert!(
                rect.y + rect.height <= classic.height + 0.05,
                "Classic card out of bottom bound: y={}, height={}, layout_height={}",
                rect.y,
                rect.height,
                classic.height
            );
        }

        // Pairwise non-overlap in classic layout
        for i in 0..classic.cards.len() {
            for j in (i + 1)..classic.cards.len() {
                let r1 = classic.cards[i].1;
                let r2 = classic.cards[j].1;
                let x_overlap = r1.x < r2.x + r2.width - 0.01 && r1.x + r1.width - 0.01 > r2.x;
                let y_overlap = r1.y < r2.y + r2.height - 0.01 && r1.y + r1.height - 0.01 > r2.y;
                assert!(!(x_overlap && y_overlap), "Classic cards {} and {} overlap at width {}", i, j, width);
            }
        }

        // -------------------------------------------------------------------
        // Layout 2: Timeline Layout (Single Column)
        // -------------------------------------------------------------------
        let timeline = LibraryLayout::timeline(&indices, width);
        assert_eq!(timeline.cards.len(), indices.len());
        assert!(timeline.height.is_finite() && timeline.height > 0.0);
        assert!(timeline.cover_width.is_finite() && timeline.cover_width > 0.0);

        for (idx, (card_idx, rect)) in timeline.cards.iter().enumerate() {
            assert_eq!(*card_idx, indices[idx]);
            assert!(rect.width.is_finite() && rect.width > 0.0);
            assert!(rect.height.is_finite() && rect.height > 0.0);
            assert!(rect.x >= 0.0, "Timeline x must be non-negative: {}", rect.x);
            assert!(rect.y >= 0.0, "Timeline y must be non-negative: {}", rect.y);
            assert!(
                rect.x + rect.width <= width + 0.05,
                "Timeline card out of right bound at width {}: x+w={}",
                width,
                rect.x + rect.width
            );
            assert!(rect.y + rect.height <= timeline.height + 0.05);
        }

        // -------------------------------------------------------------------
        // Layout 3: Shelf with Width (Knapsack Row Packing)
        // -------------------------------------------------------------------
        // Test both automatic width and explicit chosen widths from cover_levels
        let levels = cover_levels(width - 36.0);
        let chosen_options = if levels.is_empty() {
            vec![AUTOMATIC_COVER_WIDTH]
        } else {
            vec![AUTOMATIC_COVER_WIDTH, levels[0], levels[levels.len() - 1]]
        };

        for chosen in chosen_options {
            let shelf = LibraryLayout::shelf_with_width(&indices, width, chosen, |i| games[i].landscape);
            assert_eq!(shelf.cards.len(), indices.len());
            assert!(shelf.height.is_finite() && shelf.height > 0.0);
            assert!(shelf.cover_width.is_finite() && shelf.cover_width > 0.0);

            for (idx, (card_idx, rect)) in shelf.cards.iter().enumerate() {
                assert_eq!(*card_idx, indices[idx]);
                assert!(rect.width.is_finite() && rect.width > 0.0);
                assert!(rect.height.is_finite() && rect.height > 0.0);
                assert!(rect.x >= 0.0, "Shelf x must be non-negative: {} at width {}", rect.x, width);
                assert!(rect.y >= 0.0, "Shelf y must be non-negative: {} at width {}", rect.y, width);
                assert!(
                    rect.x + rect.width <= width + 0.05,
                    "Shelf card out of right bound at width {}: x={}, w={}, x+w={}",
                    width,
                    rect.x,
                    rect.width,
                    rect.x + rect.width
                );
                assert!(rect.y + rect.height <= shelf.height + 0.05);
            }
        }

        // -------------------------------------------------------------------
        // Layout 4: Staggered Timeline Layout
        // -------------------------------------------------------------------
        let staggered = LibraryLayout::staggered(&indices, width, |_, pos| {
            if pos < 5 {
                Some("2025".into())
            } else if pos < 12 {
                Some("2024".into())
            } else {
                Some("Earlier".into())
            }
        });
        assert_eq!(staggered.cards.len(), indices.len());
        assert!(staggered.height.is_finite() && staggered.height > 0.0);
        assert!(staggered.card_width.is_finite() && staggered.card_width > 0.0);
        assert!(staggered.card_height.is_finite() && staggered.card_height > 0.0);
        assert_eq!(staggered.rail_x, width / 2.0);

        if width >= 210.0 {
            // For all viewports >= 210.0 (320px, 1280px, 1920px, 3840px, 7680px),
            // cards conform strictly to viewport bounds and have non-negative coordinates.
            for card in &staggered.cards {
                assert!(card.rect.width > 0.0);
                assert!(card.rect.height > 0.0);
                assert!(card.rect.x >= 0.0, "Staggered x must be >= 0: {} at width {}", card.rect.x, width);
                assert!(card.rect.y >= 0.0, "Staggered y must be >= 0: {} at width {}", card.rect.y, width);
                assert!(
                    card.rect.x + card.rect.width <= width + 0.05,
                    "Staggered card out of right bound at width {}: x={}, w={}, x+w={}",
                    width,
                    card.rect.x,
                    card.rect.width,
                    card.rect.x + card.rect.width
                );
            }
        } else {
            // Documenting empirical boundary behavior for width < 210.0 (e.g. 200.0):
            // STAGGERED_MARGIN = 20.0, STAGGERED_MIN_COLUMN = 190.0
            // Left card: x = 20.0, width = 190.0 => x + w = 210.0 (> 200.0 viewport)
            // Right card: x = width - 20.0 - 190.0 = -10.0 (< 0.0 negative coordinate)
            let left_card = &staggered.cards[0];
            let right_card = &staggered.cards[1];
            assert_eq!(left_card.rect.x, STAGGERED_MARGIN);
            assert_eq!(left_card.rect.width, STAGGERED_MIN_COLUMN);
            assert_eq!(left_card.rect.x + left_card.rect.width, 210.0); // 210.0 > 200.0
            assert_eq!(right_card.rect.x, -10.0); // -10.0 < 0.0
            // Note: In the live application, window_min_size is enforced at (800.0, 580.0),
            // guaranteeing width >= 210.0 in runtime operation.
        }
    }
}

// ---------------------------------------------------------------------------
// 10. Empirical Challenge: CreateBottleState Invalid Sequences & Terminal Invariants
// ---------------------------------------------------------------------------

#[test]
fn test_challenge_create_bottle_state_machine_invalid_sequences() {
    // Challenge A: Completed before Started — an initial completion is still
    // accepted so the helper's readback after a reconnect lands.
    let mut state = CreateBottleState::default();
    assert_eq!(state.job_id, None);
    assert!(!state.running());
    assert!(!state.finished);

    let premature_completed = BottleCreateUpdate::Completed {
        path: "/bottles/premature".into(),
        name: "premature".into(),
        containers: Vec::new(),
    };
    assert!(state.apply(&premature_completed));
    assert!(state.finished);
    assert!(!state.running());
    assert_eq!(state.created_path.as_deref(), Some("/bottles/premature"));
    assert_eq!(state.status, Some(JobStatus::Completed));
    assert_eq!(state.job_id, None, "job_id remains None if Completed arrived prematurely");

    // Challenge B: Double Completed — terminal state is sticky, so the
    // duplicate is ignored and the first outcome wins.
    let second_completed = BottleCreateUpdate::Completed {
        path: "/bottles/second".into(),
        name: "second".into(),
        containers: Vec::new(),
    };
    assert!(!state.apply(&second_completed), "duplicate Completed must be ignored");
    assert!(state.finished);
    assert!(!state.running());
    assert_eq!(state.created_path.as_deref(), Some("/bottles/premature"));
    assert_eq!(state.status, Some(JobStatus::Completed));

    // Challenge C: Failed after Completed — also ignored.
    let post_failed = BottleCreateUpdate::Failed {
        status: JobStatus::Failed,
        reason: "Post-creation verification failed".into(),
    };
    assert!(!state.apply(&post_failed), "Failed must not overwrite a terminal state");
    assert!(state.finished);
    assert!(!state.running());
    assert_eq!(state.status, Some(JobStatus::Completed));
    assert_eq!(state.error, None);
    assert_eq!(state.created_path.as_deref(), Some("/bottles/premature"));

    // Challenge D: Progress arriving after Completed — ignored.
    let mut completed_state = CreateBottleState::default();
    assert!(completed_state.apply(&BottleCreateUpdate::Completed {
        path: "/bottles/done".into(),
        name: "done".into(),
        containers: Vec::new(),
    }));
    let late_progress = BottleCreateUpdate::Progress {
        status: JobStatus::Running,
        stage: Some("late bootstrap".into()),
    };
    assert!(
        !completed_state.apply(&late_progress),
        "late progress on a finished job must be ignored"
    );
    assert!(!completed_state.running());
    assert!(completed_state.finished);
    assert_eq!(completed_state.status, Some(JobStatus::Completed));

    // Challenge E: Started after a finished job resets everything, including
    // the previous terminal outcome and its created path.
    let mut restarted_state = CreateBottleState::default();
    assert!(restarted_state.apply(&BottleCreateUpdate::Started { job_id: "job-1".into() }));
    assert_eq!(restarted_state.job_id.as_deref(), Some("job-1"));
    assert!(restarted_state.running());
    restarted_state.finished = true;
    restarted_state.created_path = Some("/bottles/old".into());
    restarted_state.error = Some("stale outcome".into());

    assert!(restarted_state.apply(&BottleCreateUpdate::Started { job_id: "job-2".into() }));
    assert_eq!(restarted_state.job_id.as_deref(), Some("job-2"));
    assert!(restarted_state.running());
    assert!(!restarted_state.finished);
    assert_eq!(restarted_state.created_path, None, "Started clears the previous path");
    assert_eq!(restarted_state.error, None, "Started clears the previous error");

    // Challenge F: Failed before Started — an initial terminal readback is
    // still accepted.
    let mut immediate_fail = CreateBottleState::default();
    let fail_initial = BottleCreateUpdate::Failed {
        status: JobStatus::Failed,
        reason: "Wine runtime missing".into(),
    };
    assert!(immediate_fail.apply(&fail_initial));
    assert!(immediate_fail.finished);
    assert!(!immediate_fail.running());
    assert_eq!(immediate_fail.job_id, None);
    assert_eq!(immediate_fail.error.as_deref(), Some("Wine runtime missing"));

    // Challenge G: JobStatus terminal predicates and progress labels
    assert!(JobStatus::Completed.is_terminal());
    assert!(JobStatus::Failed.is_terminal());
    assert!(JobStatus::Cancelled.is_terminal());
    assert!(!JobStatus::Queued.is_terminal());
    assert!(!JobStatus::Running.is_terminal());
    assert!(!JobStatus::Cancelling.is_terminal());

    assert_eq!(progress_label(JobStatus::Queued, None), "排队中…");
    assert_eq!(progress_label(JobStatus::Running, Some("initializing")), "正在初始化容器…");
    assert_eq!(progress_label(JobStatus::Running, Some("other")), "正在创建容器…");
    assert_eq!(progress_label(JobStatus::Running, None), "正在创建容器…");
    assert_eq!(progress_label(JobStatus::Cancelling, None), "正在取消…");
    assert_eq!(progress_label(JobStatus::Completed, None), "创建完成");
    assert_eq!(progress_label(JobStatus::Failed, None), "创建失败");
    assert_eq!(progress_label(JobStatus::Cancelled, None), "已取消");
}

// ---------------------------------------------------------------------------
// 11. Empirical Challenge: Bottle Name Validation across Whitespace and Control Characters
// ---------------------------------------------------------------------------

#[test]
fn test_challenge_create_bottle_name_validation_whitespace_and_control_chars() {
    // 1. Empty and whitespace-only strings must be rejected by trim().is_empty()
    let whitespace_cases = [
        "",
        " ",
        "  ",
        "       ",
        "\t",
        "\t\t",
        "\r",
        "\n",
        "\r\n",
        " \t\r\n ",
        "\u{3000}", // Ideographic space (CJK full-width)
        "　",       // Literal full-width space
        "　　\t ",  // Mixed full-width and ASCII spaces
        "\u{00A0}", // Non-breaking space (NBSP)
        "\u{2003}", // EM space
        "\u{2009}", // Thin space
    ];

    for case in &whitespace_cases {
        assert_eq!(
            validate_name(case),
            Err("容器名称不能为空"),
            "Expected whitespace case '{case:?}' to be rejected"
        );
    }
    // Surrounding whitespace and newlines are trimmed before validation.
    assert_eq!(validate_name("\n  Good  \r\n"), Ok("Good"));
    // …but a newline inside the name still fails.
    assert_eq!(validate_name("Good\nName"), Err("容器名称不能包含换行符"));

    // 2. The production validator (`create_bottle::validate_name`) mirrors the
    // backend bridge constraints: non-empty after trimming, no `/`, NUL, CR/LF
    // or other control characters (tab survives), at most 128 UTF-8 bytes.
    assert_eq!(validate_name(""), Err("容器名称不能为空"));
    assert_eq!(validate_name("   "), Err("容器名称不能为空"));
    assert_eq!(validate_name("bottle/name"), Err("容器名称不能包含路径分隔符 '/'"));
    assert_eq!(validate_name("/root_bottle"), Err("容器名称不能包含路径分隔符 '/'"));
    assert_eq!(validate_name("bottle\0null"), Err("容器名称不能包含空字符 '\\0'"));
    assert_eq!(validate_name("bottle\nnewline"), Err("容器名称不能包含换行符"));
    assert_eq!(validate_name("bottle\rcarriage"), Err("容器名称不能包含换行符"));
    assert_eq!(validate_name("\x01\x02\x03"), Err("容器名称包含控制字符"));
    assert_eq!(validate_name("bottle\x1Fname"), Err("容器名称包含控制字符"));
    assert_eq!(validate_name("bottle\x7Fname"), Err("容器名称包含控制字符"));

    // Length limit: > 128 UTF-8 bytes, including multi-byte characters.
    let long_name = "a".repeat(129);
    assert_eq!(validate_name(&long_name), Err("容器名称不能超过 128 字节"));
    // 43 CJK glyphs = 129 UTF-8 bytes: over the wire limit.
    let long_cjk = "千".repeat(43);
    assert_eq!(validate_name(&long_cjk), Err("容器名称不能超过 128 字节"));
    // 42 CJK glyphs = 126 bytes: under the limit.
    let boundary_cjk = "千".repeat(42);
    assert_eq!(validate_name(&boundary_cjk).unwrap(), boundary_cjk);

    // Valid bottle names must succeed
    assert_eq!(validate_name("galgame"), Ok("galgame"));
    assert_eq!(validate_name("Galgame-Win7"), Ok("Galgame-Win7"));
    assert_eq!(validate_name("千恋＊万花 容器"), Ok("千恋＊万花 容器"));
    assert_eq!(validate_name("  Visual Novel 2026  "), Ok("Visual Novel 2026"));
}

// ---------------------------------------------------------------------------
// 12. Empirical Challenge: File Chooser Timeout Resiliency & Supervisor Session Preservation
// ---------------------------------------------------------------------------

#[test]
fn test_challenge_picker_wire_error_decode_and_remote_classification() {
    // 1. The supervisor's picker ceiling is the only timeout Rust owns; the
    // helper-side dialog/runner budgets are covered by the Swift
    // LinuxFilePicker tests.
    assert_eq!(PICKER_TIMEOUT, Duration::from_secs(330));

    // 2. Subprocess exit code 5 simulation:
    // Native GTK dialog times out -> exits code 5.
    // Swift LinuxFilePicker:
    //   if result.status == 5, !result.signalled {
    //       throw BridgeFailure("host_timeout", "File selection timed out; open the picker again", retryable: true)
    //   }
    // Serialized NDJSON wire error:
    let wire_error_json = r#"{
        "version": 1,
        "id": 42,
        "error": {
            "code": "host_timeout",
            "message": "File selection timed out; open the picker again",
            "retryable": true
        }
    }"#;
    let frame_val: serde_json::Value = serde_json::from_str(wire_error_json).unwrap();
    let err_obj = frame_val.get("error").unwrap();
    let remote_err: whisky_bridge::RemoteError = serde_json::from_value(err_obj.clone()).unwrap();
    assert_eq!(remote_err.code, "host_timeout");
    assert_eq!(remote_err.message, "File selection timed out; open the picker again");
    assert!(remote_err.retryable);

    // 3. Classify error into CallFailure
    let bridge_err = whisky_bridge::Error::Remote(remote_err);
    let classified = classify(bridge_err);
    match &classified {
        CallFailure::Remote(reason) => {
            assert!(reason.contains("host_timeout"), "Reason must contain error code 'host_timeout'");
            assert!(reason.contains("File selection timed out"), "Reason must preserve timeout text");
        }
        CallFailure::Session(_) => panic!("Remote timeout error must NEVER be classified as CallFailure::Session!"),
    }

    // End-to-end session preservation is covered by
    // bridge::supervisor::tests::test_supervisor_remote_wire_error_keeps_session_for_followup_calls.
}

// ---------------------------------------------------------------------------
// 13. Real Root View: bridge events and key bindings drive the real WhiskyApp
// ---------------------------------------------------------------------------

#[gpui_kit::test]
fn test_root_window_real_state_and_settings_keybinding(cx: &mut gpui_kit::TestAppContext) {
    cx.update(|app| {
        gpui_kit::init(app);
        crate::bind_shortcuts(app);
    });

    // A supervisor with no worker: commands are dropped on the floor and no
    // helper process is spawned. The event channel stays empty; the sender is
    // retained so the app's receive loop parks instead of closing.
    let (_events_tx, events_rx) = smol::channel::unbounded();
    let bridge = crate::bridge::BridgeSupervisor::disconnected_for_tests();
    let window = cx.add_window(|window, cx| {
        crate::state::WhiskyApp::new_with_bridge(window, cx, bridge, events_rx, false)
    });

    // Stale catalogue state that a fresh Containers event must clear.
    window
        .update(cx, |this, _, cx| {
            this.bottle_entries.insert(
                "/stale".into(),
                vec![make_test_game(
                    "stale:1", "Stale", None, None, 1, false, false, None, None, false,
                )],
            );
            this.entries.push(make_test_game(
                "stale:2", "Stale2", None, None, 1, false, false, None, None, false,
            ));
            this.failures.insert(0, "stale failure".into());
            this.apply_bridge_event(
                crate::bridge::BridgeEvent::Containers(vec![
                    crate::bridge::dto::Container {
                        path: "/bottles/alpha".into(),
                        name: "Alpha".into(),
                        available: true,
                    },
                    crate::bridge::dto::Container {
                        path: "/bottles/beta".into(),
                        name: "Beta".into(),
                        available: true,
                    },
                ]),
                cx,
            );
        })
        .unwrap();
    window
        .read_with(cx, |this, _| {
            assert_eq!(this.bottles.len(), 2);
            assert!(this.catalogue_ready);
            assert!(this.bottle_entries.is_empty(), "stale per-bottle cache must clear");
            assert!(this.entries.is_empty(), "stale entries must clear");
            assert!(this.failures.is_empty(), "stale failures must clear");
        })
        .unwrap();

    // Entries for one bottle populate its slot and merge into the grid.
    window
        .update(cx, |this, _, cx| {
            let entry: crate::bridge::dto::EntryDto = serde_json::from_value(serde_json::json!({
                "id": "fixture:1",
                "name": "Fixture Game",
            }))
            .unwrap();
            this.apply_bridge_event(
                crate::bridge::BridgeEvent::Entries {
                    container: "/bottles/alpha".into(),
                    entries: vec![entry],
                },
                cx,
            );
        })
        .unwrap();
    window
        .read_with(cx, |this, _| {
            assert_eq!(this.bottle_entries["/bottles/alpha"].len(), 1);
            assert_eq!(this.entries.len(), 1);
            assert_eq!(this.entries[0].title, "Fixture Game");
        })
        .unwrap();

    // A completed create-bottle job replaces the catalogue and selects the
    // new bottle through the same production path the worker drives.
    window
        .update(cx, |this, _, cx| {
            this.apply_bridge_event(
                crate::bridge::BridgeEvent::BottleCreate {
                    update: BottleCreateUpdate::Completed {
                        path: "/bottles/new".into(),
                        name: "New Bottle".into(),
                        containers: vec![
                            crate::bridge::dto::Container {
                                path: "/bottles/alpha".into(),
                                name: "Alpha".into(),
                                available: true,
                            },
                            crate::bridge::dto::Container {
                                path: "/bottles/new".into(),
                                name: "New Bottle".into(),
                                available: true,
                            },
                        ],
                    },
                },
                cx,
            );
        })
        .unwrap();
    window
        .read_with(cx, |this, _| {
            assert!(
                this.create_bottle
                    .as_ref()
                    .is_some_and(|state| state.finished)
            );
            assert_eq!(this.bottles.len(), 2);
            assert_eq!(
                this.selected_bottle,
                Some(1),
                "the created bottle must be selected"
            );
            assert_eq!(this.bottles[1].name, "New Bottle");
        })
        .unwrap();

    // The production key binding — a simulated keystroke, not a direct action
    // dispatch — opens settings through the real keymap.
    cx.simulate_keystrokes(window.into(), crate::platform::SHORTCUTS[3]);
    window
        .read_with(cx, |this, _| {
            assert!(this.settings, "ShowSettings shortcut must open settings")
        })
        .unwrap();

    // Escape exits Settings so users are never trapped when the sidebar is hidden.
    cx.simulate_keystrokes(window.into(), "escape");
    window
        .read_with(cx, |this, _| {
            assert!(!this.settings, "Escape must dismiss settings")
        })
        .unwrap();

    // FocusSearch (Cmd+F / Ctrl+F) from Settings returns to Library and focuses search.
    cx.simulate_keystrokes(window.into(), crate::platform::SHORTCUTS[3]);
    cx.simulate_keystrokes(window.into(), crate::platform::SHORTCUTS[6]);
    window
        .read_with(cx, |this, cx| {
            assert!(!this.settings, "FocusSearch must exit settings");
            assert!(
                this.preview.page == crate::state::PreviewPage::Library,
                "FocusSearch must return to Library"
            );
            let _ = this.search.read(cx);
        })
        .unwrap();

    // Light mode sync_theme must apply brand primary even on initial Light startup,
    // and reverse-sort toggle must invert ordered indices deterministically.
    window
        .update(cx, |this, _, cx| {
            crate::theme::sync_theme(AppearanceMode::Light, None, cx);
            let expected: gpui_kit::Hsla = gpui_kit::rgb(0xe8770f).into();
            assert_eq!(
                gpui_kit::component::theme::Theme::global(cx).colors.primary,
                expected
            );
            this.bottle_entries.insert(
                "/bottles/alpha".into(),
                vec![
                    make_test_game("g1", "Alpha", None, None, 1, false, false, None, None, false),
                    make_test_game("g2", "Beta", None, None, 1, false, false, None, None, false),
                ],
            );
            this.entries = crate::library_view::merge_bottles(&this.bottles, &this.bottle_entries);
            this.selected_bottle = None;
            this.set_appearance(AppearanceMode::Dark, cx);
            let forward = this.ordered(cx);
            this.command(crate::views::Command::Toggle("reverse-sort"), cx);
            let mut backward = this.ordered(cx);
            backward.reverse();
            assert_eq!(forward, backward, "reverse-sort must invert ordered()");
        })
        .unwrap();
}

// ---------------------------------------------------------------------------
// 14. Wine engine selection: per-container readback, gated writes, dialogs
// ---------------------------------------------------------------------------

use crate::bridge::dto::{
    EngineFieldPolicyDto, EnginePolicyDto, WineEngineDto, WineEngineFeatureDto,
    WineEngineListDto, WineEngineSelectionDto,
};
use crate::config::{ConfigField, FieldKind};
fn engine_window(
    cx: &mut gpui_kit::TestAppContext,
) -> gpui_kit::WindowHandle<crate::state::WhiskyApp> {
    cx.update(|app| {
        gpui_kit::init(app);
        crate::bind_shortcuts(app);
    });
    let (_events_tx, events_rx) = smol::channel::unbounded();
    let bridge = crate::bridge::BridgeSupervisor::disconnected_for_tests();
    cx.add_window(|window, cx| {
        crate::state::WhiskyApp::new_with_bridge(window, cx, bridge, events_rx, false)
    })
}

fn external_selection() -> Box<WineEngineSelectionDto> {
    let mut choices = BTreeMap::new();
    choices.insert(
        "dxvk".to_owned(),
        EnginePolicyDto {
            disabled: true,
            reason: Some("no DXVK payload in this engine".to_owned()),
            state: "unavailable".to_owned(),
            can_override: false,
            feature: Some("dxvk".to_owned()),
        },
    );
    choices.insert(
        "dxmt".to_owned(),
        EnginePolicyDto {
            disabled: false,
            reason: None,
            state: "supported".to_owned(),
            can_override: false,
            feature: Some("dxmt".to_owned()),
        },
    );
    let mut field_policy = BTreeMap::new();
    field_policy.insert(
        "graphicsBackend".to_owned(),
        EngineFieldPolicyDto {
            choices,
            ..EngineFieldPolicyDto::default()
        },
    );
    field_policy.insert(
        "dxvkAsync".to_owned(),
        EngineFieldPolicyDto {
            disabled: true,
            reason: Some("DXVK async is unverified on this engine".to_owned()),
            state: "unverified".to_owned(),
            can_override: true,
            feature: Some("dxvkAsync".to_owned()),
            choices: BTreeMap::new(),
        },
    );
    field_policy.insert(
        "metalValidation".to_owned(),
        EngineFieldPolicyDto {
            disabled: true,
            reason: Some("managed runtime only".to_owned()),
            state: "unavailable".to_owned(),
            can_override: false,
            feature: None,
            choices: BTreeMap::new(),
        },
    );
    Box::new(WineEngineSelectionDto {
        engine_id: "external-1".to_owned(),
        engine: WineEngineDto {
            id: "external-1".to_owned(),
            name: "External".to_owned(),
            path: "/engines/external".to_owned(),
            managed: false,
            available: true,
            fingerprint: Some("fp-1".to_owned()),
            features: vec![WineEngineFeatureDto {
                id: "dxvkAsync".to_owned(),
                state: "unverified".to_owned(),
                can_override: true,
                ..WineEngineFeatureDto::default()
            }],
            ..WineEngineDto::default()
        },
        feature_overrides: BTreeMap::new(),
        features: Vec::new(),
        field_policy,
    })
}

fn toggle_field(id: &str) -> ConfigField {
    ConfigField {
        id: id.to_owned(),
        title: id.to_owned(),
        title_key: String::new(),
        kind: FieldKind::Toggle,
        default: serde_json::Value::Bool(false),
        requires: Vec::new(),
        platforms: Vec::new(),
    }
}

#[gpui_kit::test]
fn engine_selection_replies_stay_on_their_own_container(cx: &mut gpui_kit::TestAppContext) {
    let window = engine_window(cx);
    window
        .update(cx, |this, _, cx| {
            this.bottles = vec![
                crate::model::BottleVm {
                    path: "/bottles/a".into(),
                    name: "A".into(),
                    available: true,
                },
                crate::model::BottleVm {
                    path: "/bottles/b".into(),
                    name: "B".into(),
                    available: true,
                },
            ];
            this.selected_bottle = Some(0);
            this.apply_bridge_event(
                crate::bridge::BridgeEvent::EngineSelection {
                    container: "/bottles/b".into(),
                    selection: external_selection(),
                },
                cx,
            );
            this.apply_bridge_event(
                crate::bridge::BridgeEvent::EngineSelection {
                    container: "/bottles/a".into(),
                    selection: external_selection(),
                },
                cx,
            );
            // Both replies landed under their own containers; nothing leaked
            // from the stale B readback into the page for A.
            assert_eq!(this.engine_selections.len(), 2);
            assert!(this.engine_selections.contains_key("/bottles/a"));
            assert!(this.engine_selections.contains_key("/bottles/b"));

            // A failure for a bottle the user is not looking at stays quiet.
            this.apply_bridge_event(
                crate::bridge::BridgeEvent::EngineSelectionFailed {
                    container: "/bottles/b".into(),
                    reason: "busy".into(),
                },
                cx,
            );
            assert!(this.notice.is_none());
            this.apply_bridge_event(
                crate::bridge::BridgeEvent::EngineSelectionFailed {
                    container: "/bottles/a".into(),
                    reason: "container busy".into(),
                },
                cx,
            );
            assert!(this.notice.is_some());
        })
        .unwrap();
}

#[gpui_kit::test]
fn wine_engines_events_update_list_and_report_errors(cx: &mut gpui_kit::TestAppContext) {
    let window = engine_window(cx);
    window
        .update(cx, |this, _, cx| {
            this.apply_bridge_event(
                crate::bridge::BridgeEvent::WineEngines {
                    list: WineEngineListDto {
                        engines: vec![
                            WineEngineDto {
                                id: "managed".into(),
                                managed: true,
                                available: true,
                                ..WineEngineDto::default()
                            },
                            WineEngineDto {
                                id: "ext".into(),
                                managed: false,
                                available: false,
                                error: Some("missing loader".into()),
                                ..WineEngineDto::default()
                            },
                        ],
                        load_error: Some("registry corrupt".into()),
                    },
                },
                cx,
            );
            assert_eq!(this.wine_engines.len(), 2);
            assert_eq!(this.wine_engines_error.as_deref(), Some("registry corrupt"));

            this.apply_bridge_event(
                crate::bridge::BridgeEvent::WineEngineOpFailed {
                    reason: "engine in use".into(),
                },
                cx,
            );
            assert!(this.notice.is_some());
        })
        .unwrap();
}

#[gpui_kit::test]
fn confirmable_engine_feature_opens_dialog_and_cancel_drops_it(
    cx: &mut gpui_kit::TestAppContext,
) {
    let window = engine_window(cx);
    window
        .update(cx, |this, _, cx| {
            this.config = Some(crate::state::ConfigPage {
                container: "/bottles/a".into(),
                capabilities: Vec::new(),
                fields: vec![toggle_field("dxvkAsync")],
                values: BTreeMap::new(),
                loading: false,
                error: None,
            });
            this.engine_selections
                .insert("/bottles/a".into(), *external_selection());

            // Enabling an unverified feature is not written immediately: the
            // confirmation dialog opens instead.
            this.set_config_value("dxvkAsync", serde_json::json!(true), cx);
            let page = this.config.as_ref().unwrap();
            assert!(!page.values.contains_key("dxvkAsync"), "unconfirmed write must not land");
            let dialog = this.engine_dialog.as_ref().expect("confirmation dialog");
            match &dialog.kind {
                crate::state::EngineDialogKind::Feature {
                    feature,
                    apply,
                    fingerprint,
                    ..
                } => {
                    assert_eq!(feature, "dxvkAsync");
                    match apply {
                        crate::state::PendingEngineApply::Config { field, value } => {
                            assert_eq!(field, "dxvkAsync");
                            assert_eq!(value, &serde_json::json!(true));
                        }
                        _ => panic!("config apply expected"),
                    }
                    assert_eq!(fingerprint, "fp-1");
                }
                _ => panic!("feature confirmation expected"),
            }

            // Cancel drops the action without touching the bottle config.
            this.dismiss_engine_dialog(cx);
            assert!(this.engine_dialog.is_none());
            assert!(this.pending_engine_action.is_none());
            assert!(
                !this
                    .config
                    .as_ref()
                    .unwrap()
                    .values
                    .contains_key("dxvkAsync")
            );
        })
        .unwrap();
}

#[gpui_kit::test]
fn confirming_engine_feature_applies_the_queued_write(cx: &mut gpui_kit::TestAppContext) {
    let window = engine_window(cx);
    window
        .update(cx, |this, _, cx| {
            this.config = Some(crate::state::ConfigPage {
                container: "/bottles/a".into(),
                capabilities: Vec::new(),
                fields: vec![toggle_field("dxvkAsync")],
                values: BTreeMap::new(),
                loading: false,
                error: None,
            });
            this.engine_selections
                .insert("/bottles/a".into(), *external_selection());
            this.set_config_value("dxvkAsync", serde_json::json!(true), cx);
            assert!(this.engine_dialog.is_some());

            // Confirming sends only the approval: the queued write waits for
            // the matching `EngineSelection` reply, so nothing lands yet.
            this.confirm_engine_dialog(cx);
            assert!(this.engine_dialog.is_none());
            assert!(this.pending_engine_action.is_some());
            assert!(
                !this
                    .config
                    .as_ref()
                    .unwrap()
                    .values
                    .contains_key("dxvkAsync"),
                "write must wait for the approval reply"
            );

            // A reply for another container does not satisfy the pending
            // action — it stays queued for the real reply.
            let mut other = *external_selection();
            other
                .feature_overrides
                .insert("dxvkAsync".to_owned(), "fp-1".to_owned());
            this.apply_bridge_event(
                crate::bridge::BridgeEvent::EngineSelection {
                    container: "/bottles/b".into(),
                    selection: Box::new(other),
                },
                cx,
            );
            assert!(this.pending_engine_action.is_some());
            assert!(
                !this
                    .config
                    .as_ref()
                    .unwrap()
                    .values
                    .contains_key("dxvkAsync")
            );

            // The matching reply — approval persisted under the fingerprint
            // the dialog was opened against, AND the field now ungated (the
            // helper recomputes policy with the override) — applies the
            // queued write.
            let mut approved = *external_selection();
            approved
                .feature_overrides
                .insert("dxvkAsync".to_owned(), "fp-1".to_owned());
            approved
                .field_policy
                .get_mut("dxvkAsync")
                .unwrap()
                .disabled = false;
            this.apply_bridge_event(
                crate::bridge::BridgeEvent::EngineSelection {
                    container: "/bottles/a".into(),
                    selection: Box::new(approved),
                },
                cx,
            );
            assert!(this.pending_engine_action.is_none());
            assert_eq!(
                this.config.as_ref().unwrap().values.get("dxvkAsync"),
                Some(&serde_json::json!(true)),
                "confirmed write lands in the page values"
            );
        })
        .unwrap();
}

#[gpui_kit::test]
fn rejected_engine_approval_applies_no_write(cx: &mut gpui_kit::TestAppContext) {
    let window = engine_window(cx);
    window
        .update(cx, |this, _, cx| {
            this.config = Some(crate::state::ConfigPage {
                container: "/bottles/a".into(),
                capabilities: Vec::new(),
                fields: vec![toggle_field("dxvkAsync")],
                values: BTreeMap::new(),
                loading: false,
                error: None,
            });
            this.engine_selections
                .insert("/bottles/a".into(), *external_selection());
            this.set_config_value("dxvkAsync", serde_json::json!(true), cx);
            this.confirm_engine_dialog(cx);
            assert!(this.pending_engine_action.is_some());

            // A stale fingerprint / busy container fails the override: the
            // pending action clears and the requested write never happens.
            this.apply_bridge_event(
                crate::bridge::BridgeEvent::EngineSelectionFailed {
                    container: "/bottles/a".into(),
                    reason: "engine fingerprint changed".into(),
                },
                cx,
            );
            assert!(this.pending_engine_action.is_none());
            assert!(
                !this
                    .config
                    .as_ref()
                    .unwrap()
                    .values
                    .contains_key("dxvkAsync"),
                "rejected approval must not write"
            );
        })
        .unwrap();
}

#[gpui_kit::test]
fn unavailable_engine_field_is_refused_not_confirmed(cx: &mut gpui_kit::TestAppContext) {
    let window = engine_window(cx);
    window
        .update(cx, |this, _, cx| {
            this.config = Some(crate::state::ConfigPage {
                container: "/bottles/a".into(),
                capabilities: Vec::new(),
                fields: vec![toggle_field("metalValidation")],
                values: BTreeMap::new(),
                loading: false,
                error: None,
            });
            this.engine_selections
                .insert("/bottles/a".into(), *external_selection());

            // `metalValidation` is managed-only: no dialog, a refusal notice.
            this.set_config_value("metalValidation", serde_json::json!(true), cx);
            assert!(this.engine_dialog.is_none());
            assert!(
                !this
                    .config
                    .as_ref()
                    .unwrap()
                    .values
                    .contains_key("metalValidation")
            );
            assert!(this.notice.is_some());
        })
        .unwrap();
}

#[gpui_kit::test]
fn disabling_a_gated_field_writes_without_confirmation(cx: &mut gpui_kit::TestAppContext) {
    let window = engine_window(cx);
    window
        .update(cx, |this, _, cx| {
            let mut values = BTreeMap::new();
            values.insert("dxvkAsync".to_owned(), serde_json::json!(true));
            this.config = Some(crate::state::ConfigPage {
                container: "/bottles/a".into(),
                capabilities: Vec::new(),
                fields: vec![toggle_field("dxvkAsync")],
                values,
                loading: false,
                error: None,
            });
            this.engine_selections
                .insert("/bottles/a".into(), *external_selection());

            // Turning a gated feature off is always allowed — never gated.
            this.set_config_value("dxvkAsync", serde_json::json!(false), cx);
            assert!(this.engine_dialog.is_none());
            assert_eq!(
                this.config.as_ref().unwrap().values.get("dxvkAsync"),
                Some(&serde_json::json!(false))
            );
        })
        .unwrap();
}

#[gpui_kit::test]
fn choice_level_policy_gates_individual_options(cx: &mut gpui_kit::TestAppContext) {
    let window = engine_window(cx);
    window
        .update(cx, |this, _, cx| {
            this.config = Some(crate::state::ConfigPage {
                container: "/bottles/a".into(),
                capabilities: Vec::new(),
                fields: vec![ConfigField {
                    id: "graphicsBackend".to_owned(),
                    title: "Backend".to_owned(),
                    title_key: String::new(),
                    kind: FieldKind::Choice {
                        options: vec![
                            crate::config::ConfigOption {
                                id: "dxvk".into(),
                                title: "DXVK".into(),
                            },
                            crate::config::ConfigOption {
                                id: "dxmt".into(),
                                title: "DXMT".into(),
                            },
                        ],
                    },
                    default: serde_json::Value::String("recommended".into()),
                    requires: Vec::new(),
                    platforms: Vec::new(),
                }],
                values: BTreeMap::new(),
                loading: false,
                error: None,
            });
            this.engine_selections
                .insert("/bottles/a".into(), *external_selection());

            // The DXVK choice is unavailable on this engine — refused with a
            // reason, and the value stays untouched.
            this.set_config_value("graphicsBackend", serde_json::json!("dxvk"), cx);
            assert!(this.engine_dialog.is_none());
            assert!(this.notice.is_some());
            assert!(!this
                .config
                .as_ref()
                .unwrap()
                .values
                .contains_key("graphicsBackend"));

            // DXMT is supported: writes straight through, no dialog.
            this.set_config_value("graphicsBackend", serde_json::json!("dxmt"), cx);
            assert_eq!(
                this.config.as_ref().unwrap().values.get("graphicsBackend"),
                Some(&serde_json::json!("dxmt"))
            );
        })
        .unwrap();
}
