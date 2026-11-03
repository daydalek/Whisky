//! Immersive library presentation: an Apple TV-style full-bleed hero carousel
//! over horizontally scrolling game rows. Selection logic lives in
//! `crate::immersive`; this file only draws.

use gpui_kit::base::transition;
use gpui_kit::component::menu::ContextMenuExt;
use gpui_kit::{prelude::*, *};

use crate::controls::*;
use crate::immersive::{FEATURED_LIMIT, Row};
use crate::runtime::RuntimeState;
use crate::state::WhiskyApp;
use crate::theme::*;

/// Hero slide crossfade.
const SLIDE_MS: u64 = 500;

/// Light text on the artwork scrims; the hero is always dark, whatever the
/// window theme resolves to.
const HERO_TEXT: u32 = 0xf4f4f6;
const HERO_MUTED: u32 = 0xffffffb0;
const HERO_SCRIM: u32 = 0x000000d0;
const HERO_CHIP: u32 = 0xffffff26;
const HERO_CHIP_HOVER: u32 = 0xffffff3d;

impl WhiskyApp {
    /// The whole page: hero plus rows inside the mode's scroll viewport. The
    /// hero scrolls away with the rest, like the TV app.
    pub(crate) fn immersive(
        &self,
        width: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // Covers the persisted-mode launch path: `set_mode` starts the loop
        // for explicit switches, this lazy start for everything else.
        self.ensure_immersive_carousel(cx);
        let games = self.games();
        let ordered = self.ordered(cx);
        if ordered.is_empty() {
            return self.library_viewport(
                3,
                col()
                    .w_full()
                    .flex_shrink_0()
                    .child(muted(self.empty_library_message()).p(px(30.))),
            );
        }
        let featured = crate::immersive::featured(games, &ordered, FEATURED_LIMIT);
        let current = if featured.is_empty() {
            0
        } else {
            self.immersive_slide % featured.len()
        };
        let sections = crate::immersive::rows(
            games,
            &ordered,
            self.selected_bottle,
            self.bottles.len(),
            |slot| self.bottle_name_at(slot).to_owned(),
        );
        let mut content = col().w_full().flex_shrink_0();
        if !featured.is_empty() {
            content =
                content.child(self.immersive_hero(width, &featured, current, window, cx));
        }
        content = content.child(self.immersive_rows(width, &sections, window, cx));
        self.library_viewport(3, content)
    }

    /// Full-bleed crossfading carousel. Art layers sit below the scrims,
    /// content blocks above them, and every layer shares the slide alpha.
    fn immersive_hero(
        &self,
        width: f32,
        featured: &[usize],
        current: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let hero_h = (width * 0.42).clamp(320., 560.);
        let count = featured.len();
        let nav_opacity = transition(
            ElementId::from("immersive-nav"),
            if self.immersive_hero_hovered {
                1_f32
            } else {
                0.
            },
            self.timing(HOVER_MS),
            window,
            cx,
        );
        let mut hero = div()
            .id("immersive-hero")
            .relative()
            .w_full()
            .h(px(hero_h))
            .flex_shrink_0()
            .overflow_hidden()
            .bg(rgb(0x000000))
            .on_hover(cx.listener(|this, active, _, cx| {
                if this.immersive_hero_hovered != *active {
                    this.immersive_hero_hovered = *active;
                    cx.notify();
                }
            }));
        let mut alphas = Vec::with_capacity(count);
        for (position, &index) in featured.iter().enumerate() {
            let alpha = transition(
                ElementId::from(("immersive-slide", position)),
                if position == current { 1_f32 } else { 0. },
                self.timing(SLIDE_MS),
                window,
                cx,
            );
            alphas.push(alpha);
            if alpha > 0.001 {
                hero = hero.child(self.immersive_slide_art(index, alpha, cx));
            }
        }
        // Scrims are shared across slides, so a crossfade never doubles the
        // darkening: a left-to-right gradient for the text block, and a fade
        // to the page background so the hero blends into the rows.
        hero = hero
            .child(
                div().absolute().size_full().bg(linear_gradient(
                    90.,
                    linear_color_stop(rgba(HERO_SCRIM), 0.),
                    linear_color_stop(rgba(0x00000000), 0.6),
                )),
            )
            .child(
                div()
                    .absolute()
                    .bottom_0()
                    .left_0()
                    .w_full()
                    .h(px(90.))
                    .bg(linear_gradient(
                        180.,
                        linear_color_stop(rgba(0x00000000), 0.),
                        linear_color_stop(rgba(bg() << 8 | 0xff), 1.),
                    )),
            );
        for (position, &index) in featured.iter().enumerate() {
            if alphas[position] > 0.001 {
                hero = hero.child(self.immersive_hero_content(
                    index,
                    width,
                    hero_h,
                    alphas[position],
                    cx,
                ));
            }
        }
        if count > 1 {
            let mut dots = row()
                .absolute()
                .bottom(px(24.))
                .left_0()
                .right_0()
                .justify_center()
                .gap(px(7.));
            for position in 0..count {
                let active = position == current;
                dots = dots.child(
                    div()
                        .id(("immersive-dot", position))
                        .h(px(6.))
                        .w(px(if active { 18. } else { 6. }))
                        .rounded_full()
                        .bg(rgba(if active { 0xffffffe6 } else { 0xffffff66 }))
                        .cursor_pointer()
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.set_immersive_slide(position, cx);
                        })),
                );
            }
            hero = hero.child(dots);
            if nav_opacity > 0.001 {
                hero = hero
                    .child(self.immersive_hero_nav(
                        "immersive-prev",
                        "chevron-left",
                        (current + count - 1) % count,
                        true,
                        hero_h,
                        nav_opacity,
                        cx,
                    ))
                    .child(self.immersive_hero_nav(
                        "immersive-next",
                        "chevron-right",
                        (current + 1) % count,
                        false,
                        hero_h,
                        nav_opacity,
                        cx,
                    ));
            }
        }
        hero.into_any_element()
    }

    /// One edge chevron: a translucent circle shown while the hero is hovered.
    fn immersive_hero_nav(
        &self,
        id: &'static str,
        symbol: &'static str,
        slide: usize,
        left: bool,
        hero_h: f32,
        opacity: f32,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        let button = row()
            .id(id)
            .absolute()
            .top(px(hero_h / 2. - 17.))
            .justify_center()
            .size(px(34.))
            .rounded_full()
            .bg(rgba(0x14141699))
            .border_1()
            .border_color(rgba(0xffffff22))
            .text_color(rgb(0xffffff))
            .cursor_pointer()
            .opacity(opacity)
            .on_click(cx.listener(move |this, _, _, cx| {
                this.set_immersive_slide(slide, cx);
            }))
            .child(icon(symbol, 17.));
        if left {
            button.left(px(18.))
        } else {
            button.right(px(18.))
        }
    }

    /// The artwork layer of one slide. Landscape art fills the hero; portrait
    /// art also fills it but stays dimmed, and the content block draws a crisp
    /// poster on the right.
    fn immersive_slide_art(
        &self,
        index: usize,
        alpha: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(game) = self.game(index) else {
            return div().into_any_element();
        };
        let (ph_start, ph_end) = placeholder_gradient();
        div()
            .absolute()
            .size_full()
            .opacity(alpha)
            .child(match self.artwork(index) {
                Some(path) => self.cover_image(path, cx)
                    .absolute()
                    .size_full()
                    .object_fit(ObjectFit::Cover)
                    .opacity(if game.landscape { 1. } else { 0.35 })
                    .into_any_element(),
                None => div()
                    .absolute()
                    .size_full()
                    .bg(gradient(ph_start, ph_end))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(icon("package", 42.).text_color(rgb(muted_color())))
                    .into_any_element(),
            })
            .into_any_element()
    }

    /// Lower-left content of one slide: title, meta line, description and the
    /// Play/详情 pair. Portrait games also get a crisp poster pinned to the
    /// right edge of the hero.
    fn immersive_hero_content(
        &self,
        index: usize,
        width: f32,
        hero_h: f32,
        alpha: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(game) = self.game(index) else {
            return div().into_any_element();
        };
        let mut block = col()
            .absolute()
            .left(px(48.))
            .top(px(110.))
            .bottom(px(64.))
            .w(px((520_f32).min(width * 0.45)))
            .justify_center()
            .gap(px(10.))
            .opacity(alpha);
        if let Some(state) = self.runtime_state(index) {
            if state == RuntimeState::Running {
                block = block.child(live_badge(self.runtime_badge_label(index, "Running")));
            } else if state.is_active() {
                block =
                    block.child(phase_badge(self.runtime_badge_label(index, state.phase_label())));
            }
        }
        block = block.child(
            div()
                .flex_shrink_0()
                .text_size(px(if width < 1000. { 30. } else { 40. }))
                .line_height(relative(1.15))
                .font_weight(FontWeight::BOLD)
                .text_color(rgb(HERO_TEXT))
                .line_clamp(2)
                .child(game.title.clone()),
        );
        let mut meta: Vec<String> = Vec::new();
        let studio = game.studio();
        if !studio.is_empty() {
            meta.push(studio.to_owned());
        }
        if let Some(year) = game.year() {
            meta.push(year.to_owned());
        }
        if game.bottle > 0 {
            let name = self.bottle_name_at(game.bottle);
            if !name.is_empty() {
                meta.push(name.to_owned());
            }
        }
        if let Some(play_time) = crate::model::format_play_time(game.play_time) {
            meta.push(play_time);
        }
        if !meta.is_empty() {
            block = block.child(
                div()
                    .flex_shrink_0()
                    .text_size(px(13.))
                    .text_color(rgba(HERO_MUTED))
                    .truncate()
                    .child(meta.join(" · ")),
            );
        }
        if let Some(description) = &game.description {
            block = block.child(
                div()
                    .flex_shrink_0()
                    .text_size(px(13.))
                    .text_color(rgba(HERO_MUTED))
                    .line_height(relative(1.5))
                    .line_clamp(3)
                    .child(
                        description
                            .split_whitespace()
                            .collect::<Vec<_>>()
                            .join(" "),
                    ),
            );
        }
        block = block.child(
            row()
                .flex_shrink_0()
                .gap(px(10.))
                .pt(px(4.))
                .child(self.play_button(
                    ("immersive-play", index),
                    index,
                    "继续游玩",
                    cx,
                ))
                .child(
                    row()
                        .id(("immersive-detail", index))
                        .flex_shrink_0()
                        .justify_center()
                        .gap(px(6.))
                        .px(px(14.))
                        .h(px(30.))
                        .rounded_full()
                        .bg(rgba(HERO_CHIP))
                        .text_size(px(12.))
                        .font_weight(FontWeight::BOLD)
                        .text_color(rgb(0xffffff))
                        .cursor_pointer()
                        .hover(|s| s.bg(rgba(HERO_CHIP_HOVER)))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.open_detail(index, cx);
                        }))
                        .child(icon("info", 13.))
                        .child("详情"),
                ),
        );
        let mut layer = div().absolute().size_full().child(block);
        if !game.landscape
            && let Some(path) = self.artwork(index)
        {
            let poster_h = hero_h - 72.;
            layer = layer.child(
                div()
                    .absolute()
                    .right(px(56.))
                    .top(px(36.))
                    .w(px(poster_h * 2. / 3.))
                    .h(px(poster_h))
                    .rounded(px(10.))
                    .overflow_hidden()
                    .shadow_xl()
                    .opacity(alpha)
                    .child(
                        self.cover_image(path, cx)
                            .size_full()
                            .object_fit(ObjectFit::Cover),
                    ),
            );
        }
        layer.into_any_element()
    }

    /// The section stack under the hero: headers plus horizontally scrolling
    /// card strips.
    fn immersive_rows(
        &self,
        width: f32,
        sections: &[Row],
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mut stack = col()
            .w_full()
            .flex_shrink_0()
            .px(px(48.))
            .pt(px(10.))
            .pb(px(40.))
            .gap(px(28.));
        for section in sections {
            let key = section.key.name();
            let handle = self
                .immersive_row_scrolls
                .borrow_mut()
                .entry(key.clone())
                .or_insert_with(ScrollHandle::new)
                .clone();
            let header = row()
                .items_center()
                .gap(px(10.))
                .child(
                    div()
                        .text_size(px(17.))
                        .font_weight(FontWeight::BOLD)
                        .child(section.title.clone()),
                )
                .child(
                    muted(section.indices.len().to_string())
                        .text_size(px(11.))
                        .mt(px(4.)),
                )
                .child(div().flex_1())
                .child(self.immersive_row_chevron(
                    format!("immersive-row-prev-{key}"),
                    "chevron-left",
                    handle.clone(),
                    -1.,
                    cx,
                ))
                .child(self.immersive_row_chevron(
                    format!("immersive-row-next-{key}"),
                    "chevron-right",
                    handle.clone(),
                    1.,
                    cx,
                ));
            let mut strip = row()
                .id(SharedString::from(format!("immersive-row-{key}")))
                .items_start()
                .gap(px(16.))
                .track_scroll(&handle)
                .overflow_x_scroll()
                // The strip is x-only: a vertical wheel over a row must keep
                // scrolling the page. Without this, GPUI maps the y delta to
                // the row's x axis and the cards drift sideways.
                .restrict_scroll_to_axis()
                // The page's vertical scroller would still translate the same
                // horizontal gesture into vertical motion, so stop the event
                // once the strip claims it.
                .on_scroll_wheel(|event: &ScrollWheelEvent, window, cx| {
                    let delta = event.delta.pixel_delta(window.line_height());
                    if delta.x.abs() > delta.y.abs() {
                        cx.stop_propagation();
                    }
                });
            for &index in &section.indices {
                strip = strip.child(self.immersive_card(&key, index, width, window, cx));
            }
            stack = stack.child(
                col()
                    .w_full()
                    .flex_shrink_0()
                    .gap(px(10.))
                    .child(header)
                    .child(strip),
            );
        }
        stack.into_any_element()
    }

    /// Header chevron scrolling its strip by ~80% of the visible width,
    /// clamped to the scrollable range.
    fn immersive_row_chevron(
        &self,
        id: String,
        symbol: &'static str,
        handle: ScrollHandle,
        direction: f32,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        row()
            .id(SharedString::from(id))
            .justify_center()
            .size(px(26.))
            .rounded_full()
            .bg(rgba(round_btn_bg()))
            .border_1()
            .border_color(rgba(round_btn_border()))
            .cursor_pointer()
            .hover(|s| s.bg(rgba(round_btn_hover())))
            .on_click(cx.listener(move |_, _, _, cx| {
                let step = f32::from(handle.bounds().size.width) * 0.8;
                let offset = f32::from(handle.offset().x);
                let max = f32::from(handle.max_offset().x);
                handle.set_offset(point(
                    px((offset - direction * step).clamp(-max, 0.)),
                    px(0.),
                ));
                cx.notify();
            }))
            .child(icon(symbol, 15.))
    }

    /// One card plus the title/subtitle pair underneath. Element ids carry the
    /// row key because the same game can appear in two rows at once.
    fn immersive_card(
        &self,
        row_key: &str,
        index: usize,
        width: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(game) = self.game(index) else {
            return div().into_any_element();
        };
        let compact = width < 1000.;
        let card_h = if compact { 192. } else { 225. };
        let card_w = if game.landscape {
            card_h * 16. / 9.
        } else {
            card_h * 2. / 3.
        };
        let hovering = self.hovered == Some(index) && !self.detail_open;
        let amount = transition(
            ElementId::from(format!("immersive-card-hover-{row_key}-{index}")),
            if hovering { 1_f32 } else { 0. },
            self.timing(HOVER_MS),
            window,
            cx,
        );
        // Frame stays fixed; only the artwork grows.
        let iw = card_w * (1. + amount * 0.04);
        let ih = card_h * (1. + amount * 0.04);
        let artwork = self.artwork(index);
        let (ph_start, ph_end) = placeholder_gradient();
        let card = div()
            .id(SharedString::from(format!("immersive-card-{row_key}-{index}")))
            .relative()
            .w(px(card_w))
            .h(px(card_h))
            .flex_shrink_0()
            .rounded(px(10.))
            .overflow_hidden()
            .border_1()
            .border_color(rgba(if hovering {
                if is_dark() {
                    0xffffff65
                } else {
                    0x00000045
                }
            } else {
                surface_border()
            }))
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
                Some(path) => self.cover_image(path, cx)
                    .absolute()
                    .left(px((card_w - iw) / 2.))
                    .top(px((card_h - ih) / 2.))
                    .w(px(iw))
                    .h(px(ih))
                    .object_fit(ObjectFit::Cover)
                    .into_any_element(),
                None => div()
                    .absolute()
                    .size_full()
                    .bg(gradient(ph_start, ph_end))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(icon("package", 26.).text_color(rgb(muted_color())))
                    .into_any_element(),
            })
            // Running and pending states stay visible; the idle affordance
            // waits for hover, matching the shelf covers.
            .child(match self.runtime_state(index) {
                Some(RuntimeState::Running) => live_badge(self.runtime_badge_label(index, "Running"))
                    .absolute()
                    .top(px(9.))
                    .right(px(9.))
                    .into_any_element(),
                Some(state) if state.is_active() => {
                    phase_badge(self.runtime_badge_label(index, state.phase_label()))
                        .absolute()
                        .top(px(9.))
                        .right(px(9.))
                        .into_any_element()
                }
                _ => self.play_circle(
                    ElementId::from(format!("immersive-card-play-{row_key}-{index}")),
                    index,
                    amount,
                    cx,
                ),
            })
            .context_menu(self.game_menu(index, cx));
        let mut subtitle: Vec<String> = Vec::new();
        if game.bottle > 0 {
            let name = self.bottle_name_at(game.bottle);
            if !name.is_empty() {
                subtitle.push(name.to_owned());
            }
        }
        let activity = game
            .last_session_ended_at
            .or(game.last_played)
            .and_then(|unix| crate::model::format_last_played(Some(unix)))
            .or_else(|| crate::model::format_play_time(game.play_time));
        if let Some(activity) = activity {
            subtitle.push(activity);
        }
        col()
            .w(px(card_w))
            .flex_shrink_0()
            .gap(px(5.))
            .child(card)
            .child(
                div()
                    .w_full()
                    .truncate()
                    .text_size(px(13.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(game.title.clone()),
            )
            .child(
                muted(subtitle.join(" · "))
                    .w_full()
                    .truncate()
                    .text_size(px(11.)),
            )
            .into_any_element()
    }
}
