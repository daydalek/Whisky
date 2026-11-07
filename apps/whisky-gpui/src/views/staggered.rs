//! Staggered two-column timeline: cards alternate left and right of a centred
//! rail, every card owns a node on it, and the focused card is tied to its
//! node by an orange Bézier connector. Selection lives in
//! `WhiskyApp::staggered_selection` keyed by `(container, id)`.

use std::time::Duration;

use gpui_kit::base::{Presence, Spring, spring, transition};
use gpui_kit::component::menu::ContextMenuExt;
use gpui_kit::{prelude::*, *};

use crate::controls::*;
use crate::library_layout::{
    CardRect, LibraryLayout, StaggeredCard, StaggeredLayout, StaggeredSide,
};
use crate::runtime::RuntimeState;
use crate::state::WhiskyApp;
use crate::theme::*;
use crate::views::{
    ConnectorPaint, connector_curve, fade_rgb, mix_rgb, mix_rgba, paint_connectors,
};

/// The opacity an unfocused card fades to while another card holds focus.
const DIMMED: f32 = 0.5;
/// Rail node radii: idle, focused, and the soft accent ring behind it.
const NODE_RADIUS: f32 = 4.;
const NODE_FOCUS_RADIUS: f32 = 6.;
const NODE_GLOW_RADIUS: f32 = 10.;
/// Date chip centred on the rail.
const MARKER_WIDTH: f32 = 92.;
const MARKER_HEIGHT: f32 = 22.;

/// One rail node, in content space.
struct NodePaint {
    x: f32,
    y: f32,
    radius: f32,
    glow_alpha: f32,
    color: u32,
}

/// Everything the overlay canvas paints, in content space.
struct RailPaint {
    rail_x: f32,
    top: f32,
    bottom: f32,
    nodes: Vec<NodePaint>,
    connectors: Vec<ConnectorPaint>,
}

fn disc(origin: Point<Pixels>, radius: f32, color: impl Into<Background>) -> PaintQuad {
    fill(
        Bounds {
            origin: origin - point(px(radius), px(radius)),
            size: size(px(radius * 2.), px(radius * 2.)),
        },
        color,
    )
    .corner_radii(px(radius))
}

fn paint_rail(origin: Point<Pixels>, rail: &RailPaint, window: &mut Window) {
    let to_window = |p: (f32, f32)| origin + point(px(p.0), px(p.1));
    if rail.bottom > rail.top {
        window.paint_quad(fill(
            Bounds {
                origin: to_window((rail.rail_x - 0.75, rail.top)),
                size: size(px(1.5), px(rail.bottom - rail.top)),
            },
            rgba(surface_border()),
        ));
    }
    paint_connectors(origin, &rail.connectors, window);
    for node in &rail.nodes {
        let centre = to_window((node.x, node.y));
        if node.glow_alpha > 0.01 {
            window.paint_quad(disc(
                centre,
                NODE_GLOW_RADIUS,
                rgba(fade_rgb(ACCENT, node.glow_alpha)),
            ));
        }
        window.paint_quad(disc(centre, node.radius, rgb(node.color)));
    }
}

impl WhiskyApp {
    /// Date-group label for the staggered rail. The demo keeps its hand-tuned
    /// pair of groups; real entries group by the last-played date the library
    /// already records, and unplayed entries tail into their own group.
    fn staggered_group_label(&self, index: usize, position: usize) -> Option<String> {
        if self.demo {
            return Some(if position < 4 { "今天" } else { "更早" }.to_owned());
        }
        let game = self.game(index)?;
        Some(match game.last_played {
            Some(unix) => crate::model::format_last_played(Some(unix))?,
            None => "未游玩".to_owned(),
        })
    }

    pub(crate) fn staggered(
        &self,
        width: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // Same order the single-column list draws — the column switch
        // reshapes the rail, it never reshuffles the games.
        let indices = self.timeline_ordered(cx);
        let selected = self.staggered_selected_index(&indices);
        let focus = self.timing(FOCUS_MS);
        let layout = LibraryLayout::staggered(&indices, width, |index, position| {
            self.staggered_group_label(index, position)
        });
        // A click that lands between cards (not on one) clears the selection.
        let mut content = div()
            .id("staggered-content")
            .relative()
            .w_full()
            .h(px(layout.height.max(100.)))
            .flex_shrink_0()
            .on_click(cx.listener(|this, _, _, cx| this.clear_staggered(cx)));
        let mut nodes = Vec::with_capacity(layout.cards.len());
        let mut connectors = Vec::with_capacity(2);
        for card in &layout.cards {
            let StaggeredCard {
                index,
                rect: target,
                side,
                ..
            } = *card;
            let rect = self.animated_rect(index, target, window, cx);
            let focused = selected == Some(index);
            // The node and its connector light while the card is hot —
            // hovered or selected — so the link previews on hover and stays
            // lit once the card owns focus.
            let presence = Presence::new(
                ElementId::from(("staggered-focus", index)),
                focused || self.hovered == Some(index),
            )
            .transition(focus.clone())
            .sample(window, cx);
            // The card's own accent (frame and tint) is selection-only.
            let emphasis = transition(
                ElementId::from(("staggered-accent", index)),
                if focused { 1_f32 } else { 0. },
                focus.clone(),
                window,
                cx,
            );
            let node_y = rect.y + rect.height / 2.;
            let radius = NODE_RADIUS + (NODE_FOCUS_RADIUS - NODE_RADIUS) * presence.progress;
            nodes.push(NodePaint {
                x: layout.rail_x,
                y: node_y,
                radius,
                glow_alpha: presence.progress * 0.3,
                color: mix_rgb(timeline_dot_idle(), ACCENT, presence.progress),
            });
            if presence.progress > 0.005 {
                let (edge, direction) = match side {
                    StaggeredSide::Left => (rect.x + rect.width, -1.),
                    StaggeredSide::Right => (rect.x, 1.),
                };
                connectors.push(connector_curve(
                    (layout.rail_x + direction * radius, node_y),
                    (edge, node_y),
                    presence.progress,
                ));
            }
            let dim = match selected {
                Some(selection) if selection != index => DIMMED,
                _ => 1.,
            };
            let opacity = transition(
                ElementId::from(("staggered-dim", index)),
                dim,
                focus.clone(),
                window,
                cx,
            );
            content = content.child(
                self.card_slot(
                    index,
                    rect,
                    self.staggered_card(index, rect, &layout, emphasis, window, cx),
                )
                .opacity(opacity),
            );
        }
        if indices.is_empty() {
            content = content.child(muted(self.empty_library_message()).p(px(30.)));
        }
        let paint = RailPaint {
            rail_x: layout.rail_x,
            top: layout.rail_top,
            bottom: layout.rail_bottom,
            nodes,
            connectors,
        };
        // The overlay canvas has no id and registers no hitboxes, so it can
        // never swallow card clicks, menus or scroll gestures. It is drawn
        // after the cards, letting a connector end visibly on its card edge.
        content = content.child(
            canvas(
                move |_, _, _| paint,
                move |bounds, paint: RailPaint, window, _| {
                    paint_rail(bounds.origin, &paint, window)
                },
            )
            .absolute()
            .inset_0(),
        );
        // Markers sit on the rail above the overlay; a group boundary already
        // reserved the space they need inside the layout. The key is the
        // marker's position, not its text — a re-sort can legitimately put
        // the same label on two chips.
        for (marker, (target_y, label)) in layout.markers.iter().enumerate() {
            let chip_y = spring(
                ElementId::from(("staggered-marker", marker)),
                *target_y,
                self.staggered_marker_spring(),
                window,
                cx,
            );
            content = content.child(
                div()
                    .absolute()
                    .left(px(layout.rail_x - MARKER_WIDTH / 2.))
                    .top(px(chip_y - MARKER_HEIGHT / 2.))
                    .w(px(MARKER_WIDTH))
                    .h(px(MARKER_HEIGHT))
                    .rounded_full()
                    .bg(rgb(crate::theme::surface()))
                    .border_1()
                    .border_color(rgba(surface_border()))
                    .flex()
                    .items_center()
                    .justify_center()
                    .text_size(px(11.))
                    .text_color(rgb(muted_color()))
                    .child(label.clone()),
            );
        }
        self.library_viewport(crate::preferences::STAGGERED_MODE, content)
    }

    /// Marker chips share the card spring so a re-sort slides them to their
    /// new slots instead of jumping.
    fn staggered_marker_spring(&self) -> Spring {
        Spring::new(Duration::from_millis(if self.lively {
            LIVELY_SPRING_MS
        } else {
            SPRING_MS
        }))
        .with_epsilon(0.1)
        .with_travel(self.motion)
        .with_damping(if self.lively { 0.68 } else { 0.86 })
    }

    /// One staggered card: cover, metadata, actions — the same content the
    /// list timeline draws, re-laid for the narrower two-column cell.
    fn staggered_card(
        &self,
        index: usize,
        rect: CardRect,
        layout: &StaggeredLayout,
        focus: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let games = self.games();
        let g = &games[index];
        let mut meta = row()
            .flex_shrink_0()
            .flex_wrap()
            .gap(px(6.))
            // Two rows of badges at most; a long bottle list clips rather
            // than overflowing the fixed-height card.
            .max_h(px(46.))
            .overflow_hidden();
        if self.demo {
            meta = meta
                .child(icon("clock-3", 11.).text_color(rgb(muted_color())))
                .child(muted(if index % 2 == 0 {
                    "晚上7:39"
                } else {
                    "下午6:39"
                }))
                .child(badge("package", self.bottle_name_at(g.bottle)))
                .child(badge("clock-3", "8分钟"));
        } else {
            if let Some(label) = crate::model::format_last_played(g.last_played) {
                meta = meta
                    .child(icon("clock-3", 11.).text_color(rgb(muted_color())))
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
            ElementId::from(("staggered-hover", index)),
            if self.hovered == Some(index) {
                1_f32
            } else {
                0.
            },
            self.timing(HOVER_MS),
            window,
            cx,
        );
        // The focused card borrows the accent for its frame; hovered cards get
        // the usual strong glass regardless of focus.
        let base = if hover > 0.1 {
            hover_strong()
        } else {
            card_bg()
        };
        let background = mix_rgba(base, fade_rgb(ACCENT, 0.1), focus);
        let border = mix_rgba(card_border(), fade_rgb(ACCENT, 0.62), focus);
        row()
            .id(("staggered", index))
            .size_full()
            .items_start()
            .gap(px(14.))
            .p(px(13.))
            .rounded(px(16.))
            .bg(rgba(background))
            .border_1()
            .border_color(rgba(border))
            .on_hover(cx.listener(move |this, active, _, cx| {
                this.hovered = if *active { Some(index) } else { None };
                this.ambient_index = index;
                cx.notify();
            }))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.select_staggered(index, cx);
                cx.stop_propagation();
            }))
            .context_menu(self.game_menu(index, cx))
            .child(
                div()
                    .id(("staggered-art", index))
                    .w(px(layout.cover_width))
                    .h(px((rect.height - 26.).max(20.)))
                    .flex_shrink_0()
                    .rounded(px(8.))
                    .overflow_hidden()
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.select_staggered(index, cx);
                        this.open_detail(index, cx);
                        cx.stop_propagation();
                    }))
                    .child(match self.artwork(index) {
                        Some(path) => self
                            .artwork_image(path)
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
                                .child(icon("package", 24.).text_color(rgb(muted_color())))
                                .into_any_element()
                        }
                    }),
            )
            .child(
                col()
                    .flex_1()
                    .min_w_0()
                    .justify_center()
                    .h_full()
                    .gap(px(6.))
                    .child(
                        div()
                            .text_size(px(15.))
                            .line_height(relative(1.25))
                            .font_weight(FontWeight::BOLD)
                            .flex_shrink_0()
                            .truncate()
                            .child(g.title.clone()),
                    )
                    .when(self.demo || g.studio.is_some(), |d| {
                        d.child(muted(g.studio()).flex_shrink_0().truncate())
                    })
                    .child(meta)
                    .when(!layout.compact && g.description.is_some(), |d| {
                        d.child(
                            div()
                                .mt(px(2.))
                                .text_size(px(12.))
                                .text_color(rgb(subtext()))
                                .line_height(relative(1.5))
                                .flex_1()
                                .min_h_0()
                                .max_h(px(12. * 1.5 * 2.))
                                .overflow_hidden()
                                .line_clamp(2)
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
                    .gap(px(9.))
                    .w(px(if layout.compact { 82. } else { 96. }))
                    .flex_shrink_0()
                    .child(self.play_button_toned(
                        ("staggered-play", index),
                        index,
                        "游玩",
                        hover,
                        cx,
                    ))
                    .child(self.game_options(index, cx)),
            )
    }
}
