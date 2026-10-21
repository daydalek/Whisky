//! Small shared widgets used by more than one surface.

use gpui_kit::component::Icon;
use gpui_kit::{prelude::*, *};

use crate::theme::MUTED;

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
        .text_color(rgb(MUTED))
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
        .bg(rgba(0xffffff0b))
        .text_size(px(11.))
        .text_color(rgb(0xb8b8bc))
        .child(icon(name, 12.))
        .child(text.into())
}
pub(crate) fn round_button(id: &'static str, name: &str) -> Stateful<Div> {
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
