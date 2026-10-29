//! Small shared widgets used by more than one surface.

use gpui_kit::component::Icon;
use gpui_kit::component::Sizable;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::{prelude::*, *};

use crate::theme::{
    self, SUCCESS, TEXT,
};

pub(crate) fn row() -> Div {
    div().flex().items_center()
}
pub(crate) fn col() -> Div {
    div().flex().flex_col()
}
pub(crate) fn icon(name: &str, size: f32) -> Icon {
    Icon::default()
        .path(format!("icons/{name}.svg"))
        .size(px(size))
        .flex_shrink_0()
}
pub(crate) fn muted(text: impl Into<SharedString>) -> Div {
    div()
        .text_size(px(12.))
        .text_color(rgb(theme::muted_color()))
        .child(text.into())
}
pub(crate) fn gradient(top: u32, bottom: u32) -> Background {
    linear_gradient(
        180.,
        linear_color_stop(rgba(top), 0.),
        linear_color_stop(rgba(bottom), 1.),
    )
}
pub(crate) fn badge(name: &str, text: impl Into<SharedString>) -> Div {
    row()
        .gap(px(5.))
        .px(px(9.))
        .py(px(3.))
        .rounded_full()
        .bg(rgba(theme::badge_bg()))
        .text_size(px(11.))
        .text_color(rgb(theme::badge_text()))
        .child(icon(name, 12.))
        .child(text.into())
}
pub(crate) fn round_button(id: &'static str, name: &str) -> Stateful<Div> {
    row()
        .id(id)
        .justify_center()
        .size(px(34.))
        .rounded_full()
        .bg(rgba(theme::round_btn_bg()))
        .border_1()
        .border_color(rgba(theme::round_btn_border()))
        .cursor_pointer()
        .hover(|s| s.bg(rgba(theme::round_btn_hover())))
        .child(icon(name, 17.))
}

/// Running indicator: the status pill's live dot inside the existing badge
/// capsule. No new art — the dot is the bridge pill's, the capsule is `badge`.
pub(crate) fn live_badge(text: impl Into<SharedString>) -> Div {
    row()
        .flex_shrink_0()
        .gap(px(5.))
        .px(px(8.))
        .py(px(3.))
        .rounded_full()
        .bg(rgba(0x000000a8))
        .child(div().size(px(6.)).rounded_full().bg(rgb(SUCCESS)))
        .child(
            div()
                .text_size(px(10.))
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(rgb(SUCCESS))
                .child(text.into()),
        )
}

/// Pre-launch phase: the toolkit spinner plus the phase name, same capsule.
pub(crate) fn phase_badge(label: impl Into<SharedString>) -> Div {
    row()
        .flex_shrink_0()
        .gap(px(5.))
        .px(px(8.))
        .py(px(3.))
        .rounded_full()
        .bg(rgba(0x000000a8))
        .child(Spinner::new().with_size(px(10.)))
        .child(
            div()
                .text_size(px(10.))
                .text_color(rgb(TEXT))
                .child(label.into()),
        )
}
