use gpui_kit::component::{
    button::Button,
    menu::{DropdownMenu, PopupMenuItem},
};
use gpui_kit::{prelude::*, *};

use crate::controls::*;
use crate::preferences::VISIBLE_MODES;
use crate::state::WhiskyApp;
use crate::theme::*;

fn preview_fill(selected: bool) -> Rgba {
    rgba(if selected {
        ACCENT << 8 | 0x66
    } else {
        muted_color() << 8 | 0x38
    })
}

fn preview_accent(selected: bool) -> Rgba {
    rgba(if selected {
        ACCENT << 8 | 0xcc
    } else {
        muted_color() << 8 | 0x55
    })
}

fn layout_preview(mode: usize, selected: bool) -> AnyElement {
    let fill = preview_fill(selected);
    let accent = preview_accent(selected);
    let content = match mode {
        1 => col()
            .size_full()
            .justify_center()
            .gap(px(6.))
            .children((0..3).map(|_| {
                row()
                    .w_full()
                    .flex_shrink_0()
                    .gap(px(6.))
                    .child(div().w(px(14.)).h(px(18.)).rounded(px(3.)).bg(fill))
                    .child(
                        col()
                            .flex_1()
                            .justify_center()
                            .gap(px(3.))
                            .child(div().h(px(4.)).w(relative(0.7)).rounded_full().bg(accent))
                            .child(div().h(px(3.)).w(relative(0.45)).rounded_full().bg(fill)),
                    )
                    .into_any_element()
            }))
            .into_any_element(),
        3 => col()
            .size_full()
            .gap(px(6.))
            .child(div().w_full().flex_1().min_h_0().rounded(px(5.)).bg(accent))
            .child(
                row()
                    .w_full()
                    .h(px(18.))
                    .flex_shrink_0()
                    .gap(px(5.))
                    .children((0..3).map(|_| {
                        div()
                            .flex_1()
                            .h_full()
                            .rounded(px(3.))
                            .bg(fill)
                            .into_any_element()
                    })),
            )
            .into_any_element(),
        4 => row()
            .size_full()
            .gap(px(6.))
            .child(
                col()
                    .w(relative(0.44))
                    .h_full()
                    .flex_shrink_0()
                    .gap(px(4.))
                    .children((0..2).map(|_| {
                        row()
                            .w_full()
                            .flex_1()
                            .min_h_0()
                            .gap(px(4.))
                            .children((0..2).map(|_| {
                                div()
                                    .flex_1()
                                    .h_full()
                                    .rounded(px(3.))
                                    .bg(fill)
                                    .into_any_element()
                            }))
                            .into_any_element()
                    })),
            )
            .child(
                col()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .gap(px(4.))
                    .child(div().w_full().flex_1().min_h_0().rounded(px(3.)).bg(fill))
                    .child(div().h(px(4.)).w(relative(0.8)).rounded_full().bg(accent))
                    .child(div().h(px(4.)).w(relative(0.55)).rounded_full().bg(fill)),
            )
            .into_any_element(),
        _ => col()
            .size_full()
            .gap(px(5.))
            .children((0..2).map(|_| {
                row()
                    .w_full()
                    .flex_1()
                    .min_h_0()
                    .gap(px(5.))
                    .children((0..3).map(|_| {
                        div()
                            .flex_1()
                            .h_full()
                            .rounded(px(4.))
                            .bg(fill)
                            .into_any_element()
                    }))
                    .into_any_element()
            }))
            .into_any_element(),
    };
    div()
        .w_full()
        .h(px(76.))
        .flex_shrink_0()
        .rounded(px(8.))
        .overflow_hidden()
        .p(px(8.))
        .bg(rgb(bg()))
        .child(content)
        .into_any_element()
}

impl WhiskyApp {
    pub(crate) fn library_mode_menu(&self, cx: &Context<Self>) -> AnyElement {
        let current = VISIBLE_MODES
            .iter()
            .find(|(index, ..)| *index == self.mode)
            .map(|(_, _, label, _)| *label)
            .unwrap_or(VISIBLE_MODES[0].2);
        let view = cx.entity().downgrade();
        let mode = self.mode;
        Button::new("library-view-menu")
            .label(format!("{current}  ⌄"))
            .rounded_full()
            .h(px(34.))
            .tooltip("切换游戏库界面")
            .dropdown_menu(move |mut menu, _, _| {
                for &(index, _, label, _) in &VISIBLE_MODES {
                    let view = view.clone();
                    menu = menu.item(PopupMenuItem::new(label).checked(mode == index).on_click(
                        move |_, _, cx| {
                            let _ = view.update(cx, |this, cx| {
                                this.set_mode(index, cx);
                            });
                        },
                    ));
                }
                menu.item(PopupMenuItem::separator()).item(
                    PopupMenuItem::new("界面偏好设置…").on_click({
                        let view = view.clone();
                        move |_, _, cx| {
                            let _ = view.update(cx, |this, cx| {
                                this.open_settings(cx);
                            });
                        }
                    }),
                )
            })
            .into_any_element()
    }

    pub(crate) fn library_mode_cards(&self, cx: &Context<Self>) -> AnyElement {
        let mut rows = col().w_full().flex_shrink_0().gap(px(12.));
        for pair in VISIBLE_MODES.chunks(2) {
            let mut strip = row().w_full().gap(px(12.));
            for &(index, name, label, description) in pair {
                let selected = self.mode == index;
                strip = strip.child(
                    col()
                        .id(("view-choice", index))
                        .flex_1()
                        .min_w_0()
                        .p(px(12.))
                        .gap(px(8.))
                        .rounded(px(12.))
                        .border_2()
                        .border_color(if selected {
                            rgb(ACCENT).into()
                        } else {
                            rgba(surface_border())
                        })
                        .bg(if selected {
                            rgba(selected_bg())
                        } else {
                            rgb(crate::theme::surface()).into()
                        })
                        .cursor_pointer()
                        .hover(|s| s.bg(rgba(hover())))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.set_mode(index, cx);
                        }))
                        .child(layout_preview(index, selected))
                        .child(
                            row()
                                .gap(px(8.))
                                .child(icon(name, 16.).text_color(rgb(if selected {
                                    ACCENT
                                } else {
                                    muted_color()
                                })))
                                .child(
                                    div()
                                        .text_size(px(13.))
                                        .font_weight(FontWeight::BOLD)
                                        .truncate()
                                        .child(label),
                                )
                                .child(div().flex_1())
                                .when(selected, |d| {
                                    d.child(icon("check", 14.).text_color(rgb(ACCENT)))
                                }),
                        )
                        .child(muted(description).text_size(px(11.)).line_clamp(2)),
                );
            }
            rows = rows.child(strip);
        }
        col()
            .w_full()
            .flex_shrink_0()
            .py(px(10.))
            .gap(px(10.))
            .child(
                col()
                    .gap(px(3.))
                    .child(div().font_weight(FontWeight::SEMIBOLD).child("游戏库界面"))
                    .child(muted("选择适合你的浏览方式，也可从游戏库右上角快速切换。")),
            )
            .child(rows)
            .into_any_element()
    }
}
