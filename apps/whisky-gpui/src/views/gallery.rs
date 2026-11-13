use gpui_kit::component::menu::ContextMenuExt;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::{prelude::*, *};

use crate::controls::*;
use crate::gallery::GalleryLayout;
use crate::runtime::RuntimeState;
use crate::state::{PreviewSheet, WhiskyApp};
use crate::theme::*;

/// One row of the summary's info card: a muted icon and label on the left,
/// the caller's value element pinned to the right edge.
fn info_row(icon_name: &'static str, label: &'static str, value: AnyElement) -> Div {
    row()
        .h(px(30.))
        .gap(px(8.))
        .flex_shrink_0()
        .child(icon(icon_name, 13.).text_color(rgb(muted_color())))
        .child(muted(label).text_size(px(12.)))
        .child(div().flex_1().min_w_0())
        .child(value)
}

fn info_value(value: String) -> Div {
    div()
        .flex_shrink_0()
        .max_w(px(160.))
        .truncate()
        .text_size(px(12.))
        .font_weight(FontWeight::MEDIUM)
        .child(value)
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
            return self.library_viewport(4, self.library_empty_surface(cx));
        };
        let layout = GalleryLayout::new(width);
        let wall = self.gallery_wall(&indices, selected, layout, cx);
        let summary =
            detail_pane(self.gallery_summary(selected, layout.detail_width, !layout.stacked, cx));
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
                    live_badge(self.runtime_badge_label(index, "运行中"))
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

    /// `fill` stretches the column to the pane's full height so the action
    /// block pins to the bottom; the stacked layout keeps natural height.
    fn gallery_summary(
        &self,
        index: usize,
        width: f32,
        fill: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
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
        let week_seconds = {
            let cutoff = chrono::Local::now().date_naive() - chrono::Duration::days(7);
            game.daily_play_time
                .iter()
                .filter(|(day, _)| {
                    chrono::NaiveDate::parse_from_str(day, "%Y-%m-%d")
                        .is_ok_and(|date| date > cutoff)
                })
                .map(|(_, secs)| *secs)
                .sum::<f64>() as u64
        };
        let week_play = (week_seconds > 0)
            .then(|| crate::model::format_play_time(Some(week_seconds)))
            .flatten();
        let install_dir = game.game_directory();
        let mut badges = row().flex_shrink_0().flex_wrap().gap(px(7.));
        badges = badges.child(badge("package", "Wine"));
        if let Some(state) = self.runtime_state(index) {
            if state == RuntimeState::Running {
                badges = badges.child(live_badge(self.runtime_badge_label(index, "运行中")));
            } else if state.is_active() {
                badges = badges.child(phase_badge(
                    self.runtime_badge_label(index, state.phase_label()),
                ));
            }
        }
        col()
            .w_full()
            .when(fill, |d| d.h_full())
            .when(!fill, |d| d.flex_shrink_0())
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
            .when_some(game.description.clone(), |d, description| {
                d.child(
                    div()
                        .w_full()
                        .flex_shrink_0()
                        .rounded(px(10.))
                        .bg(rgba(section_bg()))
                        .border_1()
                        .border_color(rgba(section_border()))
                        .px(px(10.))
                        .py(px(8.))
                        .text_size(px(12.))
                        .line_height(px(17.))
                        .text_color(rgb(subtext()))
                        .line_clamp(5)
                        .child(description),
                )
            })
            .child({
                // Grouped info card: icon + label on the left, value on the
                // right, hairlines between rows.
                let mut info_rows: Vec<AnyElement> = vec![
                    info_row("star", "评分", {
                        let value = game.rating.map_or_else(
                            || "未评分".to_owned(),
                            |rating| format!("{} / 10", rating.min(10)),
                        );
                        row()
                            .flex_shrink_0()
                            .items_center()
                            .gap(px(8.))
                            .child(self.rating_stars(index, 14., cx))
                            .child(muted(value).text_size(px(12.)))
                            .into_any_element()
                    })
                    .into_any_element(),
                    info_row("container", "运行环境", info_value(bottle).into_any_element())
                        .into_any_element(),
                    info_row("clock", "上次游玩", info_value(last_played).into_any_element())
                        .into_any_element(),
                ];
                if let Some(play_time) = crate::model::format_play_time(game.play_time) {
                    info_rows.push(
                        info_row("hourglass", "累计游玩", info_value(play_time).into_any_element())
                            .into_any_element(),
                    );
                }
                if let Some(play_time) = week_play {
                    info_rows.push(
                        info_row(
                            "calendar-clock",
                            "近 7 天游玩",
                            info_value(play_time).into_any_element(),
                        )
                        .into_any_element(),
                    );
                }
                if let Some(dir) = install_dir {
                    info_rows.push(
                        row()
                            .id(("gallery-install-dir", index))
                            .h(px(30.))
                            .gap(px(8.))
                            .flex_shrink_0()
                            .rounded(px(6.))
                            .cursor_pointer()
                            .hover(|s| s.bg(rgba(hover())))
                            .tooltip(move |_, cx| {
                                cx.new(|_| Tooltip::new("在访达中打开")).into()
                            })
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.command(
                                    crate::views::Command::OpenGameDirectory(index),
                                    cx,
                                );
                            }))
                            .child(icon("folder", 13.).text_color(rgb(muted_color())))
                            .child(muted("安装位置").text_size(px(12.)))
                            .child(div().flex_1().min_w_0())
                            .child(
                                div()
                                    .flex_shrink_0()
                                    .max_w(px(160.))
                                    .truncate()
                                    .text_size(px(12.))
                                    .text_color(rgb(muted_color()))
                                    .child(dir.to_string_lossy().to_string()),
                            )
                            .child(icon("chevron-right", 11.).text_color(rgb(muted_color())))
                            .into_any_element(),
                    );
                }
                let mut card = col()
                    .w_full()
                    .flex_shrink_0()
                    .rounded(px(10.))
                    .bg(rgba(section_bg()))
                    .border_1()
                    .border_color(rgba(section_border()))
                    .px(px(10.));
                for (row_index, info) in info_rows.into_iter().enumerate() {
                    if row_index > 0 {
                        card = card.child(div().h(px(1.)).w_full().bg(rgba(divider())));
                    }
                    card = card.child(info);
                }
                card
            })
            .when(fill, |d| {
                d.child(div().flex_1().min_h(px(8.))).child(
                    div().w_full().h(px(1.)).bg(rgba(divider())),
                )
            })
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
