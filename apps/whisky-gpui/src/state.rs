//! Application state: the root view model, page/sheet enums, and navigation.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use gpui_kit::base::Transition;
use gpui_kit::component::input::InputState;
use gpui_kit::{prelude::*, *};
use serde_json::json;

use crate::bridge::dto::{
    AudioResultDto, CandidateDto, FoldersDto, GameDbMatchDto, MetadataCandidate,
    MetadataSearchGroupDto, ProgramDto, SetupStatusDto, SystemInfoDto, TroubleshootingCheckDto,
};
use crate::bridge::{
    BottleCreateUpdate, BottleOperation, BottleOperationUpdate, BridgeEvent, BridgeStatus,
    BridgeSupervisor, DiagnosticKind, DiagnosticUpdate, EntryMutation, FolderEdit, MetadataUpdate,
    ProgramMutation, ScanUpdate, SetupUpdate,
};
#[cfg(feature = "visual-test")]
use crate::library_layout::CardRect;
use crate::config::{self, ConfigField};
use crate::create_bottle::CreateBottleState;
use crate::library_view::{self, Sort};
use crate::model::{
    BottleVm, Game, demo_bottles, demo_data, demo_requested, empty_library_message,
};
use crate::preferences;
use crate::processes::{self, KillOutcome, ProcessTable};
use crate::program_settings::{ProgramSettingsPage, settings_patch};
use crate::programs::ProgramTable;
use crate::runtime::{
    ClipboardDecision, ClipboardPrompt, ConfiguredBottles, PendingEdits, PrimaryAction,
    RuntimeAction, RuntimeState, RuntimeTable, primary_action_for,
};
use crate::scan::JobStatus;
use crate::views::Command;
use crate::winetricks::{InstallJob, WinetricksState};

/// Toast copy for the demo-only menu actions, which still do not mutate
/// anything. Runtime failures reuse the same toast with the helper's reason.
pub(crate) const DEMO_NOTICE: &str = "外观演示 · 未启动游戏，也未修改容器";

/// How long preference writes are coalesced before reaching the bridge.
const PREFERENCE_DEBOUNCE: Duration = Duration::from_millis(300);
/// Text and number rows wait this long after the last keystroke; toggles and
/// pickers commit immediately.
const CONFIG_DEBOUNCE: Duration = Duration::from_millis(400);

/// `configuration.schema` + `configuration.read` for the selected bottle.
#[derive(Clone)]
pub(crate) struct ConfigPage {
    pub(crate) container: String,
    pub(crate) capabilities: Vec<String>,
    pub(crate) fields: Vec<ConfigField>,
    pub(crate) values: BTreeMap<String, serde_json::Value>,
    pub(crate) loading: bool,
    /// A page-level failure (schema or read); field rejections use the toast.
    pub(crate) error: Option<String>,
}

/// One scan, as the sheet renders it. `finished` stays true after completion so
/// the last result remains visible; starting another scan replaces it.
#[derive(Clone, Default)]
pub(crate) struct ScanState {
    pub(crate) container: String,
    pub(crate) job_id: Option<String>,
    pub(crate) status: Option<JobStatus>,
    pub(crate) stage: Option<String>,
    pub(crate) loaded: usize,
    pub(crate) total: Option<u64>,
    pub(crate) error: Option<String>,
    pub(crate) finished: bool,
}

/// What the in-app executable picker is for. `candidates` is filled in by the
/// `folders.candidates` reply, so the sheet lists them as they arrive.
#[derive(Clone)]
pub(crate) struct ExecutablePickerState {
    pub(crate) container: String,
    pub(crate) entry_id: String,
    pub(crate) title: String,
    /// The folder entry's own path: a folder, never a file.
    pub(crate) folder: String,
    /// Play starts the game afterwards; the card menu only records the choice.
    pub(crate) launch_after: bool,
    pub(crate) candidates: Vec<CandidateDto>,
}

impl ScanState {
    pub(crate) fn running(&self) -> bool {
        self.status.is_some_and(|status| !status.is_terminal())
    }
}

/// `programs.list` for one bottle. Pin/block replies carry the refreshed
/// list, so the table is always the helper's own view of the truth except
/// for edits still in flight.
pub(crate) struct ProgramsPage {
    pub(crate) container: String,
    pub(crate) table: ProgramTable,
    pub(crate) loading: bool,
    /// A page-level failure; a rejected pin/block uses the toast and rolls
    /// its own flag back.
    pub(crate) error: Option<String>,
}

/// `processes.list` for one bottle, polled while the Processes page is open.
pub(crate) struct ProcessesPage {
    pub(crate) container: String,
    pub(crate) table: ProcessTable,
    pub(crate) loading: bool,
    pub(crate) error: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum PreviewPage {
    Library,
    Bottle,
    ConfigureBottle,
    Programs,
    Processes,
    GameConfigs,
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum PreviewSheet {
    RunSettings(usize),
    Scan,
    /// The folder's `.exe` files, for picking what a folder entry starts.
    Executable,
    Winetricks,
    CreateBottle,
    /// Choose another bottle to re-home one library entry.
    MoveEntry(usize),
    /// Choose a bottle for a file opened from Finder or dropped on the window.
    OpenFile,
    Diagnostics,
    Audio,
    Dll,
    Graphics,
    /// Online metadata, custom cover and GameDB recommendations for a card.
    GameInfo(usize),
}

/// One `entry.move` request while its target picker is open.
pub(crate) struct MoveEntryState {
    pub(crate) title: String,
    pub(crate) source_container: String,
    pub(crate) entry_id: String,
    pub(crate) pending: bool,
    pub(crate) target_container: Option<String>,
    pub(crate) error: Option<String>,
}
/// A file opened from Finder or dropped on the window, awaiting a bottle.
pub(crate) struct OpenFileState {
    pub(crate) path: String,
    pub(crate) name: String,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum BottleDialogKind {
    Rename,
    Duplicate,
    Remove,
}

/// The sidebar's modal actions. Rename and Duplicate read a text field;
/// Remove asks whether the directory should be deleted as well.
pub(crate) struct BottleDialogState {
    pub(crate) kind: BottleDialogKind,
    pub(crate) container: String,
    pub(crate) name: String,
    pub(crate) suggested: String,
    pub(crate) input: Option<Entity<InputState>>,
}

/// What a `system.choosePath` reply should do when it comes back.
#[derive(Clone)]
enum PathAction {
    Run { container: String },
    Move { container: String },
    Export { container: String },
    Pin { container: String },
    DiagnosticsExport { container: String },
    MetadataCover { container: String, entry_id: String },
}

#[derive(Clone)]
pub(crate) struct MetadataGroup {
    pub(crate) source: String,
    pub(crate) error: Option<String>,
    pub(crate) games: Vec<MetadataCandidate>,
}

/// Scraper sources: toggle key, wire name, label.
pub(crate) const METADATA_SOURCES: [(&str, &str, &str); 4] = [
    ("src-steam", "steam", "Steam"),
    ("src-bangumi", "bangumi", "Bangumi"),
    ("src-vndb", "vndb", "VNDB"),
    ("src-ymgal", "ymgal", "月幕"),
];

/// The Game Info sheet: metadata search, cover choice and GameDB matches for
/// one library card.
pub(crate) struct GameInfoPage {
    pub(crate) container: String,
    pub(crate) entry_id: String,
    pub(crate) title: String,
    pub(crate) input: Option<Entity<InputState>>,
    pub(crate) searching: bool,
    pub(crate) applying: bool,
    pub(crate) error: Option<String>,
    pub(crate) groups: Vec<MetadataGroup>,
    pub(crate) matches: Option<Vec<GameDbMatchDto>>,
    pub(crate) config_message: Option<String>,
}
pub(crate) struct PreviewState {
    pub(crate) page: PreviewPage,
    pub(crate) history: Vec<PreviewPage>,
    pub(crate) sheet: Option<PreviewSheet>,
    pub(crate) sheet_history: Vec<PreviewSheet>,
    pub(crate) toggles: BTreeMap<&'static str, bool>,
    pub(crate) choices: BTreeMap<&'static str, SharedString>,
    pub(crate) collapsed: BTreeSet<&'static str>,
    pub(crate) inputs: BTreeMap<&'static str, Entity<InputState>>,
    /// Schema text/number rows, created on first render because `InputState`
    /// needs a window. Cleared when the bottle changes.
    pub(crate) config_inputs: BTreeMap<String, Entity<InputState>>,
    /// Per-root executable fields in the scan sheet, keyed `scan-exe:<root>`.
    pub(crate) folder_inputs: BTreeMap<String, Entity<InputState>>,
    /// Run-settings fields, recreated whenever a read replaces the draft.
    pub(crate) program_inputs: BTreeMap<String, Entity<InputState>>,
    /// Fields whose input must be rebuilt on the next render, after a rejected
    /// or normalized write. Replacing the entity avoids `set_value`, which
    /// would notify an observer while the root view is rendering.
    pub(crate) config_resets: BTreeSet<String>,
    pub(crate) sort: usize,
    // Retained per document, including forms mounted inside settings sheets.
    pub(crate) scroll_handles: std::cell::RefCell<BTreeMap<&'static str, ScrollHandle>>,
}
impl PreviewState {
    pub(crate) fn form_scroll_handle(&self, id: &'static str) -> ScrollHandle {
        self.scroll_handles
            .borrow_mut()
            .entry(id)
            .or_insert_with(ScrollHandle::new)
            .clone()
    }
    pub(crate) fn new(window: &mut Window, cx: &mut Context<WhiskyApp>) -> Self {
        let mut inputs = BTreeMap::new();
        for (key, placeholder) in [
            ("arguments", "启动参数，例如 -windowed"),
            ("env-key", "变量名"),
            ("env-value", "变量值"),
            ("scan-path", "~/Games"),
            ("bottle-name", ""),
            ("dll-name", "例如 d3dcompiler_47"),
            ("build", "26100"),
            ("dpi", "96"),
            ("desktop-width", "1920"),
            ("desktop-height", "1080"),
            ("dependency-search", "搜索组件…"),
        ] {
            inputs.insert(
                key,
                cx.new(|cx| InputState::new(window, cx).placeholder(placeholder)),
            );
        }
        Self {
            page: PreviewPage::Library,
            history: vec![],
            sheet: None,
            sheet_history: vec![],
            inputs,
            config_inputs: BTreeMap::new(),
            folder_inputs: BTreeMap::new(),
            program_inputs: BTreeMap::new(),
            config_resets: BTreeSet::new(),
            toggles: [
                ("refresh", preferences::DEFAULT_REFRESH_AFTER_EXIT),
                ("single-title", preferences::DEFAULT_SINGLE_LINE_TITLES),
                ("center-cover-text", preferences::DEFAULT_CENTER_WIDE_COVER_TEXT),
                ("blurred-fill", preferences::DEFAULT_BLURRED_COVER_FILL),
                ("shader", true),
                ("appnap", true),
                ("kill", preferences::DEFAULT_KILL_ON_TERMINATE),
                ("menubar", preferences::DEFAULT_SHOW_MENU_BAR_EXTRA),
                ("src-steam", true),
                ("src-bangumi", true),
                ("src-vndb", true),
                ("src-ymgal", true),
                ("offline", preferences::DEFAULT_OFFLINE_MODE),
                ("updates", preferences::DEFAULT_CHECK_UPDATES),
                ("blur", preferences::DEFAULT_DETAIL_BLURRED_BACKGROUND),
            ]
            .into(),
            choices: [
                ("create-windows", "Windows 11".into()),
                ("terminal", preferences::DEFAULT_PREFERRED_TERMINAL.into()),
                ("cover-fill", preferences::DEFAULT_COVER_FILL_STYLE.into()),
                ("detail-layout", preferences::DEFAULT_DETAIL_LAYOUT_STYLE.into()),
            ]
            .into(),
            collapsed: [
                "launcher",
                "input",
                "dll",
                "cleanup",
                "overrides",
                "console",
            ]
            .into(),
            sort: 0,
            scroll_handles: Default::default(),
        }
    }
}

/// The query/scope a cached index list was computed for. `revision` changes
/// whenever an entry is added, removed, or mutated.
#[derive(Clone, PartialEq, Eq)]
struct ViewKey {
    query: String,
    slot: usize,
    show_hidden: bool,
    revision: u64,
}

#[derive(Clone, PartialEq, Eq)]
struct OrderKey {
    view: ViewKey,
    sort: usize,
    reversed: bool,
}

#[derive(Default)]
struct ViewCache {
    view: Option<(ViewKey, Vec<usize>)>,
    ordered: Option<(OrderKey, Vec<usize>)>,
}

pub(crate) struct WhiskyApp {
    pub(crate) preview: PreviewState,
    pub(crate) search: Entity<InputState>,
    pub(crate) mode: usize,
    /// The bundled demo snapshot, enabled with `WHISKY_GPUI_DEMO_DATA=1`.
    pub(crate) demo: bool,
    pub(crate) bottles: Vec<BottleVm>,
    /// Every loaded entry, in bottle order, de-duplicated for display.
    /// `Game::bottle` is the one-based slot and `Game::container` is the path.
    pub(crate) entries: Vec<Game>,
    /// Successful reads keyed by bottle path: revisiting a bottle is instant.
    bottle_entries: BTreeMap<String, Vec<Game>>,
    /// Index into `bottles`; `None` means the whole library.
    pub(crate) selected_bottle: Option<usize>,
    /// A read for the visible scope is still in flight.
    pub(crate) loading: bool,
    /// Session/catalogue failure for the whole library surface.
    pub(crate) load_error: Option<String>,
    /// Bottle indices with a queued or in-flight read.
    pending: BTreeSet<usize>,
    /// Per-bottle read errors, shown when that bottle is visible.
    failures: BTreeMap<usize, String>,
    /// Bottles already handed to `runtime.configure`, so Play on the Library
    /// page configures each bottle exactly once.
    configured: ConfiguredBottles,
    /// `libraryShowHiddenGames`; hidden entries stay in `entries` (so indices
    /// are stable) and only leave the grid through this filter.
    show_hidden: bool,
    view_cache: RefCell<ViewCache>,
    library_revision: u64,
    /// Keys `preferences.schema` advertises. Anything else stays in memory.
    prefs_supported: BTreeSet<String>,
    prefs_pending: BTreeMap<String, serde_json::Value>,
    prefs_generation: u64,
    /// Bottle configuration for the selected bottle; `None` until the page is
    /// opened or after a bottle switch.
    pub(crate) config: Option<ConfigPage>,
    /// Last committed value per field, for rolling back a rejected write.
    config_writes: PendingEdits<serde_json::Value>,
    /// Text/number drafts not yet sent, coalesced across fields.
    config_text_pending: BTreeMap<String, String>,
    config_text_generation: u64,
    /// Folder state keyed by container path.
    pub(crate) folders: BTreeMap<String, FoldersDto>,
    pub(crate) folders_pending: BTreeSet<String>,
    pub(crate) folders_error: BTreeMap<String, String>,
    /// Containers whose folder settings changed and whose entries need a
    /// read after the next `Folders` reply.
    folders_reload_after_write: BTreeSet<String>,
    /// Containers that already had their automatic metadata pass this
    /// session. A scan may reset it: new folders can be pending again.
    auto_synced: BTreeSet<String>,
    /// Container waiting for the native multi-folder picker reply.
    scan_root_picker: Option<String>,
    /// The card the in-app executable picker is open for, and whether choosing
    /// one should start it (Play) or only record it (the card menu).
    pub(crate) executable_picker: Option<ExecutablePickerState>,
    /// Container environment map keyed by container path.
    pub(crate) environments: BTreeMap<String, BTreeMap<String, String>>,
    pub(crate) environment_error: BTreeMap<String, String>,
    /// Installed programs for the selected bottle.
    pub(crate) programs: Option<ProgramsPage>,
    /// Running processes for the selected bottle, polled while its page is
    /// open.
    pub(crate) processes: Option<ProcessesPage>,
    /// Bumped to stop the process poll loop: a loop exits once the generation
    /// it captured no longer matches.
    process_generation: u64,
    /// The one scan job this session follows.
    pub(crate) scan: Option<ScanState>,
    /// The one create-bottle job this session follows.
    pub(crate) create_bottle: Option<CreateBottleState>,
    /// Winetricks catalog, per-bottle installed sets and the one install job.
    pub(crate) winetricks: WinetricksState,
    /// Draft of the program whose run-settings sheet is open.
    pub(crate) program_settings: ProgramSettingsPage,
    /// The pending library-entry move, while its target picker is open.
    pub(crate) move_entry: Option<MoveEntryState>,
    /// The opened/dropped file, while its bottle picker is open.
    pub(crate) open_file: Option<OpenFileState>,
    /// Metadata, cover and GameDB state for the open Game Info sheet.
    pub(crate) game_info: Option<GameInfoPage>,
    /// The sidebar's rename/duplicate/remove dialog.
    pub(crate) bottle_dialog: Option<BottleDialogState>,
    /// The lifecycle operation currently in flight, if any.
    pub(crate) bottle_operation: Option<(BottleOperation, String)>,
    /// A file/folder/save picker whose reply drives a bottle action.
    pending_path_action: Option<PathAction>,
    /// A bottle path to select once the refreshed catalogue arrives (move,
    /// duplicate).
    select_after_refresh: Option<String>,
    /// `bottle.diagnostics` report text and its request state.
    pub(crate) diagnostics_report: Option<String>,
    pub(crate) diagnostics_pending: bool,
    pub(crate) diagnostics_error: Option<String>,
    pub(crate) diagnostic_checks: Option<Vec<TroubleshootingCheckDto>>,
    pub(crate) checks_pending: bool,
    /// `audio.test` result and its request state.
    pub(crate) audio_result: Option<AudioResultDto>,
    pub(crate) audio_pending: bool,
    pub(crate) audio_error: Option<String>,
    /// WhiskyWine runtime status and the first-run setup dialog.
    pub(crate) setup_status: Option<SetupStatusDto>,
    /// The one-shot WhiskyWine update check for this session.
    wine_update_checked: bool,
    pub(crate) setup_dialog: bool,
    pub(crate) setup_installing: bool,
    pub(crate) setup_stage: Option<String>,
    /// Downloaded and total bytes while the runtime archive downloads.
    pub(crate) setup_progress: Option<(u64, u64)>,
    pub(crate) setup_error: Option<String>,
    setup_prompted: bool,
    /// `defaultBottleLocation` from preferences, used as `bottle.create`'s parent.
    pub(crate) default_bottle_location: Option<String>,
    /// Key that "编辑" put in the env inputs; saving with a different name
    /// removes it first, because the bridge has no rename call.
    env_original: Option<String>,
    env_clear_on_reply: bool,
    /// Text "编辑" staged for the two env inputs; applied on the next render.
    pub(crate) env_fill: Option<(String, String)>,
    /// Last committed value per entry, for rolling back optimistic edits.
    rating_edits: PendingEdits<Option<u8>>,
    hidden_edits: PendingEdits<bool>,
    pub(crate) sidebar: bool,
    pub(crate) settings: bool,
    /// The About panel; independent of the settings page and sheets.
    pub(crate) about: bool,
    /// Packaged version metadata from `system.info`, when the helper answered.
    pub(crate) app_info: Option<SystemInfoDto>,
    /// An explicit quit is waiting for the helper to apply the exit policy.
    quitting: bool,
    pub(crate) motion: bool,
    pub(crate) lively: bool,
    pub(crate) reversed: bool,
    pub(crate) library_scroll: [ScrollHandle; 3],
    pub(crate) detail_scroll: ScrollHandle,
    pub(crate) scroll_needs_measurement: std::cell::Cell<bool>,
    #[cfg(feature = "visual-test")]
    pub(crate) motion_samples: std::cell::RefCell<std::collections::BTreeMap<usize, CardRect>>,
    pub(crate) mixed: bool,
    pub(crate) hovered: Option<usize>,
    pub(crate) ambient_index: usize,
    pub(crate) detail: Option<usize>,
    pub(crate) detail_open: bool,
    /// The message on the existing toast; `None` hides it. Runtime and entry
    /// failures reuse the toast instead of introducing another surface.
    pub(crate) notice: Option<SharedString>,
    /// Per-entry launch state, keyed by bridge entry id.
    pub(crate) runtime: RuntimeTable,
    /// The clipboard preflight awaiting a decision, if any.
    pub(crate) clipboard_prompt: Option<ClipboardPrompt>,
    pub(crate) bridge: BridgeSupervisor,
    pub(crate) bridge_status: BridgeStatus,
    pub(crate) bridge_dialog: bool,
    pub(crate) _subscriptions: Vec<Subscription>,
}
impl WhiskyApp {
    pub(crate) fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search programs"));
        let subscription = cx.observe(&search, |_, _, cx| cx.notify());
        let preview = PreviewState::new(window, cx);
        let dependency_search = preview.inputs["dependency-search"].clone();
        let dependency_subscription = cx.observe(&dependency_search, |_, _, cx| cx.notify());
        let (bridge, bridge_events) = BridgeSupervisor::start();
        // Polling pauses in the background, so the worker starts from the real
        // activation state rather than assuming the window is focused.
        bridge.set_active(window.is_window_active());
        let activation = cx.observe_window_activation(window, |this, window, _| {
            this.bridge.set_active(window.is_window_active());
        });
        // Closing the last window quits, but the helper applies the exit policy
        // first. The frame is saved in request_quit for Cmd-Q and close alike.
        window.on_window_should_close(cx, {
            let view = cx.entity().downgrade();
            move |window, cx| {
                let _ = view.update(cx, |this, cx| this.request_quit(window, cx));
                false
            }
        });
        cx.spawn(async move |this, cx| {
            while let Ok(event) = bridge_events.recv().await {
                let _ = this.update(cx, |this, cx| this.apply_bridge_event(event, cx));
            }
        })
        .detach();
        let demo = demo_requested(std::env::var("WHISKY_GPUI_DEMO_DATA").ok().as_deref());
        Self {
            preview,
            search,
            mode: 0,
            demo,
            bottles: if demo { demo_bottles() } else { Vec::new() },
            entries: Vec::new(),
            bottle_entries: BTreeMap::new(),
            selected_bottle: None,
            loading: false,
            load_error: None,
            pending: BTreeSet::new(),
            failures: BTreeMap::new(),
            configured: ConfiguredBottles::default(),
            show_hidden: preferences::DEFAULT_SHOW_HIDDEN,
            view_cache: RefCell::new(ViewCache::default()),
            library_revision: 0,
            prefs_supported: BTreeSet::new(),
            prefs_pending: BTreeMap::new(),
            prefs_generation: 0,
            config: None,
            config_writes: PendingEdits::default(),
            config_text_pending: BTreeMap::new(),
            config_text_generation: 0,
            folders: BTreeMap::new(),
            folders_pending: BTreeSet::new(),
            folders_error: BTreeMap::new(),
            folders_reload_after_write: BTreeSet::new(),
            auto_synced: BTreeSet::new(),
            scan_root_picker: None,
            executable_picker: None,
            environments: BTreeMap::new(),
            environment_error: BTreeMap::new(),
            programs: None,
            processes: None,
            process_generation: 0,
            scan: None,
            create_bottle: None,
            winetricks: WinetricksState::default(),
            program_settings: ProgramSettingsPage::default(),
            move_entry: None,
            open_file: None,
            game_info: None,
            bottle_dialog: None,
            bottle_operation: None,
            pending_path_action: None,
            select_after_refresh: None,
            diagnostics_report: None,
            diagnostics_pending: false,
            diagnostics_error: None,
            diagnostic_checks: None,
            checks_pending: false,
            audio_result: None,
            audio_pending: false,
            audio_error: None,
            setup_status: None,
            wine_update_checked: false,
            setup_dialog: false,
            setup_installing: false,
            setup_stage: None,
            setup_progress: None,
            setup_error: None,
            setup_prompted: false,
            default_bottle_location: Self::default_bottle_location(),
            env_original: None,
            env_clear_on_reply: false,
            env_fill: None,
            rating_edits: PendingEdits::default(),
            hidden_edits: PendingEdits::default(),
            sidebar: true,
            settings: false,
            about: false,
            app_info: None,
            quitting: false,
            motion: true,
            lively: false,
            reversed: false,
            library_scroll: std::array::from_fn(|_| ScrollHandle::new()),
            detail_scroll: ScrollHandle::new(),
            scroll_needs_measurement: Default::default(),
            #[cfg(feature = "visual-test")]
            motion_samples: Default::default(),
            mixed: preferences::DEFAULT_MIXED_COVER_LAYOUT,
            hovered: None,
            ambient_index: 0,
            detail: None,
            detail_open: false,
            notice: None,
            runtime: RuntimeTable::default(),
            clipboard_prompt: None,
            bridge,
            bridge_status: BridgeStatus::Locating,
            bridge_dialog: false,
            _subscriptions: vec![subscription, dependency_subscription, activation],
        }
    }
    pub(crate) fn bridge_retry(&mut self, cx: &mut Context<Self>) {
        self.bridge.retry();
        self.bridge_status = BridgeStatus::Locating;
        self.bridge_dialog = false;
        self.pending.clear();
        self.failures.clear();
        self.load_error = None;
        self.loading = false;
        self.runtime = RuntimeTable::default();
        self.configured.clear();
        self.rating_edits.clear();
        self.hidden_edits.clear();
        self.clipboard_prompt = None;
        self.bottle_dialog = None;
        self.bottle_operation = None;
        self.pending_path_action = None;
        self.select_after_refresh = None;
        self.reset_bottle_surfaces();
        cx.notify();
    }

    /// Drop the bottle-page caches: a new helper session may have a different
    /// configuration file, folder list, and environment.
    fn reset_bottle_surfaces(&mut self) {
        self.config = None;
        self.config_writes.clear();
        self.config_text_pending.clear();
        self.config_text_generation = self.config_text_generation.wrapping_add(1);
        self.preview.config_inputs.clear();
        self.preview.folder_inputs.clear();
        self.preview.program_inputs.clear();
        self.preview.config_resets.clear();
        self.program_settings = ProgramSettingsPage::default();
        self.move_entry = None;
        self.game_info = None;
        if matches!(
            self.preview.sheet,
            Some(PreviewSheet::MoveEntry(_) | PreviewSheet::GameInfo(_))
        ) {
            self.preview.sheet = None;
            self.preview.sheet_history.clear();
        }
        self.folders.clear();
        self.folders_pending.clear();
        self.folders_error.clear();
        self.folders_reload_after_write.clear();
        self.auto_synced.clear();
        self.scan_root_picker = None;
        self.executable_picker = None;
        self.environments.clear();
        self.environment_error.clear();
        self.env_original = None;
        self.env_clear_on_reply = false;
        self.env_fill = None;
        self.diagnostics_report = None;
        self.diagnostics_pending = false;
        self.diagnostics_error = None;
        self.diagnostic_checks = None;
        self.checks_pending = false;
        self.audio_result = None;
        self.audio_pending = false;
        self.audio_error = None;
        self.pending_path_action = None;
        self.programs = None;
        self.processes = None;
        self.winetricks = WinetricksState::default();
        self.stop_process_polling();
        if self.scan.as_ref().is_some_and(ScanState::running) {
            // The job lived in the previous session.
            self.scan = None;
        }
    }

    /// Route a supervisor event into the library view model. Errors never panic
    /// and never discard entries that are already on screen.
    pub(crate) fn apply_bridge_event(&mut self, event: BridgeEvent, cx: &mut Context<Self>) {
        match event {
            BridgeEvent::Status(status) => {
                if let BridgeStatus::Connected {
                    helper,
                    version,
                    methods,
                } = &status
                {
                    eprintln!(
                        "whisky-bridge: connected to {helper} ({version}, {methods} methods)"
                    );
                }
                let connected = matches!(&status, BridgeStatus::Connected { .. });
                let unavailable =
                    matches!(&status, BridgeStatus::Failed { .. } | BridgeStatus::Stopped);
                let reason = match &status {
                    BridgeStatus::Failed { reason, .. } => Some(reason.clone()),
                    BridgeStatus::Stopped => {
                        Some("The bridge helper is not running.".to_owned())
                    }
                    _ => None,
                };
                let stopped = matches!(&status, BridgeStatus::Stopped);
                self.bridge_status = status;
                if connected && !self.demo {
                    // One read per connected session; the reply carries both
                    // the stored values and the writable-key schema.
                    self.bridge.load_preferences();
                    self.bridge.load_system_info();
                }
                if stopped && self.quitting {
                    cx.quit();
                    return;
                }
                if unavailable && !self.demo {
                    self.pending.clear();
                    self.configured.clear();
                    self.rating_edits.clear();
                    self.hidden_edits.clear();
                    // A pending clipboard token belongs to a session that is
                    // gone; re-launching from the card gets a fresh one.
                    self.clipboard_prompt = None;
                    if self.entries.is_empty() {
                        self.load_error = reason;
                    }
                }
            }
            BridgeEvent::Containers(containers) => {
                if !self.demo {
                    let previous = self
                        .selected_bottle
                        .and_then(|index| self.bottles.get(index).map(|bottle| bottle.path.clone()));
                    self.bottles = containers
                        .into_iter()
                        .map(|container| BottleVm {
                            path: container.path,
                            name: container.name,
                            available: container.available,
                        })
                        .collect();
                    // A reconnect keeps the selected bottle when it still exists.
                    self.selected_bottle = previous
                        .and_then(|path| self.bottles.iter().position(|bottle| bottle.path == path));
                    self.bottle_entries.clear();
                    self.entries.clear();
                    self.failures.clear();
                    self.load_error = None;
                    self.pending.clear();
                    // The helper keeps no runtime session across processes.
                    self.runtime = RuntimeTable::default();
                    self.configured.clear();
                    self.rating_edits.clear();
                    self.hidden_edits.clear();
                    self.reset_bottle_surfaces();
                    self.invalidate_view();
                    self.request_all();
                    // A reconnect must re-configure, or every card would stay
                    // disabled with no way back short of reselecting the bottle.
                    if let Some(path) = self
                        .selected_bottle
                        .and_then(|index| self.bottles.get(index))
                        .filter(|bottle| bottle.available)
                        .map(|bottle| bottle.path.clone())
                        && self.configured.ensure(&path)
                    {
                        self.bridge.configure_runtime(&path);
                    }
                }
            }
            BridgeEvent::ContainersRefreshed(containers) => {
                if !self.demo {
                    self.apply_refreshed_containers(containers);
                    if let Some(path) = self.select_after_refresh.take() {
                        if let Some(index) = self
                            .bottles
                            .iter()
                            .position(|bottle| bottle.path == path)
                        {
                            self.select_bottle(Some(index), cx);
                        }
                    }
                    if self
                        .bottle_dialog
                        .as_ref()
                        .is_some_and(|dialog| {
                            !self
                                .bottles
                                .iter()
                                .any(|bottle| bottle.path == dialog.container)
                        })
                    {
                        self.bottle_dialog = None;
                    }
                }
            }
            BridgeEvent::ActionFailed { reason } => {
                if !self.demo {
                    self.show_notice(reason, cx);
                }
            }
            BridgeEvent::FolderChosen { path } => {
                if let Some(path) = path {
                    self.default_bottle_location = Some(path.clone());
                    self.persist(preferences::DEFAULT_BOTTLE_LOCATION, json!(path), cx);
                    self.show_notice("已更新默认容器位置", cx);
                }
            }
            BridgeEvent::FolderChooseFailed { reason } => {
                if !self.demo {
                    self.show_notice(reason, cx);
                }
            }
            BridgeEvent::Runtime(update) => {
                if !self.demo {
                    // A poll for the previous container must not leak into the
                    // new one; `resync` already clears, this guards the delta.
                    if self
                        .selected_bottle
                        .and_then(|index| self.bottles.get(index))
                        .is_none_or(|bottle| bottle.path == update.container)
                    {
                        // `libraryRefreshAfterExit`: the activity store gains
                        // `lastSessionEndedAt` when a session ends, and the
                        // recent sort only sees it after the entries are
                        // re-read (Swift: `LibraryModel.consume`).
                        let exited = update.entries.iter().any(|entry| {
                            RuntimeState::from_wire(&entry.state) == RuntimeState::Idle
                                && self
                                    .runtime
                                    .entry(&entry.id)
                                    .is_some_and(|previous| previous.state.is_active())
                        });
                        let container = update.container.clone();
                        self.runtime.apply(update);
                        if exited
                            && self
                                .preview
                                .toggles
                                .get("refresh")
                                .copied()
                                .unwrap_or(preferences::DEFAULT_REFRESH_AFTER_EXIT)
                        {
                            self.bridge.load_entries(&container);
                        }
                    }
                }
            }
            BridgeEvent::ClipboardPrompt(prompt) => {
                if !self.demo {
                    self.clipboard_prompt = Some(prompt);
                }
            }
            BridgeEvent::RuntimeFailed { reason } => {
                if !self.demo {
                    self.show_notice(reason, cx);
                }
            }
            BridgeEvent::ConfigureFailed { container, reason } => {
                if !self.demo {
                    // The set only records successes; let the next Play retry.
                    self.configured.forget(&container);
                    self.show_notice(reason, cx);
                }
            }
            BridgeEvent::Entries { container, entries } => {
                if !self.demo
                    && let Some(index) = self
                        .bottles
                        .iter()
                        .position(|bottle| bottle.path == container)
                {
                    let slot = index + 1;
                    let games: Vec<Game> = entries
                        .into_iter()
                        .map(|entry| {
                            let mut game = entry.into_game(slot);
                            // Tag by the bottle that answered the request, not
                            // by a lookup that could race a catalogue change.
                            game.container = container.clone();
                            game
                        })
                        .collect();
                    self.bottle_entries.insert(container.clone(), games);
                    self.rebuild_entries();
                    self.pending.remove(&index);
                    self.failures.remove(&index);
                    self.maybe_auto_sync_metadata(&container);
                }
            }
            BridgeEvent::LoadFailed { container, reason } => {
                if !self.demo {
                    let index = container.and_then(|container| {
                        self.bottles
                            .iter()
                            .position(|bottle| bottle.path == container)
                    });
                    match index {
                        Some(index) => {
                            self.pending.remove(&index);
                            self.failures.insert(index, reason);
                        }
                        None => {
                            self.pending.clear();
                            self.load_error = Some(reason);
                        }
                    }
                }
            }
            BridgeEvent::Preferences { values, schema } => {
                if !self.demo {
                    self.prefs_supported = schema.keys().map(str::to_owned).collect();
                    self.apply_preferences(&values);
                }
            }
            BridgeEvent::SystemInfo { info } => {
                self.app_info = Some(info);
            }
            BridgeEvent::EntryRating {
                container,
                entry_id,
                activity,
            } => {
                if !self.demo {
                    let key = entry_key(&container, &entry_id);
                    self.rating_edits.succeed(&key);
                    // The reply is the activity record itself; never re-derive
                    // the value from what was requested.
                    self.update_entry(&container, &entry_id, |game| {
                        game.rating = activity.rating();
                        game.play_time = activity.play_time();
                        game.last_played = activity.last_played();
                        game.last_session_ended_at = activity.last_session_ended_at();
                    });
                    self.rebuild_entries();
                }
            }
            BridgeEvent::EntryHidden {
                container,
                entry_id,
                hidden,
            } => {
                if !self.demo {
                    let key = entry_key(&container, &entry_id);
                    self.hidden_edits.succeed(&key);
                    self.update_entry(&container, &entry_id, |game| game.hidden = hidden);
                    self.rebuild_entries();
                }
            }
            BridgeEvent::EntryFailed {
                mutation,
                container,
                entry_id,
                reason,
            } => {
                if !self.demo {
                    self.roll_back(mutation, &container, &entry_id);
                    self.show_notice(reason, cx);
                }
            }
            BridgeEvent::Configuration {
                container,
                capabilities,
                schema,
                values,
            } => {
                if !self.demo {
                    let changed = self
                        .config
                        .as_ref()
                        .is_none_or(|page| page.container != container);
                    if changed {
                        // A different bottle means different input entities.
                        self.preview.config_inputs.clear();
                        self.preview.config_resets.clear();
                        self.config_writes.clear();
                        self.config_text_pending.clear();
                        self.config_text_generation =
                            self.config_text_generation.wrapping_add(1);
                    }
                    self.config = Some(ConfigPage {
                        container,
                        capabilities,
                        fields: schema,
                        values,
                        loading: false,
                        error: None,
                    });
                }
            }
            BridgeEvent::ConfigurationSaved {
                container,
                field,
                values,
            } => {
                if !self.demo {
                    self.config_writes.succeed(&field);
                    if let Some(page) = self
                        .config
                        .as_mut()
                        .filter(|page| page.container == container)
                    {
                        // Apply only the field that was written: another
                        // debounced edit may still be in flight and must not be
                        // clobbered by this readback.
                        if let Some(value) = values.get(&field) {
                            page.values.insert(field, value.clone());
                        }
                    }
                }
            }
            BridgeEvent::ConfigurationFailed {
                container,
                field,
                reason,
            } => {
                if !self.demo {
                    match field {
                        None => {
                            if let Some(page) = self
                                .config
                                .as_mut()
                                .filter(|page| page.container == container)
                            {
                                page.loading = false;
                                page.error = Some(reason.clone());
                            }
                        }
                        Some(field) => {
                            if let Some(previous) = self.config_writes.fail(&field) {
                                if let Some(page) = self
                                    .config
                                    .as_mut()
                                    .filter(|page| page.container == container)
                                {
                                    page.values.insert(field.clone(), previous.clone());
                                    self.preview.config_resets.insert(field);
                                }
                            }
                        }
                    }
                    self.show_notice(reason, cx);
                }
            }
            BridgeEvent::Candidates { candidates } => {
                if let Some(picker) = self.executable_picker.as_mut() {
                    // The helper echoes the folder it walked; the reply may
                    // also be for a folder the user has since left, so both
                    // come from the reply rather than from the request.
                    if !candidates.folder.is_empty() {
                        picker.folder = candidates.folder;
                    }
                    picker.candidates = candidates.candidates;
                }
            }
            BridgeEvent::Folders { container, folders } => {
                if !self.demo {
                    self.folders_pending.remove(&container);
                    self.folders_error.remove(&container);
                    let changed = self.folders_reload_after_write.remove(&container);
                    let automatic_turned_on = folders.automatic_metadata
                        && !self
                            .folders
                            .get(&container)
                            .is_some_and(|current| current.automatic_metadata);
                    self.folders.insert(container.clone(), folders);
                    if automatic_turned_on {
                        // Switching the library's own match back on earns a
                        // fresh pass over its pending entries.
                        self.auto_synced.remove(&container);
                        self.maybe_auto_sync_metadata(&container);
                    }
                    if changed {
                        // Roots, assignment, exclusion, visibility or the
                        // executable choice all change how entries are read.
                        self.bottle_entries.remove(&container);
                        self.bridge.load_entries(&container);
                    }
                }
            }
            BridgeEvent::FoldersFailed { container, reason } => {
                if !self.demo {
                    self.folders_pending.remove(&container);
                    self.folders_reload_after_write.remove(&container);
                    self.folders_error
                        .insert(container, reason.clone());
                    self.show_notice(reason, cx);
                }
            }
            BridgeEvent::FoldersChosen { purpose, paths } => {
                if !self.demo && purpose == "scan-roots" {
                    if let Some(container) = self.scan_root_picker.take() {
                        let paths: Vec<String> = paths
                            .into_iter()
                            .filter(|path| path.starts_with('/'))
                            .collect();
                        if !paths.is_empty() {
                            self.folders_reload_after_write.insert(container.clone());
                            self.bridge.add_scan_roots(&container, &paths);
                        }
                    }
                }
            }
            BridgeEvent::ScanRootMoved { source, target } => {
                if !self.demo {
                    self.show_notice("已将扫描文件夹移动到另一个容器", cx);
                    self.folders_reload_after_write.remove(&source);
                    self.folders_reload_after_write.remove(&target);
                    self.refresh_library(cx);
                }
            }
            BridgeEvent::Environment { container, values } => {
                if !self.demo {
                    self.environment_error.remove(&container);
                    self.environments.insert(container, values);
                    if self.env_clear_on_reply {
                        self.env_clear_on_reply = false;
                        self.env_original = None;
                        // Applied on the next render, which has a window.
                        self.env_fill = Some((String::new(), String::new()));
                    }
                }
            }
            BridgeEvent::EnvironmentFailed { container, reason } => {
                if !self.demo {
                    self.env_clear_on_reply = false;
                    self.environment_error
                        .insert(container, reason.clone());
                    self.show_notice(reason, cx);
                }
            }
            BridgeEvent::Programs {
                container,
                programs,
                settled,
            } => {
                if !self.demo {
                    if let Some(page) = self
                        .programs
                        .as_mut()
                        .filter(|page| page.container == container)
                    {
                        if let Some((mutation, path)) = &settled {
                            match mutation {
                                ProgramMutation::Pin => page.table.commit_pin(path),
                                ProgramMutation::Block => page.table.commit_block(path),
                            }
                        }
                        page.table.apply(programs);
                        page.loading = false;
                        page.error = None;
                    }
                    if settled.is_some() {
                        // Pinned programs appear in (and leave) the library:
                        // `workspace.entries` is built from the pin list.
                        self.bridge.load_entries(&container);
                    }
                }
            }
            BridgeEvent::ProgramsFailed { container, reason } => {
                if !self.demo {
                    if let Some(page) = self
                        .programs
                        .as_mut()
                        .filter(|page| page.container == container)
                    {
                        page.loading = false;
                        page.error = Some(reason.clone());
                    }
                    self.show_notice(reason, cx);
                }
            }
            BridgeEvent::ProgramFailed {
                mutation,
                container,
                path,
                reason,
            } => {
                if !self.demo {
                    if let Some(page) = self
                        .programs
                        .as_mut()
                        .filter(|page| page.container == container)
                    {
                        match mutation {
                            ProgramMutation::Pin => {
                                page.table.rollback_pin(&path);
                            }
                            ProgramMutation::Block => {
                                page.table.rollback_block(&path);
                            }
                        }
                    }
                    self.show_notice(reason, cx);
                }
            }
            BridgeEvent::Processes { container, processes } => {
                if !self.demo {
                    if let Some(page) = self
                        .processes
                        .as_mut()
                        .filter(|page| page.container == container)
                    {
                        page.table.apply(processes);
                        page.loading = false;
                        page.error = None;
                    }
                }
            }
            BridgeEvent::ProcessesFailed { container, reason } => {
                if !self.demo {
                    if let Some(page) = self
                        .processes
                        .as_mut()
                        .filter(|page| page.container == container)
                    {
                        page.loading = false;
                        page.error = Some(reason.clone());
                    }
                    self.show_notice(reason, cx);
                }
            }
            BridgeEvent::ProcessKilled {
                container,
                pid,
                killed,
            } => {
                if !self.demo {
                    let restored = self
                        .processes
                        .as_mut()
                        .filter(|page| page.container == container)
                        .is_some_and(|page| {
                            matches!(page.table.finish_kill(pid, killed), KillOutcome::Restored(_))
                        });
                    if restored {
                        self.show_notice("未能结束该进程", cx);
                    }
                }
            }
            BridgeEvent::ProcessKillFailed {
                container,
                pid,
                reason,
            } => {
                if !self.demo {
                    if let Some(page) = self
                        .processes
                        .as_mut()
                        .filter(|page| page.container == container)
                    {
                        let _ = page.table.finish_kill(pid, false);
                    }
                    self.show_notice(reason, cx);
                }
            }
            BridgeEvent::Scan { container, update } => {
                if !self.demo {
                    match update {
                        ScanUpdate::Started { job_id } => {
                            let state = self.scan.get_or_insert_with(ScanState::default);
                            state.container = container;
                            state.job_id = Some(job_id);
                            state.status = Some(JobStatus::Queued);
                            state.stage = None;
                            state.error = None;
                            state.finished = false;
                        }
                        ScanUpdate::Progress {
                            status,
                            stage,
                            loaded,
                            total,
                        } => {
                            let state = self.scan.get_or_insert_with(ScanState::default);
                            state.container = container;
                            state.status = Some(status);
                            state.stage = stage;
                            if let Some(loaded) = loaded {
                                state.loaded = loaded;
                            }
                            if total.is_some() {
                                state.total = total;
                            }
                            state.error = None;
                        }
                        ScanUpdate::Completed { entries } => {
                            let state = self.scan.get_or_insert_with(ScanState::default);
                            state.container = container.clone();
                            state.status = Some(JobStatus::Completed);
                            state.stage = None;
                            state.loaded = entries.len();
                            state.total = Some(entries.len() as u64);
                            state.finished = true;
                            state.error = None;

                            let index = self
                                .bottles
                                .iter()
                                .position(|bottle| bottle.path == container);
                            let slot = index.map_or(0, |index| index + 1);
                            let games: Vec<Game> = entries
                                .into_iter()
                                .map(|entry| {
                                    let mut game = entry.into_game(slot);
                                    game.container = container.clone();
                                    game
                                })
                                .collect();
                            self.bottle_entries.insert(container.clone(), games);
                            // A bottle that vanished mid-scan must not clear
                            // another bottle's pending marker.
                            if let Some(index) = index {
                                self.pending.remove(&index);
                                self.failures.remove(&index);
                            }
                            self.rebuild_entries();
                            // New folders can be pending their first match
                            // even if this bottle already had its pass.
                            self.auto_synced.remove(&container);
                            self.maybe_auto_sync_metadata(&container);
                        }
                        ScanUpdate::Failed { status, reason } => {
                            let state = self.scan.get_or_insert_with(ScanState::default);
                            state.container = container;
                            state.status = Some(status);
                            state.stage = None;
                            state.finished = true;
                            state.error = Some(reason.clone());
                            if status != JobStatus::Cancelled {
                                self.show_notice(reason, cx);
                            }
                        }
                    }
                }
            }
            BridgeEvent::BottleCreate { update } => {
                if !self.demo {
                    match update {
                        BottleCreateUpdate::Started { job_id } => {
                            let state = self.create_bottle.get_or_insert_with(CreateBottleState::default);
                            state.job_id = Some(job_id);
                            state.status = Some(JobStatus::Queued);
                            state.stage = None;
                            state.error = None;
                            state.finished = false;
                        }
                        BottleCreateUpdate::Progress { status, stage } => {
                            let state = self.create_bottle.get_or_insert_with(CreateBottleState::default);
                            state.status = Some(status);
                            state.stage = stage;
                            state.error = None;
                        }
                        BottleCreateUpdate::Completed {
                            path,
                            name,
                            containers,
                        } => {
                            let state = self.create_bottle.get_or_insert_with(CreateBottleState::default);
                            state.status = Some(JobStatus::Completed);
                            state.stage = None;
                            state.finished = true;
                            state.error = None;
                            state.created_path = Some(path.clone());
                            self.show_notice(format!("已成功创建容器 {name}"), cx);

                            // Update the bottle catalogue
                            let previous = self
                                .selected_bottle
                                .and_then(|index| self.bottles.get(index).map(|bottle| bottle.path.clone()));
                            self.bottles = containers
                                .into_iter()
                                .map(|container| BottleVm {
                                    path: container.path,
                                    name: container.name,
                                    available: container.available,
                                })
                                .collect();
                            self.selected_bottle = previous
                                .and_then(|path| self.bottles.iter().position(|bottle| bottle.path == path));
                            self.bottle_entries.clear();
                            self.entries.clear();
                            self.failures.clear();
                            self.load_error = None;
                            self.pending.clear();
                            self.runtime = RuntimeTable::default();
                            self.configured.clear();
                            self.rating_edits.clear();
                            self.hidden_edits.clear();
                            self.reset_bottle_surfaces();
                            self.invalidate_view();
                            self.request_all();

                            // Select the newly created bottle
                            if let Some(index) = self.bottles.iter().position(|bottle| bottle.path == path) {
                                self.select_bottle(Some(index), cx);
                            }
                        }
                        BottleCreateUpdate::Failed { status, reason } => {
                            let state = self.create_bottle.get_or_insert_with(CreateBottleState::default);
                            state.status = Some(status);
                            state.stage = None;
                            state.finished = true;
                            state.error = Some(reason.clone());
                            if status != JobStatus::Cancelled {
                                self.show_notice(reason, cx);
                            }
                        }
                    }
                }
            }
            BridgeEvent::WinetricksCatalog { catalog } => {
                if !self.demo {
                    self.winetricks.catalog = Some(catalog);
                    self.winetricks.catalog_pending = false;
                    self.winetricks.catalog_error = None;
                    self.winetricks.ensure_category();
                }
            }
            BridgeEvent::WinetricksCatalogFailed { reason } => {
                if !self.demo {
                    self.winetricks.catalog_pending = false;
                    self.winetricks.catalog_error = Some(reason);
                }
            }
            BridgeEvent::WinetricksInstalled { container, verbs } => {
                if !self.demo {
                    self.winetricks.set_installed(&container, verbs);
                }
            }
            BridgeEvent::WinetricksInstalledFailed { container, reason } => {
                if !self.demo {
                    self.winetricks.installed_pending.remove(&container);
                    self.winetricks.installed_error.insert(container, reason);
                }
            }
            BridgeEvent::WinetricksInstall { container, update } => {
                if !self.demo {
                    match update {
                        crate::winetricks::InstallUpdate::Started { job_id } => {
                            let mut job = InstallJob::new(&container);
                            job.job_id = Some(job_id);
                            job.status = Some(JobStatus::Queued);
                            self.winetricks.job = Some(job);
                        }
                        crate::winetricks::InstallUpdate::Progress { status, progress } => {
                            if let Some(job) = self
                                .winetricks
                                .job
                                .as_mut()
                                .filter(|job| job.container == container)
                            {
                                job.status = Some(status);
                                job.progress = progress;
                                job.error = None;
                            }
                        }
                        crate::winetricks::InstallUpdate::Completed {
                            installed,
                            succeeded,
                            failed,
                        } => {
                            self.winetricks.set_installed(&container, installed);
                            if let Some(job) = self
                                .winetricks
                                .job
                                .as_mut()
                                .filter(|job| job.container == container)
                            {
                                job.status = Some(JobStatus::Completed);
                                job.finished = true;
                                job.succeeded = succeeded;
                                job.failed = failed.clone();
                                job.error = None;
                            }
                            if !failed.is_empty() {
                                let reason = failed
                                    .first()
                                    .map(crate::winetricks::FailureDto::label)
                                    .unwrap_or_default();
                                self.show_notice(
                                    format!("{} 个组件安装失败：{reason}", failed.len()),
                                    cx,
                                );
                            }
                        }
                        crate::winetricks::InstallUpdate::Failed { status, reason } => {
                            if let Some(job) = self
                                .winetricks
                                .job
                                .as_mut()
                                .filter(|job| job.container == container)
                            {
                                job.status = Some(status);
                                job.finished = true;
                                job.error = Some(reason.clone());
                            }
                            if status != JobStatus::Cancelled {
                                self.show_notice(reason, cx);
                            }
                        }
                    }
                }
            }
            BridgeEvent::ProgramSettings { settings } => {
                if self.program_target_matches(&settings.container, &settings.executable) {
                    let close = self.program_settings.close_after_save;
                    self.program_settings.apply_settings(settings);
                    self.preview.program_inputs.clear();
                    if close {
                        self.preview.sheet = None;
                        self.preview.sheet_history.clear();
                        self.show_notice("程序设置已保存", cx);
                    }
                }
            }
            BridgeEvent::ProgramSettingsFailed {
                container,
                executable,
                reason,
            } => {
                if self.program_target_matches(&container, &executable) {
                    let was_saving = self.program_settings.saving;
                    self.program_settings.fail(reason.clone());
                    if was_saving {
                        self.show_notice(reason, cx);
                    }
                }
            }
            BridgeEvent::ProgramHistory {
                container,
                executable,
                history,
            } => {
                if self.program_target_matches(&container, &executable) {
                    self.program_settings.apply_history(history);
                }
            }
            BridgeEvent::ProgramHistoryFailed {
                container,
                executable,
                reason,
            } => {
                if self.program_target_matches(&container, &executable) {
                    self.program_settings.history_loading = false;
                    self.program_settings.history_error = Some(reason);
                }
            }
            BridgeEvent::ProgramShortcutCreated {
                container,
                executable,
                path,
            } => {
                if self.program_target_matches(&container, &executable) {
                    self.program_settings.shortcut_path = Some(path);
                    self.program_settings.shortcut_error = None;
                    self.show_notice("快捷方式已创建", cx);
                }
            }
            BridgeEvent::ProgramShortcutFailed {
                container,
                executable,
                reason,
            } => {
                if self.program_target_matches(&container, &executable) {
                    self.program_settings.shortcut_error = Some(reason.clone());
                    self.show_notice(reason, cx);
                }
            }
            BridgeEvent::ProgramRunFailed { name, reason } => {
                self.show_notice(format!("启动 {name} 失败：{reason}"), cx);
            }
            BridgeEvent::EntryMoved {
                source_container,
                target_container,
            } => {                let matches = self.move_entry.as_ref().is_some_and(|state| {
                    state.source_container == source_container
                        && state.target_container.as_deref() == Some(target_container.as_str())
                });
                if matches {
                    self.move_entry = None;
                    self.preview.sheet = None;
                    self.preview.sheet_history.clear();
                    // The move re-keyed the entry's id on the target
                    // container, so both sides need a fresh
                    // `runtime.configure` before the next Play
                    // (`retry_library` forgets the same way).
                    self.configured.forget(&source_container);
                    self.configured.forget(&target_container);
                    self.show_notice("已移动条目，正在刷新游戏库", cx);
                    self.refresh_library(cx);
                }
            }
            BridgeEvent::EntryMoveFailed {
                source_container,
                target_container,
                reason,
            } => {
                if let Some(state) = self.move_entry.as_mut()
                    && state.source_container == source_container
                    && state.target_container.as_deref() == Some(target_container.as_str())
                {
                    state.pending = false;
                    state.error = Some(reason.clone());
                }
                self.show_notice(reason, cx);
            }
            BridgeEvent::BottleOperation {
                operation,
                container,
                update,
            } => {
                if !self.demo {
                    match update {
                        BottleOperationUpdate::Started => {
                            self.bottle_operation = Some((operation, container));
                        }
                        BottleOperationUpdate::Completed { path, name } => {
                            if self
                                .bottle_operation
                                .as_ref()
                                .is_some_and(|(active, active_container)| {
                                    *active == operation && *active_container == container
                                })
                            {
                                self.bottle_operation = None;
                            }
                            if matches!(operation, BottleOperation::Move | BottleOperation::Duplicate)
                                && path.is_some()
                            {
                                self.select_after_refresh = path.clone();
                            }
                            let message = match operation {
                                BottleOperation::Rename => name.map_or_else(
                                    || "容器已重命名".to_owned(),
                                    |name| format!("容器已重命名为 {name}"),
                                ),
                                BottleOperation::Remove => "已移除容器".to_owned(),
                                BottleOperation::Move => "已移动容器".to_owned(),
                                BottleOperation::Duplicate => name.map_or_else(
                                    || "已复制容器".to_owned(),
                                    |name| format!("已复制容器 {name}"),
                                ),
                                BottleOperation::Export => path.map_or_else(
                                    || "容器已导出".to_owned(),
                                    |path| format!("容器已导出到 {path}"),
                                ),
                                BottleOperation::Repair => "容器修复完成".to_owned(),
                                BottleOperation::CleanCache => "着色器缓存已清理".to_owned(),
                            };
                            self.show_notice(message, cx);
                        }
                        BottleOperationUpdate::Failed { reason } => {
                            self.bottle_operation = None;
                            self.show_notice(reason, cx);
                        }
                    }
                }
            }
            BridgeEvent::PathChosen { purpose, path } => {
                if !self.demo {
                    let action = self.pending_path_action.take();
                    match (purpose.as_str(), action) {
                        ("run", Some(PathAction::Run { container })) => {
                            if let Some(path) = path {
                                let name = std::path::Path::new(&path)
                                    .file_name()
                                    .map(|name| name.to_string_lossy().into_owned())
                                    .unwrap_or_else(|| path.clone());
                                self.show_notice(format!("正在启动 {name}"), cx);
                                self.bridge.run_program(&container, &path, &name);
                            }
                        }
                        ("move", Some(PathAction::Move { container })) => {
                            if let Some(destination) = path {
                                self.bridge.bottle_operation(
                                    BottleOperation::Move,
                                    &container,
                                    None,
                                    Some(&destination),
                                    false,
                                );
                            }
                        }
                        ("export", Some(PathAction::Export { container })) => {
                            if let Some(destination) = path {
                                self.bridge.bottle_operation(
                                    BottleOperation::Export,
                                    &container,
                                    None,
                                    Some(&destination),
                                    false,
                                );
                            }
                        }
                        ("pin", Some(PathAction::Pin { container })) => {
                            if let Some(path) = path {
                                let name = std::path::Path::new(&path)
                                    .file_stem()
                                    .map(|name| name.to_string_lossy().into_owned())
                                    .unwrap_or_else(|| "程序".to_owned());
                                self.bridge
                                    .set_program_pinned(&container, &path, &name, true);
                            }
                        }
                        ("diagnostics-export", Some(PathAction::DiagnosticsExport { container })) => {
                            if let Some(destination) = path {
                                self.diagnostics_pending = true;
                                self.bridge
                                    .export_diagnostics(&container, &destination);
                            }
                        }
                        (
                            "metadata-cover",
                            Some(PathAction::MetadataCover {
                                container,
                                entry_id,
                            }),
                        ) => {
                            if let Some(path) = path {
                                if let Some(page) = self.game_info.as_mut() {
                                    page.applying = true;
                                    page.error = None;
                                }
                                self.bridge
                                    .import_metadata_cover(&container, &entry_id, &path);
                            }
                        }
                        _ => {}
                    }
                }
            }
            BridgeEvent::BottleToolOpened { container, tool } => {
                if !self.demo && self.selected_container().as_deref() == Some(container.as_str()) {
                    let label = match tool.as_str() {
                        "winecfg" => "Wine 配置",
                        "regedit" => "注册表编辑器",
                        "control" => "控制面板",
                        "terminal" => "终端",
                        _ => "Wine 工具",
                    };
                    self.show_notice(format!("已打开 {label}"), cx);
                }
            }
            BridgeEvent::Diagnostics {
                kind,
                container,
                update,
            } => {
                if !self.demo {
                    let current = self.selected_container().as_deref() == Some(container.as_str());
                    match update {
                        DiagnosticUpdate::Started => match kind {
                            DiagnosticKind::Report | DiagnosticKind::Export => {
                                self.diagnostics_pending = true;
                                self.diagnostics_error = None;
                            }
                            DiagnosticKind::Checks => {
                                self.checks_pending = true;
                                self.diagnostics_error = None;
                            }
                            DiagnosticKind::Audio => {
                                self.audio_pending = true;
                                self.audio_error = None;
                            }
                        },
                        DiagnosticUpdate::Report { report } => {
                            self.diagnostics_pending = false;
                            self.diagnostics_error = None;
                            if current {
                                self.diagnostics_report = Some(report);
                            }
                        }
                        DiagnosticUpdate::Exported { path } => {
                            self.diagnostics_pending = false;
                            self.show_notice(format!("诊断报告已导出到 {path}"), cx);
                        }
                        DiagnosticUpdate::Checks { results } => {
                            self.checks_pending = false;
                            self.diagnostics_error = None;
                            let failures = results
                                .iter()
                                .filter(|check| check.outcome == "fail" || check.outcome == "error")
                                .count();
                            self.diagnostic_checks = Some(results);
                            if failures > 0 {
                                self.show_notice(
                                    format!("自动检查完成：{failures} 项需要关注"),
                                    cx,
                                );
                            } else {
                                self.show_notice("自动检查完成：未发现明显问题", cx);
                            }
                        }
                        DiagnosticUpdate::Audio { result } => {
                            self.audio_pending = false;
                            self.audio_error = None;
                            let summary = result.summary.clone();
                            if current {
                                self.audio_result = Some(result);
                            }
                            self.show_notice(summary, cx);
                        }
                        DiagnosticUpdate::Failed { reason } => {
                            self.diagnostics_pending = false;
                            self.audio_pending = false;
                            self.checks_pending = false;
                            if kind == DiagnosticKind::Audio {
                                self.audio_error = Some(reason.clone());
                            } else {
                                self.diagnostics_error = Some(reason.clone());
                            }
                            self.show_notice(reason, cx);
                        }
                    }
                }
            }
            BridgeEvent::Metadata { update } => {
                if !self.demo {
                    match update {
                        MetadataUpdate::SearchStarted {
                            container,
                            entry_id,
                        } => {
                            if self.game_info.as_ref().is_some_and(|page| {
                                page.container == container && page.entry_id == entry_id
                            }) {
                                let page = self.game_info.as_mut().unwrap();
                                page.searching = true;
                                page.error = None;
                                page.groups.clear();
                            }
                        }
                        MetadataUpdate::Results {
                            container,
                            entry_id,
                            results,
                        } => {
                            if self.game_info.as_ref().is_some_and(|page| {
                                page.container == container && page.entry_id == entry_id
                            }) {
                                let page = self.game_info.as_mut().unwrap();
                                page.searching = false;
                                page.error = None;
                                page.groups = results
                                    .into_iter()
                                    .map(|MetadataSearchGroupDto { source, error, games }| {
                                        MetadataGroup {
                                            source,
                                            error,
                                            games: games
                                                .into_iter()
                                                .filter_map(MetadataCandidate::from_value)
                                                .collect(),
                                        }
                                    })
                                    .collect();
                            }
                        }
                        MetadataUpdate::Applied {
                            container,
                            entry_id,
                        } => {
                            if self.game_info.as_ref().is_some_and(|page| {
                                page.container == container && page.entry_id == entry_id
                            }) {
                                if let Some(page) = self.game_info.as_mut() {
                                    page.applying = false;
                                    page.error = None;
                                }
                                self.bridge.load_entries(&container);
                                self.show_notice("游戏资料已更新", cx);
                            }
                        }
                        MetadataUpdate::Matches {
                            container,
                            entry_id,
                            matches,
                        } => {
                            if self.game_info.as_ref().is_some_and(|page| {
                                page.container == container && page.entry_id == entry_id
                            }) {
                                self.game_info.as_mut().unwrap().matches = Some(matches);
                            }
                        }
                        MetadataUpdate::ConfigApplied {
                            container,
                            entry_id,
                            changes,
                            pending_verbs,
                        } => {
                            if self.game_info.as_ref().is_some_and(|page| {
                                page.container == container && page.entry_id == entry_id
                            }) {
                                let page = self.game_info.as_mut().unwrap();
                                page.applying = false;
                                page.config_message = Some(if pending_verbs.is_empty() {
                                    format!("已应用 {} 项推荐设置。", changes.len())
                                } else {
                                    format!(
                                        "已应用 {} 项推荐设置；仍需安装组件：{}",
                                        changes.len(),
                                        pending_verbs.join(", ")
                                    )
                                });
                                self.bridge.load_entries(&container);
                                if self
                                    .config
                                    .as_ref()
                                    .is_some_and(|config| config.container == container)
                                {
                                    self.bridge.load_configuration(&container);
                                }
                                self.show_notice("已应用 GameDB 推荐配置", cx);
                            }
                        }
                        MetadataUpdate::EntrySynced { container, entry } => {
                            if !self.demo {
                                // Patch the finished card in place; the final
                                // `Synced` still re-reads the whole bottle.
                                let slot = self
                                    .bottles
                                    .iter()
                                    .position(|bottle| bottle.path == container)
                                    .map(|index| index + 1);
                                if let Some(slot) = slot {
                                    let entry_id = entry.id.clone();
                                    let mut game = entry.into_game(slot);
                                    game.container = container.clone();
                                    if let Some(games) =
                                        self.bottle_entries.get_mut(&container)
                                    {
                                        match games.iter_mut().find(|g| g.id == entry_id) {
                                            Some(existing) => *existing = game,
                                            None => games.push(game),
                                        }
                                        self.rebuild_entries();
                                    }
                                }
                            }
                        }
                        MetadataUpdate::Synced {
                            container,
                            matched,
                            failed,
                            automatic,
                        } => {
                            if !automatic {
                                self.bridge.load_entries(&container);
                                let message = if failed > 0 {
                                    format!("游戏信息同步完成：匹配 {matched} 个，失败 {failed} 个")
                                } else {
                                    format!("游戏信息同步完成：匹配 {matched} 个")
                                };
                                self.show_notice(message, cx);
                            }
                            // Automatic runs already patched every matched
                            // card through `EntrySynced`; staying silent here
                            // also prevents the trigger loop that a
                            // whole-bottle re-read would cause.
                        }
                        MetadataUpdate::Failed { reason } => {
                            if let Some(page) = self.game_info.as_mut() {
                                page.searching = false;
                                page.applying = false;
                                page.error = Some(reason.clone());
                            }
                            self.show_notice(reason, cx);
                        }
                    }
                }
            }
            BridgeEvent::Setup { update } => {
                if !self.demo {
                    match update {
                        SetupUpdate::Status {
                            installed,
                            version,
                            rosetta_installed,
                            apple_silicon,
                        } => {
                            self.setup_status = Some(SetupStatusDto {
                                installed,
                                version,
                                path: self
                                    .setup_status
                                    .as_ref()
                                    .map(|status| status.path.clone())
                                    .unwrap_or_default(),
                                rosetta_installed,
                                apple_silicon,
                            });
                            if !installed && !self.setup_prompted {
                                self.setup_prompted = true;
                                self.setup_dialog = true;
                            }
                            // ContentView's startup flow: with the runtime in
                            // place and update checks enabled, compare against
                            // the published manifest once per session.
                            if installed
                                && !self.wine_update_checked
                                && self
                                    .preview
                                    .toggles
                                    .get("updates")
                                    .copied()
                                    .unwrap_or(preferences::DEFAULT_CHECK_UPDATES)
                            {
                                self.wine_update_checked = true;
                                self.bridge.check_wine_update();
                            }
                        }
                        SetupUpdate::Installing { stage, progress } => {
                            self.setup_dialog = true;
                            self.setup_installing = true;
                            self.setup_stage = stage;
                            self.setup_progress = progress;
                            self.setup_error = None;
                        }
                        SetupUpdate::Installed { version } => {
                            self.setup_installing = false;
                            self.setup_stage = None;
                            self.setup_progress = None;
                            self.setup_error = None;
                            self.setup_dialog = false;
                            let rosetta_installed = self
                                .setup_status
                                .as_ref()
                                .is_some_and(|status| status.rosetta_installed);
                            let apple_silicon = self
                                .setup_status
                                .as_ref()
                                .is_some_and(|status| status.apple_silicon);
                            self.setup_status = Some(SetupStatusDto {
                                installed: true,
                                version: version.clone(),
                                path: String::new(),
                                rosetta_installed,
                                apple_silicon,
                            });
                            let message = version.map_or_else(
                                || "Wine 运行时安装完成".to_owned(),
                                |version| format!("Wine 运行时 {version} 安装完成"),
                            );
                            self.show_notice(message, cx);
                            self.bridge.reload_library();
                        }
                        SetupUpdate::RosettaInstalled => {
                            self.setup_installing = false;
                            self.setup_stage = None;
                            self.setup_progress = None;
                            self.setup_error = None;
                            if let Some(status) = self.setup_status.as_mut() {
                                status.rosetta_installed = true;
                            }
                            self.show_notice("Rosetta 2 安装完成", cx);
                        }
                        SetupUpdate::WineUpdate { local, remote } => {
                            self.show_notice(
                                format!(
                                    "发现新版 WhiskyWine {remote}（当前 {local}），可在设置中更新运行时"
                                ),
                                cx,
                            );
                        }
                        SetupUpdate::Failed { reason } => {
                            self.setup_installing = false;
                            self.setup_error = Some(reason.clone());
                            self.show_notice(reason, cx);
                        }
                    }
                }
            }
        }
        self.loading = self.compute_loading();
        cx.notify();
    }

    /// Restore the last committed value for a rejected optimistic edit.
    fn roll_back(&mut self, mutation: EntryMutation, container: &str, entry_id: &str) {
        let key = entry_key(container, entry_id);
        match mutation {
            EntryMutation::Rating => {
                if let Some(previous) = self.rating_edits.fail(&key) {
                    self.update_entry(container, entry_id, |game| game.rating = previous);
                }
            }
            EntryMutation::Hidden => {
                if let Some(previous) = self.hidden_edits.fail(&key) {
                    self.update_entry(container, entry_id, |game| game.hidden = previous);
                }
            }
        }
        self.rebuild_entries();
    }

    /// Select a bottle (or `None` for the whole library). Entries are cached per
    /// bottle, so revisiting is instant; only a bottle without a cache issues a
    /// read. The runtime is configured once per session, lazily.
    pub(crate) fn select_bottle(&mut self, index: Option<usize>, cx: &mut Context<Self>) {
        self.settings = false;
        self.selected_bottle = index;
        self.preview.page = if index.is_none() {
            PreviewPage::Library
        } else {
            PreviewPage::Bottle
        };
        self.preview.history.clear();
        self.stop_process_polling();
        self.detail_open = false;
        self.hovered = None;
        if let Some(index) = index
            && !self.demo
            && let Some(bottle) = self.bottles.get(index)
            && bottle.available
        {
            let path = bottle.path.clone();
            self.failures.remove(&index);
            if !self.bottle_entries.contains_key(&path) && !self.pending.contains(&index) {
                self.pending.insert(index);
                self.bridge.load_entries(&path);
            }
            // The runtime publishes one session at a time, so selecting a
            // bottle rebinds it before any card can offer Play.
            if self.configured.ensure(&path) {
                self.bridge.configure_runtime(&path);
            }
        }
        self.loading = self.compute_loading();
        self.invalidate_view();
        cx.notify();
    }

    /// `LibraryView.loadMetadata`: once a bottle's entries land with
    /// metadata still missing, the folder library's automatic initial match
    /// gets one pass per catalogue revision. The bridge honours the
    /// library's own switch and pending set, so this only schedules the
    /// job; `auto_synced` keeps repeated loads from spawning no-op jobs.
    fn maybe_auto_sync_metadata(&mut self, container: &str) {
        if self.demo || self.auto_synced.contains(container) || self.offline() {
            return;
        }
        let needs_metadata = self.bottle_entries.get(container).is_some_and(|games| {
            games.iter().any(|game| {
                game.is_folder
                    && game.studio.is_none()
                    && game.description.is_none()
                    && game.release.is_none()
            })
        });
        if !needs_metadata {
            return;
        }
        let sources = self.metadata_sources();
        if sources.is_empty() {
            return;
        }
        self.auto_synced.insert(container.to_owned());
        self.bridge.sync_metadata(container, sources, true);
    }

    /// Retry the visible scope: re-read while connected, reconnect otherwise.
    pub(crate) fn retry_library(&mut self, cx: &mut Context<Self>) {
        self.load_error = None;
        self.failures.clear();
        if !self.demo {
            match self.bridge_status {
                BridgeStatus::Connected { .. } => {
                    self.pending.clear();
                    match self.selected_bottle {
                        Some(index) => {
                            if let Some(path) = self
                                .bottles
                                .get(index)
                                .filter(|bottle| bottle.available)
                                .map(|bottle| bottle.path.clone())
                            {
                                // A retry re-reads the bottle, so its runtime
                                // configuration must be refreshed as well.
                                self.bottle_entries.remove(&path);
                                self.configured.forget(&path);
                                self.pending.insert(index);
                                self.bridge.load_entries(&path);
                                if self.configured.ensure(&path) {
                                    self.bridge.configure_runtime(&path);
                                }
                            } else {
                                self.failures
                                    .insert(index, "This bottle is unavailable.".to_owned());
                            }
                        }
                        None => {
                            // Keep the caches on screen while each bottle is
                            // re-read; `Entries` replaces them one at a time.
                            self.request_all();
                        }
                    }
                }
                _ => {
                    self.pending.clear();
                    self.bridge.retry();
                    self.bridge_status = BridgeStatus::Locating;
                }
            }
        }
        self.loading = self.compute_loading();
        self.invalidate_view();
        cx.notify();
    }

    fn request_all(&mut self) {
        for index in 0..self.bottles.len() {
            if !self.bottles[index].available {
                self.failures
                    .insert(index, "This bottle is unavailable.".to_owned());
                continue;
            }
            let path = self.bottles[index].path.clone();
            self.pending.insert(index);
            self.bridge.load_entries(&path);
        }
    }

    fn compute_loading(&self) -> bool {
        if self.demo {
            return false;
        }
        match self.selected_bottle {
            Some(index) => self.pending.contains(&index),
            None => !self.pending.is_empty(),
        }
    }

    /// The flat grid list is rebuilt in bottle order so shelf layout is stable.
    /// Per-bottle caches keep every `(container, id)` record; only identical
    /// title+artwork cards are collapsed, and the first bottle wins.
    fn rebuild_entries(&mut self) {
        self.entries = library_view::merge_bottles(&self.bottles, &self.bottle_entries);
        self.invalidate_view();
    }

    /// Replace one entry in the per-bottle cache and in the display list.
    fn update_entry(&mut self, container: &str, entry_id: &str, mut update: impl FnMut(&mut Game)) {
        if let Some(games) = self.bottle_entries.get_mut(container) {
            for game in games.iter_mut().filter(|game| game.id == entry_id) {
                update(game);
            }
        }
        for game in self
            .entries
            .iter_mut()
            .filter(|game| game.container == container && game.id == entry_id)
        {
            update(game);
        }
    }

    /// Invalidate the memoised filter/order lists.
    fn invalidate_view(&mut self) {
        self.library_revision = self.library_revision.wrapping_add(1);
        *self.view_cache.get_mut() = ViewCache::default();
    }

    pub(crate) fn games(&self) -> &[Game] {
        if self.demo {
            demo_data()
        } else {
            &self.entries
        }
    }

    pub(crate) fn game(&self, index: usize) -> Option<&Game> {
        self.games().get(index)
    }

    /// One-based sidebar slot: `0` for the whole library.
    pub(crate) fn bottle_slot(&self) -> usize {
        self.selected_bottle.map_or(0, |index| index + 1)
    }

    pub(crate) fn bottle_name(&self) -> &str {
        self.selected_bottle
            .and_then(|index| self.bottles.get(index))
            .map(|bottle| bottle.name.as_str())
            .unwrap_or("Bottle")
    }

    pub(crate) fn bottle_name_at(&self, slot: usize) -> &str {
        slot.checked_sub(1)
            .and_then(|index| self.bottles.get(index))
            .map(|bottle| bottle.name.as_str())
            .unwrap_or("")
    }

    /// Entries in the visible scope before the search filter runs.
    fn scope_entry_count(&self) -> usize {
        match self.selected_bottle {
            Some(index) => self
                .games()
                .iter()
                .filter(|game| game.bottle == index + 1)
                .count(),
            None => self.games().len(),
        }
    }

    pub(crate) fn empty_library_message(&self) -> &'static str {
        empty_library_message(self.demo, self.bottles.len(), self.scope_entry_count())
    }

    /// The error surface is scoped: a broken bottle does not hide entries that
    /// loaded from another bottle on the Library page.
    pub(crate) fn visible_load_error(&self) -> Option<&str> {
        if self.demo {
            return None;
        }
        match self.selected_bottle {
            Some(index) => self.failures.get(&index).map(String::as_str),
            None => {
                if !self.entries.is_empty() {
                    return None;
                }
                self.load_error
                    .as_deref()
                    .or_else(|| self.failures.values().next().map(String::as_str))
            }
        }
    }
    pub(crate) fn timing(&self, ms: u64) -> Transition {
        Transition::new(Duration::from_millis(if self.motion { ms } else { 0 }))
    }
    pub(crate) fn open_detail(&mut self, index: usize, cx: &mut Context<Self>) {
        self.preview.sheet = None;
        if self.detail != Some(index) {
            self.detail_scroll.set_offset(point(px(0.), px(0.)));
        }
        self.detail = Some(index);
        self.detail_open = true;
        self.hovered = None;
        self.notice = None;
        cx.notify();
    }
    pub(crate) fn show_notice(&mut self, message: impl Into<SharedString>, cx: &mut Context<Self>) {
        self.notice = Some(message.into());
        cx.notify();
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(3)).await;
            let _ = this.update(cx, |this, cx| {
                this.notice = None;
                cx.notify();
            });
        })
        .detach();
    }

    fn view_key(&self, cx: &App) -> ViewKey {
        ViewKey {
            query: self.search.read(cx).value().trim().to_lowercase(),
            slot: self.bottle_slot(),
            show_hidden: self.show_hidden,
            revision: self.library_revision,
        }
    }

    /// Filtered indices, memoised per `(query, scope, hidden filter, revision)`.
    pub(crate) fn filtered(&self, cx: &App) -> Vec<usize> {
        let key = self.view_key(cx);
        {
            let cache = self.view_cache.borrow();
            if let Some((cached, indices)) = &cache.view
                && *cached == key
            {
                return indices.clone();
            }
        }
        let indices = library_view::filter_indices(
            self.games(),
            &key.query,
            key.slot,
            key.show_hidden,
        );
        self.view_cache.borrow_mut().view = Some((key, indices.clone()));
        indices
    }

    pub(crate) fn reorder_library(&mut self, cx: &mut Context<Self>) {
        self.reversed = !self.reversed;
        self.hovered = None;
        self.invalidate_view();
        cx.notify();
    }

    /// Filtered and sorted indices, memoised per
    /// `(query, scope, hidden filter, sort, reverse, revision)`.
    pub(crate) fn ordered(&self, cx: &App) -> Vec<usize> {
        let key = OrderKey {
            view: self.view_key(cx),
            sort: self.preview.sort,
            reversed: self.reversed,
        };
        {
            let cache = self.view_cache.borrow();
            if let Some((cached, indices)) = &cache.ordered
                && *cached == key
            {
                return indices.clone();
            }
        }
        let mut indices = self.filtered(cx);
        library_view::sort_indices(
            self.games(),
            &mut indices,
            Sort::from_index(self.preview.sort),
            &self.bottles,
            // `groupsLaunchers: displayMode != .timeline` (LibraryView.swift).
            Some(self.mode) != preferences::mode_index("timeline"),
        );
        if self.reversed {
            indices.reverse();
        }
        self.view_cache.borrow_mut().ordered = Some((key, indices.clone()));
        indices
    }

    pub(crate) fn command(&mut self, command: Command, cx: &mut Context<Self>) {
        match command {
            Command::Page(page) => self.navigate(page, cx),
            Command::Sheet(sheet) => self.open_preview_sheet(sheet, cx),
            Command::Details(i) => self.open_detail(i, cx),
            Command::Configure(i) => {
                let slot = self.game(i).map_or(0, |game| game.bottle);
                self.selected_bottle = slot.checked_sub(1).filter(|index| *index < self.bottles.len());
                self.navigate(PreviewPage::ConfigureBottle, cx);
            }
            Command::Toggle(key) => self.toggle_option(key, cx),
            Command::Choose(key, value) => self.choose(key, value, cx),
            Command::Sort(i) => self.set_sort(i, cx),
            Command::Reorder => self.reorder_library(cx),
            Command::Hide(i) => {
                if self.demo {
                    self.show_notice(DEMO_NOTICE, cx);
                } else {
                    self.toggle_hidden(i, cx);
                }
            }
            Command::Notice => self.show_notice(DEMO_NOTICE, cx),
            Command::Runtime(i) => {
                if self.demo {
                    self.show_notice(DEMO_NOTICE, cx);
                } else {
                    let action = self.primary_action(i).action;
                    self.perform_runtime_action(i, action, cx);
                }
            }
            Command::Executable(i) => {
                if self.demo {
                    self.show_notice(DEMO_NOTICE, cx);
                } else {
                    self.open_executable_picker(i, false, cx);
                }
            }
            Command::Reveal(i) => {
                if self.demo {
                    self.show_notice(DEMO_NOTICE, cx);
                } else if let Some(game) = self.game(i)
                    && let Some(path) = game.executable.as_ref()
                {
                    self.bridge
                        .reveal(&game.container, &path.to_string_lossy());
                }
            }
            Command::Shortcut => {
                if self.demo {
                    self.show_notice(DEMO_NOTICE, cx);
                } else {
                    self.create_program_shortcut(cx);
                }
            }
            Command::Move(i) => {
                if self.demo {
                    self.show_notice(DEMO_NOTICE, cx);
                } else {
                    self.open_preview_sheet(PreviewSheet::MoveEntry(i), cx);
                }
            }
            Command::OpenDrive => {
                if self.demo {
                    self.show_notice(DEMO_NOTICE, cx);
                } else if let Some(bottle) = self.selected_bottle.and_then(|i| self.bottles.get(i)) {
                    let drive = std::path::Path::new(&bottle.path).join("drive_c");
                    self.bridge.open(&bottle.path, &drive.to_string_lossy());
                }
            }
            Command::RefreshLibrary => {
                if self.demo {
                    self.show_notice(DEMO_NOTICE, cx);
                } else {
                    self.refresh_library(cx);
                }
            }
            Command::StopAllProcesses => {
                if self.demo {
                    self.show_notice(DEMO_NOTICE, cx);
                } else {
                    self.stop_all_processes(cx);
                }
            }
            Command::BottleRename(i) => {
                self.open_bottle_dialog(BottleDialogKind::Rename, i, cx);
            }
            Command::BottleDuplicate(i) => {
                self.open_bottle_dialog(BottleDialogKind::Duplicate, i, cx);
            }
            Command::BottleRemove(i) => {
                self.open_bottle_dialog(BottleDialogKind::Remove, i, cx);
            }
            Command::BottleMove(i) => self.start_move_bottle(i, cx),
            Command::BottleExport(i) => self.start_export_bottle(i, cx),
            Command::BottleReveal(i) => self.reveal_bottle(i, cx),
            Command::BottleDialogCancel => self.dismiss_bottle_dialog(cx),
            Command::BottleDialogConfirm => self.confirm_bottle_dialog(cx),
            Command::BottleRun => self.start_bottle_run(cx),
            Command::AddProgram => self.start_pin_program(cx),
            Command::BottleTool(tool) => self.open_bottle_tool(tool, cx),
            Command::BottleRepair => self.maintain_bottle(BottleOperation::Repair, cx),
            Command::CleanShaderCache => self.maintain_bottle(BottleOperation::CleanCache, cx),
            Command::RunDiagnostics => self.load_diagnostics(cx),
            Command::ExportDiagnostics => self.export_diagnostics(cx),
            Command::TestAudio => self.test_audio(cx),
            Command::RunBottleChecks => self.run_bottle_checks(cx),
            Command::RefreshProcesses => {
                if self.demo {
                    self.show_notice(DEMO_NOTICE, cx);
                } else {
                    self.refresh_processes(cx);
                }
            }
            Command::GameInfo(i) => self.open_game_info(i, cx),
            Command::MetadataSearch => self.search_game_info(cx),
            Command::MetadataApply(source, game) => {
                self.apply_game_info_metadata(source, game, cx);
            }
            Command::MetadataClear => self.clear_game_info_metadata(cx),
            Command::MetadataCover => self.choose_game_info_cover(cx),
            Command::MetadataCoverReset => self.reset_game_info_cover(cx),
            Command::GameDbApply(i) => self.apply_game_db_match(i, cx),
            Command::SyncMetadata => {
                if self.demo {
                    self.show_notice(DEMO_NOTICE, cx);
                } else if self.offline() {
                    self.show_notice("离线模式已开启，无法同步游戏信息", cx);
                } else if let Some(container) = self.scan_container() {
                    self.show_notice("正在扫描并同步游戏信息…", cx);
                    let sources = self.metadata_sources();
                    if sources.is_empty() {
                        self.show_notice("请至少启用一个刮削源", cx);
                    } else {
                        self.bridge.sync_metadata(&container, sources, false);
                    }
                } else {
                    self.show_notice("请先在侧边栏选择一个容器", cx);
                }
            }
            Command::InstallWineRuntime => self.install_wine_runtime(cx),
            Command::InstallRosetta => self.install_rosetta(cx),
            Command::DismissSetup => self.dismiss_setup(cx),
        }
        cx.notify();
    }

    pub(crate) fn stop_all_processes(&mut self, cx: &mut Context<Self>) {
        if let Some(bottle) = self.selected_bottle.and_then(|i| self.bottles.get(i)) {
            let container = bottle.path.clone();
            if let Some(page) = self.processes.as_mut().filter(|p| p.container == container) {
                page.table.apply(Vec::new());
            }
            self.bridge.kill_all_processes(&container);
            self.show_notice("已请求停止所有进程", cx);
        }
    }

    /// Save the window frame, then let the helper apply the stored
    /// kill-on-terminate policy before the process exits.
    pub(crate) fn request_quit(&mut self, window: &Window, cx: &mut Context<Self>) {
        if self.quitting {
            return;
        }
        self.quitting = true;
        crate::ui_state::save_window(window.window_bounds());
        self.bridge.shutdown_application();
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(8)).await;
            let _ = this.update(cx, |this, cx| {
                if this.quitting {
                    cx.quit();
                }
            });
        })
        .detach();
        cx.notify();
    }

    pub(crate) fn show_about(&mut self, cx: &mut Context<Self>) {
        self.about = true;
        self.bridge_dialog = false;
        cx.notify();
    }

    /// The settings page replaces the library body, as the gear does.
    pub(crate) fn open_settings(&mut self, cx: &mut Context<Self>) {
        self.settings = true;
        self.detail_open = false;
        self.preview.sheet = None;
        self.preview.sheet_history.clear();
        if !self.demo {
            self.bridge.load_setup_status();
        }
        cx.notify();
    }

    pub(crate) fn choose_bottle_location(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let current = self.default_bottle_location.clone().unwrap_or_default();
        self.bridge.choose_folder(&current);
    }

    /// The library's Refresh: SwiftUI reloads its bottles and re-reads every
    /// entry. Cards stay on screen while each bottle's reply replaces them.
    pub(crate) fn refresh_library(&mut self, cx: &mut Context<Self>) {
        match self.bridge_status {
            BridgeStatus::Connected { .. } => {
                self.load_error = None;
                self.bridge.reload_library();
            }
            // Without a session a refresh is a reconnect, as the retry path is.
            _ => self.retry_library(cx),
        }
    }

    /// Apply a catalogue re-read without discarding the runtime session:
    /// bottles keep their selection by path, caches of removed bottles are
    /// dropped, and every remaining bottle is re-read.
    fn apply_refreshed_containers(&mut self, containers: Vec<crate::bridge::dto::Container>) {
        let previous = self
            .selected_bottle
            .and_then(|index| self.bottles.get(index).map(|bottle| bottle.path.clone()));
        self.bottles = containers
            .into_iter()
            .map(|container| BottleVm {
                path: container.path,
                name: container.name,
                available: container.available,
            })
            .collect();
        let had_selection = previous.is_some();
        self.selected_bottle =
            previous.and_then(|path| self.bottles.iter().position(|bottle| bottle.path == path));
        if had_selection && self.selected_bottle.is_none() {
            // The selected bottle was removed or moved away: drop the bottle
            // page and stop polling a container that no longer exists.
            self.preview.page = PreviewPage::Library;
            self.preview.history.clear();
            self.detail_open = false;
            self.stop_process_polling();
        }
        let bottles = &self.bottles;
        self.bottle_entries.retain(|path, games| {
            match bottles.iter().position(|bottle| &bottle.path == path) {
                Some(index) => {
                    // Slots are positional, so a reordered catalogue renumbers.
                    for game in games.iter_mut() {
                        game.bottle = index + 1;
                    }
                    true
                }
                None => false,
            }
        });
        self.failures.clear();
        self.pending.clear();
        self.rebuild_entries();
        self.request_all();
    }

    fn toggle_option(&mut self, key: &'static str, cx: &mut Context<Self>) {
        let value = match key {
            "mixed" => {
                self.mixed = !self.mixed;
                self.mixed
            }
            "motion" => {
                self.motion = !self.motion;
                self.motion
            }
            "lively" => {
                self.lively = !self.lively;
                self.lively
            }
            "show-hidden" => {
                self.show_hidden = !self.show_hidden;
                self.invalidate_view();
                self.show_hidden
            }
            _ => {
                let slot = self.preview.toggles.entry(key).or_default();
                *slot = !*slot;
                *slot
            }
        };
        if let Some(preference) = Self::toggle_preference(key) {
            self.persist(preference, json!(value), cx);
        }
        cx.notify();
    }

    /// Persisted preference behind a toggle key; `None` means session-only.
    fn toggle_preference(key: &str) -> Option<&'static str> {
        match key {
            "refresh" => Some(preferences::REFRESH_AFTER_EXIT),
            "single-title" => Some(preferences::SINGLE_LINE_TITLES),
            "center-cover-text" => Some(preferences::CENTER_WIDE_COVER_TEXT),
            "blurred-fill" => Some(preferences::BLURRED_COVER_FILL),
            "kill" => Some(preferences::KILL_ON_TERMINATE),
            "menubar" => Some(preferences::SHOW_MENU_BAR_EXTRA),
            "offline" => Some(preferences::OFFLINE_MODE),
            "updates" => Some(preferences::CHECK_UPDATES),
            "blur" => Some(preferences::DETAIL_BLURRED_BACKGROUND),
            "mixed" => Some(preferences::MIXED_COVER_LAYOUT),
            "show-hidden" => Some(preferences::SHOW_HIDDEN),
            _ => None,
        }
    }

    /// Select one option from a settings dropdown. Only keys the SwiftUI app
    /// persists are written through; the rest stay session-local.
    pub(crate) fn choose(&mut self, key: &'static str, value: &'static str, cx: &mut Context<Self>) {
        self.preview.choices.insert(key, value.into());
        match key {
            "terminal" => self.persist(preferences::PREFERRED_TERMINAL, json!(value), cx),
            "cover-fill" => self.persist(preferences::COVER_FILL_STYLE, json!(value), cx),
            "detail-layout" => self.persist(preferences::DETAIL_LAYOUT_STYLE, json!(value), cx),
            _ => {}
        }
        cx.notify();
    }

    pub(crate) fn set_mode(&mut self, index: usize, cx: &mut Context<Self>) {
        self.mode = index;
        self.settings = false;
        self.hovered = None;
        self.persist(
            preferences::DISPLAY_MODE,
            json!(preferences::mode_value(index)),
            cx,
        );
        cx.notify();
    }

    fn set_sort(&mut self, index: usize, cx: &mut Context<Self>) {
        self.preview.sort = index;
        self.persist(
            preferences::SORT,
            json!(preferences::sort_value(index)),
            cx,
        );
        self.invalidate_view();
        cx.notify();
    }

    /// Queue one preference write, coalescing bursts into a single call.
    fn persist(&mut self, key: &'static str, value: serde_json::Value, cx: &mut Context<Self>) {
        if !self.prefs_supported.contains(key) {
            // Not in `preferences.schema`: this key lives in memory only.
            return;
        }
        self.prefs_pending.insert(key.to_owned(), value);
        self.prefs_generation = self.prefs_generation.wrapping_add(1);
        let generation = self.prefs_generation;
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(PREFERENCE_DEBOUNCE).await;
            let _ = this.update(cx, |this, _| {
                if this.prefs_generation != generation {
                    return;
                }
                for (key, value) in std::mem::take(&mut this.prefs_pending) {
                    this.bridge.set_preference(&key, value);
                }
            });
        })
        .detach();
    }

    /// Apply the stored values. Keys absent from the reply keep the SwiftUI
    /// defaults already in the state; keys absent from the schema are never
    /// written, so they also keep their default for the session.
    fn apply_preferences(&mut self, values: &serde_json::Value) {
        if let Some(raw) = values
            .get(preferences::DISPLAY_MODE)
            .and_then(serde_json::Value::as_str)
            .and_then(preferences::mode_index)
        {
            self.mode = raw;
        }
        if let Some(index) = values
            .get(preferences::SORT)
            .and_then(serde_json::Value::as_str)
            .and_then(preferences::sort_index)
        {
            self.preview.sort = index;
        }
        if let Some(flag) = values
            .get(preferences::SHOW_HIDDEN)
            .and_then(serde_json::Value::as_bool)
        {
            self.show_hidden = flag;
        }
        if let Some(flag) = values
            .get(preferences::MIXED_COVER_LAYOUT)
            .and_then(serde_json::Value::as_bool)
        {
            self.mixed = flag;
        }
        for (preference, toggle) in [
            (preferences::SINGLE_LINE_TITLES, "single-title"),
            (preferences::CENTER_WIDE_COVER_TEXT, "center-cover-text"),
            (preferences::BLURRED_COVER_FILL, "blurred-fill"),
            (preferences::REFRESH_AFTER_EXIT, "refresh"),
            (preferences::DETAIL_BLURRED_BACKGROUND, "blur"),
            (preferences::KILL_ON_TERMINATE, "kill"),
            (preferences::SHOW_MENU_BAR_EXTRA, "menubar"),
            (preferences::OFFLINE_MODE, "offline"),
            (preferences::CHECK_UPDATES, "updates"),
        ] {
            if let Some(flag) = values
                .get(preference)
                .and_then(serde_json::Value::as_bool)
            {
                self.preview.toggles.insert(toggle, flag);
            }
        }
        let string_choices: [(&str, &str, fn(&str) -> Option<usize>); 3] = [
            (
                preferences::PREFERRED_TERMINAL,
                "terminal",
                preferences::terminal_index,
            ),
            (
                preferences::COVER_FILL_STYLE,
                "cover-fill",
                preferences::cover_fill_index,
            ),
            (
                preferences::DETAIL_LAYOUT_STYLE,
                "detail-layout",
                preferences::detail_layout_index,
            ),
        ];
        for (preference, choice, valid) in string_choices {
            if let Some(raw) = values
                .get(preference)
                .and_then(serde_json::Value::as_str)
                .filter(|raw| valid(raw).is_some())
            {
                self.preview.choices.insert(choice, raw.into());
            }
        }
        if let Some(location) = values
            .get(preferences::DEFAULT_BOTTLE_LOCATION)
            .and_then(serde_json::Value::as_str)
        {
            self.default_bottle_location = Some(location.to_owned());
        }
        self.invalidate_view();
    }

    // MARK: - Bottle surfaces (configuration, environment, folders, scan)

    /// Default bottle location, matching the SwiftUI default.
    fn default_bottle_location() -> Option<String> {
        let home = std::env::var_os("HOME")?.to_string_lossy().into_owned();
        #[cfg(target_os = "macos")]
        {
            Some(format!("{}/Library/Containers/com.franke.Whisky/Bottles", home))
        }
        #[cfg(not(target_os = "macos"))]
        {
            Some(format!("{}/.local/share/whisky/Bottles", home))
        }
    }

    /// The selected bottle when it is usable; the bottle page only exists for
    /// one of those.
    pub(crate) fn selected_container(&self) -> Option<String> {
        self.selected_bottle
            .and_then(|index| self.bottles.get(index))
            .filter(|bottle| bottle.available)
            .map(|bottle| bottle.path.clone())
    }

    /// Open the rename/duplicate/remove modal for one sidebar row.
    pub(crate) fn open_bottle_dialog(
        &mut self,
        kind: BottleDialogKind,
        index: usize,
        cx: &mut Context<Self>,
    ) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(bottle) = self.bottles.get(index) else {
            return;
        };
        let container = bottle.path.clone();
        let name = bottle.name.clone();
        let suggested = if kind == BottleDialogKind::Duplicate {
            next_duplicate_name(&name, &self.bottles)
        } else {
            name.clone()
        };
        self.bottle_dialog = Some(BottleDialogState {
            kind,
            container,
            name,
            suggested,
            input: None,
        });
        cx.notify();
    }

    /// The dialog's text field, created on first render because `InputState`
    /// needs a window. A new dialog always starts without one.
    pub(crate) fn bottle_dialog_input(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<InputState> {
        if let Some(input) = self.bottle_dialog.as_ref().and_then(|dialog| dialog.input.clone()) {
            return input;
        }
        let initial = self
            .bottle_dialog
            .as_ref()
            .map(|dialog| dialog.suggested.clone())
            .unwrap_or_default();
        let entity = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("容器名称")
                .default_value(initial)
        });
        if let Some(dialog) = self.bottle_dialog.as_mut() {
            dialog.input = Some(entity.clone());
        }
        entity
    }

    pub(crate) fn dismiss_bottle_dialog(&mut self, cx: &mut Context<Self>) {
        self.bottle_dialog = None;
        cx.notify();
    }

    pub(crate) fn confirm_bottle_dialog(&mut self, cx: &mut Context<Self>) {
        let Some(dialog) = self.bottle_dialog.take() else {
            return;
        };
        if dialog.kind == BottleDialogKind::Remove {
            self.bottle_dialog = Some(dialog);
            return;
        }
        let name = dialog
            .input
            .as_ref()
            .map(|input| input.read(cx).value().to_string())
            .unwrap_or_else(|| dialog.suggested.clone());
        let name = name.trim().to_owned();
        if name.is_empty() {
            self.bottle_dialog = Some(dialog);
            self.show_notice("容器名称不能为空", cx);
            return;
        }
        let operation = match dialog.kind {
            BottleDialogKind::Rename => BottleOperation::Rename,
            BottleDialogKind::Duplicate => BottleOperation::Duplicate,
            BottleDialogKind::Remove => unreachable!(),
        };
        self.bridge.bottle_operation(
            operation,
            &dialog.container,
            Some(&name),
            None,
            false,
        );
        cx.notify();
    }

    /// Remove the dialog's bottle; `delete_files` distinguishes "remove from
    /// the list" from "delete the prefix on disk".
    pub(crate) fn remove_bottle(&mut self, delete_files: bool, cx: &mut Context<Self>) {
        let Some(dialog) = self.bottle_dialog.take() else {
            return;
        };
        self.bridge.bottle_operation(
            BottleOperation::Remove,
            &dialog.container,
            None,
            None,
            delete_files,
        );
        cx.notify();
    }

    pub(crate) fn start_move_bottle(&mut self, index: usize, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(bottle) = self.bottles.get(index) else {
            return;
        };
        let container = bottle.path.clone();
        let parent = std::path::Path::new(&container)
            .parent()
            .map(|path| path.to_string_lossy().into_owned());
        self.pending_path_action = Some(PathAction::Move {
            container: container.clone(),
        });
        self.bridge
            .choose_path("move", "folder", parent.as_deref(), None, &[]);
        cx.notify();
    }

    pub(crate) fn start_export_bottle(&mut self, index: usize, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(bottle) = self.bottles.get(index) else {
            return;
        };
        let container = bottle.path.clone();
        let parent = std::path::Path::new(&container)
            .parent()
            .map(|path| path.to_string_lossy().into_owned());
        let filename = format!("{}.tar", bottle.name);
        self.pending_path_action = Some(PathAction::Export {
            container: container.clone(),
        });
        self.bridge.choose_path(
            "export",
            "save",
            parent.as_deref(),
            Some(&filename),
            &["tar"],
        );
        cx.notify();
    }

    pub(crate) fn reveal_bottle(&mut self, index: usize, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(container) = self.bottles.get(index).map(|bottle| bottle.path.clone()) else {
            return;
        };
        self.bridge.reveal(&container, &container);
        cx.notify();
    }

    /// The bottle action bar's Run button: a native file picker whose reply
    /// starts the chosen Windows file in the selected bottle.
    pub(crate) fn start_bottle_run(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        let start = format!("{container}/drive_c");
        self.pending_path_action = Some(PathAction::Run {
            container: container.clone(),
        });
        self.bridge.choose_path(
            "run",
            "file",
            Some(&start),
            None,
            &["exe", "msi", "bat", "msix", "appx", "url"],
        );
        cx.notify();
    }

    /// Pin an arbitrary Windows file the installed-programs scan did not find.
    pub(crate) fn start_pin_program(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        let start = format!("{container}/drive_c");
        self.pending_path_action = Some(PathAction::Pin {
            container: container.clone(),
        });
        self.bridge.choose_path(
            "pin",
            "file",
            Some(&start),
            None,
            &["exe", "msi", "bat", "msix", "appx", "url"],
        );
        cx.notify();
    }

    pub(crate) fn open_bottle_tool(&mut self, tool: &'static str, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        self.bridge.open_bottle_tool(&container, tool);
        cx.notify();
    }

    /// Collect the stability report shown in the Diagnostics sheet.
    pub(crate) fn load_diagnostics(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        self.diagnostics_pending = true;
        self.diagnostics_error = None;
        self.diagnostics_report = None;
        self.bridge.load_diagnostics(&container);
        cx.notify();
    }

    /// Choose a file, then have the helper write the stability report there.
    pub(crate) fn export_diagnostics(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        let name = format!(
            "whisky-diagnostics-{}.txt",
            self.bottle_name().replace(['/', ':'], "-")
        );
        self.pending_path_action = Some(PathAction::DiagnosticsExport {
            container: container.clone(),
        });
        self.bridge.choose_path(
            "diagnostics-export",
            "save",
            Some(&container),
            Some(&name),
            &["txt"],
        );
        cx.notify();
    }

    /// Run the curated bottleneck checks (crash log, launcher, process, audio,
    /// GameDB availability) for the selected bottle.
    pub(crate) fn run_bottle_checks(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        self.checks_pending = true;
        self.diagnostics_error = None;
        self.diagnostic_checks = None;
        self.bridge.run_bottle_checks(&container);
        cx.notify();
    }

    /// Play the Wine audio probe tone in the selected bottle.
    pub(crate) fn test_audio(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        self.audio_pending = true;
        self.audio_error = None;
        self.audio_result = None;
        self.bridge.test_audio(&container, true);
        cx.notify();
    }

    /// The shared `offlineMode` default (`NetworkSettings.isOffline`). The
    /// bridge reads it too, but the original app warns before the network
    /// operation starts instead of surfacing a raw failure afterwards.
    fn offline(&self) -> bool {
        self.preview
            .toggles
            .get("offline")
            .copied()
            .unwrap_or(preferences::DEFAULT_OFFLINE_MODE)
    }

    pub(crate) fn install_wine_runtime(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        if self.offline() {
            self.show_notice("离线模式已开启，无法下载 Wine 运行时", cx);
            return;
        }
        self.setup_dialog = true;
        self.setup_installing = true;
        self.setup_stage = Some("checking".to_owned());
        self.setup_progress = None;
        self.setup_error = None;
        self.bridge.install_setup();
        cx.notify();
    }

    pub(crate) fn install_rosetta(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        if self.offline() {
            self.show_notice("离线模式已开启，无法安装 Rosetta 2", cx);
            return;
        }
        self.setup_dialog = true;
        self.setup_installing = true;
        self.setup_stage = Some("rosetta".to_owned());
        self.setup_error = None;
        self.bridge.install_rosetta();
        cx.notify();
    }

    pub(crate) fn dismiss_setup(&mut self, cx: &mut Context<Self>) {
        if self.setup_installing {
            return;
        }
        self.setup_dialog = false;
        cx.notify();
    }

    /// Open the metadata/cover/GameDB sheet for one library card.
    pub(crate) fn open_game_info(&mut self, index: usize, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(game) = self.game(index) else {
            return;
        };
        let container = game.container.clone();
        let entry_id = game.id.clone();
        let title = game.title.clone();
        if container.is_empty() {
            return;
        }
        self.game_info = Some(GameInfoPage {
            container: container.clone(),
            entry_id: entry_id.clone(),
            title,
            input: None,
            searching: false,
            applying: false,
            error: None,
            groups: Vec::new(),
            matches: None,
            config_message: None,
        });
        self.bridge.match_game_config(&container, &entry_id);
        self.open_preview_sheet(PreviewSheet::GameInfo(index), cx);
    }

    pub(crate) fn game_info_input(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<InputState> {
        if let Some(input) = self.game_info.as_ref().and_then(|page| page.input.clone()) {
            return input;
        }
        let title = self
            .game_info
            .as_ref()
            .map(|page| page.title.clone())
            .unwrap_or_default();
        let entity = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("搜索游戏名称…")
                .default_value(title)
        });
        if let Some(page) = self.game_info.as_mut() {
            page.input = Some(entity.clone());
        }
        entity
    }

    pub(crate) fn search_game_info(&mut self, cx: &mut Context<Self>) {
        if self.game_info.is_none() {
            return;
        }
        if self.offline() {
            self.show_notice("离线模式已开启，无法搜索游戏信息", cx);
            return;
        }
        let Some(page) = self.game_info.as_mut() else {
            return;
        };
        let query = page
            .input
            .as_ref()
            .map(|input| input.read(cx).value().to_string())
            .unwrap_or_else(|| page.title.clone());
        let query = query.trim().to_owned();
        if query.is_empty() {
            self.show_notice("请输入要搜索的游戏名称", cx);
            return;
        }
        page.searching = true;
        page.error = None;
        page.groups.clear();
        let (container, entry_id) = (page.container.clone(), page.entry_id.clone());
        let sources = self.metadata_sources();
        if sources.is_empty() {
            if let Some(page) = self.game_info.as_mut() {
                page.searching = false;
            }
            self.show_notice("请至少启用一个刮削源", cx);
            return;
        }
        self.bridge
            .search_metadata(&container, &entry_id, &query, sources);
        cx.notify();
    }

    pub(crate) fn apply_game_info_metadata(
        &mut self,
        source: usize,
        game: usize,
        cx: &mut Context<Self>,
    ) {
        let Some(page) = self.game_info.as_mut() else {
            return;
        };
        let Some(candidate) = page
            .groups
            .get(source)
            .and_then(|group| group.games.get(game))
        else {
            return;
        };
        let raw = candidate.raw.clone();
        page.applying = true;
        page.error = None;
        let (container, entry_id) = (page.container.clone(), page.entry_id.clone());
        self.bridge.apply_metadata(&container, &entry_id, raw);
        cx.notify();
    }

    pub(crate) fn clear_game_info_metadata(&mut self, cx: &mut Context<Self>) {
        let Some(page) = self.game_info.as_mut() else {
            return;
        };
        page.applying = true;
        page.error = None;
        let (container, entry_id) = (page.container.clone(), page.entry_id.clone());
        self.bridge.clear_metadata(&container, &entry_id);
        cx.notify();
    }

    pub(crate) fn choose_game_info_cover(&mut self, cx: &mut Context<Self>) {
        let Some(page) = self.game_info.as_mut() else {
            return;
        };
        let (container, entry_id) = (page.container.clone(), page.entry_id.clone());
        page.applying = true;
        page.error = None;
        self.pending_path_action = Some(PathAction::MetadataCover {
            container: container.clone(),
            entry_id,
        });
        self.bridge.choose_path(
            "metadata-cover",
            "file",
            Some(&container),
            None,
            &["png", "jpg", "jpeg", "heic", "webp"],
        );
        cx.notify();
    }

    pub(crate) fn reset_game_info_cover(&mut self, cx: &mut Context<Self>) {
        let Some(page) = self.game_info.as_mut() else {
            return;
        };
        page.applying = true;
        page.error = None;
        let (container, entry_id) = (page.container.clone(), page.entry_id.clone());
        self.bridge.reset_metadata_cover(&container, &entry_id);
        cx.notify();
    }

    pub(crate) fn apply_game_db_match(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(page) = self.game_info.as_mut() else {
            return;
        };
        let Some(matched) = page.matches.as_ref().and_then(|matches| matches.get(index)) else {
            return;
        };
        let game_id = matched
            .entry
            .get("id")
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default()
            .to_owned();
        if game_id.is_empty() {
            self.show_notice("GameDB 条目无效", cx);
            return;
        }
        let variant_id = matched.variant_id.clone();
        page.applying = true;
        page.error = None;
        page.config_message = None;
        let (container, entry_id) = (page.container.clone(), page.entry_id.clone());
        self.bridge
            .apply_game_config(&container, &entry_id, &game_id, &variant_id);
        cx.notify();
    }

    pub(crate) fn maintain_bottle(
        &mut self,
        operation: BottleOperation,
        cx: &mut Context<Self>,
    ) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        self.bridge
            .bottle_operation(operation, &container, None, None, false);
        cx.notify();
    }

    /// The install job only belongs to the sheet while its bottle is selected.
    pub(crate) fn winetricks_job(&self) -> Option<&InstallJob> {
        let container = self.selected_container()?;
        self.winetricks
            .job
            .as_ref()
            .filter(|job| job.container == container)
    }

    /// The sheet's bottle: the selection, or the first available bottle.
    pub(crate) fn scan_container(&self) -> Option<String> {
        self.selected_container().or_else(|| {
            self.bottles
                .iter()
                .find(|bottle| bottle.available)
                .map(|bottle| bottle.path.clone())
        })
    }

    /// Read the schema and values once per bottle, or again after a failure.
    pub(crate) fn ensure_configuration(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        if let Some(page) = &self.config
            && page.container == container
            && (page.loading || page.error.is_none())
        {
            return;
        }
        if self
            .config
            .as_ref()
            .is_none_or(|page| page.container != container)
        {
            // Input entities are per bottle: the same field id can hold a very
            // different value in another bottle.
            self.preview.config_inputs.clear();
            self.preview.config_resets.clear();
            self.config_writes.clear();
            self.config_text_pending.clear();
            self.config_text_generation = self.config_text_generation.wrapping_add(1);
        }
        self.config = Some(ConfigPage {
            container: container.clone(),
            capabilities: Vec::new(),
            fields: Vec::new(),
            values: BTreeMap::new(),
            loading: true,
            error: None,
        });
        self.bridge.load_configuration(&container);
        if !self.environments.contains_key(&container) {
            self.bridge.load_environment(&container);
        }
        cx.notify();
    }

    /// Read the folder payload for the sheet's bottle.
    pub(crate) fn ensure_folders(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            return;
        }
        let Some(container) = self.scan_container() else {
            return;
        };
        if self.folders.contains_key(&container) || self.folders_pending.contains(&container) {
            return;
        }
        self.folders_pending.insert(container.clone());
        self.bridge.load_folders(&container);
        cx.notify();
    }

    /// Retry a failed `folders.read`.
    pub(crate) fn reload_folders(&mut self, cx: &mut Context<Self>) {
        let Some(container) = self.scan_container() else {
            return;
        };
        self.folders_error.remove(&container);
        self.folders_pending.insert(container.clone());
        self.bridge.load_folders(&container);
        cx.notify();
    }

    /// Load the static catalog once and the selected bottle's installed set.
    pub(crate) fn ensure_winetricks(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        if self.winetricks.catalog.is_none()
            && !self.winetricks.catalog_pending
            && self.winetricks.catalog_error.is_none()
        {
            self.winetricks.catalog_pending = true;
            self.bridge.load_winetricks_catalog();
        }
        if !self.winetricks.installed.contains_key(&container)
            && !self.winetricks.installed_pending.contains(&container)
            && !self.winetricks.installed_error.contains_key(&container)
        {
            self.winetricks.installed_pending.insert(container.clone());
            self.bridge.load_installed_winetricks(&container);
        }
        cx.notify();
    }

    /// Retry `winetricks.catalog` after a failure.
    pub(crate) fn reload_winetricks_catalog(&mut self, cx: &mut Context<Self>) {
        self.winetricks.catalog_error = None;
        self.winetricks.catalog_pending = true;
        self.bridge.load_winetricks_catalog();
        cx.notify();
    }

    /// Retry the visible bottle's `winetricks.installed`.
    pub(crate) fn reload_installed_winetricks(&mut self, cx: &mut Context<Self>) {
        let Some(container) = self.selected_container() else {
            return;
        };
        self.winetricks.installed_error.remove(&container);
        self.winetricks.installed_pending.insert(container.clone());
        self.bridge.load_installed_winetricks(&container);
        cx.notify();
    }

    /// Install the selected verb. The helper refuses concurrent jobs; an
    /// optimistic queued row also stops the button from sending twice.
    pub(crate) fn start_winetricks_install(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        if self.winetricks.job.as_ref().is_some_and(InstallJob::running) {
            return;
        }
        if self.offline() {
            self.show_notice("离线模式已开启，无法安装组件", cx);
            return;
        }
        let Some(container) = self.selected_container() else {
            self.show_notice("请先选择一个容器", cx);
            return;
        };
        let Some(verb) = self.winetricks.selected.clone() else {
            self.show_notice("请先选择一个组件", cx);
            return;
        };
        let mut job = InstallJob::new(&container);
        job.status = Some(JobStatus::Queued);
        self.winetricks.job = Some(job);
        self.bridge.install_winetricks(&container, &[verb]);
        cx.notify();
    }

    pub(crate) fn cancel_winetricks_install(&mut self, cx: &mut Context<Self>) {
        if self.winetricks.job.as_ref().is_some_and(InstallJob::running) {
            self.bridge.cancel_winetricks();
        }
        cx.notify();
    }

    /// Capture the entry the move picker will act on.
    pub(crate) fn prepare_move_entry(&mut self, index: usize, cx: &mut Context<Self>) {
        if self.demo {
            return;
        }
        let Some(game) = self.game(index).cloned() else {
            return;
        };
        if game.id.starts_with("steam:") || game.executable.is_none() {
            self.move_entry = None;
            self.preview.sheet = None;
            self.preview.sheet_history.clear();
            self.show_notice("Steam 条目不能移动到其他容器", cx);
            return;
        }
        self.move_entry = Some(MoveEntryState {
            title: game.title,
            source_container: game.container,
            entry_id: game.id,
            pending: false,
            target_container: None,
            error: None,
        });
        cx.notify();
    }

    pub(crate) fn start_move_entry(&mut self, target: String, cx: &mut Context<Self>) {
        let Some(state) = self.move_entry.as_mut() else {
            return;
        };
        if state.pending {
            return;
        }
        state.pending = true;
        state.error = None;
        state.target_container = Some(target.clone());
        let source = state.source_container.clone();
        let entry_id = state.entry_id.clone();
        self.bridge.move_entry(&source, &entry_id, &target);
        cx.notify();
    }

    /// A file handed over by Finder (`open`) or dragged onto the window.
    /// One bottle runs it directly; several open the bottle picker, as the
    /// SwiftUI Run panel does.
    pub(crate) fn open_external_file(&mut self, path: std::path::PathBuf, cx: &mut Context<Self>) {
        let runnable = ["exe", "msi", "bat", "msix", "appx", "url"];
        let extension = path
            .extension()
            .and_then(|extension| extension.to_str())
            .map(str::to_lowercase)
            .unwrap_or_default();
        let name = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.to_string_lossy().into_owned());
        if !runnable.contains(&extension.as_str()) || !path.is_file() {
            self.show_notice(format!("无法运行 {name}：请选择 Windows 程序或安装包"), cx);
            return;
        }
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        if self.bottles.is_empty() {
            self.show_notice("请先创建一个容器", cx);
            return;
        }
        if self.bottles.len() == 1 {
            self.run_file_in(0, &path.to_string_lossy(), &name, cx);
            return;
        }
        self.open_file = Some(OpenFileState {
            path: path.to_string_lossy().into_owned(),
            name,
        });
        self.open_preview_sheet(PreviewSheet::OpenFile, cx);
    }

    pub(crate) fn start_open_file(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(file) = self.open_file.take() else {
            return;
        };
        self.run_file_in(index, &file.path, &file.name, cx);
        self.preview.sheet = None;
        self.preview.sheet_history.clear();
        cx.notify();
    }

    fn run_file_in(&mut self, index: usize, path: &str, name: &str, cx: &mut Context<Self>) {
        let Some(bottle) = self.bottles.get(index) else {
            return;
        };
        if !bottle.available {
            self.show_notice("所选容器不可用", cx);
            return;
        }
        let container = bottle.path.clone();
        self.bridge.run_program(&container, path, name);
        self.show_notice(format!("正在启动 {name}"), cx);
    }

    fn program_target_matches(&self, container: &str, executable: &str) -> bool {
        self.program_settings.container.as_deref() == Some(container)
            && self.program_settings.executable.as_deref() == Some(executable)
    }

    /// Open the real run-settings draft for the game at `index`.
    pub(crate) fn open_program_settings(&mut self, index: usize, cx: &mut Context<Self>) {
        if self.demo {
            return;
        }
        self.preview.program_inputs.clear();
        let Some(game) = self.game(index).cloned() else {
            return;
        };
        let executable = game
            .executable
            .as_ref()
            .filter(|path| {
                path.extension()
                    .is_some_and(|extension| extension.eq_ignore_ascii_case("exe"))
            })
            .map(|path| path.to_string_lossy().into_owned());
        let Some(executable) = executable.filter(|_| !game.container.is_empty()) else {
            self.program_settings = ProgramSettingsPage::default();
            self.program_settings.title = game.title;
            self.program_settings.loading = false;
            self.program_settings.error =
                Some("该条目没有可用的 .exe，无法编辑程序设置。".to_owned());
            cx.notify();
            return;
        };
        self.program_settings
            .start(&game.container, &executable, &game.title);
        self.bridge
            .load_program_settings(&game.container, &executable);
        self.bridge.load_program_history(&game.container, &executable);
        cx.notify();
    }

    /// Retry both reads after the sheet failed to open.
    pub(crate) fn retry_program_settings(&mut self, cx: &mut Context<Self>) {
        let (Some(container), Some(executable)) = (
            self.program_settings.container.clone(),
            self.program_settings.executable.clone(),
        ) else {
            return;
        };
        self.program_settings.loading = true;
        self.program_settings.saving = false;
        self.program_settings.error = None;
        self.program_settings.history_loading = true;
        self.program_settings.history_error = None;
        self.preview.program_inputs.clear();
        self.bridge.load_program_settings(&container, &executable);
        self.bridge.load_program_history(&container, &executable);
        cx.notify();
    }

    /// Read the text inputs, build one patch and save on the current target.
    pub(crate) fn save_program_settings(&mut self, cx: &mut Context<Self>) {
        let (Some(container), Some(executable), Some(mut settings)) = (
            self.program_settings.container.clone(),
            self.program_settings.executable.clone(),
            self.program_settings.settings.clone(),
        ) else {
            return;
        };
        if settings.display_enabled()
            && settings
                .overrides
                .as_ref()
                .and_then(|overrides| overrides.resolution_preset.as_deref())
                == Some("custom")
        {
            let width = self
                .preview
                .program_inputs
                .get("ps-res-width")
                .map(|input| input.read(cx).value().to_string())
                .unwrap_or_else(|| {
                    settings
                        .defaults
                        .custom_resolution_width
                        .unwrap_or(1920)
                        .to_string()
                });
            let height = self
                .preview
                .program_inputs
                .get("ps-res-height")
                .map(|input| input.read(cx).value().to_string())
                .unwrap_or_else(|| {
                    settings
                        .defaults
                        .custom_resolution_height
                        .unwrap_or(1080)
                        .to_string()
                });
            let (Ok(width), Ok(height)) = (width.trim().parse::<i64>(), height.trim().parse::<i64>())
            else {
                self.show_notice("自定义分辨率必须是整数", cx);
                return;
            };
            if !(200..=16_384).contains(&width) || !(200..=16_384).contains(&height) {
                self.show_notice("自定义分辨率超出范围", cx);
                return;
            }
            if let Some(overrides) = settings.overrides.as_mut() {
                overrides.custom_resolution_width = Some(width);
                overrides.custom_resolution_height = Some(height);
            }
        }
        let arguments = self
            .preview
            .program_inputs
            .get("ps-args")
            .map(|input| input.read(cx).value().to_string())
            .unwrap_or_else(|| settings.arguments.clone());
        let mut environment = BTreeMap::new();
        for row in self.program_settings.env_rows.clone() {
            let key = self
                .preview
                .program_inputs
                .get(&format!("ps-env-key-{}", row.id))
                .map(|input| input.read(cx).value().to_string())
                .unwrap_or(row.key);
            let value = self
                .preview
                .program_inputs
                .get(&format!("ps-env-value-{}", row.id))
                .map(|input| input.read(cx).value().to_string())
                .unwrap_or(row.value);
            let key = key.trim().to_owned();
            if key.is_empty() {
                continue;
            }
            if key.contains('=') || key.contains('\0') {
                self.show_notice("环境变量名不能包含 = 或 NUL", cx);
                return;
            }
            if environment.insert(key.clone(), value).is_some() {
                self.show_notice(format!("环境变量 {key} 重复"), cx);
                return;
            }
        }
        let patch = settings_patch(&settings, &arguments, &environment);
        self.program_settings.saving = true;
        self.program_settings.close_after_save = true;
        self.program_settings.error = None;
        self.bridge
            .save_program_settings(&container, &executable, patch);
        cx.notify();
    }

    pub(crate) fn create_program_shortcut(&mut self, cx: &mut Context<Self>) {
        let (Some(container), Some(executable)) = (
            self.program_settings.container.clone(),
            self.program_settings.executable.clone(),
        ) else {
            return;
        };
        let destination = self
            .preview
            .program_inputs
            .get("ps-shortcut-dest")
            .map(|input| input.read(cx).value().to_string())
            .unwrap_or_else(|| self.program_settings.shortcut_destination.clone());
        let destination = crate::program_settings::expand_home(destination.trim());
        if !destination.starts_with('/') {
            self.program_settings.shortcut_error =
                Some("快捷方式目标必须是绝对路径。".to_owned());
            cx.notify();
            return;
        }
        self.program_settings.shortcut_destination = destination.clone();
        self.program_settings.shortcut_error = None;
        self.bridge
            .create_program_shortcut(&container, &executable, &destination);
        cx.notify();
    }

    pub(crate) fn delete_program_run(&mut self, run_id: String, cx: &mut Context<Self>) {
        let (Some(container), Some(executable)) = (
            self.program_settings.container.clone(),
            self.program_settings.executable.clone(),
        ) else {
            return;
        };
        self.program_settings.history_loading = true;
        self.bridge
            .delete_program_history(&container, &executable, Some(&run_id));
        cx.notify();
    }

    pub(crate) fn clear_program_history(&mut self, cx: &mut Context<Self>) {
        let (Some(container), Some(executable)) = (
            self.program_settings.container.clone(),
            self.program_settings.executable.clone(),
        ) else {
            return;
        };
        self.program_settings.history_loading = true;
        self.bridge
            .delete_program_history(&container, &executable, None);
        cx.notify();
    }

    pub(crate) fn reload_program_history(&mut self, cx: &mut Context<Self>) {
        let (Some(container), Some(executable)) = (
            self.program_settings.container.clone(),
            self.program_settings.executable.clone(),
        ) else {
            return;
        };
        self.program_settings.history_loading = true;
        self.program_settings.history_error = None;
        self.bridge.load_program_history(&container, &executable);
        cx.notify();
    }

    pub(crate) fn add_program_env_row(&mut self, cx: &mut Context<Self>) {
        let id = self.program_settings.next_env_id;
        self.program_settings.next_env_id += 1;
        self.program_settings.env_rows.push(crate::program_settings::EnvRow {
            id,
            key: String::new(),
            value: String::new(),
        });
        cx.notify();
    }

    pub(crate) fn remove_program_env_row(&mut self, id: u64, cx: &mut Context<Self>) {
        self.program_settings.env_rows.retain(|row| row.id != id);
        self.preview
            .program_inputs
            .remove(&format!("ps-env-key-{id}"));
        self.preview
            .program_inputs
            .remove(&format!("ps-env-value-{id}"));
        cx.notify();
    }

    pub(crate) fn set_program_choice(&mut self, field: &str, raw: &str) {
        if field == "locale" {
            // The locale row has its own environment side effects; it is
            // handled by `set_program_locale` from the click listener.
            return;
        }
        if field == "dllNewMode" {
            self.program_settings.dll_new_mode = raw.to_owned();
            return;
        }
        let Some(settings) = self.program_settings.settings.as_mut() else {
            return;
        };
        let overrides = settings.overrides_mut();
        match field {
            "graphicsBackend" => overrides.graphics_backend = Some(raw.to_owned()),
            "dxvkHud" => overrides.dxvk_hud = Some(raw.to_owned()),
            "enhancedSync" => overrides.enhanced_sync = Some(raw.to_owned()),
            "resolutionPreset" => overrides.resolution_preset = Some(raw.to_owned()),
            _ => {}
        }
    }

    pub(crate) fn set_program_override_bool(&mut self, field: &str, value: bool) {
        let Some(settings) = self.program_settings.settings.as_mut() else {
            return;
        };
        let overrides = settings.overrides_mut();
        match field {
            "dxvkAsync" => overrides.dxvk_async = Some(value),
            "metal4Enabled" => overrides.metal4_enabled = Some(value),
            "shaderCacheEnabled" => overrides.shader_cache_enabled = Some(value),
            "controllerCompatibilityMode" => overrides.controller_compatibility_mode = Some(value),
            "disableHIDAPI" => overrides.disable_hidapi = Some(value),
            "allowBackgroundEvents" => overrides.allow_background_events = Some(value),
            "disableControllerMapping" => overrides.disable_controller_mapping = Some(value),
            "useButtonLabels" => overrides.use_button_labels = Some(value),
            "virtualDesktopEnabled" => overrides.virtual_desktop_enabled = Some(value),
            _ => {}
        }
    }

    /// Turn a whole override group on with the bottle's current values, or
    /// clear every field in it. `groupName` matches the UI section.
    pub(crate) fn set_program_override_group(&mut self, group: &str, on: bool) {
        let Some(settings) = self.program_settings.settings.as_mut() else {
            return;
        };
        let defaults = settings.defaults.clone();
        let overrides = settings.overrides_mut();
        match group {
            "graphics" if on => {
                overrides.graphics_backend =
                    Some(defaults.graphics_backend.unwrap_or_else(|| "recommended".into()));
                overrides.dxvk = None;
                overrides.dxvk_async = defaults.dxvk_async;
                overrides.dxvk_hud = defaults.dxvk_hud;
                overrides.metal4_enabled = defaults.metal4_enabled;
            }
            "graphics" => {
                overrides.graphics_backend = None;
                overrides.dxvk = None;
                overrides.dxvk_async = None;
                overrides.dxvk_hud = None;
                overrides.metal4_enabled = None;
            }
            "sync" => {
                overrides.enhanced_sync = on.then_some(defaults.enhanced_sync).flatten();
            }
            "performance" => {
                overrides.shader_cache_enabled =
                    on.then_some(defaults.shader_cache_enabled).flatten();
            }
            "input" if on => {
                overrides.controller_compatibility_mode = defaults.controller_compatibility_mode;
                overrides.disable_hidapi = defaults.disable_hidapi;
                overrides.allow_background_events = defaults.allow_background_events;
                overrides.disable_controller_mapping = defaults.disable_controller_mapping;
                overrides.use_button_labels = defaults.use_button_labels;
            }
            "input" => {
                overrides.controller_compatibility_mode = None;
                overrides.disable_hidapi = None;
                overrides.allow_background_events = None;
                overrides.disable_controller_mapping = None;
                overrides.use_button_labels = None;
            }
            "display" if on => {
                overrides.virtual_desktop_enabled = defaults.virtual_desktop_enabled;
                overrides.resolution_preset = defaults.resolution_preset;
                overrides.custom_resolution_width = defaults.custom_resolution_width;
                overrides.custom_resolution_height = defaults.custom_resolution_height;
            }
            "display" => {
                overrides.virtual_desktop_enabled = None;
                overrides.resolution_preset = None;
                overrides.custom_resolution_width = None;
                overrides.custom_resolution_height = None;
            }
            "dll" => {
                overrides.dll_overrides = on.then(|| defaults.dll_overrides.unwrap_or_default());
            }
            _ => {}
        }
    }

    pub(crate) fn add_program_dll_override(&mut self, name: String, cx: &mut Context<Self>) {
        let name = name.trim().to_owned();
        if name.is_empty()
            || name.contains(char::is_whitespace)
            || name.contains('=')
            || name.contains(',')
        {
            self.show_notice("DLL 名称不能为空或包含空格、=、,", cx);
            return;
        }
        let Some(settings) = self.program_settings.settings.as_mut() else {
            return;
        };
        let overrides = settings.overrides_mut();
        overrides.dll_overrides.get_or_insert_with(Vec::new).push(
            crate::program_settings::DllOverrideDto {
                dll_name: name,
                mode: self.program_settings.dll_new_mode.clone(),
            },
        );
        self.preview.program_inputs.remove("ps-dll-name");
        cx.notify();
    }

    pub(crate) fn remove_program_dll_override(&mut self, index: usize) {
        let Some(settings) = self.program_settings.settings.as_mut() else {
            return;
        };
        let Some(overrides) = settings.overrides.as_mut() else {
            return;
        };
        let Some(entries) = overrides.dll_overrides.as_mut() else {
            return;
        };
        if index < entries.len() {
            entries.remove(index);
        }
    }

    /// Copy what the user typed in the environment inputs back into the draft
    /// rows, so rebuilding the inputs after a preset never drops edits.
    fn sync_env_rows_from_inputs(&mut self, cx: &mut Context<Self>) {
        for row in &mut self.program_settings.env_rows {
            if let Some(input) = self.preview.program_inputs.get(&format!("ps-env-key-{}", row.id)) {
                row.key = input.read(cx).value().to_string();
            }
            if let Some(input) = self.preview.program_inputs.get(&format!("ps-env-value-{}", row.id)) {
                row.value = input.read(cx).value().to_string();
            }
        }
    }

    /// Current value of one draft environment variable.
    pub(crate) fn program_env_value(&self, key: &str) -> Option<&str> {
        self.program_settings
            .env_rows
            .iter()
            .find(|row| row.key == key)
            .map(|row| row.value.as_str())
    }

    /// The WineD3D renderer named by `WINE_D3D_CONFIG`; `""` is the default.
    pub(crate) fn program_d3d_renderer(&self) -> Option<String> {
        let config = self.program_env_value("WINE_D3D_CONFIG").unwrap_or("");
        for entry in config.split(',') {
            if let Some((name, value)) = entry.split_once('=')
                && name.trim() == "renderer"
            {
                let value = value.trim();
                return match value {
                    "no3d" | "gdi" => Some("gdi".to_owned()),
                    "gl" | "vulkan" => Some(value.to_owned()),
                    _ => None,
                };
            }
        }
        Some(String::new())
    }

    /// Change only the renderer entry, keeping the user's other WineD3D options.
    pub(crate) fn set_program_renderer(&mut self, renderer: &str, cx: &mut Context<Self>) {
        self.sync_env_rows_from_inputs(cx);
        let existing = self.program_env_value("WINE_D3D_CONFIG").unwrap_or("").to_owned();
        let mut entries: Vec<String> = existing
            .split(',')
            .map(str::trim)
            .filter(|entry| {
                !entry.is_empty()
                    && entry.split_once('=').map(|(name, _)| name.trim()) != Some("renderer")
            })
            .map(str::to_owned)
            .collect();
        if !renderer.is_empty() {
            entries.push(format!("renderer={renderer}"));
        }
        self.program_settings.env_rows.retain(|row| row.key != "WINE_D3D_CONFIG");
        if !entries.is_empty() {
            let id = self.program_settings.next_env_id;
            self.program_settings.next_env_id += 1;
            self.program_settings.env_rows.push(crate::program_settings::EnvRow {
                id,
                key: "WINE_D3D_CONFIG".to_owned(),
                value: entries.join(","),
            });
        }
        self.preview
            .program_inputs
            .retain(|key, _| !key.starts_with("ps-env-"));
        cx.notify();
    }

    /// Locale presets also own LANG and LC_ALL, matching the SwiftUI editor.
    pub(crate) fn set_program_locale(&mut self, locale: String, cx: &mut Context<Self>) {
        self.sync_env_rows_from_inputs(cx);
        let Some(settings) = self.program_settings.settings.as_mut() else {
            return;
        };
        settings.locale = locale.clone();
        if locale.is_empty() {
            self.program_settings
                .env_rows
                .retain(|row| row.key != "LANG" && row.key != "LC_ALL");
        } else {
            for key in ["LANG", "LC_ALL"] {
                if let Some(row) = self
                    .program_settings
                    .env_rows
                    .iter_mut()
                    .find(|row| row.key == key)
                {
                    row.value = locale.clone();
                } else {
                    let id = self.program_settings.next_env_id;
                    self.program_settings.next_env_id += 1;
                    self.program_settings.env_rows.push(crate::program_settings::EnvRow {
                        id,
                        key: key.to_owned(),
                        value: locale.clone(),
                    });
                }
            }
        }
        self.preview
            .program_inputs
            .retain(|key, _| !key.starts_with("ps-env-"));
        cx.notify();
    }

    pub(crate) fn reload_config(&mut self, cx: &mut Context<Self>) {
        self.ensure_configuration(cx);
    }

    /// Toggle and choice rows commit immediately. The value is shown first and
    /// rolled back if the helper rejects it.
    pub(crate) fn set_config_value(
        &mut self,
        field: &str,
        next: serde_json::Value,
        cx: &mut Context<Self>,
    ) {
        let Some(page) = self.config.as_ref() else {
            return;
        };
        let Some(config_field) = page.fields.iter().find(|candidate| candidate.id == field) else {
            return;
        };
        if !config_field.enabled(&page.capabilities) {
            return;
        }
        let current = page
            .values
            .get(field)
            .cloned()
            .unwrap_or_else(|| config_field.default.clone());
        if current == next {
            return;
        }
        let container = page.container.clone();
        self.config_writes.begin(field, current);
        if let Some(page) = self.config.as_mut() {
            page.values.insert(field.to_owned(), next.clone());
        }
        self.bridge.set_configuration(&container, field, next);
        cx.notify();
    }

    /// Called from the `InputState` observer on every notify; identical text is
    /// ignored, and the newest draft is sent after [`CONFIG_DEBOUNCE`].
    pub(crate) fn config_text_changed(&mut self, field: &str, text: &str, cx: &mut Context<Self>) {
        let Some(page) = self.config.as_ref().filter(|page| !page.loading) else {
            return;
        };
        let Some(config_field) = page.fields.iter().find(|candidate| candidate.id == field) else {
            return;
        };
        if !config_field.kind.is_textual() || !config_field.enabled(&page.capabilities) {
            return;
        }
        let committed = page
            .values
            .get(field)
            .and_then(|value| config::display_value(config_field, value));
        if committed.as_deref() == Some(text)
            || self.config_text_pending.get(field).map(String::as_str) == Some(text)
        {
            return;
        }
        self.config_text_pending
            .insert(field.to_owned(), text.to_owned());
        self.config_text_generation = self.config_text_generation.wrapping_add(1);
        let generation = self.config_text_generation;
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(CONFIG_DEBOUNCE).await;
            let _ = this.update(cx, |this, cx| {
                if this.config_text_generation != generation {
                    return;
                }
                let pending = std::mem::take(&mut this.config_text_pending);
                for (field, raw) in pending {
                    this.commit_config_text(&field, &raw, cx);
                }
            });
        })
        .detach();
    }

    fn commit_config_text(&mut self, field: &str, raw: &str, cx: &mut Context<Self>) {
        let Some(page) = self.config.as_ref().filter(|page| !page.loading) else {
            return;
        };
        let Some(config_field) = page
            .fields
            .iter()
            .find(|candidate| candidate.id == field)
            .cloned()
        else {
            return;
        };
        let current = page
            .values
            .get(field)
            .cloned()
            .unwrap_or_else(|| config_field.default.clone());
        let container = page.container.clone();
        let value = match config::encode_edit(&config_field, raw) {
            Ok(value) => value,
            Err(reason) => {
                // The value never reached the helper: restore the last good one
                // and say why on the toast.
                self.preview.config_resets.insert(field.to_owned());
                self.show_notice(reason, cx);
                return;
            }
        };
        if value == current {
            return;
        }
        self.config_writes.begin(field, current);
        if let Some(page) = self.config.as_mut() {
            page.values.insert(field.to_owned(), value.clone());
        }
        // Trimmed numbers and a typed " 1920 " must not read back as a new
        // draft; normalize the field once the value is committed.
        if value.is_number() {
            self.preview.config_resets.insert(field.to_owned());
        }
        self.bridge.set_configuration(&container, field, value);
        cx.notify();
    }

    /// Stage an "编辑" row into the two environment inputs. `set_value` needs a
    /// window, which the click listener has.
    pub(crate) fn begin_environment_edit(&mut self, key: &str, value: &str, cx: &mut Context<Self>) {
        // Applied by replacing the two inputs on the next render.
        self.env_fill = Some((key.to_owned(), value.to_owned()));
        self.env_original = Some(key.to_owned());
        cx.notify();
    }

    pub(crate) fn save_environment(&mut self, key: &str, value: &str, cx: &mut Context<Self>) {
        let Some(container) = self.selected_container().or_else(|| self.scan_container()) else {
            return;
        };
        let key = match config::validate_environment_name(key) {
            Ok(key) => key.to_owned(),
            Err(reason) => {
                self.show_notice(reason, cx);
                return;
            }
        };
        let original = self.env_original.take();
        self.env_clear_on_reply = true;
        self.bridge
            .set_environment(&container, &key, Some(value), original.as_deref());
        cx.notify();
    }

    pub(crate) fn remove_environment(&mut self, key: &str, cx: &mut Context<Self>) {
        let Some(container) = self.selected_container().or_else(|| self.scan_container()) else {
            return;
        };
        if self.env_original.as_deref() == Some(key) {
            self.env_original = None;
        }
        self.env_clear_on_reply = false;
        self.bridge.set_environment(&container, key, None, None);
        cx.notify();
    }

    /// Native multi-select folder picker, starting inside the bottle's C drive.
    pub(crate) fn choose_scan_roots(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(container) = self.scan_container() else {
            return;
        };
        self.scan_root_picker = Some(container.clone());
        let start = format!("{container}/drive_c");
        self.bridge.choose_folders("scan-roots", &start);
        cx.notify();
    }

    /// Typed-path fallback for adding one scan root.
    pub(crate) fn add_scan_root(&mut self, path: &str, cx: &mut Context<Self>) {
        let path = path.trim();
        if path.is_empty() {
            self.show_notice("请输入文件夹路径", cx);
            return;
        }
        if !path.starts_with('/') {
            self.show_notice("请输入绝对路径", cx);
            return;
        }
        self.edit_folder(FolderEdit::AddRoot(path.to_owned()), cx);
    }

    /// Move one scan root (and its games) into another bottle.
    pub(crate) fn move_scan_root(
        &mut self,
        root: &str,
        target_index: usize,
        cx: &mut Context<Self>,
    ) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(source) = self.scan_container() else {
            return;
        };
        let Some(target) = self
            .bottles
            .get(target_index)
            .filter(|bottle| bottle.available && bottle.path != source)
            .map(|bottle| bottle.path.clone())
        else {
            return;
        };
        self.bridge.move_scan_root(&source, root, &target);
        cx.notify();
    }

    pub(crate) fn edit_folder(&mut self, edit: FolderEdit, cx: &mut Context<Self>) {
        let Some(container) = self.scan_container() else {
            return;
        };
        self.folders_reload_after_write.insert(container.clone());
        self.bridge.edit_folders(&container, edit);
        cx.notify();
    }

    pub(crate) fn start_scan(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(container) = self.scan_container() else {
            return;
        };
        if let Some(active) = self.scan.as_ref().filter(|scan| scan.running()) {
            if active.container != container {
                self.show_notice("另一个容器的扫描正在进行", cx);
            }
            return;
        }
        self.scan = Some(ScanState {
            container: container.clone(),
            status: Some(JobStatus::Queued),
            ..ScanState::default()
        });
        self.bridge.start_scan(&container);
        cx.notify();
    }

    pub(crate) fn cancel_scan(&mut self, cx: &mut Context<Self>) {
        if self.scan.as_ref().is_some_and(ScanState::running) {
            self.bridge.cancel_scan();
            cx.notify();
        }
    }

    /// The scan this sheet shows, if it belongs to `container`.
    pub(crate) fn scan_for(&self, container: &str) -> Option<&ScanState> {
        self.scan
            .as_ref()
            .filter(|scan| scan.container == container)
    }

    // MARK: - Programs and processes

    /// Read the program list once per bottle, or again after a failure.
    pub(crate) fn ensure_programs(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        if let Some(page) = &self.programs
            && page.container == container
            && (page.loading || page.error.is_none())
        {
            return;
        }
        self.programs = Some(ProgramsPage {
            container: container.clone(),
            table: ProgramTable::default(),
            loading: true,
            error: None,
        });
        self.bridge.load_programs(&container);
        cx.notify();
    }

    /// Retry a failed `programs.list`.
    pub(crate) fn reload_programs(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        self.programs = Some(ProgramsPage {
            container: container.clone(),
            table: ProgramTable::default(),
            loading: true,
            error: None,
        });
        self.bridge.load_programs(&container);
        cx.notify();
    }

    /// Read the process list once, then let the poll loop keep it fresh.
    pub(crate) fn ensure_processes(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        if let Some(page) = &self.processes
            && page.container == container
            && (page.loading || page.error.is_none())
        {
            return;
        }
        self.processes = Some(ProcessesPage {
            container: container.clone(),
            table: ProcessTable::default(),
            loading: true,
            error: None,
        });
        self.bridge.load_processes(&container);
        cx.notify();
    }

    /// The "刷新" row: re-read now; the poll loop continues afterwards.
    pub(crate) fn refresh_processes(&mut self, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        if let Some(page) = self
            .processes
            .as_mut()
            .filter(|page| page.container == container)
        {
            page.error = None;
        } else {
            self.processes = Some(ProcessesPage {
                container: container.clone(),
                table: ProcessTable::default(),
                loading: true,
                error: None,
            });
        }
        self.bridge.load_processes(&container);
        cx.notify();
    }

    /// Poll `processes.list` while the Processes page is open. The cadence
    /// follows [`processes::poll_interval`]; the loop exits on the next tick
    /// after [`Self::stop_process_polling`] bumps the generation.
    fn start_process_polling(&mut self, cx: &mut Context<Self>) {
        self.process_generation = self.process_generation.wrapping_add(1);
        let generation = self.process_generation;
        cx.spawn(async move |this, cx| {
            loop {
                let cadence = {
                    let mut scheduled = None;
                    let _ = this.update(cx, |this, _cx| {
                        if this.process_generation != generation {
                            return;
                        }
                        if let Some(container) = this.selected_container() {
                            this.bridge.load_processes(&container);
                        }
                        let any_alive = this
                            .processes
                            .as_ref()
                            .is_some_and(|page| page.table.any_alive());
                        scheduled = Some(processes::poll_interval(any_alive));
                    });
                    match scheduled {
                        Some(cadence) => cadence,
                        None => break,
                    }
                };
                cx.background_executor().timer(cadence).await;
            }
        })
        .detach();
    }

    /// Stop the poll loop at the end of the current interval (or now, on the
    /// loop's next generation check).
    fn stop_process_polling(&mut self) {
        self.process_generation = self.process_generation.wrapping_add(1);
    }

    /// Flip a program's pin state. The row changes at once and the reply's
    /// refreshed list settles it; a rejection rolls the flag back.
    pub(crate) fn toggle_program_pin(&mut self, path: &str, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        let Some(page) = self
            .programs
            .as_mut()
            .filter(|page| page.container == container)
        else {
            return;
        };
        let Some(row) = page.table.row(path) else {
            return;
        };
        let pinned = row.pinned;
        let name = row.name.clone();
        if !page.table.set_pinned(path, !pinned) {
            return;
        }
        self.bridge
            .set_program_pinned(&container, path, &name, !pinned);
        cx.notify();
    }

    /// Flip a program's block state; same optimistic contract as the pin.
    pub(crate) fn toggle_program_block(&mut self, path: &str, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        let Some(page) = self
            .programs
            .as_mut()
            .filter(|page| page.container == container)
        else {
            return;
        };
        let Some(row) = page.table.row(path) else {
            return;
        };
        let blocked = row.blocked;
        if !page.table.set_blocked(path, !blocked) {
            return;
        }
        self.bridge.set_program_blocked(&container, path, !blocked);
        cx.notify();
    }

    /// The library entry a program launches through, when one exists.
    ///
    /// Pinned programs gain an entry named `pinned:<path>`
    /// (`ContainerProgram.entry`); folder and store entries match by their
    /// launch executable. A program with no entry cannot be started through
    /// `runtime.launch`, which resolves an `entryID`, so those rows simply
    /// offer no Play.
    pub(crate) fn program_entry_id(
        &self,
        container: &str,
        program: &ProgramDto,
    ) -> Option<String> {
        let pinned_id = program.entry_id();
        let executable = std::path::Path::new(&program.path);
        self.bottle_entries.get(container)?.iter().find_map(|game| {
            (game.id == pinned_id || game.executable.as_deref() == Some(executable))
                .then(|| game.id.clone())
        })
    }

    /// Play a program through its library entry. The executable parameter
    /// names exactly what to run, matching `RuntimeService.launch`'s
    /// `executable` override.
    pub(crate) fn play_program(&mut self, path: &str, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        let entry_id = self
            .programs
            .as_ref()
            .filter(|page| page.container == container)
            .and_then(|page| page.table.row(path))
            .and_then(|program| self.program_entry_id(&container, program));
        let Some(entry_id) = entry_id else {
            self.show_notice("该程序没有可启动的游戏库条目", cx);
            return;
        };
        // Configure the bottle lazily, exactly like a card's Play.
        if self.configured.ensure(&container) {
            self.bridge.configure_runtime(&container);
        }
        self.runtime.set_state(&entry_id, RuntimeState::Preparing);
        self.bridge.launch(&container, &entry_id, Some(path));
        cx.notify();
    }

    /// A folder entry names its folder, so the helper cannot run it until the
    /// user has chosen an executable for that folder.
    fn needs_executable(&self, index: usize) -> bool {
        self.game(index).is_some_and(|game| game.needs_executable)
    }

    /// Open the in-app picker over a folder entry's `.exe` files.
    ///
    /// The helper resolves an already-recorded executable on its own, so Play
    /// only reaches this for a folder that has none. `launch_after` starts the
    /// game once a choice is made, which is what Play does; the card menu
    /// records the choice only.
    fn open_executable_picker(&mut self, index: usize, launch_after: bool, cx: &mut Context<Self>) {
        let details = self.game(index).map(|game| {
            (
                game.container.clone(),
                game.id.clone(),
                game.title.clone(),
                game.folder(),
            )
        });
        let Some((container, entry_id, title, Some(folder))) = details else {
            self.show_notice("该条目没有可指定的程序", cx);
            return;
        };
        if container.is_empty() {
            return;
        }
        let folder = folder.to_string_lossy().to_string();
        self.executable_picker = Some(ExecutablePickerState {
            container: container.clone(),
            entry_id,
            title,
            folder: folder.clone(),
            launch_after,
            candidates: Vec::new(),
        });
        self.bridge.load_candidates(&container, &folder);
        self.open_preview_sheet(PreviewSheet::Executable, cx);
    }

    /// Record the picked executable through `folders.executable`, then honour
    /// what opened the picker.
    pub(crate) fn choose_executable(&mut self, path: &str, cx: &mut Context<Self>) {
        let Some(picker) = self.executable_picker.take() else {
            return;
        };
        self.bridge.edit_folders(
            &picker.container,
            FolderEdit::Executable {
                path: picker.folder.clone(),
                executable: Some(path.to_owned()),
            },
        );
        let folder_path = std::path::PathBuf::from(&picker.folder);
        let exe_path = std::path::PathBuf::from(path);
        self.update_entry(&picker.container, &picker.entry_id, |game| {
            game.needs_executable = false;
            game.executable = Some(exe_path.clone());
            game.folder_path = Some(folder_path.clone());
        });
        if picker.launch_after {
            if self.configured.ensure(&picker.container) {
                self.bridge.configure_runtime(&picker.container);
            }
            self.runtime
                .set_state(&picker.entry_id, RuntimeState::Preparing);
            self.bridge
                .launch(&picker.container, &picker.entry_id, Some(path));
        }
        self.preview.sheet = None;
        self.preview.sheet_history.clear();
        cx.notify();
    }

    /// Kill one process. The row leaves the list at once; the reply either
    /// settles the removal or rolls it back with the reason on the toast.
    pub(crate) fn kill_process(&mut self, pid: i64, cx: &mut Context<Self>) {
        if self.demo {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let Some(container) = self.selected_container() else {
            return;
        };
        let Some(page) = self
            .processes
            .as_mut()
            .filter(|page| page.container == container)
        else {
            return;
        };
        if !page.table.begin_kill(pid) {
            return;
        }
        self.bridge.kill_process(&container, pid);
        cx.notify();
    }

    /// Container path that owns this card's entry.
    fn bottle_path(&self, index: usize) -> Option<String> {
        self.game(index)
            .map(|game| game.container.clone())
            .filter(|path| !path.is_empty())
    }
    /// Per-entry runtime state. Cards for entries the helper has never
    /// configured (the Library page before any bottle is opened, or the demo)
    /// have no state yet.
    pub(crate) fn runtime_state(&self, index: usize) -> Option<RuntimeState> {
        self.game(index)
            .and_then(|game| self.runtime.entry(&game.id))
            .map(|entry| entry.state)
    }

    /// The card's primary action. Before a bottle is configured there is no
    /// runtime state, but the entry is launchable: the click configures the
    /// bottle first and the next snapshot replaces this optimistic action.
    pub(crate) fn primary_action(&self, index: usize) -> PrimaryAction {
        if let Some(entry) = self
            .game(index)
            .and_then(|game| self.runtime.entry(&game.id))
        {
            return primary_action_for(entry.state, entry.capabilities);
        }
        if !self.demo && self.bottle_path(index).is_some() {
            return PrimaryAction {
                label: "Play",
                action: Some(RuntimeAction::Launch),
                enabled: true,
                busy: false,
            };
        }
        PrimaryAction::unavailable()
    }

    /// Send the mutation and move the card into a plausible transitional state.
    /// The next snapshot is authoritative and corrects it.
    pub(crate) fn perform_runtime_action(
        &mut self,
        index: usize,
        action: Option<RuntimeAction>,
        cx: &mut Context<Self>,
    ) {
        let Some(action) = action else { return };
        let (Some(container), Some(entry_id)) = (
            self.bottle_path(index),
            self.game(index).map(|game| game.id.clone()),
        ) else {
            return;
        };
        match action {
            RuntimeAction::Launch => {
                // Configure the bottle lazily, once per helper session. The
                // worker handles commands in order, so the launch lands after
                // the configure that made the entry actionable.
                if self.configured.ensure(&container) {
                    self.bridge.configure_runtime(&container);
                }
                if self.needs_executable(index) {
                    self.open_executable_picker(index, true, cx);
                    return;
                }
                self.runtime.set_state(&entry_id, RuntimeState::Preparing);
                self.bridge.launch(&container, &entry_id, None);
            }
            RuntimeAction::Cancel => {
                // Cancel is only accepted while preparing/launching; showing the
                // pre-launch phase keeps the button unavailable until the next
                // event lands.
                self.runtime.set_state(&entry_id, RuntimeState::CheckingLaunch);
                self.bridge.cancel(&container, &entry_id);
            }
            RuntimeAction::Stop => {
                self.runtime.set_state(&entry_id, RuntimeState::Idle);
                self.bridge.stop(&container, &entry_id);
            }
        }
        cx.notify();
    }

    /// Set one rating (1–10). Choosing the current value clears it, which
    /// is how the detail panel expresses "unrated".
    pub(crate) fn set_rating(&mut self, index: usize, star: u8, cx: &mut Context<Self>) {
        let Some(game) = self.game(index) else { return };
        let previous = game.rating;
        let next = library_view::next_rating(previous, star);
        let (container, entry_id) = (game.container.clone(), game.id.clone());
        if self.demo || container.is_empty() {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        self.rating_edits.begin(&entry_key(&container, &entry_id), previous);
        self.update_entry(&container, &entry_id, |game| game.rating = next);
        self.rebuild_entries();
        self.bridge
            .set_rating(&container, &entry_id, next.map(i64::from));
        cx.notify();
    }

    /// Flip the visibility of one entry. The grid reacts immediately; the
    /// bridge reply (or an error rollback) settles it.
    pub(crate) fn toggle_hidden(&mut self, index: usize, cx: &mut Context<Self>) {
        let Some(game) = self.game(index) else { return };
        let (container, entry_id, previous) =
            (game.container.clone(), game.id.clone(), game.hidden);
        if self.demo || container.is_empty() {
            self.show_notice(DEMO_NOTICE, cx);
            return;
        }
        let next = !previous;
        self.hidden_edits
            .begin(&entry_key(&container, &entry_id), previous);
        self.update_entry(&container, &entry_id, |game| game.hidden = next);
        self.rebuild_entries();
        self.bridge.set_hidden(&container, &entry_id, next);
        cx.notify();
    }

    /// Second launch call for a clipboard prompt. The token travels unchanged;
    /// dismissing the sheet calls `dismiss_clipboard` instead and never launches.
    pub(crate) fn resolve_clipboard(
        &mut self,
        decision: ClipboardDecision,
        cx: &mut Context<Self>,
    ) {
        let Some(prompt) = self.clipboard_prompt.take() else {
            return;
        };
        self.runtime
            .set_state(&prompt.entry_id, RuntimeState::Preparing);
        self.bridge.resolve_clipboard(prompt, decision);
        cx.notify();
    }

    pub(crate) fn dismiss_clipboard(&mut self, cx: &mut Context<Self>) {
        self.clipboard_prompt = None;
        cx.notify();
    }
    pub(crate) fn navigate(&mut self, page: PreviewPage, cx: &mut Context<Self>) {
        if page != self.preview.page {
            self.preview.history.push(self.preview.page);
        }
        self.preview.page = page;
        self.settings = false;
        self.detail_open = false;
        self.preview.sheet = None;
        self.hovered = None;
        self.apply_page_loads(cx);
        cx.notify();
    }

    /// The page-back button: pop history without pushing onto it.
    pub(crate) fn navigate_back(&mut self, cx: &mut Context<Self>) {
        self.preview.page = self.preview.history.pop().unwrap_or(PreviewPage::Bottle);
        self.apply_page_loads(cx);
        cx.notify();
    }

    /// Load what the new page shows and keep the process poll in step with
    /// the Processes page's visibility.
    fn apply_page_loads(&mut self, cx: &mut Context<Self>) {
        self.stop_process_polling();
        match self.preview.page {
            PreviewPage::ConfigureBottle => self.ensure_configuration(cx),
            PreviewPage::Programs => self.ensure_programs(cx),
            PreviewPage::Processes => {
                self.ensure_processes(cx);
                self.start_process_polling(cx);
            }
            _ => {}
        }
    }
    pub(crate) fn open_preview_sheet(&mut self, sheet: PreviewSheet, cx: &mut Context<Self>) {
        if let Some(previous) = self.preview.sheet {
            self.preview.sheet_history.push(previous);
        } else {
            self.preview.sheet_history.clear();
        }
        self.preview.sheet = Some(sheet);
        self.detail_open = false;
        self.hovered = None;
        if sheet == PreviewSheet::Scan {
            self.ensure_folders(cx);
        }
        if let PreviewSheet::RunSettings(index) = sheet {
            self.open_program_settings(index, cx);
        }
        if let PreviewSheet::MoveEntry(index) = sheet {
            self.prepare_move_entry(index, cx);
        }
        if sheet == PreviewSheet::Winetricks {
            // A finished job is a result surface, not a permanent lock: opening
            // the sheet again starts from the catalog.
            if self.winetricks.job.as_ref().is_some_and(|job| job.finished) {
                self.winetricks.job = None;
            }
            self.ensure_winetricks(cx);
        }
        cx.notify();
    }
    pub(crate) fn preview_title(&self) -> SharedString {
        if self.settings {
            return "设置".into();
        }
        match self.preview.page {
            PreviewPage::Library => "Library".into(),
            PreviewPage::Bottle => self.bottle_name().to_owned().into(),
            PreviewPage::ConfigureBottle => "Configure Bottle".into(),
            PreviewPage::Programs => "已安装的程序".into(),
            PreviewPage::Processes => "运行中的进程".into(),
            PreviewPage::GameConfigs => "游戏配置".into(),
        }
    }
    /// Enabled scraper sources, in provider order. Defaults to all of them.
    pub(crate) fn metadata_sources(&self) -> Vec<String> {
        METADATA_SOURCES
            .iter()
            .filter(|(key, _, _)| self.flag(key))
            .map(|(_, source, _)| (*source).to_owned())
            .collect()
    }
    pub(crate) fn flag(&self, key: &'static str) -> bool {
        self.preview.toggles.get(key).copied().unwrap_or(false)
    }
    pub(crate) fn preview_single_line(&self) -> bool {
        self.flag("single-title")
    }
    pub(crate) fn preview_dismiss(&mut self, cx: &mut Context<Self>) {
        self.preview.sheet = None;
        self.preview.sheet_history.clear();
        // A dismissed picker chose nothing, so nothing is recorded or launched.
        self.executable_picker = None;
        self.open_file = None;
        self.game_info = None;
        cx.notify();
    }
    /// Whether the `Hidden` filter currently includes hidden entries.
    pub(crate) fn show_hidden(&self) -> bool {
        self.show_hidden
    }
    /// Count of hidden entries in the current scope, for the filter chip.
    pub(crate) fn hidden_count(&self) -> usize {
        let slot = self.bottle_slot();
        self.games()
            .iter()
            .filter(|game| (slot == 0 || game.bottle == slot) && game.hidden)
            .count()
    }
}

/// Internal identity: the same bridge id in two bottles is two records.
fn entry_key(container: &str, entry_id: &str) -> String {
    format!("{container}\u{1}{entry_id}")
}

/// Finder's duplicate naming: "Name Copy", then "Name Copy 2", …
fn next_duplicate_name(base: &str, bottles: &[BottleVm]) -> String {
    let candidate = format!("{base} Copy");
    if !bottles.iter().any(|bottle| bottle.name == candidate) {
        return candidate;
    }
    let mut counter = 2;
    loop {
        let candidate = format!("{base} Copy {counter}");
        if !bottles.iter().any(|bottle| bottle.name == candidate) {
            return candidate;
        }
        counter += 1;
    }
}
