use gpui_kit::component::menu::ContextMenuExt;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::{prelude::*, *};

use crate::controls::*;
use crate::gallery::GalleryLayout;
use crate::runtime::RuntimeState;
use crate::state::{PreviewSheet, WhiskyApp};
use crate::theme::*;

fn summary_field(label: &'static str, value: String) -> AnyElement {
    col()
        .w_full()
        .flex_shrink_0()
        .gap(px(4.))
        .child(muted(label))
        .child(div().text_size(px(13.)).line_clamp(2).child(value))
        .into_any_element()
}

fn detail_pane(content: AnyElement) -> AnyElement {
    div()
        .w_full()
        .flex_shrink_0()
        .rounded(px(16.))
        .bg(rgb(crate::theme::surface()))
        .border_1()
        .border_color(rgba(surface_border()))
        .child(content)
        .into_any_element()
}

impl WhiskyApp {
    pub(crate) fn gallery(
        &self,
        width: f32,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let games = self.games();
        let indices = self.ordered(cx);
        let Some(selected) =
            crate::gallery::selected_index(games, &indices, self.gallery_selection.as_ref())
        else {
            return self.library_viewport(
                4,
                col()
                    .w_full()
                    .flex_shrink_0()
                    .child(muted(self.empty_library_message()).p(px(30.))),
            );
        };
        let layout = GalleryLayout::new(width);
        let wall = self.gallery_wall(&indices, selected, layout, cx);
        let summary = detail_pane(self.gallery_summary(selected, layout.detail_width, cx));
        if layout.stacked {
            self.library_viewport(
                4,
                col()
                    .w_full()
                    .flex_shrink_0()
                    .p(px(20.))
                    .gap(px(20.))
                    .child(summary)
                    .child(wall),
            )
        } else {
            row()
                .size_full()
                .min_h_0()
                .items_start()
                .p(px(20.))
                .gap(px(20.))
                .child(
                    div()
                        .w(px(layout.wall_width))
                        .h_full()
                        .min_h_0()
                        .child(self.library_viewport(4, wall)),
                )
                .child(div().w(px(layout.detail_width)).h_full().min_h_0().child(
                    self.bouncing_scroll("gallery-detail", &self.gallery_detail_scroll, summary),
                ))
                .into_any_element()
        }
    }

    fn gallery_wall(
        &self,
        indices: &[usize],
        selected: usize,
        layout: GalleryLayout,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let heading: SharedString = if self.selected_bottle.is_some() {
            self.bottle_name().to_owned().into()
        } else {
            "全部游戏".into()
        };
        let mut grid = col().w_full().flex_shrink_0().gap(px(12.));
        for strip_indices in indices.chunks(layout.columns) {
            let mut strip = row().items_start().gap(px(12.));
            for &index in strip_indices {
                strip = strip.child(self.gallery_card(
                    index,
                    index == selected,
                    layout.card_width,
                    layout.card_height,
                    cx,
                ));
            }
            grid = grid.child(strip);
        }
        col()
            .w_full()
            .flex_shrink_0()
            .gap(px(14.))
            .child(
                row()
                    .items_baseline()
                    .gap(px(8.))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(px(17.))
                            .font_weight(FontWeight::BOLD)
                            .child(heading),
                    )
                    .child(muted(indices.len().to_string()).text_size(px(11.))),
            )
            .child(grid)
            .into_any_element()
    }

    fn gallery_card(
        &self,
        index: usize,
        selected: bool,
        width: f32,
        height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(game) = self.game(index) else {
            return div().into_any_element();
        };
        let title = game.title.clone();
        let artwork = self.artwork(index);
        let (ph_start, ph_end) = placeholder_gradient();
        div()
            .id(("gallery-card", index))
            .relative()
            .w(px(width))
            .h(px(height))
            .flex_shrink_0()
            .rounded(px(10.))
            .overflow_hidden()
            .border_2()
            .border_color(if selected {
                rgb(ACCENT).into()
            } else {
                rgba(surface_border())
            })
            .cursor_pointer()
            .on_hover(cx.listener(move |this, active, _, cx| {
                if *active {
                    this.hovered = Some(index);
                } else if this.hovered == Some(index) {
                    this.hovered = None;
                }
                cx.notify();
            }))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.select_gallery_game(index, cx);
            }))
            .child(match artwork {
                Some(path) => self.cover_image(path, cx)
                    .absolute()
                    .size_full()
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
            .child(
                div()
                    .absolute()
                    .bottom_0()
                    .left_0()
                    .right_0()
                    .h(px(30.))
                    .bg(gradient(0x00000000, 0x000000a8)),
            )
            .child(
                div()
                    .absolute()
                    .bottom(px(5.))
                    .left(px(8.))
                    .right(px(8.))
                    .text_size(px(11.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(rgb(0xf4f4f6))
                    .truncate()
                    .child(title.clone()),
            )
            .child(match self.runtime_state(index) {
                Some(RuntimeState::Running) => {
                    live_badge(self.runtime_badge_label(index, "Running"))
                        .absolute()
                        .top(px(7.))
                        .right(px(7.))
                        .into_any_element()
                }
                Some(state) if state.is_active() => {
                    phase_badge(self.runtime_badge_label(index, state.phase_label()))
                        .absolute()
                        .top(px(7.))
                        .right(px(7.))
                        .into_any_element()
                }
                _ => div().into_any_element(),
            })
            .when(selected, |d| {
                d.child(
                    div()
                        .absolute()
                        .top(px(7.))
                        .left(px(7.))
                        .size(px(18.))
                        .rounded_full()
                        .bg(rgb(ACCENT))
                        .flex()
                        .items_center()
                        .justify_center()
                        .child(icon("check", 11.).text_color(rgb(0xffffff))),
                )
            })
            .tooltip(move |_, cx| cx.new(|_| Tooltip::new(title.clone())).into())
            .context_menu(self.game_menu(index, cx))
            .into_any_element()
    }

    fn gallery_summary(&self, index: usize, width: f32, cx: &mut Context<Self>) -> AnyElement {
        let Some(game) = self.game(index) else {
            return div().into_any_element();
        };
        let hero_height = ((width - 32.) * 0.60).clamp(150., 300.);
        let artwork = self.artwork(index);
        let (ph_start, ph_end) = placeholder_gradient();
        let mut meta: Vec<String> = Vec::new();
        let studio = game.studio();
        if !studio.is_empty() {
            meta.push(studio.to_owned());
        }
        if let Some(year) = game.year() {
            meta.push(year.to_owned());
        }
        let bottle = if game.bottle > 0 {
            let name = self.bottle_name_at(game.bottle);
            if name.is_empty() {
                "未关联容器".to_owned()
            } else {
                name.to_owned()
            }
        } else {
            "未关联容器".to_owned()
        };
        let last_played =
            crate::model::format_last_played(game.last_session_ended_at.or(game.last_played))
                .unwrap_or_else(|| "尚无游玩记录".to_owned());
        let mut badges = row().flex_shrink_0().flex_wrap().gap(px(7.));
        badges = badges.child(badge("package", "Wine"));
        if let Some(state) = self.runtime_state(index) {
            if state == RuntimeState::Running {
                badges = badges.child(live_badge(self.runtime_badge_label(index, "Running")));
            } else if state.is_active() {
                badges = badges.child(phase_badge(
                    self.runtime_badge_label(index, state.phase_label()),
                ));
            }
        }
        col()
            .w_full()
            .flex_shrink_0()
            .p(px(16.))
            .gap(px(12.))
            .child(
                div()
                    .w_full()
                    .h(px(hero_height))
                    .flex_shrink_0()
                    .rounded(px(12.))
                    .overflow_hidden()
                    .bg(rgba(card_bg()))
                    .child(match artwork {
                        Some(path) => self.cover_image(path, cx)
                            .size_full()
                            .object_fit(if game.landscape {
                                ObjectFit::Cover
                            } else {
                                ObjectFit::Contain
                            })
                            .into_any_element(),
                        None => div()
                            .size_full()
                            .bg(gradient(ph_start, ph_end))
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(icon("package", 32.).text_color(rgb(muted_color())))
                            .into_any_element(),
                    }),
            )
            .child(
                div()
                    .text_size(px(28.))
                    .line_height(relative(1.15))
                    .font_weight(FontWeight::BOLD)
                    .line_clamp(3)
                    .child(game.title.clone()),
            )
            .when(!meta.is_empty(), |d| {
                d.child(muted(meta.join(" · ")).truncate())
            })
            .child(badges)
            .child(summary_field("运行环境", bottle))
            .child(summary_field("上次游玩", last_played))
            .when_some(
                crate::model::format_play_time(game.play_time),
                |d, play_time| d.child(summary_field("累计游玩", play_time)),
            )
            .child(
                self.play_button(("gallery-play", index), index, "启动游戏", cx)
                    .w_full()
                    .h(px(44.)),
            )
            .child(
                row()
                    .id(("gallery-settings", index))
                    .w_full()
                    .h(px(44.))
                    .flex_shrink_0()
                    .justify_center()
                    .gap(px(6.))
                    .rounded_full()
                    .border_1()
                    .border_color(rgba(surface_border()))
                    .cursor_pointer()
                    .hover(|s| s.bg(rgba(hover())))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.open_preview_sheet(PreviewSheet::RunSettings(index), cx);
                    }))
                    .child(icon("sliders-horizontal", 15.))
                    .child(
                        div()
                            .text_size(px(12.))
                            .font_weight(FontWeight::BOLD)
                            .child("游戏设置"),
                    ),
            )
            .child(
                row()
                    .id(("gallery-details-link", index))
                    .w_full()
                    .h(px(30.))
                    .flex_shrink_0()
                    .justify_center()
                    .rounded_full()
                    .cursor_pointer()
                    .hover(|s| s.bg(rgba(hover())))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.open_detail(index, cx);
                    }))
                    .child(muted("查看完整详情")),
            )
            .into_any_element()
    }
}
