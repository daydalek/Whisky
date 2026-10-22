//! Application state: the root view model, page/sheet enums, and navigation.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use gpui_kit::base::Transition;
use gpui_kit::component::input::InputState;
use gpui_kit::{prelude::*, *};
use serde_json::json;

use crate::bridge::dto::{CandidateDto, FoldersDto, ProgramDto};
use crate::bridge::{
    BottleCreateUpdate, BridgeEvent, BridgeStatus, BridgeSupervisor, EntryMutation, FolderEdit,
    ProgramMutation, ScanUpdate,
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
    Diagnostics,
    Audio,
    Dll,
    Graphics,
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
                ("shader", true),
                ("appnap", true),
                ("kill", true),
                ("blur", true),
                ("updates", true),
            ]
            .into(),
            choices: [("create-windows", "Windows 11".into())].into(),
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
            default_bottle_location: Self::default_bottle_location(),
            env_original: None,
            env_clear_on_reply: false,
            env_fill: None,
            rating_edits: PendingEdits::default(),
            hidden_edits: PendingEdits::default(),
            sidebar: true,
            settings: false,
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
        self.folders.clear();
        self.folders_pending.clear();
        self.folders_error.clear();
        self.executable_picker = None;
        self.environments.clear();
        self.environment_error.clear();
        self.env_original = None;
        self.env_clear_on_reply = false;
        self.env_fill = None;
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
                self.bridge_status = status;
                if connected && !self.demo {
                    // One read per connected session; the reply carries both
                    // the stored values and the writable-key schema.
                    self.bridge.load_preferences();
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
                }
            }
            BridgeEvent::ActionFailed { reason } => {
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
                        self.runtime.apply(update);
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
                    self.bottle_entries.insert(container, games);
                    self.rebuild_entries();
                    self.pending.remove(&index);
                    self.failures.remove(&index);
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
                    self.folders.insert(container, folders);
                }
            }
            BridgeEvent::FoldersFailed { container, reason } => {
                if !self.demo {
                    self.folders_pending.remove(&container);
                    self.folders_error
                        .insert(container, reason.clone());
                    self.show_notice(reason, cx);
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
                            name: _,
                            containers,
                        } => {
                            let state = self.create_bottle.get_or_insert_with(CreateBottleState::default);
                            state.status = Some(JobStatus::Completed);
                            state.stage = None;
                            state.finished = true;
                            state.error = None;
                            state.created_path = Some(path.clone());

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
        self.selected_bottle =
            previous.and_then(|path| self.bottles.iter().position(|bottle| bottle.path == path));
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
        match key {
            "mixed" => {
                self.mixed = !self.mixed;
                self.persist(preferences::MIXED_COVER_LAYOUT, json!(self.mixed), cx);
            }
            "motion" => self.motion = !self.motion,
            "lively" => self.lively = !self.lively,
            "show-hidden" => {
                self.show_hidden = !self.show_hidden;
                self.persist(preferences::SHOW_HIDDEN, json!(self.show_hidden), cx);
                self.invalidate_view();
            }
            _ => {
                let value = {
                    let slot = self.preview.toggles.entry(key).or_default();
                    *slot = !*slot;
                    *slot
                };
                match key {
                    "single-title" => {
                        self.persist(preferences::SINGLE_LINE_TITLES, json!(value), cx)
                    }
                    "refresh" => {
                        self.persist(preferences::REFRESH_AFTER_EXIT, json!(value), cx)
                    }
                    _ => {}
                }
            }
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
        if let Some(flag) = values
            .get(preferences::SINGLE_LINE_TITLES)
            .and_then(serde_json::Value::as_bool)
        {
            self.preview.toggles.insert("single-title", flag);
        }
        if let Some(flag) = values
            .get(preferences::REFRESH_AFTER_EXIT)
            .and_then(serde_json::Value::as_bool)
        {
            self.preview.toggles.insert("refresh", flag);
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

    /// Locale presets also own LANG and LC_ALL, matching the SwiftUI editor.
    pub(crate) fn set_program_locale(&mut self, locale: String, cx: &mut Context<Self>) {
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

    /// Add a typed root. The native picker is M4; this milestone uses the
    /// existing text field.
    pub(crate) fn add_scan_root(&mut self, path: &str, cx: &mut Context<Self>) {
        let path = path.trim();
        if path.is_empty() {
            self.show_notice("请输入文件夹路径", cx);
            return;
        }
        self.edit_folder(FolderEdit::AddRoot(path.to_owned()), cx);
    }

    pub(crate) fn edit_folder(&mut self, edit: FolderEdit, cx: &mut Context<Self>) {
        let Some(container) = self.scan_container() else {
            return;
        };
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

    /// Set one star rating (1–5). Choosing the current value clears it, which
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
