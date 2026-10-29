//! Spoiler-aware route reader within the GPUI game detail surface.
use crate::{controls::*, state::WhiskyApp, theme::*, walkthrough::*};
use gpui_kit::component::{Disableable, Sizable, button::Button};
use gpui_kit::{prelude::*, *};

impl WhiskyApp {
    pub(crate) fn detail_walkthroughs(&self, index: usize, cx: &Context<Self>) -> AnyElement {
        let Some(game) = self.game(index) else {
            return div().into_any_element();
        };
        let metadata = game.metadata.as_ref();
        let guides = metadata.and_then(|m| m.walkthroughs.as_deref());
        let is_nextmoe = metadata
            .and_then(|m| m.extra.get("source"))
            .and_then(|v| v.as_str())
            == Some("nextmoe");
        let mut content = col()
            .flex_shrink_0()
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
                    .child(div().font_weight(FontWeight::SEMIBOLD).child("攻略路线"))
                    .child(muted("NextMoe · 鲲 Galgame 论坛").text_size(px(11.))),
            );
        let Some(guides) = guides.filter(|g| !g.is_empty()) else {
            let message = if is_nextmoe {
                "该作品当前暂无收录的攻略。"
            } else {
                "关联 NextMoe 游戏资料后，可在这里阅读选项、存档与结局路线。"
            };
            content = content.child(muted(message)).child(
                Button::new("walkthrough-link")
                    .label("查找 NextMoe 游戏资料…")
                    .on_click(cx.listener(move |this, _, _, cx| this.open_game_info(index, cx))),
            );
            return content.into_any_element();
        };
        let scope = format!(
            "{}:{}:{}",
            game.container,
            game.id,
            metadata
                .and_then(|m| m.extra.get("sourceID"))
                .and_then(|v| v.as_str())
                .unwrap_or_default()
        );
        let pending = self.walkthrough_view.pending.is_some();
        content = content.child(muted(
            "选项和结局包含剧透，选择攻略后再展开路线。译文标有机译时，可切换原文核对。",
        ));
        if let Some(error) = self.walkthrough_view.error.as_ref() {
            content = content.child(muted(format!("攻略读取失败：{error}。点击攻略可重试。")));
        }
        for guide in guides {
            let key = format!("{scope}:{}", guide.id);
            let selected = self.walkthrough_view.guide.as_deref() == Some(key.as_str());
            let id = guide.id.clone();
            let has_chart = guide.chart.is_some();
            let author = guide.source_author.as_deref().unwrap_or(&guide.source);
            let release = guide
                .release
                .as_ref()
                .map(|v| {
                    let title = field_text(v, "title");
                    let language = field_text(v, "lang");
                    format!(" · {title} {language}")
                })
                .unwrap_or_else(|| " · 通用版本".into());
            let label = if selected && pending {
                "加载中…"
            } else if selected {
                "重新选择"
            } else {
                "打开路线图"
            };
            let summary = col()
                .flex_1()
                .min_w_0()
                .gap(px(5.))
                .child(
                    div()
                        .font_weight(FontWeight::MEDIUM)
                        .child(format!("{author} · {}", guide.lang)),
                )
                .child(
                    muted(format!(
                        "{} 个结局 · {} 个存档{}",
                        guide.ending_count, guide.save_count, release
                    ))
                    .text_size(px(12.)),
                );
            content = content.child(
                row()
                    .items_center()
                    .gap(px(12.))
                    .p(px(12.))
                    .rounded(px(8.))
                    .bg(rgba(card_bg_subtle()))
                    .child(summary)
                    .child(
                        Button::new(format!("guide-{}", guide.id))
                            .small()
                            .label(label)
                            .disabled(pending)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.walkthrough_view.guide = Some(key.clone());
                                this.walkthrough_view.fullscreen = true;
                                this.walkthrough_view.camera = Default::default();
                                this.walkthrough_view.error = None;
                                if !has_chart {
                                    this.load_walkthrough(index, &id, cx);
                                }
                                cx.notify();
                            })),
                    ),
            );
            if selected {
                if guide.work_route_hints {
                    content = content.child(muted("游戏自带路线提示，可优先参考游戏内提示。"));
                }
                if let Some(date) = guide.source_updated_on.as_ref() {
                    content = content.child(muted(format!("原攻略更新于 {date}")));
                }
                if let Some(url) = guide
                    .source_url
                    .as_ref()
                    .filter(|u| u.starts_with("https://") || u.starts_with("http://"))
                {
                    let url = url.clone();
                    content = content.child(
                        Button::new(format!("guide-source-{}", guide.id))
                            .small()
                            .label("查看原攻略与作者署名 ↗")
                            .on_click(move |_, _, cx| cx.open_url(&url)),
                    );
                }
                if let Some(review) = guide.extra.get("import_review") {
                    if let Some(coverage) = review
                        .get("coverage")
                        .and_then(|v| v.as_f64())
                        .filter(|c| *c < 1.)
                    {
                        content = content.child(muted(format!(
                            "选项图收录率 {:.0}%，可对照原攻略补全。",
                            coverage * 100.
                        )));
                    }
                }
                if let Some(chart) = guide.chart.as_ref() {
                    let guide_scope = format!("{scope}:{}", guide.id);
                    if !self.walkthrough_view.fullscreen {
                        content =
                            content.child(self.walkthrough_chart(chart, &guide_scope, false, cx));
                    }
                }
            }
        }
        content.into_any_element()
    }

    fn load_walkthrough(&mut self, index: usize, id: &str, cx: &mut Context<Self>) {
        if self.offline() {
            self.walkthrough_view.error = Some("离线模式下可阅读已缓存的攻略".into());
            return;
        }
        let Some(game) = self.game(index) else { return };
        let Some(metadata) = game.metadata.as_ref() else {
            return;
        };
        let Ok(mut raw) = serde_json::to_value(metadata) else {
            return;
        };
        let (container, entry_id) = (game.container.clone(), game.id.clone());
        raw["walkthroughID"] = serde_json::Value::String(id.to_owned());
        self.walkthrough_view.pending = Some((container.clone(), entry_id.clone()));
        self.bridge.apply_metadata(&container, &entry_id, raw);
        cx.notify();
    }
}
