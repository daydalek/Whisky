//! Application state: the root view model, page/sheet enums, and navigation.

use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use gpui_kit::base::Transition;
use gpui_kit::component::input::InputState;
use gpui_kit::{prelude::*, *};

use crate::bridge::{BridgeEvent, BridgeStatus, BridgeSupervisor};
#[cfg(feature = "visual-test")]
use crate::library_layout::CardRect;
use crate::model::{
    BottleVm, Game, demo_bottles, demo_data, demo_requested, empty_library_message,
};
use crate::runtime::{
    ClipboardDecision, ClipboardPrompt, PrimaryAction, RuntimeAction, RuntimeState, RuntimeTable,
    primary_action_for,
};
use crate::views::Command;

/// Toast copy for the demo-only menu actions, which still do not mutate
/// anything. Runtime failures reuse the same toast with the helper's reason.
pub(crate) const DEMO_NOTICE: &str = "外观演示 · 未启动游戏，也未修改容器";

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
    pub(crate) hidden: BTreeSet<usize>,
    pub(crate) moved: BTreeMap<usize, usize>,
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
            ("bottle-name", "新建容器"),
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
            toggles: [
                ("refresh", true),
                ("shader", true),
                ("appnap", true),
                ("kill", true),
                ("blur", true),
                ("updates", true),
            ]
            .into(),
            choices: BTreeMap::new(),
            collapsed: [
                "launcher",
                "input",
                "dll",
                "cleanup",
                "overrides",
                "console",
            ]
            .into(),
            hidden: BTreeSet::new(),
            moved: BTreeMap::new(),
            sort: 0,
            scroll_handles: Default::default(),
        }
    }
}

pub(crate) struct WhiskyApp {
    pub(crate) preview: PreviewState,
    pub(crate) search: Entity<InputState>,
    pub(crate) mode: usize,
    /// The bundled demo snapshot, enabled with `WHISKY_GPUI_DEMO_DATA=1`.
    pub(crate) demo: bool,
    pub(crate) bottles: Vec<BottleVm>,
    /// Every loaded entry, in bottle order. `Game::bottle` is the one-based slot.
    pub(crate) entries: Vec<Game>,
    /// Index into `bottles`; `None` means the whole library.
    pub(crate) selected_bottle: Option<usize>,
    /// A read for the visible scope is still in flight.
    pub(crate) loading: bool,
    /// Session/catalogue failure for the whole library surface.
    pub(crate) load_error: Option<String>,
    /// Successful entries per bottle, seeded from the cache and invalidation.
    bottle_entries: BTreeMap<usize, Vec<Game>>,
    /// Bottle indices with a queued or in-flight read.
    pending: BTreeSet<usize>,
    /// Per-bottle read errors, shown when that bottle is visible.
    failures: BTreeMap<usize, String>,
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
    /// The message on the existing toast; `None` hides it. Runtime failures
    /// reuse the toast instead of introducing another surface.
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
            preview: PreviewState::new(window, cx),
            search,
            mode: 0,
            demo,
            bottles: if demo { demo_bottles() } else { Vec::new() },
            entries: Vec::new(),
            selected_bottle: None,
            loading: false,
            load_error: None,
            bottle_entries: BTreeMap::new(),
            pending: BTreeSet::new(),
            failures: BTreeMap::new(),
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
            mixed: true,
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
            _subscriptions: vec![subscription, activation],
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
        self.clipboard_prompt = None;
        cx.notify();
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
                if unavailable && !self.demo {
                    self.pending.clear();
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
                    self.request_all();
                    // A reconnect must re-configure, or every card would stay
                    // disabled with no way back short of reselecting the bottle.
                    if let Some(path) = self
                        .selected_bottle
                        .and_then(|index| self.bottles.get(index))
                        .filter(|bottle| bottle.available)
                        .map(|bottle| bottle.path.clone())
                    {
                        self.bridge.configure_runtime(&path);
                    }
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
            BridgeEvent::Entries { container, entries } => {
                if !self.demo
                    && let Some(index) = self
                        .bottles
                        .iter()
                        .position(|bottle| bottle.path == container)
                {
                    let fallback = index + 1;
                    let games: Vec<Game> = entries
                        .into_iter()
                        .map(|entry| {
                            let slot = entry
                                .container
                                .as_deref()
                                .and_then(|path| {
                                    self.bottles
                                        .iter()
                                        .position(|bottle| bottle.path == path)
                                })
                                .map_or(fallback, |bottle_index| bottle_index + 1);
                            entry.into_game(slot)
                        })
                        .collect();
                    self.bottle_entries.insert(index, games);
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
        }
        self.loading = self.compute_loading();
        cx.notify();
    }

    /// Select a bottle (or `None` for the whole library). A switch always asks
    /// for a fresh read; the supervisor drops its cache for the old bottle.
    pub(crate) fn select_bottle(&mut self, index: Option<usize>, cx: &mut Context<Self>) {
        self.settings = false;
        self.selected_bottle = index;
        self.preview.page = if index.is_none() {
            PreviewPage::Library
        } else {
            PreviewPage::Bottle
        };
        self.preview.history.clear();
        self.detail_open = false;
        self.hovered = None;
        if let Some(index) = index
            && !self.demo
            && let Some(bottle) = self.bottles.get(index)
            && bottle.available
        {
            let path = bottle.path.clone();
            self.failures.remove(&index);
            self.pending.insert(index);
            self.bridge.load_entries(&path);
            // The runtime publishes one session at a time, so selecting a
            // bottle rebinds it before any card can offer Play.
            self.bridge.configure_runtime(&path);
        }
        self.loading = self.compute_loading();
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
                                self.pending.insert(index);
                                self.bridge.load_entries(&path);
                                self.bridge.configure_runtime(&path);
                            } else {
                                self.failures
                                    .insert(index, "This bottle is unavailable.".to_owned());
                            }
                        }
                        None => self.request_all(),
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
    fn rebuild_entries(&mut self) {
        let mut entries = Vec::new();
        for games in self.bottle_entries.values() {
            entries.extend(games.iter().cloned());
        }
        self.entries = entries;
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
    pub(crate) fn filtered(&self, cx: &App) -> Vec<usize> {
        let query = self.search.read(cx).value().to_lowercase();
        let games = self.games();
        let slot = self.bottle_slot();
        (0..games.len())
            .filter(|&i| {
                (slot == 0 || self.preview_bottle(i) == slot)
                    && self.preview_visible(i)
                    && (games[i].title.to_lowercase().contains(&query)
                        || games[i].studio().to_lowercase().contains(&query))
            })
            .collect()
    }
    pub(crate) fn reorder_library(&mut self, cx: &mut Context<Self>) {
        self.reversed = !self.reversed;
        self.hovered = None;
        cx.notify();
    }
    pub(crate) fn ordered(&self, cx: &App) -> Vec<usize> {
        let mut indices = self.filtered(cx);
        self.preview_sort(&mut indices);
        if self.reversed {
            indices.reverse();
        }
        indices
    }
    pub(crate) fn command(&mut self, command: Command, cx: &mut Context<Self>) {
        match command {
            Command::Page(page) => self.navigate(page, cx),
            Command::Sheet(sheet) => self.open_preview_sheet(sheet, cx),
            Command::Details(i) => self.open_detail(i, cx),
            Command::Configure(i) => {
                let slot = self
                    .preview
                    .moved
                    .get(&i)
                    .copied()
                    .unwrap_or_else(|| self.game(i).map_or(0, |game| game.bottle));
                self.selected_bottle = slot.checked_sub(1).filter(|index| *index < self.bottles.len());
                self.navigate(PreviewPage::ConfigureBottle, cx);
            }
            Command::Toggle(key) => match key {
                "mixed" => self.mixed = !self.mixed,
                "motion" => self.motion = !self.motion,
                "lively" => self.lively = !self.lively,
                _ => {
                    let value = self.preview.toggles.entry(key).or_default();
                    *value = !*value;
                }
            },
            Command::Sort(i) => self.preview.sort = i,
            Command::Reorder => self.reorder_library(cx),
            Command::Hide(i) => {
                if !self.preview.hidden.remove(&i) {
                    self.preview.hidden.insert(i);
                }
            }
            Command::Move(i, bottle) => {
                self.preview.moved.insert(i, bottle);
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
        }
        cx.notify();
    }

    /// Container path that owns this card's entry, when the bottle is present.
    fn bottle_path(&self, index: usize) -> Option<String> {
        self.game(index)
            .and_then(|game| game.bottle.checked_sub(1))
            .and_then(|slot| self.bottles.get(slot))
            .filter(|bottle| bottle.available)
            .map(|bottle| bottle.path.clone())
    }

    /// Per-entry runtime state. Cards for entries the helper has never
    /// configured (the Library page before any bottle is opened, or the demo)
    /// have no state and therefore no action.
    pub(crate) fn runtime_state(&self, index: usize) -> Option<RuntimeState> {
        self.game(index)
            .and_then(|game| self.runtime.entry(&game.id))
            .map(|entry| entry.state)
    }

    /// The card's primary action. Entries without runtime state — and states
    /// this build does not understand — yield a disabled, neutral button.
    pub(crate) fn primary_action(&self, index: usize) -> PrimaryAction {
        self.game(index)
            .and_then(|game| self.runtime.entry(&game.id))
            .map_or(PrimaryAction::unavailable(), |entry| {
                primary_action_for(entry.state, entry.capabilities)
            })
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
                self.runtime.set_state(&entry_id, RuntimeState::Preparing);
                self.bridge.launch(&container, &entry_id);
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
        cx.notify();
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
        cx.notify();
    }
    pub(crate) fn preview_visible(&self, index: usize) -> bool {
        self.flag("show-hidden")
            || (!self.preview.hidden.contains(&index)
                && !self.game(index).is_some_and(|game| game.hidden))
    }
    pub(crate) fn preview_bottle(&self, index: usize) -> usize {
        self.preview
            .moved
            .get(&index)
            .copied()
            .unwrap_or_else(|| self.game(index).map_or(0, |game| game.bottle))
    }
    pub(crate) fn preview_sort(&self, indices: &mut [usize]) {
        let games = self.games();
        match self.preview.sort {
            1 => indices.sort_by_key(|&i| games[i].title.as_str()),
            2 => indices.reverse(),
            _ => {}
        }
    }
}
