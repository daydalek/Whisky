//! Library surface: sidebar, toolbar, three presentations, and the detail panel.

use std::time::Duration;

use gpui_kit::base::{Spring, spring, transition};
use gpui_kit::component::{
    Disableable, Sizable,
    button::{Button, ButtonVariants},
    menu::{ContextMenuExt, PopupMenu, PopupMenuItem},
    spinner::Spinner,
    tooltip::Tooltip,
};
use gpui_kit::{prelude::*, *};

use crate::bridge::BridgeStatus;
use crate::controls::*;
use crate::library_layout::{CardRect, LibraryLayout};
use crate::model::{ambient, art};
use crate::runtime::{RuntimeAction, RuntimeState};
use crate::state::{DEMO_NOTICE, PreviewPage, SidebarMode, WhiskyApp};
use crate::theme::*;
use crate::views::{
    ConnectorPaint, connector_curve, fade_rgb, mix_rgb, mix_rgba, paint_connectors,
};

const CHARACTER_CARD_WIDTH: f32 = 164.;
const CHARACTER_CARD_PADDING: f32 = 10.;
const CHARACTER_PORTRAIT_HEIGHT: f32 = 144.;

/// Cover size track and thumb, in points.
const COVER_SLIDER_WIDTH: f32 = 118.;
const COVER_SLIDER_THUMB: f32 = 12.;

/// Pointer x on the cover size track, snapped to the nearest level the shelf
/// can draw flush. `bounds` is `[origin x, width]`; `levels` is narrowest
/// first, matching the track's left-to-right growth.
fn cover_slider_value(x: f32, bounds: [f32; 2], levels: &[f32]) -> f32 {
    let fraction = if bounds[1] > 0. {
        ((x - bounds[0]) / bounds[1]).clamp(0., 1.)
    } else {
        0.
    };
    match levels.len() {
        0 => 0.,
        1 => levels[0],
        count => levels[(fraction * (count - 1) as f32).round() as usize],
    }
}

/// Index of the level nearest `current` — where the control's thumb sits.
fn cover_level_index(levels: &[f32], current: f32) -> usize {
    levels
        .iter()
        .enumerate()
        .min_by(|(_, a), (_, b)| (*a - current).abs().total_cmp(&(*b - current).abs()))
        .map(|(index, _)| index)
        .unwrap_or(0)
}

/// Cover only when at least 80% of the artwork remains visible. Both the card
/// and portrait have a one-pixel border, which is excluded from the viewport.
fn character_portrait_fit(width: i32, height: i32) -> ObjectFit {
    if width <= 0 || height <= 0 {
        return ObjectFit::Contain;
    }
    let viewport_width = CHARACTER_CARD_WIDTH - 2. * (CHARACTER_CARD_PADDING + 2.);
    let viewport_height = CHARACTER_PORTRAIT_HEIGHT - 2.;
    let relative_width = f64::from(width) * f64::from(viewport_height);
    let relative_height = f64::from(height) * f64::from(viewport_width);
    // Cross-multiply the 4/5 threshold so exactly 20% cropping is stable.
    if 5. * relative_width.min(relative_height) >= 4. * relative_width.max(relative_height) {
        ObjectFit::Cover
    } else {
        ObjectFit::Contain
    }
}

fn character_portrait_placeholder(label: &'static str) -> AnyElement {
    col()
        .size_full()
        .items_center()
        .justify_center()
        .gap(px(6.))
        .child(icon("user", 22.).text_color(rgb(muted_color())))
        .child(muted(label).text_size(px(11.)))
        .into_any_element()
}

#[derive(IntoElement)]
struct CharacterPortrait {
    path: std::path::PathBuf,
}

impl RenderOnce for CharacterPortrait {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        // Reuse GPUI's asynchronous image cache: no file reads or second image
        // decode on the render thread just to discover the artwork's dimensions.
        match window.use_asset::<ImgResourceLoader>(&self.path.into(), cx) {
            Some(Ok(image)) => {
                let dimensions = image.size(0);
                let fit = character_portrait_fit(dimensions.width.0, dimensions.height.0);
                div()
                    .size_full()
                    .when(matches!(fit, ObjectFit::Contain), |d| d.p(px(4.)))
                    .child(img(image).size_full().object_fit(fit))
                    .into_any_element()
            }
            Some(Err(_)) => character_portrait_placeholder("头像加载失败"),
            None => character_portrait_placeholder("加载中…"),
        }
    }
}

fn characters_in_display_order<'a>(
    characters: &'a [crate::bridge::dto::CharacterDto],
    images: &std::collections::BTreeMap<String, String>,
) -> Vec<&'a crate::bridge::dto::CharacterDto> {
    let mut ordered: Vec<_> = characters.iter().collect();
    ordered.sort_by_key(|character| !images.contains_key(&character.id));
    ordered
}

#[cfg(test)]
mod character_presentation_tests {
    use super::{character_portrait_fit, characters_in_display_order};
    use crate::bridge::dto::CharacterDto;
    use gpui_kit::ObjectFit;
    use std::collections::BTreeMap;

    #[test]
    fn ordinary_portraits_fill_the_fixed_viewport() {
        for (width, height) in [(400, 400), (450, 500), (500, 450)] {
            assert!(matches!(character_portrait_fit(width, height), ObjectFit::Cover));
        }
    }

    #[test]
    fn full_body_and_extremely_tall_artwork_remains_complete() {
        for (width, height) in [(400, 650), (300, 1200), (1, 10000)] {
            assert!(matches!(character_portrait_fit(width, height), ObjectFit::Contain));
        }
    }

    #[test]
    fn wide_artwork_remains_complete() {
        for (width, height) in [(800, 400), (10000, 1)] {
            assert!(matches!(character_portrait_fit(width, height), ObjectFit::Contain));
        }
    }

    #[test]
    fn crop_limit_applies_in_both_directions() {
        // The drawable viewport is 140 × 142. These retain exactly 80%.
        for (width, height) in [(112, 142), (175, 142)] {
            assert!(matches!(character_portrait_fit(width, height), ObjectFit::Cover));
        }
        for (width, height) in [(111, 142), (176, 142)] {
            assert!(matches!(character_portrait_fit(width, height), ObjectFit::Contain));
        }
    }

    #[test]
    fn missing_dimensions_never_trigger_cropping() {
        for (width, height) in [(0, 0), (0, 400), (400, 0), (-1, 400), (400, -1)] {
            assert!(matches!(character_portrait_fit(width, height), ObjectFit::Contain));
        }
    }

    #[test]
    fn cached_portraits_come_first_and_each_group_keeps_its_order() {
        let characters: Vec<CharacterDto> = ["missing", "first", "failed", "second"]
            .into_iter()
            .map(|id| CharacterDto {
                id: id.into(),
                image_url: Some("https://example.com/portrait.png".into()),
                ..Default::default()
            })
            .collect();
        let images = BTreeMap::from([
            ("first".into(), "/cache/first.png".into()),
            ("second".into(), "/cache/second.png".into()),
        ]);
        let ordered = characters_in_display_order(&characters, &images);
        assert_eq!(ordered.iter().map(|character| character.id.as_str()).collect::<Vec<_>>(),
            ["first", "second", "missing", "failed"]);
    }
}

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
            rgba(selected_bg())
        } else {
            rgba(0x00000000)
        })
        .cursor_pointer()
        .hover(|s| s.bg(rgba(hover())))
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

/// One rail button, mirroring a `sidebar_row` icon. The label and count move
/// into the tooltip so the strip can stay at icon width.
fn sidebar_icon(id: impl Into<ElementId>, symbol: &str, selected: bool) -> Stateful<Div> {
    row()
        .id(id)
        .size(px(36.))
        .justify_center()
        .rounded(px(6.))
        .bg(if selected {
            rgba(selected_bg())
        } else {
            rgba(0x00000000)
        })
        .cursor_pointer()
        .hover(|s| s.bg(rgba(hover())))
        .child(icon(symbol, 18.).text_color(rgb(ACCENT)))
}

/// A plain tooltip closure for the sidebar's collapsed presentations.
fn text_tip(text: impl Into<SharedString>) -> impl Fn(&mut Window, &mut App) -> AnyView + 'static {
    let text = text.into();
    move |_, cx| cx.new(|_| Tooltip::new(text.clone())).into()
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
    pub(crate) fn ambient_art(&self, index: usize) -> Option<std::path::PathBuf> {
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
            3 => self.immersive(width, window, cx),
            4 => self.gallery(width, window, cx),
            5 => self.staggered(width, window, cx),
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
                    .bg(rgb(crate::theme::surface()))
                    .border_1()
                    .border_color(rgba(surface_border()))
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
        if self.sidebar == SidebarMode::Icons {
            self.sidebar_rail(cx)
        } else {
            // `Hidden` keeps the expanded rows: they slide out under the clip.
            self.sidebar_expanded(cx)
        }
    }

    /// Right-click on a sidebar affordance picks the presentation directly;
    /// the buttons keep their one-click behaviour.
    fn sidebar_mode_menu(
        &self,
        cx: &Context<Self>,
    ) -> impl Fn(PopupMenu, &mut Window, &mut Context<PopupMenu>) -> PopupMenu + 'static {
        let view = cx.entity().downgrade();
        let current = self.sidebar;
        move |mut menu, _, _| {
            for (label, mode) in [
                ("展开侧边栏", SidebarMode::Expanded),
                ("仅显示图标", SidebarMode::Icons),
                ("完全隐藏", SidebarMode::Hidden),
            ] {
                let view = view.clone();
                menu = menu.item(
                    PopupMenuItem::new(label)
                        .checked(current == mode)
                        .on_click(move |_, _, cx| {
                            let _ = view.update(cx, |this, cx| {
                                this.set_sidebar(mode, cx);
                            });
                        }),
                );
            }
            menu
        }
    }

    /// The rail's container picker: one submenu per bottle — its first item
    /// selects the container, the rest are the expanded row's bottle actions.
    fn container_menu(
        &self,
        cx: &Context<Self>,
    ) -> impl Fn(PopupMenu, &mut Window, &mut Context<PopupMenu>) -> PopupMenu + 'static {
        let view = cx.entity().downgrade();
        let selected = self.selected_bottle;
        let bottles: Vec<_> = self
            .bottles
            .iter()
            .enumerate()
            .map(|(index, bottle)| {
                (index, bottle.name.clone(), self.bottle_menu_entries(index, cx))
            })
            .collect();
        move |mut menu, window, cx| {
            if bottles.is_empty() {
                menu = menu.item(PopupMenuItem::new("（无容器）").disabled(true));
            }
            for (index, name, items) in &bottles {
                let (index, name, items) = (*index, name.clone(), items.clone());
                let view = view.clone();
                menu = menu.submenu(name, window, cx, move |mut sub, _, _| {
                    let view = view.clone();
                    sub = sub
                        .item(
                            PopupMenuItem::new("显示")
                                .checked(selected == Some(index))
                                .on_click(move |_, _, cx| {
                                    let _ = view.update(cx, |this, cx| {
                                        this.select_bottle(Some(index), cx);
                                    });
                                }),
                        )
                        .separator();
                    for item in &items {
                        sub = sub.item(item.build());
                    }
                    sub
                });
            }
            menu
        }
    }

    /// The collapsed rail: every expanded entry mapped to its icon, with the
    /// name and count carried by the row's tooltip.
    fn sidebar_rail(&self, cx: &mut Context<Self>) -> AnyElement {
        let games = self.games();
        let mut entries = col().items_center().gap(px(1.)).px(px(10.));
        entries = entries.child(
            sidebar_icon("sidebar-expand", "panel-left-open", false)
                .tooltip(text_tip("展开侧边栏 · 右键选择显示方式"))
                .on_click(cx.listener(|this, _, _, cx| {
                    this.set_sidebar(SidebarMode::Expanded, cx);
                }))
                .context_menu(self.sidebar_mode_menu(cx)),
        );
        entries = entries.child(
            sidebar_icon(
                "library",
                "layout-grid",
                !self.settings && self.preview.page == PreviewPage::Library && self.selected_bottle.is_none(),
            )
            .tooltip(text_tip(format!(
                "Library · {}",
                games.iter().filter(|game| !game.is_launcher).count()
            )))
            .on_click(cx.listener(|this, _, _, cx| this.select_bottle(None, cx))),
        );
        entries = entries.child(
            sidebar_icon(
                "statistics",
                "rows-3",
                !self.settings && self.preview.page == PreviewPage::Statistics,
            )
            .tooltip(text_tip(format!(
                "游玩统计 · {}",
                games
                    .iter()
                    .filter(|game| !game.is_launcher && game.play_time.unwrap_or(0) > 0)
                    .count()
            )))
            .on_click(cx.listener(|this, _, _, cx| {
                this.navigate(PreviewPage::Statistics, cx);
            })),
        );
        entries = entries.child(
            sidebar_icon(
                "launchers",
                "store",
                !self.settings && self.preview.page == PreviewPage::Launchers,
            )
            .tooltip(text_tip(format!(
                "启动器 · {}",
                games.iter().filter(|game| game.is_launcher).count()
            )))
            .on_click(cx.listener(|this, _, _, cx| {
                this.navigate(PreviewPage::Launchers, cx);
            })),
        );
        // The expanded "Bottles" caption becomes a hairline at rail width.
        entries = entries.child(div().h(px(1.)).w(px(24.)).my(px(5.)).bg(rgba(divider())));
        // One container affordance: left-click reopens the active bottle,
        // right-click lists every container so one pick selects it.
        let container_tip = match self.selected_bottle.and_then(|index| self.bottles.get(index)) {
            Some(bottle) => format!("{} · 右键选择容器", bottle.name),
            None => "容器 · 右键选择".to_owned(),
        };
        entries = entries.child(
            sidebar_icon(
                "containers",
                "package",
                !self.settings && self.selected_bottle.is_some(),
            )
            .tooltip(text_tip(container_tip))
            .on_click(cx.listener(|this, _, _, cx| {
                let target = this
                    .selected_bottle
                    .or_else(|| (!this.bottles.is_empty()).then_some(0));
                if target.is_some() {
                    this.select_bottle(target, cx);
                }
            }))
            .context_menu(self.container_menu(cx)),
        );
        let (grad_start, grad_end) = sidebar_gradient();
        col()
            .id("sidebar-rail")
            .size_full()
            .items_center()
            .bg(gradient(grad_start, grad_end))
            .border_r_1()
            .border_color(rgba(divider()))
            // The traffic lights span the rail's full width; the header band
            // stays empty so they never cover a button.
            .child(div().w_full().h(px(52.)).flex_shrink_0())
            .child(entries)
            .child(div().flex_1())
            .child(
                col()
                    .items_center()
                    .gap(px(6.))
                    .pb(px(8.))
                    .child(self.bridge_dot(cx))
                    .child(
                        round_button("appearance-toggle", self.appearance.icon_name())
                            .size(px(28.))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.cycle_appearance(cx);
                            })),
                    )
                    .child(
                        round_button("settings", "settings-2")
                            .size(px(28.))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.settings = !this.settings;
                                cx.notify();
                            })),
                    ),
            )
            .context_menu(self.sidebar_mode_menu(cx))
            .into_any_element()
    }

    fn sidebar_expanded(&self, cx: &mut Context<Self>) -> AnyElement {
        let games = self.games();
        let mut entries = col().gap(px(1.));
        entries = entries.child(
            sidebar_row(
                "library",
                "Library",
                "layout-grid",
                games.iter().filter(|game| !game.is_launcher).count(),
                !self.settings && self.preview.page == PreviewPage::Library && self.selected_bottle.is_none(),
            )
            .on_click(cx.listener(|this, _, _, cx| this.select_bottle(None, cx))),
        );
        entries = entries.child(
            sidebar_row(
                "statistics", "游玩统计", "rows-3",
                games.iter().filter(|game| !game.is_launcher && game.play_time.unwrap_or(0) > 0).count(),
                !self.settings && self.preview.page == PreviewPage::Statistics,
            ).on_click(cx.listener(|this, _, _, cx| {
                this.navigate(PreviewPage::Statistics, cx);
            })),
        );
        entries = entries.child(
            sidebar_row(
                "launchers", "启动器", "store",
                games.iter().filter(|game| game.is_launcher).count(),
                !self.settings && self.preview.page == PreviewPage::Launchers,
            ).on_click(cx.listener(|this, _, _, cx| {
                this.navigate(PreviewPage::Launchers, cx);
            })),
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
            let count = games
                .iter()
                .filter(|game| game.bottle == index + 1 && !game.is_launcher)
                .count();
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
        let (grad_start, grad_end) = sidebar_gradient();
        col()
            .size_full()
            .bg(gradient(grad_start, grad_end))
            .border_r_1()
            .border_color(rgba(divider()))
            .child(
                row()
                    .h(px(52.))
                    .flex_shrink_0()
                    .px(px(14.))
                    .justify_end()
                    .child(
                        round_button("sidebar-hide", "panel-left")
                            .tooltip(text_tip("收起侧边栏 · 右键选择显示方式"))
                            .on_click(cx.listener(|this, _, _, cx| {
                                let style = this.sidebar_collapsed_style;
                                this.set_sidebar(style, cx);
                            }))
                            .context_menu(self.sidebar_mode_menu(cx)),
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
                            .child(muted("Maltoria").text_size(px(11.)))
                            .child(
                                row()
                                    .gap(px(6.))
                                    .child(
                                        round_button(
                                            "appearance-toggle",
                                            self.appearance.icon_name(),
                                        )
                                        .size(px(28.))
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.cycle_appearance(cx);
                                        })),
                                    )
                                    .child(
                                        round_button("settings", "settings-2")
                                            .size(px(28.))
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                this.settings = !this.settings;
                                                cx.notify();
                                            })),
                                    ),
                            ),
                    ),
            )
            .into_any_element()
    }
    /// The bridge indicator's (dot colour, clickable-failure) pair, shared by
    /// the expanded pill and the rail's dot.
    fn bridge_status_style(&self) -> (u32, bool) {
        match &self.bridge_status {
            BridgeStatus::Connected { .. } => (SUCCESS, false),
            BridgeStatus::Failed { .. } => (DANGER, true),
            BridgeStatus::Stopped => (DANGER, false),
            BridgeStatus::Locating | BridgeStatus::Starting => (muted_color(), false),
        }
    }
    /// The rail's bridge indicator: the pill's dot alone, still opening the
    /// recovery dialog after a failure.
    fn bridge_dot(&self, cx: &mut Context<Self>) -> AnyElement {
        let (dot, failed) = self.bridge_status_style();
        div()
            .id("bridge-status")
            .size(px(28.))
            .flex()
            .items_center()
            .justify_center()
            .rounded_full()
            .when(failed, |d| {
                d.cursor_pointer()
                    .hover(|s| s.bg(rgba(hover())))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.bridge_dialog = true;
                        cx.notify();
                    }))
            })
            .tooltip(text_tip(self.bridge_status.label()))
            .child(div().size(px(6.)).rounded_full().bg(rgb(dot)))
            .into_any_element()
    }
    fn bridge_pill(&self, cx: &mut Context<Self>) -> AnyElement {
        let (dot, failed) = self.bridge_status_style();
        row()
            .id("bridge-status")
            .px(px(10.))
            .py(px(6.))
            .gap(px(7.))
            .rounded(px(RADIUS_SM))
            .when(failed, |d| {
                d.cursor_pointer()
                    .hover(|s| s.bg(rgba(hover())))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.bridge_dialog = true;
                        cx.notify();
                    }))
            })
            .child(div().size(px(6.)).rounded_full().bg(rgb(dot)))
            .child(
                div()
                    .text_size(px(11.))
                    .text_color(rgb(muted_color()))
                    .child(self.bridge_status.label()),
            )
            .into_any_element()
    }
    pub(crate) fn toolbar(&self, left_padding: f32, cx: &mut Context<Self>) -> impl IntoElement {
        // Classic stays hidden in GPUI; immersive is GPUI-only. Labelled
        // segments read better than bare icons: each mode names its layout.
        let modes = self.library_mode_menu(cx);
        row()
            .h(px(52.))
            .flex_shrink_0()
            .pl(px(left_padding))
            .pr(px(18.))
            .gap(px(9.))
            .bg(rgba(toolbar_bg()))
            .border_b_1()
            .border_color(rgba(divider()))
            .when(matches!(self.sidebar, SidebarMode::Hidden), |d| {
                d.child(
                    round_button("sidebar-show", "panel-left")
                        .tooltip(text_tip("显示侧边栏 · 右键选择显示方式"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.set_sidebar(SidebarMode::Expanded, cx);
                        }))
                        .context_menu(self.sidebar_mode_menu(cx)),
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
                // The list owns both timeline layouts; the switch picks
                // single or staggered columns.
                self.preview.page == PreviewPage::Library
                    && !self.settings
                    && (self.mode == 1 || self.mode == crate::preferences::STAGGERED_MODE),
                |d| d.child(self.timeline_layout_control(cx)),
            )
            .when(
                // Only the shelf has a cover size; the timeline and the classic
                // list draw fixed rows.
                self.preview.page == PreviewPage::Library && !self.settings && self.mode == 0,
                |d| d.child(self.cover_size_control(cx)),
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

    /// 单列/双列 segmented switch for the timeline family. The staggered rail
    /// is a variant of the list rather than its own picker entry, so the
    /// switch just moves the mode slot between 1 and STAGGERED_MODE.
    fn timeline_layout_control(&self, cx: &mut Context<Self>) -> AnyElement {
        let staggered = self.mode == crate::preferences::STAGGERED_MODE;
        let mut group = row()
            .p(px(3.))
            .gap(px(2.))
            .rounded_full()
            .border_1()
            .border_color(rgba(divider()))
            .bg(rgba(hover()));
        for (target, icon_name, label) in [
            (1usize, "rows-3", "单列"),
            (
                crate::preferences::STAGGERED_MODE,
                "git-commit-vertical",
                "双列",
            ),
        ] {
            let active = (target == crate::preferences::STAGGERED_MODE) == staggered;
            group = group.child(
                row()
                    .id(("timeline-layout", target))
                    .h(px(22.))
                    .px(px(9.))
                    .gap(px(5.))
                    .rounded_full()
                    .text_size(px(11.))
                    .cursor_pointer()
                    .when(active, |d| d.bg(rgba(hover_strong())))
                    .when(!active, |d| {
                        d.text_color(rgb(muted_color()))
                            .hover(|s| s.bg(rgba(hover())))
                    })
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.set_mode(target, cx);
                    }))
                    .child(icon(icon_name, 12.))
                    .child(label),
            );
        }
        group.into_any_element()
    }

    /// Stepped cover size for the shelf. The thumb sits on the level the covers
    /// actually draw, so an automatic shelf still reads truthfully; dragging or
    /// double-clicking leaves that mode. Every level fills the row, so the
    /// shelf never leaves a gap at the edges.
    fn cover_size_control(&self, cx: &mut Context<Self>) -> AnyElement {
        let automatic = self.cover_width <= f32::EPSILON;
        let levels = crate::library_layout::cover_levels(self.cover_span.get());
        let current = if automatic {
            self.cover_unit.get()
        } else {
            self.cover_width
        };
        let position = cover_level_index(&levels, current);
        let fraction = if levels.len() > 1 {
            position as f32 / (levels.len() - 1) as f32
        } else {
            0.
        };
        let thumb = fraction * COVER_SLIDER_WIDTH - COVER_SLIDER_THUMB / 2.;
        let label: SharedString = if automatic {
            "自动".into()
        } else {
            format!("{:.0}", levels[position]).into()
        };
        let ticks: Vec<AnyElement> = (1..levels.len().saturating_sub(1))
            .map(|index| {
                let offset =
                    COVER_SLIDER_WIDTH * index as f32 / (levels.len() - 1) as f32;
                div()
                    .absolute()
                    .left(px(offset - 1.))
                    .top(px(COVER_SLIDER_THUMB / 2. + 0.5 + 1.))
                    .size(px(3.))
                    .rounded_full()
                    .bg(rgba(round_btn_border()))
                    .into_any_element()
            })
            .collect();
        // Hit testing needs the track's window position; prepaint is the only
        // place GPUI hands it out.
        let bounds = std::rc::Rc::new(std::cell::Cell::new([0f32; 2]));
        let measured = bounds.clone();
        let down = bounds.clone();
        let moved = bounds.clone();
        let down_levels = levels.clone();
        let moved_levels = levels.clone();
        row()
            .gap(px(8.))
            .flex_shrink_0()
            .child(
                div()
                    .id("cover-size-track")
                    .relative()
                    .w(px(COVER_SLIDER_WIDTH))
                    .h(px(COVER_SLIDER_THUMB + 6.))
                    .cursor_pointer()
                    .child(
                        canvas(
                            move |bounds, _, _| {
                                measured.set([
                                    f32::from(bounds.origin.x),
                                    f32::from(bounds.size.width),
                                ]);
                            },
                            |_, _, _, _| {},
                        )
                        .absolute()
                        .size_full(),
                    )
                    .child(
                        div()
                            .absolute()
                            .left(px(0.))
                            .top(px(COVER_SLIDER_THUMB / 2. + 0.5))
                            .h(px(5.))
                            .w_full()
                            .rounded_full()
                            .bg(rgba(round_btn_bg())),
                    )
                    .child(
                        div()
                            .absolute()
                            .left(px(0.))
                            .top(px(COVER_SLIDER_THUMB / 2. + 0.5))
                            .h(px(5.))
                            .w(px(COVER_SLIDER_WIDTH * fraction))
                            .rounded_full()
                            .bg(rgb(ACCENT)),
                    )
                    .children(ticks)
                    .child(
                        div()
                            .absolute()
                            .left(px(thumb.clamp(
                                0.,
                                COVER_SLIDER_WIDTH - COVER_SLIDER_THUMB,
                            )))
                            .top(px(3.))
                            .size(px(COVER_SLIDER_THUMB))
                            .rounded_full()
                            .bg(rgb(0xffffff))
                            .border_1()
                            .border_color(rgba(round_btn_border())),
                    )
                    .on_mouse_down(
                        MouseButton::Left,
                        cx.listener(move |this, event: &MouseDownEvent, _, cx| {
                            cx.stop_propagation();
                            if event.click_count >= 2 {
                                this.reset_cover_width(cx);
                                return;
                            }
                            this.set_cover_width(
                                cover_slider_value(
                                    f32::from(event.position.x),
                                    down.get(),
                                    &down_levels,
                                ),
                                cx,
                            );
                        }),
                    )
                    .on_mouse_move(cx.listener(move |this, event: &MouseMoveEvent, _, cx| {
                        if !event.dragging() {
                            return;
                        }
                        this.set_cover_width(
                            cover_slider_value(
                                f32::from(event.position.x),
                                moved.get(),
                                &moved_levels,
                            ),
                            cx,
                        );
                    })),
            )
            .child(muted(label).w(px(34.)).text_size(px(11.)))
            .into_any_element()
    }
    pub(crate) fn backdrop(&self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        // Per-image channels preserve continuous blending even during rapid A → B → C hovers.
        let mut layers = div().absolute().size_full().overflow_hidden().bg(rgb(bg()));
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
                    self.artwork_image(path)
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
        title_overlay: bool,
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
        let (ph_start, ph_end) = placeholder_gradient();
        div()
            .id(("cover", index))
            .relative()
            .w(px(width))
            .h(px(height))
            .flex_shrink_0()
            .rounded(px(8.))
            .overflow_hidden()
            .border_1()
            .border_color(rgba(if hovering {
                if is_dark() { 0xffffff65 } else { 0x00000045 }
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
                    .bg(gradient(ph_start, ph_end))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(icon("package", 26.).text_color(rgb(muted_color())))
                    .into_any_element(),
            })
            // Overlay title is used by the classic card; the shelf draws its
            // label below the artwork instead.
            .when(title_overlay, |d| {
                d.child(
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
                        .text_color(rgb(0xf4f4f6))
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
            })
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
        self.play_circle(("cover-play", index), index, amount, cx)
    }
    /// Same circle under a caller-chosen id: the immersive page draws the
    /// same game in more than one row, so `cover-play` alone would collide.
    pub(crate) fn play_circle(
        &self,
        id: impl Into<ElementId>,
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
            .id(id)
            .absolute()
            .top(px(10. + (1. - amount) * 5.))
            .right(px(10.))
            .justify_center()
            .size(px(30.))
            .rounded_full()
            // Fades in translucent and saturates to the accent as the card's
            // hover peaks — the same grey→orange language as the text buttons.
            .bg(rgba(mix_rgba(
                play_circle_bg(),
                fade_rgb(ACCENT, 0.95),
                amount,
            )))
            .opacity(amount)
            .child(icon("play", 15.));
        if let Some(action) = action {
            let view = cx.entity().downgrade();
            circle = circle
                .cursor_pointer()
                .hover(|s| s.bg(rgb(0xff9c3a)))
                .on_click(move |_, _, cx| {
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
    ) -> Stateful<Div> {
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
        let layout = LibraryLayout::shelf_with_width(&indices, width, self.cover_width, |i| {
            self.mixed && self.game(i).is_some_and(|game| game.landscape)
        });
        // The control reads these to show the size an automatic shelf picked
        // and which flush levels the current row width offers.
        self.cover_unit.set(layout.cover_width);
        self.cover_span.set(crate::library_layout::shelf_available(width));
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
                self.cover(index, rect.width, rect.height, true, window, cx),
            ));
        }
        if indices.is_empty() {
            content = content.child(muted(self.empty_library_message()).p(px(30.)));
        }
        self.library_viewport(0, content)
    }
    /// Default run button: grey glass at rest, orange under the pointer. The
    /// timeline family passes a card-hover `lit` instead, so the accent
    /// already rises as the cursor reaches the card.
    pub(crate) fn play_button(
        &self,
        id: impl Into<ElementId>,
        index: usize,
        demo_label: &'static str,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        self.play_button_toned(id, index, demo_label, 0., cx)
    }
    /// A play button whose accent fades in with `lit` (0 idle → 1 hot). The
    /// timeline family keeps a row of these calm: they stay muted glass until
    /// their own card is hovered, so the accent lands where the cursor is.
    pub(crate) fn play_button_toned(
        &self,
        id: impl Into<ElementId>,
        index: usize,
        demo_label: &'static str,
        lit: f32,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
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
                .bg(rgba(hover_strong()))
                .text_color(rgb(muted_color()))
                .child(Spinner::new().with_size(px(12.)))
                .child(label);
        } else if enabled {
            let leading = match action {
                Some(RuntimeAction::Cancel) => icon("x", 13.),
                Some(RuntimeAction::Stop) => icon("square", 12.),
                _ => icon("play", 13.),
            };
            button = button
                .bg(rgba(mix_rgba(hover_strong(), fade_rgb(ACCENT, 1.), lit)))
                .text_color(rgb(mix_rgb(muted_color(), 0xffffff, lit)))
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
                .bg(rgba(hover_strong()))
                .text_color(rgb(muted_color()))
                .child(leading.into_any_element())
                .child(label);
        }
        button
    }
    /// Ordered indices for the timeline family (list and staggered). The demo
    /// keeps its hand-tuned featured order for the default sort; every other
    /// case uses the same memoised order as the other modes.
    pub(crate) fn timeline_ordered(&self, cx: &mut Context<Self>) -> Vec<usize> {
        let games = self.games();
        if self.demo && self.preview.sort == 0 {
            let mut indices = self.filtered(cx);
            let featured = [
                "Northwind Signal",
                "Saltlight",
                "Quiet Frequency",
                "Emberline",
            ];
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
        }
    }
    pub(crate) fn timeline(&self, width: f32, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let games = self.games();
        let indices = self.timeline_ordered(cx);
        let rail = if width > 1000. { 100. } else { 48. };
        let cw = if width > 1000. { 145. } else { 125. };
        let ch = cw * 1.5 + 26.;
        let layout = LibraryLayout::timeline(&indices, width);
        let mut content = div()
            .relative()
            .w_full()
            .h(px(layout.height.max(100.)))
            .flex_shrink_0();
        // Node → card links, collected while the rows build and painted by one
        // overlay canvas afterwards (the canvas has no hitboxes).
        let mut links = Vec::new();
        for (position, (index, target)) in layout.cards.into_iter().enumerate() {
            let rect = self.animated_rect(index, target, window, cx);
            let g = &games[index];
            let mut meta = row().flex_shrink_0().flex_wrap().gap(px(7.)).mt(px(3.));
            if self.demo {
                meta = meta
                    .child(icon("clock-3", 12.).text_color(rgb(muted_color())))
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
                        .child(icon("clock-3", 12.).text_color(rgb(muted_color())))
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
            // A hovered row grows its link from the rail node to the card
            // edge; the same curve as the staggered rail, always left→right.
            if hover > 0.005 {
                let node_y = rect.y + ch / 2.;
                links.push(connector_curve(
                    (rect.x + rail * 0.55 + 4.5, node_y),
                    (rect.x + rail + 17., node_y),
                    hover,
                ));
            }
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
                                        .bg(rgba(surface_border())),
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
                                            timeline_dot_idle()
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
                                .bg(rgba(if hover > 0.1 { hover_strong() } else { card_bg() }))
                                .border_1()
                                .border_color(rgba(card_border()))
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
                                            Some(path) => self.artwork_image(path)
                                                .size_full()
                                                .object_fit(ObjectFit::Cover)
                                                .into_any_element(),
                                            None => {
                                                let (ph_start, ph_end) = placeholder_gradient();
                                                div()
                                                    .size_full()
                                                    .bg(gradient(ph_start, ph_end))
                                                    .flex()
                                                    .items_center()
                                                    .justify_center()
                                                    .child(
                                                        icon("package", 26.)
                                                            .text_color(rgb(muted_color())),
                                                    )
                                                    .into_any_element()
                                            }
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
                                                    .text_color(rgb(subtext()))
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
                                        .child(self.play_button_toned(
                                            ("timeline-play", index),
                                            index,
                                            "继续游玩",
                                            hover,
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
        content = content.child(
            canvas(
                move |_, _, _| links,
                move |bounds, links: Vec<ConnectorPaint>, window, _| {
                    paint_connectors(bounds.origin, &links, window)
                },
            )
            .absolute()
            .inset_0(),
        );
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
                .bg(rgba(card_bg()))
                .border_1()
                .border_color(rgba(card_border()))
                .child(self.cover(i, rect.width, (rect.height - 55.).max(1.), true, window, cx))
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
    /// The five interactive stars alone, sized by `star`; callers add their
    /// own label and numeric value around it.
    pub(crate) fn rating_stars(
        &self,
        index: usize,
        star: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
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
                    .w(px(star / 2.))
                    .h(px(star))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| this.set_rating(index, points, cx)))
            };
            stars = stars.child(
                div()
                    .relative()
                    .w(px(star))
                    .h(px(star))
                    .child(icon("star", star).text_color(rgba(star_empty())))
                    .child(
                        div()
                            .absolute()
                            .top(px(0.))
                            .left(px(0.))
                            .h(px(star))
                            .w(px(star * f32::from(covered) / 2.))
                            .overflow_hidden()
                            .child(div().w(px(star)).h(px(star)).child(icon("star", star).text_color(rgb(ACCENT)))),
                    )
                    .child(half(usize::from(slot) * 2, slot * 2 + 1, 0.))
                    .child(half(usize::from(slot) * 2 + 1, slot * 2 + 2, star / 2.)),
            );
        }
        stars.into_any_element()
    }

    pub(crate) fn rating_row(&self, index: usize, cx: &mut Context<Self>) -> AnyElement {
        let current = self.game(index).and_then(|game| game.rating);
        row()
            .gap(px(10.))
            .items_center()
            .child(muted("评分"))
            .child(self.rating_stars(index, 20., cx))
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
        // The hero cover is a fixed 190 points wide.
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
        let (ph_start, ph_end) = placeholder_gradient();
        div()
            .absolute()
            .inset_0()
            // Modal hitboxes must also block wheel events, including at scroll boundaries.
            .occlude()
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .bg(rgba(overlay()))
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
                    .border_color(rgba(surface_border()))
                    .bg(rgb(crate::theme::surface()))
                    .child(
                        div()
                            .absolute()
                            .size_full()
                            .when_some(backdrop, |d, path| {
                                d.child(
                                    self.artwork_image(path)
                                        .size_full()
                                        .object_fit(ObjectFit::Cover)
                                        .opacity(if is_dark() { 0.22 } else { 0.12 }),
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
                            .child(muted("游戏详情").text_color(rgb(subtext())))
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
                                                Some(path) => self.cover_image(path, cx)
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
                                                    .bg(gradient(ph_start, ph_end))
                                                    .flex()
                                                    .items_center()
                                                    .justify_center()
                                                    .child(
                                                        icon("package", 34.)
                                                            .text_color(rgb(muted_color())),
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
                                                .bg(rgba(card_bg()))
                                                .border_1()
                                                .border_color(rgba(card_border()))
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
                                                        .text_color(rgb(subtext()))
                                                        .line_height(relative(1.65))
                                                        .child(description),
                                                ),
                                        )
                                    })
                                    .child(self.detail_character_cards(index, cx))
                                    .child(self.detail_walkthroughs(index, cx)),
                            ),
                        ),
                    ),
            )
            .into_any_element()
    }

    fn detail_character_cards(&self, index: usize, cx: &Context<Self>) -> AnyElement {
        let Some(game) = self.game(index) else {
            return div().into_any_element();
        };
        let Some(characters) = game
            .metadata
            .as_ref()
            .and_then(|metadata| metadata.characters.as_ref())
            .filter(|characters| !characters.is_empty())
        else {
            return div().into_any_element();
        };
        let selected_character = self
            .detail_character
            .as_deref()
            .and_then(|id| characters.iter().find(|c| c.id == id));
        col()
            .gap(px(14.))
            .p(px(20.))
            .rounded(px(12.))
            .bg(rgba(card_bg()))
            .border_1()
            .border_color(rgba(card_border()))
            .child(
                row()
                    .justify_between()
                    .items_center()
                    .child(
                        row()
                            .gap(px(8.))
                            .items_center()
                            .child(icon("users", 16.).text_color(rgb(ACCENT)))
                            .child(div().font_weight(FontWeight::SEMIBOLD).child("登场人物"))
                            .child(
                                div()
                                    .px(px(8.))
                                    .py(px(2.))
                                    .rounded_full()
                                    .bg(rgba(badge_bg()))
                                    .text_size(px(11.))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(rgb(muted_color()))
                                    .child(characters.len().to_string()),
                            ),
                    )
                    .child(muted("点击卡片查看角色详情").text_size(px(11.))),
            )
            .when_some(selected_character, |d, character| {
                d.child(self.character_showcase_card(
                    character,
                    characters,
                    &game.character_images,
                    false,
                    cx,
                ))
            })
            .child(self.character_cards(characters, &game.character_images, Some(index), cx))
            .into_any_element()
    }

    /// Rich character showcase card shared by the Game Detail panel and the Game Info modal.
    pub(crate) fn character_showcase_card(
        &self,
        character: &crate::bridge::dto::CharacterDto,
        characters: &[crate::bridge::dto::CharacterDto],
        images: &std::collections::BTreeMap<String, String>,
        in_game_info: bool,
        cx: &Context<Self>,
    ) -> AnyElement {
        let ordered = characters_in_display_order(characters, images);
        let total = ordered.len();
        let pos = ordered
            .iter()
            .position(|c| c.id == character.id)
            .unwrap_or(0);
        let prev_id = pos.checked_sub(1).and_then(|i| ordered.get(i)).map(|c| c.id.clone());
        let next_id = ordered.get(pos + 1).map(|c| c.id.clone());

        let original_name = character
            .original_name
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty() && *s != character.name);
        let role = character
            .role
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let voice_actor = character
            .voice_actor
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let summary = character
            .summary
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("暂无该角色的详细简介。");

        let portrait = match images.get(&character.id) {
            Some(path) => self.artwork_image(std::path::PathBuf::from(path))
                .w_full()
                .h_full()
                .object_fit(ObjectFit::Contain)
                .into_any_element(),
            None => col()
                .size_full()
                .items_center()
                .justify_center()
                .gap(px(8.))
                .child(icon("user", 32.).text_color(rgb(muted_color())))
                .child(muted("暂无立绘").text_size(px(12.)))
                .into_any_element(),
        };

        let nav_bar = row()
            .justify_between()
            .items_center()
            .pb(px(10.))
            .border_b_1()
            .border_color(rgba(divider()))
            .child(
                Button::new("character-back")
                    .label("‹ 返回人物列表")
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if in_game_info {
                            if let Some(page) = this.game_info.as_mut() {
                                page.selected_character = None;
                            }
                        } else {
                            this.detail_character = None;
                        }
                        cx.notify();
                    })),
            )
            .when(total > 1, |d| {
                d.child(
                    row()
                        .gap(px(8.))
                        .items_center()
                        .child(
                            muted(format!("{} / {}", pos + 1, total))
                                .text_size(px(12.))
                                .font_weight(FontWeight::MEDIUM),
                        )
                        .child(
                            Button::new("character-prev")
                                .label("‹ 上一位")
                                .disabled(prev_id.is_none())
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if let Some(id) = prev_id.clone() {
                                        if in_game_info {
                                            if let Some(page) = this.game_info.as_mut() {
                                                page.selected_character = Some(id);
                                            }
                                        } else {
                                            this.detail_character = Some(id);
                                        }
                                        cx.notify();
                                    }
                                })),
                        )
                        .child(
                            Button::new("character-next")
                                .label("下一位 ›")
                                .disabled(next_id.is_none())
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if let Some(id) = next_id.clone() {
                                        if in_game_info {
                                            if let Some(page) = this.game_info.as_mut() {
                                                page.selected_character = Some(id);
                                            }
                                        } else {
                                            this.detail_character = Some(id);
                                        }
                                        cx.notify();
                                    }
                                })),
                        ),
                )
            });

        col()
            .id("character-showcase")
            .gap(px(16.))
            .p(px(18.))
            .rounded(px(14.))
            .bg(rgba(section_bg()))
            .border_1()
            .border_color(rgba(surface_border()))
            .child(nav_bar)
            .child(
                row()
                    .items_start()
                    .gap(px(22.))
                    .child(
                        col()
                            .w(px(180.))
                            .flex_shrink_0()
                            .gap(px(10.))
                            .child(
                                div()
                                    .w(px(180.))
                                    .h(px(246.))
                                    .rounded(px(12.))
                                    .overflow_hidden()
                                    .bg(rgba(portrait_bg()))
                                    .border_1()
                                    .border_color(rgba(surface_border()))
                                    .p(px(6.))
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .child(portrait),
                            )
                            .when_some(voice_actor, |d, actor| {
                                d.child(
                                    row()
                                        .w_full()
                                        .gap(px(7.))
                                        .px(px(10.))
                                        .py(px(7.))
                                        .rounded(px(8.))
                                        .bg(rgba(badge_bg()))
                                        .border_1()
                                        .border_color(rgba(card_border()))
                                        .child(icon("mic", 13.).text_color(rgb(ACCENT)))
                                        .child(
                                            div()
                                                .text_size(px(11.))
                                                .font_weight(FontWeight::SEMIBOLD)
                                                .text_color(rgb(ACCENT))
                                                .child("CV"),
                                        )
                                        .child(
                                            div()
                                                .flex_1()
                                                .min_w_0()
                                                .truncate()
                                                .text_size(px(12.))
                                                .font_weight(FontWeight::MEDIUM)
                                                .text_color(rgb(text()))
                                                .child(actor.to_owned()),
                                        ),
                                )
                            }),
                    )
                    .child(
                        col()
                            .flex_1()
                            .min_w_0()
                            .gap(px(12.))
                            .child(
                                col()
                                    .gap(px(6.))
                                    .child(
                                        row()
                                            .flex_wrap()
                                            .gap(px(10.))
                                            .items_center()
                                            .child(
                                                div()
                                                    .text_size(px(22.))
                                                    .font_weight(FontWeight::BOLD)
                                                    .line_height(relative(1.25))
                                                    .text_color(rgb(text()))
                                                    .child(character.name.clone()),
                                            )
                                            .when_some(role, |d, r| {
                                                d.child(
                                                    div()
                                                        .px(px(10.))
                                                        .py(px(3.))
                                                        .rounded_full()
                                                        .bg(rgba(0xff891b22))
                                                        .border_1()
                                                        .border_color(rgba(0xff891b55))
                                                        .text_size(px(11.))
                                                        .font_weight(FontWeight::SEMIBOLD)
                                                        .text_color(rgb(ACCENT))
                                                        .child(r.to_owned()),
                                                )
                                            }),
                                    )
                                    .when_some(original_name, |d, orig| {
                                        d.child(muted(orig).text_size(px(13.)))
                                    }),
                            )
                            .child(div().w_full().h(px(1.)).bg(rgba(divider())))
                            .child(
                                col()
                                    .gap(px(8.))
                                    .child(
                                        row()
                                            .gap(px(6.))
                                            .items_center()
                                            .child(
                                                div()
                                                    .w(px(3.))
                                                    .h(px(13.))
                                                    .rounded_full()
                                                    .bg(rgb(ACCENT)),
                                            )
                                            .child(
                                                div()
                                                    .text_size(px(12.))
                                                    .font_weight(FontWeight::SEMIBOLD)
                                                    .text_color(rgb(muted_color()))
                                                    .child("人物简介"),
                                            ),
                                    )
                                    .child(
                                        div()
                                            .text_size(px(13.))
                                            .text_color(rgb(subtext()))
                                            .line_height(relative(1.75))
                                            .child(summary.to_owned()),
                                    ),
                            ),
                    ),
            )
            .into_any_element()
    }

    pub(crate) fn character_cards(
        &self,
        characters: &[crate::bridge::dto::CharacterDto],
        images: &std::collections::BTreeMap<String, String>,
        open_game: Option<usize>,
        cx: &Context<Self>,
    ) -> AnyElement {
        let selected_id = if open_game.is_some() {
            self.detail_character.as_deref()
        } else {
            self.game_info
                .as_ref()
                .and_then(|page| page.selected_character.as_deref())
        };
        let mut cards = row()
            .id("detail-character-cards")
            .items_start()
            .gap(px(14.))
            .overflow_x_scroll();
        // Match the portrait lookup below and retain provider order within each group.
        for character in characters_in_display_order(characters, images) {
            let id = character.id.clone();
            let is_selected = selected_id == Some(character.id.as_str());
            let role = character
                .role
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty());
            let original_name = character
                .original_name
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty() && *s != character.name);
            let voice_actor = character
                .voice_actor
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty());
            let summary = character
                .summary
                .as_deref()
                .map(|s| s.split_whitespace().collect::<Vec<_>>().join(" "))
                .filter(|s| !s.is_empty());

            let portrait_frame = div()
                .relative()
                .w_full()
                .h(px(CHARACTER_PORTRAIT_HEIGHT))
                .flex_shrink_0()
                .rounded(px(8.))
                .overflow_hidden()
                .bg(rgba(portrait_bg()))
                .border_1()
                .border_color(rgba(card_border()))
                .child(match images.get(&character.id) {
                    Some(path) => CharacterPortrait { path: path.into() }.into_any_element(),
                    None => character_portrait_placeholder("暂无头像"),
                })
                .when_some(role, |d, r| {
                    d.child(
                        div()
                            .absolute()
                            .top(px(6.))
                            .left(px(6.))
                            .px(px(7.))
                            .py(px(2.))
                            .rounded_full()
                            .bg(rgba(role_chip_bg()))
                            .text_size(px(10.))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(rgb(role_chip_text()))
                            .child(r.to_owned()),
                    )
                });

            let mut info = col().flex_1().min_h_0().w_full().gap(px(3.));
            info = info.child(
                div()
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_size(px(13.))
                    .truncate()
                    .child(character.name.clone()),
            );
            if let Some(orig) = original_name {
                info = info.child(muted(orig).text_size(px(11.)).truncate());
            }
            if let Some(actor) = voice_actor {
                info = info.child(
                    row()
                        .gap(px(4.))
                        .items_center()
                        .child(icon("mic", 11.).text_color(rgb(ACCENT)))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .truncate()
                                .text_size(px(11.))
                                .text_color(rgb(ACCENT))
                                .child(actor.to_owned()),
                        ),
                );
            }
            if let Some(summary) = summary {
                info = info.child(
                    muted(summary)
                        .mt(px(2.))
                        .text_size(px(11.))
                        .line_height(px(15.))
                        .overflow_hidden()
                        .line_clamp(2),
                );
            }

            let card = col()
                .id(format!("detail-character:{}", character.id))
                .w(px(CHARACTER_CARD_WIDTH))
                .h(px(272.))
                .flex_shrink_0()
                .gap(px(8.))
                .p(px(CHARACTER_CARD_PADDING))
                .overflow_hidden()
                .rounded(px(12.))
                .border_1()
                .border_color(rgba(if is_selected {
                    if is_dark() { 0xff891baa } else { 0x00000038 }
                } else {
                    card_border()
                }))
                .bg(rgba(if is_selected { selected_bg() } else { card_bg() }))
                .cursor_pointer()
                .hover(|style| {
                    style.bg(rgba(if is_selected {
                        selected_bg()
                    } else {
                        hover_strong()
                    }))
                })
                .on_click(cx.listener(move |this, _, _, cx| {
                    if open_game.is_some() {
                        if this.detail_character.as_deref() == Some(id.as_str()) {
                            this.detail_character = None;
                        } else {
                            this.detail_character = Some(id.clone());
                        }
                    }
                    if let Some(page) = this.game_info.as_mut() {
                        page.selected_character = Some(id.clone());
                    }
                    cx.notify();
                }))
                .child(portrait_frame)
                .child(info);
            cards = cards.child(card);
        }
        cards.into_any_element()
    }
}
