//! Route reader: a nested route index beside a linear, full-size step page.
use crate::{controls::*, state::WhiskyApp, theme::*, walkthrough_routes::*, walkthrough_tree::Kind};
use gpui_kit::{prelude::*, *};

/// Distinct hues for route sections; endings, saves and entries keep fixed tints.
const SECTION_TINTS: [u32; 8] = [
    0x8b5cf6, 0x3b82f6, 0xec4899, 0x14b8a6, 0xf97316, 0x6366f1, 0x84cc16, 0xef4444,
];
pub(crate) fn section_tint(section: usize) -> u32 {
    SECTION_TINTS[section % SECTION_TINTS.len()]
}
pub(crate) fn anchor_tint(kind: Kind) -> u32 {
    match kind {
        Kind::Save => 0xf59e0b,
        Kind::Ending => 0x10b981,
        Kind::Note => 0x06b6d4,
        _ => 0x3b82f6,
    }
}
fn anchor_word(kind: Kind) -> &'static str {
    match kind {
        Kind::Save => "存档",
        Kind::Ending => "结局",
        _ => "入口",
    }
}

struct Palette {
    fg: u32,
    secondary: u32,
    border: u32,
    pane: u32,
    page: u32,
    hover: u32,
    dark: bool,
}
impl Palette {
    fn current() -> Self {
        let dark = is_dark();
        Self {
            fg: if dark { 0xe5eaf3 } else { 0x1f2a3d },
            secondary: if dark { 0x94a3b8 } else { 0x64748b },
            border: if dark { 0x2b3442 } else { 0xe3e8f0 },
            pane: if dark { 0x161b24 } else { 0xf7f9fc },
            page: if dark { 0x11151d } else { 0xffffff },
            hover: if dark { 0x1f2733 } else { 0xeef2f8 },
            dark,
        }
    }
    /// Translucent wash of `color` suitable for chips and callouts.
    fn wash(&self, color: u32) -> Rgba {
        rgba((color << 8) | if self.dark { 0x26 } else { 0x16 })
    }
}

fn chip(p: &Palette, color: u32, label: &str, text: impl Into<SharedString>) -> Div {
    row()
        .gap(px(6.))
        .px(px(9.))
        .py(px(4.))
        .rounded(px(6.))
        .bg(p.wash(color))
        .text_size(px(12.))
        .child(
            div()
                .text_color(rgb(color))
                .font_weight(FontWeight::SEMIBOLD)
                .child(label.to_owned()),
        )
        .child(div().text_color(rgb(p.fg)).child(text.into()))
}

impl WhiskyApp {
    pub(crate) fn select_route(&mut self, key: String, cx: &mut Context<Self>) {
        self.walkthrough_view.route = Some(key);
        self.walkthrough_view.graph = false;
        self.walkthrough_view
            .route_scroll
            .set_offset(point(px(0.), px(0.)));
        cx.notify();
    }

    pub(crate) fn walkthrough_reader(
        &self,
        chart: &serde_json::Value,
        fullscreen: bool,
        cx: &Context<Self>,
    ) -> AnyElement {
        let model = Routes::build(chart, self.walkthrough_view.original);
        let p = Palette::current();
        if model.routes.is_empty() {
            return div()
                .p(px(24.))
                .child(muted("这份攻略暂未收录路线。"))
                .into_any_element();
        }
        let current = model
            .index_of(self.walkthrough_view.route.as_deref())
            .unwrap_or(model.order[0]);

        // Route index.
        let mut index = col().gap(px(2.)).p(px(8.));
        for &i in &model.order {
            let route = &model.routes[i];
            let selected = i == current;
            let color = section_tint(route.section);
            let key = route.key.clone();
            let ending = route
                .to
                .as_ref()
                .map(|a| (anchor_tint(a.kind), format!("→ {}", a.label)));
            index = index.child(
                row()
                    .id(SharedString::from(format!("route-item-{i}")))
                    .items_start()
                    .gap(px(8.))
                    .pl(px(8. + route.depth.min(6) as f32 * 14.))
                    .pr(px(8.))
                    .py(px(7.))
                    .rounded(px(7.))
                    .cursor_pointer()
                    .when(selected, |d| d.bg(p.wash(color)))
                    .when(!selected, |d| d.hover(|s| s.bg(rgb(p.hover))))
                    .on_click(cx.listener(move |this, _, _, cx| this.select_route(key.clone(), cx)))
                    .child(
                        div()
                            .mt(px(3.))
                            .w(px(3.))
                            .h(px(28.))
                            .flex_shrink_0()
                            .rounded_full()
                            .bg(rgb(color)),
                    )
                    .child(
                        col()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(
                                div()
                                    .text_size(px(13.))
                                    .font_weight(if selected {
                                        FontWeight::SEMIBOLD
                                    } else {
                                        FontWeight::MEDIUM
                                    })
                                    .text_color(rgb(p.fg))
                                    .text_ellipsis()
                                    .child(if route.depth > 0 {
                                        format!("↳ {}", route.title)
                                    } else {
                                        route.title.clone()
                                    }),
                            )
                            .child(
                                row()
                                    .gap(px(6.))
                                    .text_size(px(11.))
                                    .min_w_0()
                                    .child(
                                        div()
                                            .flex_shrink_0()
                                            .text_color(rgb(p.secondary))
                                            .child(format!("{} 个选项", route.choices)),
                                    )
                                    .when_some(ending, |d, (tint, text)| {
                                        d.child(div().text_color(rgb(tint)).text_ellipsis().child(text))
                                    }),
                            ),
                    ),
            );
        }
        let sidebar = col()
            .w(px(if fullscreen { 280. } else { 230. }))
            .flex_shrink_0()
            .h_full()
            .bg(rgb(p.pane))
            .border_r_1()
            .border_color(rgb(p.border))
            .child(
                row()
                    .justify_between()
                    .px(px(16.))
                    .py(px(10.))
                    .border_b_1()
                    .border_color(rgb(p.border))
                    .text_size(px(11.))
                    .text_color(rgb(p.secondary))
                    .child(format!("{} 条路线", model.routes.len()))
                    .child(format!("{} 个结局", model.endings)),
            )
            .child(
                div()
                    .id("route-index")
                    .occlude()
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .child(index),
            );

        // Route page.
        let route = &model.routes[current];
        let color = section_tint(route.section);
        let lineage = model.lineage(current);
        let mut crumbs = row().flex_wrap().gap(px(4.)).text_size(px(12.));
        for &a in &lineage {
            let key = model.routes[a].key.clone();
            crumbs = crumbs
                .child(
                    div()
                        .id(SharedString::from(format!("route-crumb-{a}")))
                        .text_color(rgb(p.secondary))
                        .cursor_pointer()
                        .hover(|s| s.text_color(rgb(color)).underline())
                        .on_click(cx.listener(move |this, _, _, cx| this.select_route(key.clone(), cx)))
                        .child(model.routes[a].title.clone()),
                )
                .child(div().text_color(rgb(p.secondary)).child("›"));
        }
        crumbs = crumbs.child(div().text_color(rgb(p.fg)).child(route.title.clone()));

        let mut meta = row().flex_wrap().gap(px(6.));
        if !route.condition.is_empty() {
            meta = meta.child(chip(&p, 0xf59e0b, "条件", route.condition.clone()));
        }
        meta = meta.child(chip(&p, color, "选项", format!("{} 个", route.choices)));
        if let Some(to) = route.to.as_ref() {
            meta = meta.child(chip(&p, anchor_tint(to.kind), anchor_word(to.kind), to.label.clone()));
        }

        // Timeline rows share a rail so the reading direction is obvious.
        let rail = |marker: Div, last: bool, body: Div| {
            row()
                .items_stretch()
                .gap(px(14.))
                .child(
                    col()
                        .w(px(28.))
                        .flex_shrink_0()
                        .items_center()
                        .child(marker)
                        .when(!last, |d| {
                            d.child(div().flex_1().min_h(px(14.)).w(px(2.)).bg(rgb(p.border)))
                        }),
                )
                .child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .pb(px(if last { 0. } else { 18. }))
                        .child(body),
                )
        };
        let dot = |tint: u32, glyph: String| {
            row()
                .justify_center()
                .size(px(28.))
                .flex_shrink_0()
                .rounded_full()
                .bg(p.wash(tint))
                .border_1()
                .border_color(rgba((tint << 8) | 0x80))
                .text_size(px(12.))
                .font_weight(FontWeight::BOLD)
                .text_color(rgb(tint))
                .child(glyph)
        };
        let anchor_body = |prefix: &str, a: &crate::walkthrough_routes::Anchor| {
            let tint = anchor_tint(a.kind);
            col()
                .gap(px(3.))
                .pt(px(4.))
                .child(
                    div()
                        .text_size(px(11.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(rgb(tint))
                        .child(format!("{prefix}{}", anchor_word(a.kind))),
                )
                .child(
                    div()
                        .text_size(px(14.))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(rgb(p.fg))
                        .child(a.label.clone()),
                )
                .when(!a.detail.is_empty(), |d| {
                    d.child(div().text_size(px(12.)).text_color(rgb(p.secondary)).child(a.detail.clone()))
                })
        };
        let glyph = |kind: Kind| match kind {
            Kind::Save => "◆".to_owned(),
            Kind::Ending => "★".to_owned(),
            _ => "▶".to_owned(),
        };

        let mut timeline = col().child(rail(
            dot(anchor_tint(route.from.kind), glyph(route.from.kind)),
            false,
            anchor_body("起点 · ", &route.from),
        ));
        for (n, step) in route.steps.iter().enumerate() {
            let last = route.to.is_none() && n + 1 == route.steps.len();
            timeline = timeline.child(match step {
                Step::Choice {
                    number,
                    text,
                    alternatives,
                    achievement,
                } => rail(
                    dot(color, number.to_string()),
                    last,
                    col()
                        .gap(px(4.))
                        .pt(px(4.))
                        .child(
                            row()
                                .flex_wrap()
                                .gap(px(8.))
                                .child(
                                    div()
                                        .text_size(px(14.))
                                        .font_weight(FontWeight::MEDIUM)
                                        .text_color(rgb(p.fg))
                                        .child(format!("选择「{text}」")),
                                )
                                .when(*achievement, |d| {
                                    d.child(
                                        div()
                                            .px(px(6.))
                                            .py(px(1.))
                                            .rounded(px(4.))
                                            .bg(p.wash(0xeab308))
                                            .text_size(px(11.))
                                            .text_color(rgb(0xca8a04))
                                            .child("★ 成就"),
                                    )
                                }),
                        )
                        .when(!alternatives.is_empty(), |d| {
                            d.child(
                                div()
                                    .text_size(px(12.))
                                    .text_color(rgb(p.secondary))
                                    .child(format!("也可选：{}", alternatives.join(" / "))),
                            )
                        }),
                ),
                Step::Note(text) => rail(
                    dot(0x06b6d4, "i".into()),
                    last,
                    div()
                        .mt(px(2.))
                        .px(px(12.))
                        .py(px(8.))
                        .rounded(px(8.))
                        .bg(p.wash(0x06b6d4))
                        .text_size(px(13.))
                        .text_color(rgb(p.fg))
                        .child(text.clone()),
                ),
                Step::Save { label, branches } => {
                    let tint = anchor_tint(Kind::Save);
                    let mut body = col()
                        .gap(px(8.))
                        .mt(px(2.))
                        .p(px(12.))
                        .rounded(px(8.))
                        .border_1()
                        .border_color(rgba((tint << 8) | 0x70))
                        .bg(p.wash(tint))
                        .child(
                            row()
                                .gap(px(8.))
                                .child(
                                    div()
                                        .text_size(px(11.))
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .text_color(rgb(tint))
                                        .child("在此存档"),
                                )
                                .child(
                                    div()
                                        .text_size(px(14.))
                                        .font_weight(FontWeight::MEDIUM)
                                        .text_color(rgb(p.fg))
                                        .child(label.clone()),
                                ),
                        );
                    if !branches.is_empty() {
                        let mut links = row().flex_wrap().gap(px(6.));
                        for &b in branches {
                            let target = &model.routes[b];
                            let key = target.key.clone();
                            let tint = section_tint(target.section);
                            links = links.child(
                                row()
                                    .id(SharedString::from(format!("route-branch-{current}-{n}-{b}")))
                                    .gap(px(6.))
                                    .px(px(10.))
                                    .py(px(5.))
                                    .rounded(px(6.))
                                    .bg(rgb(p.page))
                                    .border_1()
                                    .border_color(rgba((tint << 8) | 0x60))
                                    .cursor_pointer()
                                    .hover(|s| s.border_color(rgb(tint)))
                                    .on_click(cx.listener(move |this, _, _, cx| this.select_route(key.clone(), cx)))
                                    .text_size(px(12.))
                                    .child(div().size(px(7.)).rounded_full().bg(rgb(tint)))
                                    .child(div().text_color(rgb(p.fg)).child(target.title.clone()))
                                    .when(!target.condition.is_empty(), |d| {
                                        d.child(div().text_color(rgb(p.secondary)).child(target.condition.clone()))
                                    })
                                    .child(div().text_color(rgb(p.secondary)).child("›")),
                            );
                        }
                        body = body
                            .child(
                                div()
                                    .text_size(px(12.))
                                    .text_color(rgb(p.secondary))
                                    .child("读取这个存档还可以进入："),
                            )
                            .child(links);
                    }
                    rail(dot(tint, "◆".into()), last, body)
                }
            });
        }
        if let Some(to) = route.to.as_ref() {
            timeline = timeline.child(rail(
                dot(anchor_tint(to.kind), glyph(to.kind)),
                true,
                anchor_body(if to.kind == Kind::Ending { "到达" } else { "前往" }, to),
            ));
        }

        // Previous / next in reading order.
        let position = model.order.iter().position(|&i| i == current).unwrap_or(0);
        let nav = |id: &'static str, target: Option<usize>, forward: bool| {
            let mut cell = col()
                .id(id)
                .flex_1()
                .min_w_0()
                .gap(px(2.))
                .px(px(14.))
                .py(px(10.))
                .rounded(px(8.))
                .border_1()
                .border_color(rgb(p.border))
                .when(forward, |d| d.items_end());
            if let Some(t) = target {
                let key = model.routes[t].key.clone();
                cell = cell
                    .cursor_pointer()
                    .hover(|s| s.bg(rgb(p.hover)))
                    .on_click(cx.listener(move |this, _, _, cx| this.select_route(key.clone(), cx)))
                    .child(
                        div()
                            .text_size(px(11.))
                            .text_color(rgb(p.secondary))
                            .child(if forward { "下一条路线 ›" } else { "‹ 上一条路线" }),
                    )
                    .child(
                        div()
                            .text_size(px(13.))
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(rgb(p.fg))
                            .text_ellipsis()
                            .child(model.routes[t].title.clone()),
                    );
            } else {
                cell = cell.opacity(0.);
            }
            cell
        };
        let footer = row()
            .gap(px(10.))
            .mt(px(28.))
            .child(nav("route-prev", position.checked_sub(1).map(|i| model.order[i]), false))
            .child(nav("route-next", model.order.get(position + 1).copied(), true));

        let page = div()
            .id("route-page")
            .occlude()
            .flex_1()
            .min_w_0()
            .h_full()
            .bg(rgb(p.page))
            .overflow_y_scroll()
            .track_scroll(&self.walkthrough_view.route_scroll)
            .child(
                col()
                    .w_full()
                    .max_w(px(780.))
                    .px(px(if fullscreen { 36. } else { 24. }))
                    .py(px(24.))
                    .gap(px(14.))
                    .when(!lineage.is_empty(), |d| d.child(crumbs))
                    .child(
                        row()
                            .gap(px(10.))
                            .child(div().w(px(4.)).h(px(22.)).rounded_full().bg(rgb(color)))
                            .child(
                                div()
                                    .text_size(px(20.))
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(rgb(p.fg))
                                    .child(route.title.clone()),
                            ),
                    )
                    .child(meta)
                    .child(div().h(px(1.)).my(px(4.)).bg(rgb(p.border)))
                    .child(timeline)
                    .child(footer),
            );

        row()
            .w_full()
            .items_stretch()
            .when(fullscreen, |d| d.flex_1().min_h_0())
            .when(!fullscreen, |d| d.h(px(560.)))
            .child(sidebar)
            .child(page)
            .into_any_element()
    }
}
