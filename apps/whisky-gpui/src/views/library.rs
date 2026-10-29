//! Library surface: sidebar, toolbar, three presentations, and the detail panel.

use std::time::Duration;

use gpui_kit::base::{Spring, spring, transition};
use gpui_kit::component::{
    Sizable,
    button::{Button, ButtonVariants},
    menu::ContextMenuExt,
    spinner::Spinner,
};
use gpui_kit::{prelude::*, *};

use crate::bridge::BridgeStatus;
use crate::controls::*;
use crate::library_layout::{CardRect, LibraryLayout};
use crate::model::{ambient, art};
use crate::runtime::{RuntimeAction, RuntimeState};
use crate::state::{DEMO_NOTICE, PreviewPage, WhiskyApp};
use crate::theme::*;

/// One sidebar row. Kept next to the sidebar so the Library and bottle entries
/// cannot drift apart visually.
fn sidebar_row(
    id: impl Into<ElementId>,
    label: &str,
    symbol: &str,
    count: usize,
    selected: bool,
) -> Stateful<Div> {
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
        .child(icon(symbol, 18.).text_color(rgb(ACCENT)))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_size(px(13.))
                .font_weight(FontWeight::SEMIBOLD)
                .child(label.to_owned()),
        )
        .child(muted(count.to_string()).text_size(px(11.)))
}

impl WhiskyApp {
    /// Existing artwork only; the demo keeps its bundled sample covers.
    pub(crate) fn artwork(&self, index: usize) -> Option<std::path::PathBuf> {
        if self.demo {
            Some(art(index))
        } else {
            self.game(index).and_then(|game| game.art.clone())
        }
    }

    /// The blurred backdrop is derived from the same artwork.
    fn ambient_art(&self, index: usize) -> Option<std::path::PathBuf> {
        if self.demo {
            Some(ambient(index))
        } else {
            self.artwork(index)
        }
    }

    /// The library body plus the shared loading/error surfaces.
    pub(crate) fn library_page(
        &self,
        width: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if let Some(error) = self.visible_load_error() {
            return self.library_error_surface(error, cx);
        }
        if self.games().is_empty() && self.loading {
            // The empty-state treatment, not a spinner overlay: content that
            // already exists stays visible while a refresh is in flight.
            return self.library_viewport(0, col().p(px(30.)).child(muted("Loading…")));
        }
        match self.mode {
            1 => self.timeline(width, window, cx),
            2 => self.classic(width, window, cx),
            _ => self.shelf(width, window, cx),
        }
    }

    pub(crate) fn library_error_surface(&self, reason: &str, cx: &mut Context<Self>) -> AnyElement {
        col()
            .size_full()
            .items_center()
            .justify_center()
            .p(px(30.))
            .child(
                col()
                    .w(px(420.))
                    .gap(px(14.))
                    .p(px(20.))
                    .rounded(px(RADIUS_LG))
                    .bg(rgb(SURFACE))
                    .border_1()
                    .border_color(rgba(SURFACE_BORDER))
                    .child(div().font_weight(FontWeight::SEMIBOLD).child("Library unavailable"))
                    .child(
                        muted(reason)
                            .line_height(relative(1.5))
                            .line_clamp(4),
                    )
                    .child(
                        row().justify_end().child(
                            Button::new("library-retry")
                                .label("Retry")
                                .primary()
                                .on_click(cx.listener(|this, _, _, cx| this.retry_library(cx))),
                        ),
                    ),
            )
            .into_any_element()
    }

    pub(crate) fn sidebar(&self, cx: &mut Context<Self>) -> AnyElement {
        let games = self.games();
        let mut entries = col().gap(px(1.));
        entries = entries.child(
            sidebar_row(
                "library",
                "Library",
                "layout-grid",
                games.len(),
                !self.settings && self.selected_bottle.is_none(),
            )
            .on_click(cx.listener(|this, _, _, cx| this.select_bottle(None, cx))),
        );
        entries = entries.child(
            muted("Bottles")
                .text_size(px(11.))
                .font_weight(FontWeight::SEMIBOLD)
                .mt(px(17.))
                .mb(px(4.))
                .px(px(13.)),
        );
        for (index, bottle) in self.bottles.iter().enumerate() {
            let count = games.iter().filter(|game| game.bottle == index + 1).count();
            entries = entries.child(
                sidebar_row(
                    ("bottle", index),
                    &bottle.name,
                    "package",
                    count,
                    !self.settings && self.selected_bottle == Some(index),
                )
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.select_bottle(Some(index), cx);
                }))
                .context_menu(self.bottle_menu(index, cx)),
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
                col()
                    .gap(px(2.))
                    .px(px(8.))
                    .pb(px(8.))
                    .child(self.bridge_pill(cx))
                    .child(
                        row()
                            .justify_between()
                            .px(px(4.))
                            .py(px(4.))
                            .child(muted("Whisky").text_size(px(11.)))
                            .child(
                                round_button("settings", "settings-2")
                                    .size(px(28.))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.settings = !this.settings;
                                        cx.notify();
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }
    fn bridge_pill(&self, cx: &mut Context<Self>) -> AnyElement {
        let (dot, failed) = match &self.bridge_status {
            BridgeStatus::Connected { .. } => (SUCCESS, false),
            BridgeStatus::Failed { .. } => (DANGER, true),
            BridgeStatus::Stopped => (DANGER, false),
            BridgeStatus::Locating | BridgeStatus::Starting => (MUTED, false),
        };
        row()
            .id("bridge-status")
            .px(px(10.))
            .py(px(6.))
            .gap(px(7.))
            .rounded(px(RADIUS_SM))
            .when(failed, |d| {
                d.cursor_pointer()
                    .hover(|s| s.bg(rgba(HOVER)))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.bridge_dialog = true;
                        cx.notify();
                    }))
            })
            .child(div().size(px(6.)).rounded_full().bg(rgb(dot)))
            .child(
                div()
                    .text_size(px(11.))
                    .text_color(rgb(MUTED))
                    .child(self.bridge_status.label()),
            )
            .into_any_element()
    }
    pub(crate) fn toolbar(&self, cx: &mut Context<Self>) -> impl IntoElement {
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
                        this.set_mode(index, cx);
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
                    this.open_preview_sheet(crate::state::PreviewSheet::CreateBottle, cx)
                })),
            )
            .when(
                self.preview.page == PreviewPage::Library && !self.settings,
                |d| {
                    d.child(modes)
                },
            )
            .when(
                self.preview.page == PreviewPage::Library && !self.settings,
                |d| {
                    let hidden = self.hidden_count();
                    let label: SharedString = if hidden == 0 {
                        "Hidden".into()
                    } else {
                        format!("Hidden · {hidden}").into()
                    };
                    d.child(
                        Button::new("hidden-filter")
                            .label(label)
                            .rounded_full()
                            .tooltip("显示或隐藏已隐藏的游戏")
                            .when(self.show_hidden(), |button| button.primary())
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.command(crate::views::Command::Toggle("show-hidden"), cx);
                            })),
                    )
                },
            )
            .child(self.options_menu(cx))
            .child(
                div()
                    .w(px(190.))
                    .flex_shrink_0()
                    .child(gpui_kit::component::input::Input::new(&self.search)),
            )
    }
    pub(crate) fn backdrop(&self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        // Per-image channels preserve continuous blending even during rapid A → B → C hovers.
        let mut layers = div().absolute().size_full().overflow_hidden().bg(rgb(BG));
        for i in 0..self.games().len() {
            let target = if self.hovered.is_some() && self.ambient_index == i {
                0.24_f32
            } else {
                0.0
            };
            let alpha = transition(
                ElementId::from(("ambient", i)),
                target,
                self.timing(BACKDROP_MS),
                window,
                cx,
            );
            if alpha > 0.001
                && let Some(path) = self.ambient_art(i)
            {
                layers = layers.child(
                    img(path)
                        .absolute()
                        .size_full()
                        .object_fit(ObjectFit::Cover)
                        .opacity(alpha),
                );
            }
        }
        layers.into_any_element()
    }
    pub(crate) fn cover(
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
            self.timing(HOVER_MS),
            window,
            cx,
        );
        // Frame stays fixed; only artwork expands, avoiding shelf reflow.
        let iw = width * (1. + amount * 0.025);
        let ih = height * (1. + amount * 0.025);
        let artwork = self.artwork(index);
        let title = self
            .game(index)
            .map(|game| game.title.clone())
            .unwrap_or_default();
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
            .child(match artwork {
                Some(path) => img(path)
                    .absolute()
                    .left(px((width - iw) / 2.))
                    .top(px((height - ih) / 2.))
                    .w(px(iw))
                    .h(px(ih))
                    .object_fit(ObjectFit::Cover)
                    .into_any_element(),
                // Same frame, same gradient language as the demo covers.
                None => div()
                    .absolute()
                    .size_full()
                    .bg(gradient(0xffffff12, 0xffffff04))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(icon("package", 26.).text_color(rgb(MUTED)))
                    .into_any_element(),
            })
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
                    // `libraryCenterWideCoverText`: wide covers get a
                    // centered label instead of the leading one.
                    .when(
                        self.flag("center-cover-text")
                            && self
                                .game(index)
                                .is_some_and(|game| game.landscape),
                        |d| d.text_center(),
                    )
                    .child(title),
            )
            // Running and pending states are always visible; only the idle
            // affordance waits for hover, as it did before.
            .child(match self.runtime_state(index) {
                Some(RuntimeState::Running) => {
                    live_badge(self.runtime_badge_label(index, "Running"))
                    .absolute()
                    .top(px(9.))
                    .right(px(9.))
                    .into_any_element()
                }
                Some(state) if state.is_active() => {
                    phase_badge(self.runtime_badge_label(index, state.phase_label()))
                        .absolute()
                        .top(px(9.))
                        .right(px(9.))
                        .into_any_element()
                }
                _ => self.cover_play_circle(index, amount, cx),
            })
            .context_menu(self.game_menu(index, cx))
            .into_any_element()
    }
    /// The hover play circle. It dispatches the runtime action when there is
    /// one and stops the click so the card does not also open the details.
    fn cover_play_circle(
        &self,
        index: usize,
        amount: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let action = if self.demo {
            None
        } else {
            self.primary_action(index).action
        };
        let mut circle = row()
            .id(("cover-play", index))
            .absolute()
            .top(px(10. + (1. - amount) * 5.))
            .right(px(10.))
            .justify_center()
            .size(px(30.))
            .rounded_full()
            .bg(rgba(0x141416bb))
            .opacity(amount)
            .child(icon("play", 15.));
        if let Some(action) = action {
            let view = cx.entity().downgrade();
            circle = circle.cursor_pointer().on_click(move |_, _, cx| {
                let _ = view.update(cx, |this, cx| {
                    this.perform_runtime_action(index, Some(action), cx)
                });
                // The card behind this control opens the details panel.
                cx.stop_propagation();
            });
        }
        circle.into_any_element()
    }
    pub(crate) fn animated_rect(
        &self,
        index: usize,
        target: CardRect,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> CardRect {
        // Identity follows the game across order/column/layout changes. Base retains
        // position AND velocity on retarget; dimensions use critical damping.
        let response = Duration::from_millis(if self.lively {
            LIVELY_SPRING_MS
        } else {
            SPRING_MS
        });
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
    pub(crate) fn card_slot(
        &self,
        index: usize,
        rect: CardRect,
        child: impl IntoElement,
    ) -> impl IntoElement {
        div()
            .id(("library-slot", index))
            .absolute()
            .left(px(rect.x))
            .top(px(rect.y))
            .w(px(rect.width))
            .h(px(rect.height))
            .child(child)
    }
    pub(crate) fn shelf(&self, width: f32, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let indices = self.ordered(cx);
        let layout = LibraryLayout::shelf(&indices, width, |i| {
            self.mixed && self.game(i).is_some_and(|game| game.landscape)
        });
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
            content = content.child(muted(self.empty_library_message()).p(px(30.)));
        }
        self.library_viewport(0, content)
    }
    pub(crate) fn play_button(
        &self,
        id: impl Into<ElementId>,
        index: usize,
        demo_label: &'static str,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        // The demo has no runtime; it keeps its own label and its notice.
        let (label, enabled, busy, action) = if self.demo {
            (demo_label, true, false, None)
        } else {
            let action = self.primary_action(index);
            (action.label, action.enabled, action.busy, action.action)
        };
        let mut button = row()
            .id(id)
            .flex_shrink_0()
            .justify_center()
            .gap(px(6.))
            .px(px(16.))
            .h(px(30.))
            .rounded_full()
            .text_size(px(12.))
            .font_weight(FontWeight::BOLD);
        if busy {
            button = button
                .bg(rgba(0xffffff14))
                .text_color(rgb(MUTED))
                .child(Spinner::new().with_size(px(12.)))
                .child(label);
        } else if enabled {
            let leading = match action {
                Some(RuntimeAction::Cancel) => icon("x", 13.),
                Some(RuntimeAction::Stop) => icon("square", 12.),
                _ => icon("play", 13.),
            };
            button = button
                .bg(rgb(ACCENT))
                .text_color(rgb(0xffffff))
                .cursor_pointer()
                .hover(|s| s.bg(rgb(0xff9c3a)))
                .on_click(cx.listener(move |this, _, _, cx| {
                    if this.demo {
                        this.show_notice(DEMO_NOTICE, cx);
                    } else {
                        this.perform_runtime_action(index, action, cx);
                    }
                }))
                .child(leading.into_any_element())
                .child(label);
        } else {
            let leading = match action {
                Some(RuntimeAction::Stop) => icon("square", 12.),
                _ => icon("play", 13.),
            };
            button = button
                .bg(rgba(0xffffff12))
                .text_color(rgb(MUTED))
                .child(leading.into_any_element())
                .child(label);
        }
        button
    }
    pub(crate) fn timeline(&self, width: f32, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let games = self.games();
        // The demo keeps its hand-tuned featured order for the default sort;
        // every other case uses the same memoised order as the other modes.
        let indices = if self.demo && self.preview.sort == 0 {
            let mut indices = self.filtered(cx);
            let featured = ["Northwind Signal", "Saltlight", "Quiet Frequency", "Emberline"];
            indices.sort_by_key(|&i| {
                featured
                    .iter()
                    .position(|s| games[i].title.starts_with(s))
                    .unwrap_or(10 + i)
            });
            if self.reversed {
                indices.reverse();
            }
            indices
        } else {
            self.ordered(cx)
        };
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
            let g = &games[index];
            let mut meta = row().flex_shrink_0().flex_wrap().gap(px(7.)).mt(px(3.));
            if self.demo {
                meta = meta
                    .child(icon("clock-3", 12.).text_color(rgb(MUTED)))
                    .child(muted(if position == 0 {
                        "晚上7:39"
                    } else if position == 1 {
                        "晚上7:37"
                    } else {
                        "下午6:39"
                    }))
                    .child(badge("package", self.bottle_name_at(g.bottle)))
                    .child(badge("clock-3", "8分钟"));
            } else {
                if let Some(label) = crate::model::format_last_played(g.last_played) {
                    meta = meta
                        .child(icon("clock-3", 12.).text_color(rgb(MUTED)))
                        .child(muted(label));
                }
                if g.bottle > 0 {
                    meta = meta.child(badge("package", self.bottle_name_at(g.bottle)));
                }
                if let Some(label) = crate::model::format_play_time(g.play_time) {
                    meta = meta.child(badge("clock-3", label));
                }
            }
            if let Some(state) = self.runtime_state(index) {
                meta = if state == RuntimeState::Running {
                    meta.child(live_badge(self.runtime_badge_label(index, "Running")))
                } else if state.is_active() {
                    meta.child(phase_badge(
                        self.runtime_badge_label(index, state.phase_label()),
                    ))
                } else {
                    meta
                };
            }
            let hover = transition(
                ElementId::from(("timeline-hover", index)),
                if self.hovered == Some(index) {
                    1_f32
                } else {
                    0.0
                },
                self.timing(HOVER_MS),
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
                                        .child(match self.artwork(index) {
                                            Some(path) => img(path)
                                                .size_full()
                                                .object_fit(ObjectFit::Cover)
                                                .into_any_element(),
                                            None => div()
                                                .size_full()
                                                .bg(gradient(0xffffff12, 0xffffff04))
                                                .flex()
                                                .items_center()
                                                .justify_center()
                                                .child(
                                                    icon("package", 26.)
                                                        .text_color(rgb(MUTED)),
                                                )
                                                .into_any_element(),
                                        })
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
                                                .child(g.title.clone()),
                                        )
                                        .when(self.demo || g.studio.is_some(), |d| {
                                            d.child(
                                                muted(g.studio())
                                                    .flex_shrink_0()
                                                    .truncate(),
                                            )
                                        })
                                        .child(meta)
                                        .when(g.description.is_some(), |d| {
                                            d.child(
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
                                                            .as_deref()
                                                            .unwrap_or_default()
                                                            .split_whitespace()
                                                            .collect::<Vec<_>>()
                                                            .join(" "),
                                                    ),
                                            )
                                        }),
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
                                            index,
                                            "继续游玩",
                                            cx,
                                        ))
                                        .child(self.game_options(index, cx)),
                                ),
                        ),
                ),
            );
        }
        if indices.is_empty() {
            content = content.child(muted(self.empty_library_message()).p(px(30.)));
        }
        self.library_viewport(1, content)
    }
    pub(crate) fn classic(&self, width: f32, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let indices = self.ordered(cx);
        let layout = LibraryLayout::classic(&indices, width);
        let mut content = div()
            .relative()
            .w_full()
            .h(px(layout.height.max(100.)))
            .flex_shrink_0();
        for (i, target) in layout.cards {
            let rect = self.animated_rect(i, target, window, cx);
            // The demo always rendered the studio line, even when it was empty.
            let studio = self
                .game(i)
                .map(|game| game.studio.clone().unwrap_or_default());
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
                        .when(self.demo || studio.is_some(), |d| {
                            d.child(
                                muted(studio.clone().unwrap_or_default())
                                    .flex_1()
                                    .min_w_0()
                                    .truncate(),
                            )
                        })
                        .child(self.play_button(("classic-play", i), i, "游玩", cx)),
                );
            content = content.child(self.card_slot(i, rect, card));
        }
        if indices.is_empty() {
            content = content.child(muted(self.empty_library_message()).p(px(30.)));
        }
        self.library_viewport(2, content)
    }
    /// Rating control for the detail panel: five stars with half-star steps,
    /// which maps onto the 1–10 stored value. Re-clicking the current value
    /// writes `null`, matching "unrated" in the SwiftUI menu.
    fn rating_row(&self, index: usize, cx: &mut Context<Self>) -> AnyElement {
        const STAR: f32 = 20.;
        let current = self.game(index).and_then(|game| game.rating);
        let value = current.map_or(0, |rating| rating.min(10));
        let mut stars = row().gap(px(2.));
        for slot in 0..5_u8 {
            // Points covered by this star: 0, 1 (half) or 2 (full).
            let covered = value.saturating_sub(slot * 2).min(2);
            let half = |id: usize, points: u8, left: f32| {
                div()
                    .id(("rating", index * 32 + id))
                    .absolute()
                    .left(px(left))
                    .top(px(0.))
                    .w(px(STAR / 2.))
                    .h(px(STAR))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| this.set_rating(index, points, cx)))
            };
            stars = stars.child(
                div()
                    .relative()
                    .w(px(STAR))
                    .h(px(STAR))
                    .child(icon("star", STAR).text_color(rgba(0xffffff26)))
                    .child(
                        div()
                            .absolute()
                            .top(px(0.))
                            .left(px(0.))
                            .h(px(STAR))
                            .w(px(STAR * f32::from(covered) / 2.))
                            .overflow_hidden()
                            .child(div().w(px(STAR)).h(px(STAR)).child(icon("star", STAR).text_color(rgb(ACCENT)))),
                    )
                    .child(half(usize::from(slot) * 2, slot * 2 + 1, 0.))
                    .child(half(usize::from(slot) * 2 + 1, slot * 2 + 2, STAR / 2.)),
            );
        }
        row()
            .gap(px(10.))
            .items_center()
            .child(muted("评分"))
            .child(stars)
            .child(
                muted(current.map_or_else(|| "未评分".to_owned(), |rating| format!("{rating} / 10")))
                    .text_size(px(12.)),
            )
            .into_any_element()
    }

    pub(crate) fn detail_panel(
        &self,
        index: usize,
        progress: f32,
        width: f32,
        height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(g) = self.game(index) else {
            return div().into_any_element();
        };
        let backdrop = self.ambient_art(index);
        let artwork = self.artwork(index);
        let mut badges = row().gap(px(8.)).mt(px(8.));
        if self.demo {
            badges = badges
                .child(badge("package", "galgame"))
                .child(badge("star", "8 / 10"));
        } else {
            if g.bottle > 0 {
                badges = badges.child(badge("package", self.bottle_name_at(g.bottle)));
            }
            if let Some(year) = g.year() {
                badges = badges.child(badge("calendar", year));
            }
            if let Some(rating) = g.rating {
                badges = badges.child(badge("star", format!("{rating} / 10")));
            }
            if let Some(play_time) = crate::model::format_play_time(g.play_time) {
                badges = badges.child(badge("clock-3", play_time));
            }
            if let Some(last_played) = crate::model::format_last_played(g.last_played) {
                badges = badges.child(badge("clock-3", last_played));
            }
        }
        if let Some(state) = self.runtime_state(index) {
            badges = if state == RuntimeState::Running {
                badges.child(live_badge(self.runtime_badge_label(index, "Running")))
            } else if state.is_active() {
                badges.child(phase_badge(
                    self.runtime_badge_label(index, state.phase_label()),
                ))
            } else {
                badges
            };
        }
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
                    // Keep clicks inside the panel from reaching the dismiss layer.
                    .occlude()
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
                        div()
                            .absolute()
                            .size_full()
                            .when_some(backdrop, |d, path| {
                                d.child(
                                    img(path)
                                        .size_full()
                                        .object_fit(ObjectFit::Cover)
                                        .opacity(0.22),
                                )
                            }),
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
                                            .child(match artwork {
                                                Some(path) => img(path)
                                                    .w(px(190.))
                                                    .h(px(278.))
                                                    .flex_shrink_0()
                                                    .rounded(px(9.))
                                                    .object_fit(ObjectFit::Cover)
                                                    .into_any_element(),
                                                None => div()
                                                    .w(px(190.))
                                                    .h(px(278.))
                                                    .flex_shrink_0()
                                                    .rounded(px(9.))
                                                    .bg(gradient(0xffffff12, 0xffffff04))
                                                    .flex()
                                                    .items_center()
                                                    .justify_center()
                                                    .child(
                                                        icon("package", 34.)
                                                            .text_color(rgb(MUTED)),
                                                    )
                                                    .into_any_element(),
                                            })
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
                                                            .child(g.title.clone()),
                                                    )
                                                    .when(self.demo || g.studio.is_some(), |d| {
                                                        d.child(
                                                            muted(g.studio())
                                                                .text_size(px(14.)),
                                                        )
                                                    })
                                                    .when(g.release.is_some(), |d| {
                                                        d.child(muted(
                                                            g.release.clone().unwrap_or_default(),
                                                        ))
                                                    })
                                                    .child(badges)
                                                    .when(!self.demo, |d| {
                                                        d.child(self.rating_row(index, cx))
                                                    })
                                                    .child(div().mt(px(12.)).child(
                                                        self.play_button(
                                                            "detail-play",
                                                            index,
                                                            "继续游玩",
                                                            cx,
                                                        ),
                                                    ))
                                                    .when(!self.demo, |d| {
                                                        d.child(
                                                            row()
                                                                .gap(px(8.))
                                                                .child(
                                                                    Button::new("detail-game-info")
                                                                        .label("游戏资料与封面…")
                                                                        .on_click(cx.listener(
                                                                            move |this, _, _, cx| {
                                                                                this.open_game_info(index, cx);
                                                                            },
                                                                        )),
                                                                )
                                                                .child(
                                                                    Button::new("detail-game-config")
                                                                        .label("GameDB 推荐配置…")
                                                                        .on_click(cx.listener(
                                                                            move |this, _, _, cx| {
                                                                                this.open_game_info(index, cx);
                                                                            },
                                                                        )),
                                                                ),
                                                        )
                                                    }),
                                            ),
                                    )
                                    .when_some(g.description.clone(), |d, description| {
                                        d.child(
                                            col()
                                                .flex_shrink_0()
                                                .gap(px(12.))
                                                .p(px(20.))
                                                .rounded(px(12.))
                                                .bg(rgba(0xffffff09))
                                                .child(
                                                    row().justify_between()
                                                        .child(div().font_weight(FontWeight::SEMIBOLD).child("简介"))
                                                        .when_some(g.metadata_sources.get("summary").cloned(), |row, source| {
                                                            row.child(muted(source).text_size(px(11.)))
                                                        }),
                                                )
                                                .child(
                                                    div()
                                                        .text_size(px(13.))
                                                        .text_color(rgb(0xc3c3ca))
                                                        .line_height(relative(1.65))
                                                        .child(description),
                                                ),
                                        )
                                    })
                                    .when(!g.characters.is_empty(), |d| {
                                        let mut characters = col().flex_shrink_0().gap(px(12.))
                                            .p(px(20.)).rounded(px(12.)).bg(rgba(0xffffff09))
                                            .child(row().justify_between()
                                                .child(div().font_weight(FontWeight::SEMIBOLD).child("人物"))
                                                .when_some(g.metadata_sources.get("characters").cloned(), |row, source| {
                                                    row.child(muted(source).text_size(px(11.)))
                                                }));
                                        for character in &g.characters {
                                            let role = match character.role.as_deref() {
                                                Some("main") => "主要角色",
                                                Some("primary") => "主角",
                                                Some("side") => "配角",
                                                Some("appears") => "登场角色",
                                                Some(role) => role,
                                                None => "",
                                            };
                                            characters = characters.child(row().gap(px(12.))
                                                .child(col().flex_1().gap(px(3.))
                                                    .child(character.name.clone())
                                                    .when_some(character.original_name.clone().filter(|name| name != &character.name), |col, name| {
                                                        col.child(muted(name).text_size(px(11.)))
                                                    }))
                                                .child(muted(role.to_owned()).text_size(px(11.))));
                                        }
                                        d.child(characters)
                                    }),
                            ),
                        ),
                    ),
            )
            .into_any_element()
    }
}
