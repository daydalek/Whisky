//! A small welcome flow, also reused by the source preferences entry point.
use gpui_kit::component::{
    Disableable,
    button::{Button, ButtonVariants},
    menu::{DropdownMenu, PopupMenuItem},
};
use gpui_kit::{prelude::*, *};
use serde_json::json;

use crate::controls::{col, muted, row};
use crate::onboarding::{CATEGORIES, COMPLETED, Onboarding, SOURCES};
use crate::state::WhiskyApp;
use crate::theme::{SURFACE, SURFACE_BORDER};

impl WhiskyApp {
    pub(crate) fn open_onboarding(&mut self, welcome: bool, cx: &mut Context<Self>) {
        self.onboarding = Some(Onboarding::new(self.metadata_preferences.clone(), welcome));
        cx.notify();
    }

    fn save_onboarding(&mut self, skip: bool, cx: &mut Context<Self>) {
        let Some(state) = &mut self.onboarding else {
            return;
        };
        if state.saving {
            return;
        }
        let mut values = if skip {
            // Skipping is an explicit no-scraping choice, not consent to defaults.
            state.draft.enabled_sources.clear();
            state.draft.values()
        } else {
            state.draft.values()
        };
        if state.welcome {
            values[COMPLETED] = json!(true);
        }
        state.saving = true;
        state.error = None;
        self.bridge.save_metadata_preferences(values, true);
        cx.notify();
    }

    fn onboarding_source_menu(
        &self,
        category: Option<&'static str>,
        cx: &Context<Self>,
    ) -> AnyElement {
        let state = self.onboarding.as_ref().expect("visible onboarding");
        let selected = category
            .map(|key| {
                state
                    .draft
                    .category_sources
                    .get(key)
                    .map(String::as_str)
                    .unwrap_or("inherit")
            })
            .unwrap_or(&state.draft.default_source);
        let label = SOURCES
            .iter()
            .find(|(id, _)| *id == selected)
            .map(|(_, label)| *label)
            .unwrap_or("跟随默认");
        let view = cx.entity().downgrade();
        Button::new(format!(
            "onboarding-source-{}",
            category.unwrap_or("default")
        ))
        .label(format!("{label}  ⌄"))
        .disabled(state.saving)
        .dropdown_menu(move |mut menu, _, _| {
            let choices = category
                .map(|_| vec![("inherit", "跟随默认")])
                .unwrap_or_default()
                .into_iter()
                .chain(SOURCES);
            for (id, label) in choices {
                // Only providers with a character endpoint may be selected.
                if category == Some("characters") && !["inherit", "bangumi", "vndb"].contains(&id) {
                    continue;
                }
                let view = view.clone();
                menu = menu.item(PopupMenuItem::new(label).on_click(move |_, _, cx| {
                    let _ = view.update(cx, |this, cx| {
                        if let Some(state) = &mut this.onboarding {
                            if state.saving {
                                return;
                            }
                            if let Some(category) = category {
                                if id == "inherit" {
                                    state.draft.category_sources.remove(category);
                                } else {
                                    state
                                        .draft
                                        .category_sources
                                        .insert(category.into(), id.into());
                                }
                            } else {
                                state.draft.default_source = id.into();
                            }
                        }
                        cx.notify();
                    });
                }));
            }
            menu
        })
        .into_any_element()
    }

    pub(crate) fn onboarding_view(
        &self,
        width: f32,
        height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let state = self.onboarding.as_ref().expect("visible onboarding");
        let introduction = state.welcome && state.step == 0;
        let mut content = col().gap(px(14.));
        if introduction {
            content = content
                .child(
                    div()
                        .text_size(px(26.))
                        .font_weight(FontWeight::SEMIBOLD)
                        .child("让游戏各就其位"),
                )
                .child(
                    muted("Whisky 帮助你运行 Windows 游戏，并整理属于自己的游戏库。")
                        .line_height(relative(1.6)),
                )
                .child(
                    col()
                        .gap(px(8.))
                        .p(px(16.))
                        .rounded(px(12.))
                        .bg(rgba(0xffffff08))
                        .child("① 创建或导入容器")
                        .child(muted("容器是游戏独立的 Windows 环境，运行时可稍后安装。"))
                        .child("② 添加游戏，再选择启动程序")
                        .child(muted("已有游戏不必重新下载；资料名称不会改变启动路径。"))
                        .child("③ 选择资料来源")
                        .child(muted("补充封面、简介与人物；不同平台的作品由你确认关联。")),
                )
                .child(muted(
                    "接下来只保存偏好，不会扫描目录、下载运行时或发起刮削。",
                ));
        } else {
            content = content
                .child(div().text_size(px(24.)).font_weight(FontWeight::SEMIBOLD).child("选择资料来源"))
                .child(muted("先选一个默认平台，需要时再单独调整。只影响新资料，不会重写已确认的作品。").line_height(relative(1.5)))
                .child(row().justify_between().child("默认来源").child(self.onboarding_source_menu(None, cx)))
                .child(muted("Bangumi：中文作品资料 · VNDB：视觉小说 · Steam：商店资料 · 月幕 / NextMoe：Galgame 资料").text_size(px(11.)))
                .child(Button::new("onboarding-expand")
                    .label(if state.expanded { "收起分类设置 −" } else { "按资料类型调整 ＋" })
                    .ghost().disabled(state.saving)
                    .on_click(cx.listener(|this, _, _, cx| {
                        if let Some(state) = &mut this.onboarding { state.expanded = !state.expanded; }
                        cx.notify();
                    })));
            if state.expanded {
                for (category, label, _) in CATEGORIES {
                    content = content.child(
                        row()
                            .justify_between()
                            .child(label)
                            .child(self.onboarding_source_menu(Some(category), cx)),
                    );
                }
                content = content.child(
                    muted("人物仅支持 Bangumi / VNDB；跟随不支持人物的默认来源时，该项留空。")
                        .text_size(px(11.)),
                );
            }
            let mut sources = row().gap(px(8.)).flex_wrap();
            for (id, label) in SOURCES {
                let selected = state
                    .draft
                    .enabled_sources
                    .iter()
                    .any(|source| source == id);
                sources = sources.child(
                    Button::new(format!("onboarding-enabled-{id}"))
                        .label(format!("{} {label}", if selected { "✓" } else { "+" }))
                        .disabled(state.saving)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if let Some(state) = &mut this.onboarding {
                                if state
                                    .draft
                                    .enabled_sources
                                    .iter()
                                    .any(|source| source == id)
                                {
                                    state.draft.enabled_sources.retain(|source| source != id);
                                } else {
                                    state.draft.enabled_sources.push(id.into());
                                }
                            }
                            cx.notify();
                        })),
                );
            }
            content = content
                .child(muted("允许搜索的平台").text_size(px(11.)))
                .child(sources)
                .child(
                    muted(if state.draft.enabled_sources.is_empty() {
                        "已暂停资料搜索。以后可在设置中启用；本地资料不受影响。"
                    } else {
                        "搜索会向所选平台发送作品名。平台名称不同也没关系，可分别搜索并确认条目。"
                    })
                    .text_size(px(11.))
                    .line_height(relative(1.5)),
                );
        }
        if let Some(error) = &state.error {
            content = content.child(muted(format!(
                "未保存：{error}。请重试，或取消后稍后设置。"
            )));
        }
        let mut footer = row().gap(px(8.)).justify_end();
        if state.welcome {
            footer = footer.child(
                Button::new("onboarding-skip")
                    .label("暂不刮削")
                    .ghost()
                    .disabled(state.saving)
                    .on_click(cx.listener(|this, _, _, cx| this.save_onboarding(true, cx))),
            );
        } else {
            footer = footer.child(
                Button::new("onboarding-cancel")
                    .label("取消")
                    .ghost()
                    .disabled(state.saving)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.onboarding = None;
                        cx.notify();
                    })),
            );
        }
        if introduction {
            footer = footer.child(
                Button::new("onboarding-next")
                    .label("选择资料来源")
                    .primary()
                    .disabled(state.saving)
                    .on_click(cx.listener(|this, _, _, cx| {
                        if let Some(state) = &mut this.onboarding {
                            state.step = 1;
                        }
                        cx.notify();
                    })),
            );
        } else {
            if state.welcome {
                footer = footer.child(
                    Button::new("onboarding-back")
                        .label("上一步")
                        .ghost()
                        .disabled(state.saving)
                        .on_click(cx.listener(|this, _, _, cx| {
                            if let Some(state) = &mut this.onboarding {
                                state.step = 0;
                            }
                            cx.notify();
                        })),
                );
            }
            footer = footer.child(
                Button::new("onboarding-save")
                    .label(if state.saving {
                        "正在保存…"
                    } else if state.welcome {
                        "开始使用"
                    } else {
                        "保存"
                    })
                    .primary()
                    .disabled(state.saving)
                    .on_click(cx.listener(|this, _, _, cx| this.save_onboarding(false, cx))),
            );
        }
        div()
            .absolute()
            .inset_0()
            .size_full()
            .bg(rgba(0x00000088))
            .flex()
            .items_center()
            .justify_center()
            .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
            .child(
                col()
                    .w(px(560_f32.min(width - 32.)))
                    .max_h(px(height - 32.))
                    .bg(rgb(SURFACE))
                    .rounded(px(18.))
                    .border_1()
                    .border_color(rgba(SURFACE_BORDER))
                    .shadow_xl()
                    .child(
                        div()
                            .id("onboarding-scroll")
                            .overflow_y_scroll()
                            .min_h_0()
                            .p(px(24.))
                            .child(content),
                    )
                    .child(
                        footer
                            .p(px(16.))
                            .border_t_1()
                            .border_color(rgba(SURFACE_BORDER)),
                    ),
            )
            .into_any_element()
    }
}
