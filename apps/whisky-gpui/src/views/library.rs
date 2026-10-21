//! Library surface: sidebar, toolbar, three presentations, and the detail panel.

use std::time::Duration;

use gpui_kit::base::{Spring, spring, transition};
use gpui_kit::component::{button::Button, menu::ContextMenuExt};
use gpui_kit::{prelude::*, *};

use crate::controls::*;
use crate::library_layout::{CardRect, LibraryLayout};
use crate::model::{ambient, art, demo_data};
use crate::state::{PreviewPage, WhiskyApp};
use crate::theme::*;

impl WhiskyApp {
    pub(crate) fn sidebar(&self, cx: &mut Context<Self>) -> AnyElement {
        let games = demo_data();
        let mut entries = col().gap(px(1.));
        for (id, label, symbol, bottle, count) in [
            (
                "library",
                "Library",
                "layout-grid",
                0,
                games.len().to_string(),
            ),
            (
                "bottle-one",
                "galgame",
                "package",
                1,
                games.iter().filter(|g| g.bottle == 1).count().to_string(),
            ),
            (
                "bottle-two",
                "galgame-win7",
                "package",
                2,
                games.iter().filter(|g| g.bottle == 2).count().to_string(),
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
                    this.open_preview_sheet(crate::state::PreviewSheet::CreateBottle, cx)
                })),
            )
            .when(
                self.preview.page == PreviewPage::Library && !self.settings,
                |d| {
                    d.child(modes).child(
                        Button::new("reorder-library")
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
                    .child(gpui_kit::component::input::Input::new(&self.search)),
            )
    }
    pub(crate) fn backdrop(&self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        // Per-image channels preserve continuous blending even during rapid A → B → C hovers.
        let mut layers = div().absolute().size_full().overflow_hidden().bg(rgb(BG));
        for i in 0..demo_data().len() {
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
                    .child(demo_data()[index].title),
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
            self.mixed && demo_data()[i].landscape
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
            content = content.child(muted("没有找到匹配的游戏").p(px(30.)));
        }
        self.library_viewport(0, content)
    }
    pub(crate) fn play_button(
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
    pub(crate) fn timeline(&self, width: f32, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let games = demo_data();
        let mut indices = self.filtered(cx);
        // Presentation ordering and sample times; no personal activity records are read.
        let featured = ["Northwind Signal", "Saltlight", "Quiet Frequency", "Emberline"];
        indices.sort_by_key(|&i| {
            featured
                .iter()
                .position(|s| games[i].title.starts_with(s))
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
            let g = games[index];
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
                        .child(muted(demo_data()[i].studio).flex_1().min_w_0().truncate())
                        .child(self.play_button(("classic-play", i), "游玩", cx)),
                );
            content = content.child(self.card_slot(i, rect, card));
        }
        self.library_viewport(2, content)
    }
    pub(crate) fn detail_panel(
        &self,
        index: usize,
        progress: f32,
        width: f32,
        height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let g = demo_data()[index];
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
