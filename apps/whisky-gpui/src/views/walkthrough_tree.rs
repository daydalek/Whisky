//! Native zoomable graph canvas for NextMoe routes.
use crate::{controls::*, state::WhiskyApp, theme::*, walkthrough_tree::*};
use gpui_kit::component::{
    Sizable,
    button::{Button, ButtonVariants},
};
use gpui_kit::{prelude::*, *};

fn tint(kind: Kind) -> u32 {
    match kind {
        Kind::Entry => 0x3b82f6,
        Kind::Save => 0xf59e0b,
        Kind::Ending => 0x10b981,
        Kind::Branch => 0x8b5cf6,
        Kind::Choice => 0x64748b,
        Kind::Note => 0x06b6d4,
    }
}
fn label(kind: Kind) -> &'static str {
    match kind {
        Kind::Entry => "入口",
        Kind::Save => "存档",
        Kind::Ending => "结局",
        Kind::Branch => "路线",
        Kind::Choice => "选项",
        Kind::Note => "提示",
    }
}

impl WhiskyApp {
    /// Header, mode switch and body shared by the inline card and the large canvas.
    pub(crate) fn walkthrough_chart(
        &self,
        chart: &serde_json::Value,
        scope: &str,
        fullscreen: bool,
        cx: &Context<Self>,
    ) -> AnyElement {
        let dark = is_dark();
        let chrome = if dark { 0x181e29 } else { 0xffffff };
        let border = if dark { 0x303949 } else { 0xe0e6ef };
        let graph = self.walkthrough_view.graph;
        let original = self.walkthrough_view.original;
        let segment = |id: &'static str, label: &'static str, active: bool| {
            div()
                .id(id)
                .px(px(12.))
                .py(px(4.))
                .rounded(px(6.))
                .text_size(px(12.))
                .cursor_pointer()
                .when(active, |d| {
                    d.bg(rgb(if dark { 0x2c3647 } else { 0xffffff }))
                        .font_weight(FontWeight::SEMIBOLD)
                        .shadow_sm()
                })
                .when(!active, |d| d.text_color(rgb(muted_color())))
                .child(label)
        };
        let switch = row()
            .p(px(2.))
            .gap(px(2.))
            .rounded(px(8.))
            .bg(rgb(if dark { 0x111720 } else { 0xeef1f6 }))
            .child(segment("tree-mode-routes", "路线", !graph).on_click(cx.listener(
                |this, _, _, cx| {
                    this.walkthrough_view.graph = false;
                    cx.notify();
                },
            )))
            .child(segment("tree-mode-graph", "关系图", graph).on_click(cx.listener(
                |this, _, _, cx| {
                    this.walkthrough_view.graph = true;
                    this.walkthrough_view.camera.needs_fit = true;
                    cx.notify();
                },
            )));
        let (body, graph_tools) = if graph {
            let (body, tools) = self.walkthrough_graph(chart, scope, fullscreen, cx);
            (body, Some(tools))
        } else {
            (self.walkthrough_reader(chart, fullscreen, cx), None)
        };
        col()
            .w_full()
            .when(fullscreen, |d| d.flex_1().min_h_0())
            .rounded(px(12.))
            .overflow_hidden()
            .border_1()
            .border_color(rgb(border))
            .child(
                row()
                    .flex_wrap()
                    .gap(px(10.))
                    .px(px(14.))
                    .py(px(8.))
                    .bg(rgb(chrome))
                    .border_b_1()
                    .border_color(rgb(border))
                    .child(switch)
                    .children(graph_tools)
                    .child(div().flex_1())
                    .child(
                        Button::new("tree-lang")
                            .small()
                            .ghost()
                            .label(if original { "显示：原文" } else { "显示：中文" })
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.walkthrough_view.original = !this.walkthrough_view.original;
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("tree-fullscreen")
                            .small()
                            .ghost()
                            .label(if fullscreen { "收起" } else { "大画布 ↗" })
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.walkthrough_view.fullscreen = !this.walkthrough_view.fullscreen;
                                this.walkthrough_view.camera.needs_fit = true;
                                cx.notify();
                            })),
                    ),
            )
            .child(body)
            .into_any_element()
    }

    fn walkthrough_graph(
        &self,
        chart: &serde_json::Value,
        scope: &str,
        fullscreen: bool,
        cx: &Context<Self>,
    ) -> (AnyElement, Div) {
        let tree = Tree::build(
            chart,
            scope,
            self.walkthrough_view.original,
            &self.walkthrough_view.expanded,
        );
        let extent = tree.extent;
        let zoom = self.walkthrough_view.camera.zoom;
        let pan = self.walkthrough_view.camera.pan;
        let dark = is_dark();
        let bg = if dark { 0x11151d } else { 0xf6f8fc };
        let foreground = if dark { 0xe5eaf3 } else { 0x243148 };
        let secondary = if dark { 0x94a3b8 } else { 0x718096 };
        let measure = self.walkthrough_view.viewport.clone();
        let entity = cx.entity().downgrade();
        let positions: Vec<_> = tree
            .nodes
            .iter()
            .map(|n| (n.x, n.y, tint(n.kind)))
            .collect();
        let edges = tree.edges.clone();
        let mut viewport = div()
            .id(if fullscreen {
                "tree-full"
            } else {
                "tree-inline"
            })
            .relative()
            .w_full()
            .overflow_hidden()
            .bg(rgb(bg))
            .when(fullscreen, |d| d.flex_1().min_h_0())
            .when(!fullscreen, |d| d.h(px(500.)))
            .on_scroll_wheel(cx.listener(|this, event: &ScrollWheelEvent, _, cx| {
                cx.stop_propagation();
                let mut delta = match event.delta {
                    ScrollDelta::Pixels(p) => [f32::from(p.x), f32::from(p.y)],
                    ScrollDelta::Lines(p) => [p.x * 36., p.y * 36.],
                };
                if event.modifiers.platform || event.modifiers.control {
                    let b = this.walkthrough_view.viewport.get();
                    this.walkthrough_view.camera.zoom_at(
                        (delta[1] * 0.006).exp(),
                        [f32::from(event.position.x) - b[0], f32::from(event.position.y) - b[1]],
                    );
                } else {
                    if event.modifiers.shift && delta[0].abs() < 0.01 {
                        delta = [delta[1], 0.];
                    }
                    this.walkthrough_view.camera.pan_by(delta);
                }
                cx.notify();
            }))
            .on_pinch(cx.listener(|this, event: &PinchEvent, _, cx| {
                cx.stop_propagation();
                let b = this.walkthrough_view.viewport.get();
                this.walkthrough_view.camera.zoom_at(
                    1. + event.delta,
                    [
                        f32::from(event.position.x) - b[0],
                        f32::from(event.position.y) - b[1],
                    ],
                );
                cx.notify();
            }))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, event: &MouseDownEvent, _, cx| {
                    this.walkthrough_view.drag =
                        Some([f32::from(event.position.x), f32::from(event.position.y)]);
                    cx.stop_propagation();
                }),
            )
            .on_mouse_move(cx.listener(|this, event: &MouseMoveEvent, _, cx| {
                if event.dragging() {
                    if let Some(previous) = this.walkthrough_view.drag {
                        let next = [f32::from(event.position.x), f32::from(event.position.y)];
                        for i in 0..2 {
                            this.walkthrough_view.camera.pan[i] += next[i] - previous[i];
                        }
                        this.walkthrough_view.drag = Some(next);
                        cx.notify();
                    }
                } else {
                    this.walkthrough_view.drag = None;
                }
            }))
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|this, _, _, _| this.walkthrough_view.drag = None),
            )
            .on_mouse_up_out(
                MouseButton::Left,
                cx.listener(|this, _, _, _| this.walkthrough_view.drag = None),
            )
            .child(
                canvas(
                    move |bounds, _, cx| {
                        let b = [
                            f32::from(bounds.origin.x),
                            f32::from(bounds.origin.y),
                            f32::from(bounds.size.width),
                            f32::from(bounds.size.height),
                        ];
                        measure.set(b);
                        let _ = entity.update(cx, |this, cx| {
                            if this.walkthrough_view.camera.needs_fit && b[2] > 0. && b[3] > 0. {
                                this.walkthrough_view.camera.fit(extent, [b[2], b[3]]);
                                cx.notify();
                            }
                        });
                    },
                    move |bounds, _, window, _| {
                        let origin = bounds.origin;
                        let w = f32::from(bounds.size.width);
                        let h = f32::from(bounds.size.height);
                        let mut dots = PathBuilder::stroke(px(1.4));
                        for x in 0..(w / 24.) as i32 + 1 {
                            for y in 0..(h / 24.) as i32 + 1 {
                                let p = origin
                                    + point(
                                        px(x as f32 * 24. + pan[0].rem_euclid(24.)),
                                        px(y as f32 * 24. + pan[1].rem_euclid(24.)),
                                    );
                                dots.move_to(p);
                                dots.line_to(p + point(px(0.6), px(0.)));
                            }
                        }
                        if let Ok(path) = dots.build() {
                            window.paint_path(path, rgb(if dark { 0x273140 } else { 0xdde3ee }));
                        }
                        for (a, b) in edges {
                            let from = positions[a];
                            let to = positions[b];
                            let start = origin
                                + point(
                                    px((from.0 + NODE_W) * zoom + pan[0]),
                                    px((from.1 + NODE_H / 2.) * zoom + pan[1]),
                                );
                            let end = origin
                                + point(
                                    px(to.0 * zoom + pan[0]),
                                    px((to.1 + NODE_H / 2.) * zoom + pan[1]),
                                );
                            let bend = px(36. * zoom);
                            let mut line = PathBuilder::stroke(px((1.7 * zoom).max(1.)));
                            line.move_to(start);
                            line.cubic_bezier_to(
                                end,
                                start + point(bend, px(0.)),
                                end - point(bend, px(0.)),
                            );
                            if let Ok(path) = line.build() {
                                window.paint_path(path, rgba((to.2 << 8) | 0x90));
                            }
                            let mut arrow = PathBuilder::stroke(px(1.5));
                            arrow.move_to(end - point(px(5. * zoom), px(3. * zoom)));
                            arrow.line_to(end);
                            arrow.line_to(end - point(px(5. * zoom), px(-3. * zoom)));
                            if let Ok(path) = arrow.build() {
                                window.paint_path(path, rgb(to.2));
                            }
                        }
                    },
                )
                .absolute()
                .size_full(),
            );
        for node in &tree.nodes {
            let route = node.route.clone();
            let expandable = route.is_some();
            let color = tint(node.kind);
            viewport = viewport.child(
                col()
                    .id(format!("node-{}", node.key))
                    .absolute()
                    .left(px(node.x * zoom + pan[0]))
                    .top(px(node.y * zoom + pan[1]))
                    .w(px(NODE_W * zoom))
                    .h(px(NODE_H * zoom))
                    .p(px(11. * zoom))
                    .gap(px(4. * zoom))
                    .rounded(px(10. * zoom))
                    .bg(rgb(if dark { 0x1d2430 } else { 0xffffff }))
                    .border_1()
                    .border_color(rgba((color << 8) | 0x65))
                    .overflow_hidden()
                    .text_color(rgb(foreground))
                    .cursor_pointer()
                    .hover(move |s| {
                        s.border_color(rgb(color))
                            .bg(rgb(if dark { 0x253043 } else { 0xfafcff }))
                    })
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if let Some(route) = route.clone() {
                            this.select_route(route, cx);
                        }
                        cx.stop_propagation();
                    }))
                    .child(
                        row()
                            .items_center()
                            .justify_between()
                            .text_size(px(9. * zoom))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(div().text_color(rgb(color)).child(label(node.kind)))
                            .child(div().text_color(rgb(secondary)).child(if expandable {
                                "阅读 ›"
                            } else {
                                ""
                            })),
                    )
                    .child(
                        div()
                            .h(px(30. * zoom))
                            .overflow_hidden()
                            .text_size(px(12. * zoom))
                            .font_weight(FontWeight::MEDIUM)
                            .child(node.label.clone()),
                    )
                    .child(
                        div()
                            .text_size(px(9. * zoom))
                            .text_color(rgb(secondary))
                            .text_ellipsis()
                            .child(node.detail.clone()),
                    ),
            );
        }
        let tools = row()
            .items_center()
            .gap(px(2.))
            .child(
                Button::new("tree-fit")
                    .small()
                    .ghost()
                    .label("适应画布")
                    .on_click(cx.listener(move |this, _, _, cx| {
                        let b = this.walkthrough_view.viewport.get();
                        this.walkthrough_view.camera.fit(extent, [b[2], b[3]]);
                        cx.notify();
                    })),
            )
            .child(
                Button::new("tree-actual-size")
                    .small()
                    .ghost()
                    .label("100%")
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.walkthrough_view.camera.readable();
                        cx.notify();
                    })),
            )
            .child(
                Button::new("tree-minus")
                    .small()
                    .ghost()
                    .label("−")
                    .on_click(cx.listener(|this, _, _, cx| {
                        let b = this.walkthrough_view.viewport.get();
                        this.walkthrough_view
                            .camera
                            .zoom_at(1. / 1.2, [b[2] / 2., b[3] / 2.]);
                        cx.notify();
                    })),
            )
            .child(muted(format!("{:.0}%", zoom * 100.)).text_size(px(11.)))
            .child(
                Button::new("tree-plus")
                    .small()
                    .ghost()
                    .label("＋")
                    .on_click(cx.listener(|this, _, _, cx| {
                        let b = this.walkthrough_view.viewport.get();
                        this.walkthrough_view
                            .camera
                            .zoom_at(1.2, [b[2] / 2., b[3] / 2.]);
                        cx.notify();
                    })),
            );
        let chrome = if dark { 0x181e29 } else { 0xffffff };
        let body = col()
            .w_full()
            .when(fullscreen, |d| d.flex_1().min_h_0())
            .child(viewport)
            .child(
                row()
                    .flex_wrap()
                    .gap(px(12.))
                    .px(px(14.))
                    .py(px(8.))
                    .bg(rgb(chrome))
                    .child(
                        row().gap(px(10.)).children(
                            [Kind::Entry, Kind::Branch, Kind::Save, Kind::Ending]
                                .into_iter()
                                .map(|k| {
                                    div()
                                        .text_size(px(10.))
                                        .text_color(rgb(tint(k)))
                                        .child(format!("● {}", label(k)))
                                }),
                        ),
                    )
                    .child(
                        muted("点击路线节点阅读步骤 · 拖动或滚动平移 · 捏合或 ⌘ + 滚轮缩放")
                            .text_size(px(10.)),
                    ),
            )
            .into_any_element();
        (body, tools)
    }

    pub(crate) fn walkthrough_tree_overlay(&self, cx: &Context<Self>) -> AnyElement {
        let Some(game) = self.detail.and_then(|i| self.game(i)) else {
            return div().into_any_element();
        };
        let Some(metadata) = game.metadata.as_ref() else {
            return div().into_any_element();
        };
        let work = metadata
            .extra
            .get("walkthroughWorkID").or_else(|| metadata.extra.get("sourceID"))
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        let prefix = format!("{}:{}:{}", game.container, game.id, work);
        let Some(guide) = metadata.walkthroughs.as_ref().and_then(|g| {
            g.iter().find(|g| {
                self.walkthrough_view.guide.as_deref()
                    == Some(format!("{prefix}:{}", g.id).as_str())
            })
        }) else {
            return div().into_any_element();
        };
        let Some(chart) = guide.chart.as_ref() else {
            return div().into_any_element();
        };
        col()
            .absolute()
            .inset_0()
            .occlude()
            .p(px(24.))
            .gap(px(16.))
            .bg(rgb(crate::theme::bg()))
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(
                row()
                    .items_center()
                    .justify_between()
                    .child(
                        col()
                            .gap(px(4.))
                            .child(
                                div()
                                    .text_size(px(20.))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child(game.title.clone()),
                            )
                            .child(muted(format!(
                                "攻略路线 · {} · NextMoe",
                                guide.source_author.as_deref().unwrap_or(&guide.source)
                            ))),
                    )
                    .child(
                        Button::new("tree-close")
                            .label("完成")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.walkthrough_view.fullscreen = false;
                                cx.notify();
                            })),
                    ),
            )
            .child(self.walkthrough_chart(chart, &format!("{prefix}:{}", guide.id), true, cx))
            .into_any_element()
    }
}
