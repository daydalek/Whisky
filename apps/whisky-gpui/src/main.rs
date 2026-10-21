use gpui_kit::base::{
    Presence, ScrollBounce, ScrollBounceMotion, Spring, Transition, spring, transition,
};
use gpui_kit::component::{
    Icon,
    input::{Input, InputState},
    switch::Switch,
    theme::{Theme, ThemeMode},
};
use gpui_kit::{prelude::*, *};
use std::{path::PathBuf, time::Duration};
mod library_layout;
#[cfg(feature = "visual-test")]
mod motion_capture;
mod preview;
use gpui_kit::component::menu::ContextMenuExt;
use library_layout::{CardRect, LibraryLayout};
use preview::*;
gpui_kit::actions!(
    whisky_preview,
    [DismissPreview, QuitPreview, ReorderLibrary, ToggleMotion]
);
const BG: u32 = 0x202021;
const MUTED: u32 = 0x97979b;
const ACCENT: u32 = 0xff891b;
#[derive(Clone, Copy)]
struct Game {
    art: &'static str,
    title: &'static str,
    studio: &'static str,
    description: &'static str,
    release: &'static str,
    landscape: bool,
    bottle: usize,
}
include!("games.rs");
fn asset(file: impl AsRef<std::path::Path>) -> PathBuf {
    static ROOT: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    ROOT.get_or_init(|| {
        let bundled = std::env::current_exe()
            .ok()
            .and_then(|exe| Some(exe.parent()?.parent()?.join("Resources/local-library")));
        bundled.filter(|path| path.is_dir()).unwrap_or_else(|| {
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("assets/local-library")
        })
    })
    .join(file)
}
fn art(i: usize) -> PathBuf {
    asset(GAMES[i].art)
}
fn ambient(i: usize) -> PathBuf {
    asset(format!("{i}-ambient.jpg"))
}
fn row() -> Div {
    div().flex().items_center()
}
fn col() -> Div {
    div().flex().flex_col()
}
fn icon(name: &str, size: f32) -> Icon {
    Icon::default()
        .path(format!("icons/{name}.svg"))
        .size(px(size))
        .flex_shrink_0()
}
fn muted(text: impl Into<SharedString>) -> Div {
    div()
        .text_size(px(12.))
        .text_color(rgb(MUTED))
        .child(text.into())
}
fn gradient(top: u32, bottom: u32) -> Background {
    linear_gradient(
        180.,
        linear_color_stop(rgba(top), 0.),
        linear_color_stop(rgba(bottom), 1.),
    )
}
fn badge(name: &str, text: impl Into<SharedString>) -> Div {
    row()
        .gap(px(5.))
        .px(px(9.))
        .py(px(3.))
        .rounded_full()
        .bg(rgba(0xffffff0b))
        .text_size(px(11.))
        .text_color(rgb(0xb8b8bc))
        .child(icon(name, 12.))
        .child(text.into())
}
fn round_button(id: &'static str, name: &str) -> Stateful<Div> {
    row()
        .id(id)
        .justify_center()
        .size(px(34.))
        .rounded_full()
        .bg(rgba(0xffffff09))
        .border_1()
        .border_color(rgba(0xffffff0d))
        .cursor_pointer()
        .hover(|s| s.bg(rgba(0xffffff20)))
        .child(icon(name, 17.))
}
struct Demo {
    preview: PreviewState,
    search: Entity<InputState>,
    mode: usize,
    bottle: usize,
    sidebar: bool,
    settings: bool,
    motion: bool,
    lively: bool,
    reversed: bool,
    library_scroll: [ScrollHandle; 3],
    detail_scroll: ScrollHandle,
    scroll_needs_measurement: std::cell::Cell<bool>,
    #[cfg(feature = "visual-test")]
    motion_samples: std::cell::RefCell<std::collections::BTreeMap<usize, CardRect>>,
    mixed: bool,
    hovered: Option<usize>,
    ambient_index: usize,
    detail: Option<usize>,
    detail_open: bool,
    notice: bool,
    _subscriptions: Vec<Subscription>,
}
impl Demo {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
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
    fn timing(&self, ms: u64) -> Transition {
        Transition::new(Duration::from_millis(if self.motion { ms } else { 0 }))
    }
    fn open_detail(&mut self, index: usize, cx: &mut Context<Self>) {
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
    fn sidebar(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut entries = col().gap(px(1.));
        for (id, label, symbol, bottle, count) in [
            (
                "library",
                "Library",
                "layout-grid",
                0,
                GAMES.len().to_string(),
            ),
            (
                "bottle-one",
                "galgame",
                "package",
                1,
                GAMES.iter().filter(|g| g.bottle == 1).count().to_string(),
            ),
            (
                "bottle-two",
                "galgame-win7",
                "package",
                2,
                GAMES.iter().filter(|g| g.bottle == 2).count().to_string(),
            ),
        ] {
            if bottle == 1 {
                entries = entries.child(
                    muted("Bottles")
                        .text_size(px(11.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .mt(px(17.))
                        .mb(px(4.))
                        .px(px(13.)),
                );
            }
            let selected = !self.settings && self.bottle == bottle;
            entries = entries.child(
                row()
                    .id(id)
                    .h(px(34.))
                    .px(px(13.))
                    .gap(px(10.))
                    .rounded(px(6.))
                    .bg(if selected {
                        rgba(0xffffff1a)
                    } else {
                        rgba(0x00000000)
                    })
                    .cursor_pointer()
                    .hover(|s| s.bg(rgba(0xffffff10)))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.settings = false;
                        this.bottle = bottle;
                        this.preview.page = if bottle == 0 {
                            PreviewPage::Library
                        } else {
                            PreviewPage::Bottle
                        };
                        this.preview.history.clear();
                        cx.notify();
                    }))
                    .child(icon(symbol, 18.).text_color(rgb(ACCENT)))
                    .child(
                        div()
                            .flex_1()
                            .text_size(px(13.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(label),
                    )
                    .child(muted(count).text_size(px(11.))),
            );
        }
        col()
            .size_full()
            .bg(gradient(0x272930ff, 0x242529ff))
            .border_r_1()
            .border_color(rgba(0xffffff0b))
            .child(
                row()
                    .h(px(52.))
                    .flex_shrink_0()
                    .px(px(14.))
                    .justify_end()
                    .child(
                        round_button("sidebar-hide", "panel-left").on_click(cx.listener(
                            |this, _, _, cx| {
                                this.sidebar = false;
                                cx.notify();
                            },
                        )),
                    ),
            )
            .child(entries.px(px(5.)))
            .child(div().flex_1())
            .child(
                row()
                    .justify_between()
                    .p(px(12.))
                    .child(muted("Whisky").text_size(px(11.)))
                    .child(
                        round_button("settings", "settings-2")
                            .size(px(28.))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.settings = !this.settings;
                                cx.notify();
                            })),
                    ),
            )
            .into_any_element()
    }
    fn toolbar(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let mut modes = row()
            .gap(px(1.))
            .p(px(3.))
            .rounded_full()
            .bg(rgba(0xffffff0b))
            .border_1()
            .border_color(rgba(0xffffff09));
        for (index, name) in ["library-big", "rows-3", "layout-grid"]
            .into_iter()
            .enumerate()
        {
            modes = modes.child(
                row()
                    .id(("mode", index))
                    .w(px(34.))
                    .h(px(28.))
                    .justify_center()
                    .rounded_full()
                    .bg(if self.mode == index {
                        rgba(0xffffff1a)
                    } else {
                        rgba(0x00000000)
                    })
                    .cursor_pointer()
                    .hover(|s| s.bg(rgba(0xffffff15)))
                    .child(icon(name, 19.))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.mode = index;
                        this.settings = false;
                        this.hovered = None;
                        cx.notify();
                    })),
            );
        }
        row()
            .h(px(52.))
            .flex_shrink_0()
            .px(px(18.))
            .gap(px(9.))
            .bg(rgba(0x272729f5))
            .border_b_1()
            .border_color(rgba(0xffffff08))
            .when(!self.sidebar, |d| {
                d.child(
                    round_button("sidebar-show", "panel-left").on_click(cx.listener(
                        |this, _, _, cx| {
                            this.sidebar = true;
                            cx.notify();
                        },
                    )),
                )
            })
            .child(
                div()
                    .flex_1()
                    .text_size(px(15.))
                    .font_weight(FontWeight::BOLD)
                    .child(self.preview_title()),
            )
            .child(
                round_button("add", "plus").on_click(cx.listener(|this, _, _, cx| {
                    this.open_preview_sheet(PreviewSheet::CreateBottle, cx)
                })),
            )
            .when(
                self.preview.page == PreviewPage::Library && !self.settings,
                |d| {
                    d.child(modes).child(
                        gpui_kit::component::button::Button::new("reorder-library")
                            .label("重排")
                            .tooltip("反转卡片顺序 · ⌘R")
                            .on_click(cx.listener(|this, _, _, cx| this.reorder_library(cx))),
                    )
                },
            )
            .child(self.options_menu(cx))
            .child(
                div()
                    .w(px(190.))
                    .flex_shrink_0()
                    .child(Input::new(&self.search)),
            )
    }
    fn show_notice(&mut self, cx: &mut Context<Self>) {
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
    fn backdrop(&self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        // Per-image channels preserve continuous blending even during rapid A → B → C hovers.
        let mut layers = div().absolute().size_full().overflow_hidden().bg(rgb(BG));
        for i in 0..GAMES.len() {
            let target = if self.hovered.is_some() && self.ambient_index == i {
                0.24_f32
            } else {
                0.0
            };
            let alpha = transition(
                ElementId::from(("ambient", i)),
                target,
                self.timing(420),
                window,
                cx,
            );
            if alpha > 0.001 {
                layers = layers.child(
                    img(ambient(i))
                        .absolute()
                        .size_full()
                        .object_fit(ObjectFit::Cover)
                        .opacity(alpha),
                );
            }
        }
        layers.into_any_element()
    }
    fn cover(
        &self,
        index: usize,
        width: f32,
        height: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let hovering = self.hovered == Some(index) && !self.detail_open;
        let amount = transition(
            ElementId::from(("cover-hover", index)),
            if hovering { 1_f32 } else { 0.0 },
            self.timing(180),
            window,
            cx,
        );
        // Frame stays fixed; only artwork expands, avoiding shelf reflow.
        let iw = width * (1. + amount * 0.025);
        let ih = height * (1. + amount * 0.025);
        div()
            .id(("cover", index))
            .relative()
            .w(px(width))
            .h(px(height))
            .flex_shrink_0()
            .rounded(px(8.))
            .overflow_hidden()
            .border_1()
            .border_color(rgba(if hovering { 0xffffff65 } else { 0xffffff14 }))
            .cursor_pointer()
            .on_hover(cx.listener(move |this, active, _, cx| {
                if *active {
                    this.ambient_index = index;
                    this.hovered = Some(index);
                } else if this.hovered == Some(index) {
                    this.hovered = None;
                }
                cx.notify();
            }))
            .on_click(cx.listener(move |this, _, _, cx| this.open_detail(index, cx)))
            .child(
                img(art(index))
                    .absolute()
                    .left(px((width - iw) / 2.))
                    .top(px((height - ih) / 2.))
                    .w(px(iw))
                    .h(px(ih))
                    .object_fit(ObjectFit::Cover),
            )
            .child(
                div()
                    .absolute()
                    .bottom_0()
                    .w_full()
                    .h(px(85.))
                    .bg(gradient(0x00000000, 0x000000b5)),
            )
            .child(
                div()
                    .absolute()
                    .bottom(px(9.))
                    .left(px(10.))
                    .right(px(9.))
                    .text_size(px(12.))
                    .font_weight(FontWeight::BOLD)
                    .when(self.preview_single_line(), |d| d.truncate())
                    .when(!self.preview_single_line(), |d| d.line_clamp(2))
                    .child(GAMES[index].title),
            )
            .child(
                row()
                    .absolute()
                    .top(px(10. + (1. - amount) * 5.))
                    .right(px(10.))
                    .justify_center()
                    .size(px(30.))
                    .rounded_full()
                    .bg(rgba(0x141416bb))
                    .opacity(amount)
                    .child(icon("play", 15.)),
            )
            .context_menu(self.game_menu(index, cx))
            .into_any_element()
    }
    fn filtered(&self, cx: &App) -> Vec<usize> {
        let query = self.search.read(cx).value().to_lowercase();
        (0..GAMES.len())
            .filter(|&i| {
                (self.bottle == 0 || self.preview_bottle(i) == self.bottle)
                    && self.preview_visible(i)
                    && (GAMES[i].title.to_lowercase().contains(&query)
                        || GAMES[i].studio.to_lowercase().contains(&query))
            })
            .collect()
    }
    fn reorder_library(&mut self, cx: &mut Context<Self>) {
        self.reversed = !self.reversed;
        self.hovered = None;
        cx.notify();
    }
    fn ordered(&self, cx: &App) -> Vec<usize> {
        let mut indices = self.filtered(cx);
        self.preview_sort(&mut indices);
        if self.reversed {
            indices.reverse();
        }
        indices
    }
    fn animated_rect(
        &self,
        index: usize,
        target: CardRect,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> CardRect {
        // Identity follows the game across order/column/layout changes. Base retains
        // position AND velocity on retarget; dimensions use critical damping.
        let response = Duration::from_millis(if self.lively { 460 } else { 350 });
        let geometry = Spring::new(response)
            .with_epsilon(0.1)
            .with_travel(self.motion);
        let travel = geometry.with_damping(if self.lively { 0.68 } else { 0.86 });
        let rect = CardRect {
            x: spring(
                ElementId::from(("library-card-x", index)),
                target.x,
                travel,
                window,
                cx,
            ),
            y: spring(
                ElementId::from(("library-card-y", index)),
                target.y,
                travel,
                window,
                cx,
            ),
            width: spring(
                ElementId::from(("library-card-w", index)),
                target.width,
                geometry,
                window,
                cx,
            )
            .max(1.),
            height: spring(
                ElementId::from(("library-card-h", index)),
                target.height,
                geometry,
                window,
                cx,
            )
            .max(1.),
        };
        #[cfg(feature = "visual-test")]
        self.motion_samples.borrow_mut().insert(index, rect);
        rect
    }

    fn card_slot(&self, index: usize, rect: CardRect, child: impl IntoElement) -> impl IntoElement {
        div()
            .id(("library-slot", index))
            .absolute()
            .left(px(rect.x))
            .top(px(rect.y))
            .w(px(rect.width))
            .h(px(rect.height))
            .child(child)
    }
    fn bouncing_scroll(
        &self,
        id: impl Into<ElementId>,
        handle: &ScrollHandle,
        content: impl IntoElement,
    ) -> AnyElement {
        let id = id.into();
        // One follow-up frame resolves the document's initial scroll metrics.
        if handle.bounds().size.height == px(0.) {
            self.scroll_needs_measurement.set(true);
        }
        let viewport = div()
            .id((id.clone(), "viewport"))
            .size_full()
            .track_scroll(handle)
            .overflow_y_scroll()
            .child(content);
        ScrollBounce::new((id, "bounce"), handle, viewport)
            .enabled(self.motion)
            // Base's direct edge path also stretches documents that fit the viewport.
            .scroll_wheel(handle.max_offset().y > px(0.))
            .motion(ScrollBounceMotion::default())
            .into_any_element()
    }
    fn library_viewport(&self, mode: usize, content: impl IntoElement) -> AnyElement {
        self.bouncing_scroll(
            ("library-scroll", mode),
            &self.library_scroll[mode],
            content,
        )
    }
    fn shelf(&self, width: f32, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let indices = self.ordered(cx);
        let layout = LibraryLayout::shelf(&indices, width, |i| self.mixed && GAMES[i].landscape);
        let mut content = div()
            .relative()
            .w_full()
            .h(px(layout.height.max(100.)))
            .flex_shrink_0();
        for (index, target) in layout.cards {
            let rect = self.animated_rect(index, target, window, cx);
            content = content.child(self.card_slot(
                index,
                rect,
                self.cover(index, rect.width, rect.height, window, cx),
            ));
        }
        if indices.is_empty() {
            content = content.child(muted("没有找到匹配的游戏").p(px(30.)));
        }
        self.library_viewport(0, content)
    }
    fn play_button(
        &self,
        id: impl Into<ElementId>,
        label: &'static str,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        row()
            .id(id)
            .flex_shrink_0()
            .justify_center()
            .gap(px(6.))
            .px(px(16.))
            .h(px(30.))
            .rounded_full()
            .bg(rgb(ACCENT))
            .text_color(rgb(0xffffff))
            .text_size(px(12.))
            .font_weight(FontWeight::BOLD)
            .cursor_pointer()
            .hover(|s| s.bg(rgb(0xff9c3a)))
            .on_click(cx.listener(|this, _, _, cx| this.show_notice(cx)))
            .child(icon("play", 13.))
            .child(label)
    }
    fn timeline(&self, width: f32, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let mut indices = self.filtered(cx);
        // Presentation ordering and sample times; no personal activity records are read.
        let featured = ["eden*", "サクラノ詩", "AIR", "Kanon"];
        indices.sort_by_key(|&i| {
            featured
                .iter()
                .position(|s| GAMES[i].title.starts_with(s))
                .unwrap_or(10 + i)
        });
        self.preview_sort(&mut indices);
        if self.reversed {
            indices.reverse();
        }
        let rail = if width > 1000. { 100. } else { 48. };
        let cw = if width > 1000. { 145. } else { 125. };
        let ch = cw * 1.5 + 26.;
        let layout = LibraryLayout::timeline(&indices, width);
        let mut content = div()
            .relative()
            .w_full()
            .h(px(layout.height.max(100.)))
            .flex_shrink_0();
        for (position, (index, target)) in layout.cards.into_iter().enumerate() {
            let rect = self.animated_rect(index, target, window, cx);
            let g = GAMES[index];
            let hover = transition(
                ElementId::from(("timeline-hover", index)),
                if self.hovered == Some(index) {
                    1_f32
                } else {
                    0.0
                },
                self.timing(180),
                window,
                cx,
            );
            content = content.child(
                self.card_slot(
                    index,
                    rect,
                    row()
                        .size_full()
                        .items_start()
                        .gap(px(18.))
                        .child(
                            div()
                                .relative()
                                .w(px(rail))
                                .h(px(ch))
                                .flex_shrink_0()
                                .child(
                                    div()
                                        .absolute()
                                        .left(px(rail * 0.55))
                                        .top(px(-12.))
                                        .bottom(px(-12.))
                                        .w(px(1.))
                                        .bg(rgba(0xffffff12)),
                                )
                                .child(
                                    muted(if position == 0 {
                                        "今天"
                                    } else if position == 4 {
                                        "更早"
                                    } else {
                                        ""
                                    })
                                    .absolute()
                                    .top(px(4.))
                                    .left_0()
                                    .text_size(px(11.)),
                                )
                                .child(
                                    div()
                                        .absolute()
                                        .left(px(rail * 0.55 - 4.))
                                        .top(px(ch / 2. - 4.))
                                        .size(px(8.))
                                        .rounded_full()
                                        .bg(rgb(if position == 0 || self.hovered == Some(index) {
                                            ACCENT
                                        } else {
                                            0x565658
                                        })),
                                ),
                        )
                        .child(
                            row()
                                .id(("timeline", index))
                                .flex_1()
                                .min_w_0()
                                .h(px(ch))
                                .gap(px(19.))
                                .p(px(13.))
                                .rounded(px(16.))
                                .bg(rgba(if hover > 0.1 { 0xffffff0e } else { 0xffffff07 }))
                                .border_1()
                                .border_color(rgba(0xffffff0d))
                                .on_hover(cx.listener(move |this, active, _, cx| {
                                    this.hovered = if *active { Some(index) } else { None };
                                    this.ambient_index = index;
                                    cx.notify();
                                }))
                                .child(
                                    div()
                                        .id(("timeline-art", index))
                                        .w(px(cw))
                                        .h(px(ch - 26.))
                                        .flex_shrink_0()
                                        .rounded(px(6.))
                                        .overflow_hidden()
                                        .cursor_pointer()
                                        .on_click(cx.listener(move |this, _, _, cx| {
                                            this.open_detail(index, cx)
                                        }))
                                        .child(
                                            img(art(index))
                                                .size_full()
                                                .object_fit(ObjectFit::Cover),
                                        )
                                        .context_menu(self.game_menu(index, cx)),
                                )
                                .child(
                                    col()
                                        .flex_1()
                                        .min_w_0()
                                        .justify_center()
                                        .h_full()
                                        .gap(px(8.))
                                        .child(
                                            div()
                                                .text_size(px(19.))
                                                .line_height(relative(1.25))
                                                .font_weight(FontWeight::BOLD)
                                                .flex_shrink_0()
                                                .child(g.title),
                                        )
                                        .child(muted(g.studio).flex_shrink_0().truncate())
                                        .child(
                                            row()
                                                .flex_shrink_0()
                                                .flex_wrap()
                                                .gap(px(7.))
                                                .mt(px(3.))
                                                .child(icon("clock-3", 12.).text_color(rgb(MUTED)))
                                                .child(muted(if position == 0 {
                                                    "晚上7:39"
                                                } else if position == 1 {
                                                    "晚上7:37"
                                                } else {
                                                    "下午6:39"
                                                }))
                                                .child(badge(
                                                    "package",
                                                    if g.bottle == 1 {
                                                        "galgame"
                                                    } else {
                                                        "galgame-win7"
                                                    },
                                                ))
                                                .child(badge("clock-3", "8分钟")),
                                        )
                                        .child(
                                            div()
                                                .mt(px(5.))
                                                .text_size(px(13.))
                                                .text_color(rgb(0xaaaaae))
                                                .line_height(relative(1.55))
                                                .flex_1()
                                                .min_h_0()
                                                .max_h(px(13. * 1.55 * 3.))
                                                .overflow_hidden()
                                                .line_clamp(3)
                                                // Metadata contains paragraph breaks; a card uses one
                                                // bounded preview, while details retain the full text.
                                                .child(
                                                    g.description
                                                        .split_whitespace()
                                                        .collect::<Vec<_>>()
                                                        .join(" "),
                                                ),
                                        ),
                                )
                                .child(
                                    col()
                                        .justify_center()
                                        .items_end()
                                        .gap(px(12.))
                                        .w(px(106.))
                                        .flex_shrink_0()
                                        .child(self.play_button(
                                            ("timeline-play", index),
                                            "继续游玩",
                                            cx,
                                        ))
                                        .child(self.game_options(index, cx)),
                                ),
                        ),
                ),
            );
        }
        self.library_viewport(1, content)
    }
    fn classic(&self, width: f32, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let indices = self.ordered(cx);
        let layout = LibraryLayout::classic(&indices, width);
        let mut content = div()
            .relative()
            .w_full()
            .h(px(layout.height.max(100.)))
            .flex_shrink_0();
        for (i, target) in layout.cards {
            let rect = self.animated_rect(i, target, window, cx);
            let card = col()
                .size_full()
                .gap(px(10.))
                .pb(px(13.))
                .rounded(px(12.))
                .overflow_hidden()
                .bg(rgba(0xffffff08))
                .border_1()
                .border_color(rgba(0xffffff0d))
                .child(self.cover(i, rect.width, (rect.height - 55.).max(1.), window, cx))
                .child(
                    row()
                        .px(px(12.))
                        .justify_between()
                        .child(muted(GAMES[i].studio).flex_1().min_w_0().truncate())
                        .child(self.play_button(("classic-play", i), "游玩", cx)),
                );
            content = content.child(self.card_slot(i, rect, card));
        }
        self.library_viewport(2, content)
    }
    fn detail_panel(
        &self,
        index: usize,
        progress: f32,
        width: f32,
        height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let g = GAMES[index];
        let pw = (width - 100.).clamp(600., 910.).min(width - 36.);
        let ph = (height - 90.).clamp(480., 690.).min(height - 36.);
        div()
            .absolute()
            .inset_0()
            // Modal hitboxes must also block wheel events, including at scroll boundaries.
            .occlude()
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .bg(rgba(0x00000080))
            .opacity(progress)
            .child(
                div()
                    .id("detail-dismiss")
                    .absolute()
                    .inset_0()
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.detail_open = false;
                        cx.notify();
                    })),
            )
            .child(
                col()
                    .absolute()
                    .left(px((width - pw) / 2.))
                    .top(px((height - ph) / 2. + (1. - progress) * 20.))
                    .w(px(pw))
                    .h(px(ph))
                    .rounded(px(18.))
                    .overflow_hidden()
                    .shadow_xl()
                    .border_1()
                    .border_color(rgba(0xffffff25))
                    .bg(rgb(0x29292c))
                    .child(
                        div().absolute().size_full().child(
                            img(ambient(index))
                                .size_full()
                                .object_fit(ObjectFit::Cover)
                                .opacity(0.22),
                        ),
                    )
                    .child(
                        row()
                            .relative()
                            .h(px(48.))
                            .px(px(16.))
                            .flex_shrink_0()
                            .justify_between()
                            .child(muted("游戏详情").text_color(rgb(0xc4c4c9)))
                            .child(row().gap(px(8.)).child(self.game_options(index, cx)).child(
                                round_button("detail-close", "x").size(px(27.)).on_click(
                                    cx.listener(|this, _, _, cx| {
                                        this.detail_open = false;
                                        cx.notify();
                                    }),
                                ),
                            )),
                    )
                    .child(
                        div().relative().flex_1().min_h_0().child(
                            self.bouncing_scroll(
                                ("detail-scroll", index),
                                &self.detail_scroll,
                                col()
                                    .w_full()
                                    .flex_shrink_0()
                                    .px(px(28.))
                                    .pb(px(28.))
                                    .gap(px(23.))
                                    .child(
                                        row()
                                            .flex_shrink_0()
                                            .items_start()
                                            .gap(px(25.))
                                            .child(
                                                img(art(index))
                                                    .w(px(190.))
                                                    .h(px(278.))
                                                    .flex_shrink_0()
                                                    .rounded(px(9.))
                                                    .object_fit(ObjectFit::Cover),
                                            )
                                            .child(
                                                col()
                                                    .flex_1()
                                                    .min_w_0()
                                                    .gap(px(12.))
                                                    .pt(px(15.))
                                                    .child(
                                                        div()
                                                            .text_size(px(27.))
                                                            .font_weight(FontWeight::BOLD)
                                                            .line_height(relative(1.2))
                                                            .child(g.title),
                                                    )
                                                    .child(muted(g.studio).text_size(px(14.)))
                                                    .child(muted(g.release))
                                                    .child(
                                                        row()
                                                            .gap(px(8.))
                                                            .mt(px(8.))
                                                            .child(badge("package", "galgame"))
                                                            .child(badge("star", "8 / 10")),
                                                    )
                                                    .child(div().mt(px(12.)).child(
                                                        self.play_button(
                                                            "detail-play",
                                                            "继续游玩",
                                                            cx,
                                                        ),
                                                    )),
                                            ),
                                    )
                                    .child(
                                        col()
                                            .flex_shrink_0()
                                            .gap(px(12.))
                                            .p(px(20.))
                                            .rounded(px(12.))
                                            .bg(rgba(0xffffff09))
                                            .child(
                                                div()
                                                    .font_weight(FontWeight::SEMIBOLD)
                                                    .child("简介"),
                                            )
                                            .child(
                                                div()
                                                    .text_size(px(13.))
                                                    .text_color(rgb(0xc3c3ca))
                                                    .line_height(relative(1.65))
                                                    .child(g.description),
                                            ),
                                    ),
                            ),
                        ),
                    ),
            )
            .into_any_element()
    }
}
impl Render for Demo {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.scroll_needs_measurement.set(false);
        let ww = f32::from(window.viewport_size().width);
        let wh = f32::from(window.viewport_size().height);
        let sw = spring(
            "sidebar-width",
            if self.sidebar { 200_f32 } else { 0. },
            Spring::new(Duration::from_millis(320))
                .with_epsilon(0.1)
                .with_travel(self.motion),
            window,
            cx,
        );
        let width = ww - sw;
        let backdrop = self.backdrop(window, cx);
        let body = if self.settings {
            self.application_settings(cx)
        } else if self.preview.page != PreviewPage::Library {
            self.preview_page(cx)
        } else {
            match self.mode {
                1 => self.timeline(width, window, cx),
                2 => self.classic(width, window, cx),
                _ => self.shelf(width, window, cx),
            }
        };
        let presence = Presence::new("detail-presence", self.detail_open)
            .transition(self.timing(240))
            .sample(window, cx);
        let notification = Presence::new("notice-presence", self.notice)
            .transition(self.timing(180))
            .sample(window, cx);
        let mut root = row()
            .relative()
            .size_full()
            .items_start()
            .overflow_hidden()
            .bg(rgb(BG))
            .font_family(".AppleSystemUIFont")
            .text_color(rgb(0xededee))
            .text_size(px(13.))
            .on_action(cx.listener(|this, _: &ReorderLibrary, _, cx| {
                if this.preview.page == PreviewPage::Library
                    && !this.settings
                    && !this.detail_open
                    && this.preview.sheet.is_none()
                {
                    this.reorder_library(cx);
                }
            }))
            .on_action(cx.listener(|this, _: &ToggleMotion, _, cx| {
                this.motion = !this.motion;
                cx.notify();
            }))
            .on_action(cx.listener(|this, _: &DismissPreview, _, cx| {
                if this.preview.sheet.is_some() {
                    this.preview_dismiss(cx);
                } else {
                    this.detail_open = false;
                    cx.notify();
                }
            }))
            .child(
                div()
                    .w(px(sw))
                    .min_w(px(sw))
                    .h_full()
                    .overflow_hidden()
                    .flex_shrink_0()
                    .child(div().w(px(200.)).h_full().child(self.sidebar(cx))),
            )
            .child(
                col()
                    .relative()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .child(backdrop)
                    .child(div().relative().child(self.toolbar(cx)))
                    .child(div().relative().flex_1().min_h_0().w_full().child(body)),
            );
        if presence.should_render() {
            if let Some(index) = self.detail {
                root = root.child(self.detail_panel(index, presence.progress, ww, wh, cx));
            }
        }
        if let Some(sheet) = self.preview.sheet {
            root = root.child(self.preview_sheet(sheet, ww, wh, cx));
        }
        if notification.should_render() {
            root = root.child(
                row()
                    .absolute()
                    .bottom(px(24.))
                    .left(px(sw + 24.))
                    .gap(px(8.))
                    .px(px(16.))
                    .py(px(12.))
                    .rounded(px(12.))
                    .bg(rgb(0x3b3b40))
                    .border_1()
                    .border_color(rgba(0xffffff20))
                    .shadow_lg()
                    .opacity(notification.progress)
                    .child(icon("info", 16.).text_color(rgb(ACCENT)))
                    .child("外观演示 · 未启动游戏，也未修改容器"),
            );
        }
        if self.scroll_needs_measurement.get() {
            window.request_animation_frame();
        }
        root
    }
}
#[cfg(feature = "visual-test")]
fn capture_preview(handle: AnyWindowHandle, view: Entity<Demo>, cx: &mut App) {
    cx.spawn(async move |cx| {
        let out = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("screenshots");
        std::fs::create_dir_all(&out).unwrap();
        let names = [
            "library",
            "timeline",
            "details",
            "settings",
            "compact",
            "classic",
            "bottle",
            "configure-bottle",
            "programs",
            "run-settings",
            "scan-settings",
            "winetricks",
            "compact-bottle",
        ];
        for (stage, name) in names.into_iter().enumerate() {
            handle
                .update(cx, |_, window, cx| {
                    view.update(cx, |this, cx| {
                        this.settings = false;
                        this.detail_open = false;
                        this.preview.sheet = None;
                        this.preview.page = PreviewPage::Library;
                        this.mode = 0;
                        this.bottle = 0;
                        match stage {
                            0 => window.resize(size(px(1280.), px(820.))),
                            1 => this.mode = 1,
                            2 => {
                                this.mode = 1;
                                this.open_detail(
                                    GAMES
                                        .iter()
                                        .position(|g| g.title.starts_with("Saltlight"))
                                        .unwrap(),
                                    cx,
                                );
                            }
                            3 => this.settings = true,
                            4 => window.resize(size(px(900.), px(650.))),
                            5 => this.mode = 2,
                            6 => {
                                window.resize(size(px(1280.), px(820.)));
                                this.bottle = 1;
                                this.preview.page = PreviewPage::Bottle;
                            }
                            7 => {
                                this.bottle = 1;
                                this.preview.page = PreviewPage::ConfigureBottle;
                            }
                            8 => {
                                this.bottle = 1;
                                this.preview.page = PreviewPage::Programs;
                            }
                            9 => this.open_preview_sheet(PreviewSheet::RunSettings(0), cx),
                            10 => this.open_preview_sheet(PreviewSheet::Scan, cx),
                            11 => this.open_preview_sheet(PreviewSheet::Winetricks, cx),
                            _ => {
                                window.resize(size(px(800.), px(580.)));
                                this.bottle = 1;
                                this.preview.page = PreviewPage::ConfigureBottle;
                            }
                        }
                        cx.notify();
                    });
                })
                .unwrap();
            cx.background_executor()
                .timer(Duration::from_millis(750))
                .await;
            handle
                .update(cx, |_, window, _| {
                    window
                        .render_to_image()
                        .expect("GPU capture failed")
                        .save(out.join(format!("{name}.png")))
                        .unwrap();
                })
                .unwrap();
        }
        cx.update(|cx| cx.quit());
    })
    .detach();
}

fn main() {
    gpui_kit::application()
        .with_assets(gpui_kit::assets::AllAssets)
        .run(|cx| {
            gpui_kit::init(cx);
            cx.bind_keys([
                KeyBinding::new("escape", DismissPreview, None),
                KeyBinding::new("cmd-q", QuitPreview, None),
                KeyBinding::new("cmd-r", ReorderLibrary, None),
                KeyBinding::new("cmd-shift-m", ToggleMotion, None),
            ]);
            cx.on_action(|_: &QuitPreview, cx| cx.quit());
            Theme::change(ThemeMode::Dark, None, cx);
            cx.on_window_closed(|cx, _| {
                if cx.windows().is_empty() {
                    cx.quit();
                }
            })
            .detach();
            let (_handle, _view) = gpui_kit::open_window(
                WindowOptions {
                    titlebar: Some(TitlebarOptions {
                        title: Some("Whisky".into()),
                        appears_transparent: true,
                        traffic_light_position: Some(point(px(15.), px(21.))),
                    }),
                    window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                        None,
                        size(px(1280.), px(820.)),
                        cx,
                    ))),
                    window_min_size: Some(size(px(800.), px(580.))),
                    ..Default::default()
                },
                cx,
                |window, cx| cx.new(|cx| Demo::new(window, cx)),
            )
            .expect("Failed to open GPUI preview");
            cx.activate(true);
            #[cfg(feature = "visual-test")]
            if std::env::var_os("WHISKY_MOTION_CAPTURE").is_some() {
                motion_capture::run(_handle, _view.clone(), cx);
            }
            #[cfg(feature = "visual-test")]
            if std::env::var_os("WHISKY_DEMO_CAPTURE").is_some() {
                capture_preview(_handle, _view, cx);
            }
        });
}
