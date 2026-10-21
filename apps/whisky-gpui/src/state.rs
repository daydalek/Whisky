//! Application state: the root view model, page/sheet enums, and navigation.

use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use gpui_kit::base::Transition;
use gpui_kit::component::input::InputState;
use gpui_kit::{prelude::*, *};

#[cfg(feature = "visual-test")]
use crate::library_layout::CardRect;
use crate::model::demo_data;
use crate::views::Command;

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
    pub(crate) bottle: usize,
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
    pub(crate) notice: bool,
    pub(crate) _subscriptions: Vec<Subscription>,
}
impl WhiskyApp {
    pub(crate) fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = cx.new(|cx| InputState::new(window, cx).placeholder("Search programs"));
        let subscription = cx.observe(&search, |_, _, cx| cx.notify());
        Self {
            preview: PreviewState::new(window, cx),
            search,
            mode: 0,
            bottle: 0,
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
            notice: false,
            _subscriptions: vec![subscription],
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
        self.notice = false;
        cx.notify();
    }
    pub(crate) fn show_notice(&mut self, cx: &mut Context<Self>) {
        self.notice = true;
        cx.notify();
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(3)).await;
            let _ = this.update(cx, |this, cx| {
                this.notice = false;
                cx.notify();
            });
        })
        .detach();
    }
    pub(crate) fn filtered(&self, cx: &App) -> Vec<usize> {
        let query = self.search.read(cx).value().to_lowercase();
        let games = demo_data();
        (0..games.len())
            .filter(|&i| {
                (self.bottle == 0 || self.preview_bottle(i) == self.bottle)
                    && self.preview_visible(i)
                    && (games[i].title.to_lowercase().contains(&query)
                        || games[i].studio.to_lowercase().contains(&query))
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
                self.bottle = self
                    .preview
                    .moved
                    .get(&i)
                    .copied()
                    .unwrap_or(demo_data()[i].bottle);
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
            Command::Notice => self.show_notice(cx),
        }
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
    pub(crate) fn preview_title(&self) -> &'static str {
        if self.settings {
            return "设置";
        }
        match self.preview.page {
            PreviewPage::Library => "Library",
            PreviewPage::Bottle => {
                if self.bottle == 2 {
                    "galgame-win7"
                } else {
                    "galgame"
                }
            }
            PreviewPage::ConfigureBottle => "Configure Bottle",
            PreviewPage::Programs => "已安装的程序",
            PreviewPage::Processes => "运行中的进程",
            PreviewPage::GameConfigs => "游戏配置",
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
        self.flag("show-hidden") || !self.preview.hidden.contains(&index)
    }
    pub(crate) fn preview_bottle(&self, index: usize) -> usize {
        self.preview
            .moved
            .get(&index)
            .copied()
            .unwrap_or(demo_data()[index].bottle)
    }
    pub(crate) fn preview_sort(&self, indices: &mut [usize]) {
        let games = demo_data();
        match self.preview.sort {
            1 => indices.sort_by_key(|&i| games[i].title),
            2 => indices.reverse(),
            _ => {}
        }
    }
}
