//! Bottle surfaces: home, configuration, programs, processes, and game rules.

use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::menu::ContextMenuExt;
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Disableable, Sizable};
use gpui_kit::component::{
    menu::{DropdownMenu, PopupMenuItem},
    switch::Switch,
};
use gpui_kit::{prelude::*, *};

use super::Command;
use crate::config::{self, ConfigField};
use crate::controls::*;
use crate::state::{PreviewPage, PreviewSheet, WhiskyApp};
use crate::theme;

impl WhiskyApp {
    pub(crate) fn bottle_bar(&self, cx: &Context<Self>) -> AnyElement {
        let terminal_enabled = if cfg!(target_os = "linux") {
            let preferred = self.preview.choices.get("terminal")
                .map(|value| value.as_ref()).unwrap_or("auto");
            self.host_terminals.as_ref().is_some_and(|status| status.can_open(preferred))
        } else {
            true
        };
        row()
            .flex_shrink_0()
            .justify_end()
            .flex_wrap()
            .gap(px(9.))
            .p(px(14.))
            .border_t_1()
            .border_color(rgba(theme::card_border()))
            .child(self.action("bottle-c-drive", "打开 C: 盘", Command::OpenDrive, cx))
            .child(
                Button::new("bottle-terminal")
                    .label("终端")
                    .disabled(!terminal_enabled)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.command(Command::BottleTool("terminal"), cx)
                    })),
            )
            .child(self.action(
                "bottle-tricks",
                "Winetricks…",
                Command::Sheet(PreviewSheet::Winetricks),
                cx,
            ))
            .child(self.action("bottle-run", "运行…", Command::BottleRun, cx))
            .when(cfg!(target_os = "linux"), |bar| {
                bar.child(self.action(
                    "bottle-diagnostics",
                    "诊断…",
                    Command::Sheet(PreviewSheet::Diagnostics),
                    cx,
                ))
            })
            .into_any_element()
    }
    pub(crate) fn preview_page(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let body = match self.preview.page {
            PreviewPage::Bottle => match self.visible_load_error() {
                Some(error) => self.library_error_surface(error, cx),
                None => self.bottle_home(cx),
            },
            PreviewPage::ConfigureBottle => self.bottle_config(window, cx),
            PreviewPage::Programs => self.programs(cx),
            PreviewPage::Processes => self.processes(cx),
            PreviewPage::GameConfigs => self.game_configs(cx),
            // Library/Statistics/Launchers are rendered by a different surface;
            // if state desyncs and we land here, degrade to the bottle home
            // rather than panic — a transient wrong page is recoverable.
            PreviewPage::Library | PreviewPage::Statistics | PreviewPage::Launchers => {
                self.bottle_home(cx)
            }
        };
        col()
            .size_full()
            .child(
                row()
                    .flex_shrink_0()
                    .px(px(24.))
                    .py(px(8.))
                    .gap(px(10.))
                    .child(
                        Button::new("page-back")
                            .label("‹ 返回")
                            .ghost()
                            .on_click(cx.listener(|this, _, _, cx| this.navigate_back(cx))),
                    )
                    .child(muted(self.bottle_name().to_owned())),
            )
            .child(div().flex_1().min_h_0().child(body))
            .child(if self.preview.page == PreviewPage::ConfigureBottle {
                row()
                    .flex_shrink_0()
                    .justify_end()
                    .flex_wrap()
                    .gap(px(8.))
                    .p(px(14.))
                    .border_t_1()
                    .border_color(rgba(theme::card_border()))
                    .child(self.action(
                        "control",
                        "控制面板",
                        Command::BottleTool("control"),
                        cx,
                    ))
                    .child(self.action(
                        "regedit",
                        "注册表编辑器",
                        Command::BottleTool("regedit"),
                        cx,
                    ))
                    .child(self.action(
                        "winecfg",
                        "Wine 配置",
                        Command::BottleTool("winecfg"),
                        cx,
                    ))
                    .into_any_element()
            } else {
                self.bottle_bar(cx)
            })
            .into_any_element()
    }
    fn bottle_home(&self, cx: &Context<Self>) -> AnyElement {
        let slot = self.bottle_slot();
        let bottle_games: Vec<_> = self
            .games()
            .iter()
            .enumerate()
            .filter(|(_, game)| game.bottle == slot && !game.is_launcher)
            .collect();
        let total_games = bottle_games.len();
        let pins: Vec<_> = bottle_games
            .into_iter()
            .take(6)
            .map(|(i, game)| {
                let (top, bottom) = theme::placeholder_gradient();
                col()
                    .w(px(110.))
                    .items_center()
                    .child(
                        // Explicit clipped frame: the artwork can never grow
                        // into the label strip below.
                        div()
                            .id(("pin", i))
                            .cursor_pointer()
                            .w(px(80.))
                            .h(px(108.))
                            .rounded(px(9.))
                            .overflow_hidden()
                            .border_1()
                            .border_color(rgba(theme::surface_border()))
                            .hover(|d| d.border_color(rgb(theme::ACCENT)))
                            .on_click(cx.listener(move |this, _, _, cx| this.open_detail(i, cx)))
                            .child(match self.artwork(i) {
                                Some(path) => self.artwork_image(path)
                                    .size_full()
                                    .object_fit(ObjectFit::Cover)
                                    .into_any_element(),
                                None => div()
                                    .size_full()
                                    .bg(gradient(top, bottom))
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .child(icon("package", 22.).text_color(rgb(theme::muted_color())))
                                    .into_any_element(),
                            })
                            .context_menu(self.game_menu(i, cx)),
                    )
                    .child(
                        // Reserved band keeps the two-line label entirely
                        // below the cover; without it a wrapping title hugs
                        // the artwork's bottom edge.
                        div()
                            .w_full()
                            .h(px(34.))
                            .pt(px(8.))
                            .text_size(px(11.))
                            .text_center()
                            .line_clamp(2)
                            .child(game.title.clone()),
                    )
                    .into_any_element()
            })
            .collect();
        let pins_empty = pins.is_empty();
        let nav_items = [
            ("app-window", "已安装的程序", "浏览、固定或屏蔽容器内的可执行文件", PreviewPage::Programs),
            ("sliders-horizontal", "容器配置", "调整 Windows 版本、图形后端、超分与环境变量", PreviewPage::ConfigureBottle),
            ("activity", "运行中的进程", "查看或结束当前容器内活跃的 Wine 进程", PreviewPage::Processes),
            ("sparkles", "游戏配置", "匹配本地 GameDB 社区兼容性与推荐设置", PreviewPage::GameConfigs),
        ];
        let mut links = col()
            .rounded(px(12.))
            .overflow_hidden()
            .bg(rgba(theme::section_bg()))
            .border_1()
            .border_color(rgba(theme::section_border()));
        for (i, (symbol, label, subtitle, page)) in nav_items.into_iter().enumerate() {
            if i > 0 {
                links = links.child(div().h(px(1.)).mx(px(16.)).bg(rgba(theme::divider())));
            }
            links = links.child(
                row()
                    .id(("bottle-link", i))
                    .px(px(16.))
                    .py(px(12.))
                    .gap(px(12.))
                    .cursor_pointer()
                    .hover(|d| d.bg(rgba(theme::hover())))
                    .on_click(cx.listener(move |this, _, _, cx| this.navigate(page, cx)))
                    .child(
                        div()
                            .size(px(32.))
                            .rounded(px(8.))
                            .bg(rgba(theme::accent_subtle_bg()))
                            .flex()
                            .items_center()
                            .justify_center()
                            .flex_shrink_0()
                            .child(icon(symbol, 16.).text_color(rgb(theme::accent_fg()))),
                    )
                    .child(
                        col()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(div().font_weight(FontWeight::MEDIUM).child(label))
                            .child(muted(subtitle).text_size(px(11.)).truncate()),
                    )
                    .child(icon("chevron-right", 15.).text_color(rgb(theme::muted_color()))),
            );
        }

        let summary_line = if self.demo {
            "自动选择图形后端 · Windows 11 · Wine".to_owned()
        } else {
            let bottle = self.selected_bottle.and_then(|idx| self.bottles.get(idx));
            let mut parts = vec![format!("{total_games} 款游戏")];
            if let Some(bottle) = bottle {
                if let Some(cfg) = self.config.as_ref().filter(|c| c.container == bottle.path && !c.loading) {
                    if let Some(win) = cfg.values.get("windowsVersion").and_then(|v| v.as_str()) {
                        let win_label = match win {
                            "win11" => "Windows 11",
                            "win10" => "Windows 10",
                            "win81" => "Windows 8.1",
                            "win8" => "Windows 8",
                            "win7" => "Windows 7",
                            "winxp" => "Windows XP",
                            other => other,
                        };
                        parts.push(win_label.to_owned());
                    }
                    if let Some(backend) = cfg.values.get("graphicsBackend").and_then(|v| v.as_str()) {
                        parts.push(crate::program_settings::graphics_label(backend).to_owned());
                    }
                }
                parts.push(crate::create_bottle::display_bottle_location(&bottle.path));
            }
            parts.join(" · ")
        };

        let games_section = col()
            .gap(px(12.))
            .child(
                row()
                    .justify_between()
                    .items_center()
                    .child(
                        row()
                            .gap(px(8.))
                            .child(div().font_weight(FontWeight::SEMIBOLD).child("容器内游戏"))
                            .child(muted(total_games.to_string()).text_size(px(11.))),
                    )
                    .when(total_games > 6, |d| {
                        d.child(
                            Button::new("bottle-view-all-games")
                                .label(format!("在游戏库查看全部（{total_games}）"))
                                .ghost()
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.preview.page = PreviewPage::Library;
                                    cx.notify();
                                })),
                        )
                    }),
            )
            .when(!pins_empty, |d| {
                d.child(row().items_start().flex_wrap().gap(px(14.)).children(pins))
            })
            .when(pins_empty, |d| {
                d.child(
                    row()
                        .justify_between()
                        .items_center()
                        .flex_wrap()
                        .gap(px(12.))
                        .p(px(16.))
                        .rounded(px(12.))
                        .bg(rgba(theme::section_bg()))
                        .border_1()
                        .border_color(rgba(theme::section_border()))
                        .child(
                            col()
                                .flex_1()
                                .min_w_0()
                                .gap(px(4.))
                                .child(div().font_weight(FontWeight::MEDIUM).child("此容器还没有游戏"))
                                .child(muted("可配置游戏目录自动扫描，或将已安装的 .exe 程序固定到此处。").text_size(px(11.))),
                        )
                        .child(
                            row()
                                .gap(px(8.))
                                .child(self.action(
                                    "bottle-empty-scan",
                                    "扫描文件夹…",
                                    Command::Sheet(PreviewSheet::Scan),
                                    cx,
                                ))
                                .child(self.action(
                                    "bottle-empty-pin",
                                    "添加程序…",
                                    Command::AddProgram,
                                    cx,
                                )),
                        ),
                )
            });

        self.preview_scroll(
            "bottle-home-scroll",
            col()
                .p(px(26.))
                .gap(px(24.))
                .child(games_section)
                .child(links)
                .child(muted(summary_line).text_size(px(11.)).truncate()),
        )
    }
    /// Configure Bottle. The demo keeps its static design snapshot; a live
    /// bottle renders the bridge schema, one section at a time.
    fn bottle_config(&mut self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        if self.demo {
            return self.demo_bottle_config(cx);
        }
        self.apply_pending_input_text(window, cx);
        let Some(container) = self.selected_container() else {
            return self.form(
                "bottle-config-scroll",
                vec![self.section(
                    "config-empty",
                    "容器配置",
                    vec![muted("请先在侧边栏选择一个容器。").into_any_element()],
                    cx,
                )],
            );
        };
        // A stale page belongs to the previously selected bottle.
        let page = self
            .config
            .clone()
            .filter(|page| page.container == container);
        let Some(page) = page else {
            return self.config_loading(cx);
        };
        if page.loading {
            return self.config_loading(cx);
        }
        if let Some(reason) = &page.error {
            return self.config_error(reason, cx);
        }

        let mut sections = Vec::new();
        for group in config::group_sections(&page.fields) {
            let mut rows = Vec::new();
            for field in group.fields {
                let value = page
                    .values
                    .get(&field.id)
                    .cloned()
                    .unwrap_or_else(|| field.default.clone());
                let enabled = field.enabled(&page.capabilities);
                let has_coreml = page.capabilities.iter().any(|cap| cap == "gdi.coreml");
                rows.push(self.config_row(&container, field, &value, enabled, has_coreml, window, cx));
            }
            sections.push(self.section(group.spec.id, group.spec.title, rows, cx));
        }
        if let Some(engine) = self.engine_section(&container, cx) {
            sections.insert(0, engine);
        }
        sections.push(self.environment_section(&container, cx));
        self.form("bottle-config-scroll", sections)
    }

    fn config_loading(&self, cx: &Context<Self>) -> AnyElement {
        self.form(
            "bottle-config-scroll",
            vec![self.section(
                "config-loading",
                "容器配置",
                vec![
                    row()
                        .gap(px(8.))
                        .py(px(10.))
                        .child(Spinner::new().with_size(px(14.)))
                        .child(muted("正在读取配置…"))
                        .into_any_element(),
                ],
                cx,
            )],
        )
    }

    fn config_error(&self, reason: &str, cx: &Context<Self>) -> AnyElement {
        self.form(
            "bottle-config-scroll",
            vec![self.section(
                "config-error",
                "容器配置",
                vec![
                    muted(reason.to_owned()).into_any_element(),
                    row()
                        .py(px(8.))
                        .child(
                            Button::new("config-retry")
                                .label("重试")
                                .on_click(cx.listener(|this, _, _, cx| this.reload_config(cx))),
                        )
                        .into_any_element(),
                ],
                cx,
            )],
        )
    }

    /// One schema row. Toggles and pickers commit on click; text and number
    /// rows are debounced by their `InputState` observer.
    fn config_row(
        &mut self,
        container: &str,
        field: &ConfigField,
        value: &serde_json::Value,
        enabled: bool,
        has_coreml: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        // Selected-engine policy: unavailable options stay visibly disabled
        // with the bridge's reason; `unverified` ones show an explicit
        // "确认后尝试启用" action — the control itself stays off until the
        // approval lands (`engine_gate_check` queues the write behind it).
        let policy = self.engine_field_policy(container, &field.id).cloned();
        let gated = policy.as_ref().is_some_and(|policy| policy.disabled);
        let confirmable = policy
            .as_ref()
            .is_some_and(|policy| policy.state == "unverified" && policy.can_override);
        // `outer_enabled` is the section's own editability; `enabled` folds
        // the engine gate in. Off/neutral actions stay reachable even while
        // gated — only enabling writes are blocked.
        let outer_enabled = enabled;
        let enabled = enabled && !gated;
        let gate_reason = gated.then(|| {
            policy
                .as_ref()
                .and_then(|policy| policy.reason.clone())
                .unwrap_or_else(|| "所选引擎不支持此选项".to_owned())
        });
        match &field.kind {
            config::FieldKind::Toggle => {
                let checked_now = value.as_bool().unwrap_or(false);
                let id = field.id.clone();
                let feature = policy
                    .as_ref()
                    .and_then(|policy| policy.feature.clone())
                    .unwrap_or_default();
                let container_owned = container.to_owned();
                row()
                    .gap(px(20.))
                    .py(px(10.))
                    .items_start()
                    .child(
                        col()
                            .flex_1()
                            .min_w_0()
                            .gap(px(4.))
                            .child(field.title.clone())
                            .when(field.id == "metalFXSpatial", |d| {
                                d.child(muted(
                                    "GDI / WineD3D OpenGL · Retina 超分；重启游戏后生效。",
                                ))
                            })
                            .when(field.id == "metalFX", |d| {
                                d.child(muted("仅 D3DMetal 后端；仅对游戏内开启 DLSS 的标题生效。"))
                            })
                            .when(!enabled && gate_reason.is_none(), |d| {
                                d.child(muted("需要 Wine 主机适配器").line_height(relative(1.4)))
                            })
                            .when_some(gate_reason.clone(), |d, reason| {
                                d.child(muted(reason).line_height(relative(1.4))).when(
                                    confirmable,
                                    |d| {
                                        d.child(
                                            muted("启用将需要确认，且引擎更换后需重新确认。")
                                                .line_height(relative(1.4)),
                                        )
                                    },
                                )
                            })
                            // A saved ON the engine does not honor is shown
                            // as an inactive preference, not a live setting.
                            .when(gated && checked_now, |d| {
                                d.child(
                                    muted("已保存的偏好在当前引擎下未生效。")
                                        .line_height(relative(1.4)),
                                )
                            }),
                    )
                    .child(
                        col()
                            .gap(px(6.))
                            .child(
                                Switch::new(format!("config-toggle:{}", field.id))
                                    .checked(checked_now)
                                    // Off stays reachable: a gated saved ON
                                    // must remain switchable to OFF.
                                    .disabled(!outer_enabled || (gated && !checked_now))
                                    .on_change(cx.listener(move |this, checked, _, cx| {
                                        this.set_config_value(
                                            &id,
                                            serde_json::Value::Bool(*checked),
                                            cx,
                                        );
                                    })),
                            )
                            .when(confirmable, |d| {
                                let feature = feature.clone();
                                let container = container_owned.clone();
                                let field_id = field.id.clone();
                                d.child(
                                    Button::new(format!("config-confirm:{}", field.id))
                                        .label("确认后尝试启用")
                                        .on_click(cx.listener(move |this, _, _, cx| {
                                            this.request_feature_confirm(
                                                &container,
                                                &feature,
                                                &field_id,
                                                serde_json::Value::Bool(true),
                                                cx,
                                            );
                                        })),
                                )
                            }),
                    )
                    .into_any_element()
            }
            config::FieldKind::Choice { options } => {
                let id = field.id.clone();
                let selected = value.as_str().unwrap_or_default().to_owned();
                let mut title = config::display_value(field, value).unwrap_or_default();
                let choice_policies = policy
                    .as_ref()
                    .map(|policy| policy.choices.clone())
                    .unwrap_or_default();
                // Field-level gate fallback: fields like `dxvkHud` carry the
                // gate on the FIELD, not per choice — every non-neutral
                // option inherits it, neutral/off choices stay selectable.
                let neutral = |id: &str| id.is_empty() || id == "none" || id == "off";
                let policy_for = move |option_id: &str| -> Option<crate::bridge::dto::EnginePolicyDto> {
                    if let Some(policy) = choice_policies.get(option_id) {
                        return Some(policy.clone());
                    }
                    let policy = policy.as_ref()?;
                    if policy.disabled && !neutral(option_id) {
                        return Some(crate::bridge::dto::EnginePolicyDto {
                            disabled: policy.disabled,
                            reason: policy.reason.clone(),
                            state: policy.state.clone(),
                            can_override: policy.can_override,
                            feature: policy.feature.clone(),
                        });
                    }
                    None
                };
                // A saved selection the engine does not enable stays visible
                // but is marked inactive — the runtime ignores it until the
                // user either reverts to a permitted value or confirms the
                // feature.
                let selected_gated = policy_for(selected.as_str())
                    .is_some_and(|policy| policy.disabled);
                if selected_gated {
                    title = format!("{title}（未生效）");
                }
                let disabled_reasons: Vec<String> = options
                    .iter()
                    .filter_map(|option| {
                        let policy = policy_for(&option.id)?;
                        policy.disabled.then(|| {
                            format!(
                                "{}：{}",
                                option.title,
                                policy
                                    .reason
                                    .clone()
                                    .unwrap_or_else(|| "所选引擎不支持".to_owned())
                            )
                        })
                    })
                    .collect();
                let options: Vec<(String, String)> = options
                    .iter()
                    .map(|option| (option.id.clone(), option.title.clone()))
                    .collect();
                let view = cx.entity().downgrade();
                row()
                    .py(px(10.))
                    .gap(px(16.))
                    .child(
                        col().flex_1().min_w_0().gap(px(4.)).child(field.title.clone())
                            .when(field.id == "gdiUpscaler", |d| {
                                d.child(muted("GDI / WineD3D OpenGL · Retina 超分；重启游戏后生效。"))
                                    .when(value.as_str() == Some("adaptive"), |d| {
                                        d.child(muted("局部变化即时显示；静止约 200 毫秒后异步补充细节。"))
                                    })
                                    .when(value.as_str() == Some("realcugan"), |d| {
                                        d.child(muted("保留静态细节；文字与光标变化即时显示。"))
                                    })
                                    .when(value.as_str() == Some("adaptive-realesrgan"), |d| {
                                        d.child(muted("局部变化即时显示；静止约 200 毫秒后异步补充 AnimeVideo-v3 细节。"))
                                    })
                                    .when(value.as_str() == Some("adaptive-anime4k"), |d| {
                                        d.child(muted("局部变化由 Anime4K 即时超分；静止约 200 毫秒后异步补充 Real-CUGAN 细节。"))
                                    })
                                    .when(value.as_str() == Some("adaptive-anime4k-realesrgan"), |d| {
                                        d.child(muted("局部变化由 Anime4K 即时超分；静止约 200 毫秒后异步补充 AnimeVideo-v3 细节。"))
                                    })
                                    .when(value.as_str() == Some("realesrgan"), |d| {
                                        d.child(muted("以 AnimeVideo-v3 保留静态细节；文字与光标变化即时显示。"))
                                    })
                                    .when(
                                        !has_coreml
                                            && matches!(
                                                value.as_str(),
                                                Some("realcugan")
                                                    | Some("realesrgan")
                                                    | Some("adaptive")
                                                    | Some("adaptive-realesrgan")
                                                    | Some("adaptive-anime4k")
                                                    | Some("adaptive-anime4k-realesrgan")
                                            ),
                                        |d| {
                                            d.child(muted("当前运行时缺少 Core ML 模型：神经网络超分只能在 CPU 上运行（每帧数秒），画面需静止较长时间才会切换。"))
                                        },
                                    )
                            })
                            .when(field.id == "gdiUpscalerCache", |d| {
                                d.child(muted("会话内容缓存：跨场景与分辨率变化复用推理结果，重启游戏生效。"))
                                    .child(muted("持久化默认每个游戏 256 MiB 内存 + 4 GiB 磁盘，LRU 淘汰。"))
                                    .child(muted("仅作用于 CoreML 神经后端（Real-CUGAN／AnimeVideo-v3），MetalFX／Anime4K 不受影响。"))
                            })
                            .when_some(gate_reason.clone(), |d, reason| {
                                d.child(muted(reason).line_height(relative(1.4)))
                                    .when(confirmable, |d| {
                                        d.child(muted("启用将需要确认，且引擎更换后需重新确认。").line_height(relative(1.4)))
                                    })
                            })
                            .children(
                                disabled_reasons
                                    .iter()
                                    .map(|reason| muted(reason.clone()).text_size(px(11.))),
                            ),
                    )
                    .child(
                        Button::new(format!("config-choice:{}", field.id))
                            .label(format!("{title}  ⌄"))
                            // Gated fields keep the menu reachable: neutral
                            // choices (off/none) are always selectable so a
                            // saved gated value can be reverted.
                            .disabled(!outer_enabled)
                            .dropdown_menu(move |mut menu, _, _| {
                                for (option_id, option_title) in &options {
                                    let view = view.clone();
                                    let id = id.clone();
                                    let option_id = option_id.clone();
                                    let choice_disabled = policy_for(option_id.as_str())
                                        .is_some_and(|policy| {
                                            policy.disabled
                                                && !(policy.can_override
                                                    && policy.state == "unverified")
                                        });
                                    let choice_confirmable = policy_for(option_id.as_str())
                                        .is_some_and(|policy| {
                                            policy.disabled
                                                && policy.can_override
                                                && policy.state == "unverified"
                                        });
                                    let option_title = if choice_confirmable {
                                        format!("{option_title}（需确认）")
                                    } else {
                                        option_title.clone()
                                    };
                                    menu = menu.item(
                                        PopupMenuItem::new(option_title)
                                            .disabled(choice_disabled)
                                            .checked(selected == option_id)
                                            .on_click(move |_, _, cx| {
                                                let _ = view.update(cx, |this, cx| {
                                                    this.set_config_value(
                                                        &id,
                                                        serde_json::Value::String(
                                                            option_id.clone(),
                                                        ),
                                                        cx,
                                                    );
                                                });
                                            }),
                                    );
                                }
                                menu
                            }),
                    )
                    .into_any_element()
            }
            config::FieldKind::Text | config::FieldKind::Number { .. } => {
                let text = config::display_value(field, value).unwrap_or_default();
                let input = self.config_input(field, &text, window, cx);
                let hint = match &field.kind {
                    config::FieldKind::Number { min, max } => Some(format!("{min}–{max}")),
                    _ => None,
                };
                col()
                    .gap(px(7.))
                    .py(px(8.))
                    .child(
                        row()
                            .gap(px(8.))
                            .child(div().flex_1().child(field.title.clone()))
                            .when_some(hint, |d, hint| d.child(muted(hint))),
                    )
                    // Clearing a gated saved value (empty write) always
                    // passes the engine gate — keep the field editable.
                    .child(Input::new(&input).disabled(!outer_enabled))
                    .when(field.id == "gdiUpscalerExcludedRegions", |d| {
                        d.child(muted("原图左上角起算：x,y,宽,高；多个矩形用英文分号分隔，留空为全部超分。"))
                            .child(muted("例如 1280×720 画面的底部文字区：0,520,1280,200。区域内普通缩放；重启游戏生效。"))
                    })
                    .into_any_element()
            }
        }
    }

    /// Schema text/number fields need an `InputState`, which requires a window;
    /// create one on first render and observe it for debounced writes.
    fn config_input(
        &mut self,
        field: &ConfigField,
        text: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<InputState> {
        if let Some(input) = self.preview.config_inputs.get(&field.id) {
            return input.clone();
        }
        let placeholder = match field.kind {
            config::FieldKind::Number { .. } => "整数".to_owned(),
            _ => field.title.clone(),
        };
        let entity = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(placeholder)
                .default_value(text.to_owned())
        });
        self.preview
            .config_inputs
            .insert(field.id.clone(), entity.clone());
        let id = field.id.clone();
        let subscription = cx.observe(&entity, move |this, input, cx| {
            let text = input.read(cx).value().to_string();
            this.config_text_changed(&id, &text, cx);
        });
        self._subscriptions.push(subscription);
        entity
    }

    /// Rebuild inputs that a rejected write touched. Creating a fresh
    /// `InputState` with the committed value avoids mutating an input while the
    /// root view is rendering (which would re-enter this view's observer).
    fn apply_pending_input_text(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        for field in std::mem::take(&mut self.preview.config_resets) {
            self.preview.config_inputs.remove(&field);
        }
        if let Some((key, value)) = self.env_fill.take() {
            let key_input = cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("变量名")
                    .default_value(key)
            });
            let value_input = cx.new(|cx| {
                InputState::new(window, cx)
                    .placeholder("变量值")
                    .default_value(value)
            });
            self.preview.inputs.insert("env-key", key_input);
            self.preview.inputs.insert("env-value", value_input);
        }
    }

    /// Container environment. The rows and the add form reuse the run-settings
    /// sheet's layout; each save is one `environment.set` call.
    fn environment_section(&self, container: &str, cx: &Context<Self>) -> AnyElement {
        let values = self.environments.get(container).cloned().unwrap_or_default();
        let mut rows: Vec<AnyElement> = Vec::new();
        if values.is_empty() {
            rows.push(muted("暂无环境变量").into_any_element());
        }
        for (key, value) in config::environment_rows(&values) {
            let edit_key = key.to_owned();
            let edit_value = value.to_owned();
            let remove_key = key.to_owned();
            rows.push(
                row()
                    .gap(px(12.))
                    .py(px(10.))
                    .child(div().w(px(180.)).truncate().child(key.to_owned()))
                    .child(muted(value.to_owned()).flex_1().truncate())
                    .child(
                        Button::new(format!("env-edit:{key}"))
                            .label("编辑")
                            .ghost()
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.begin_environment_edit(&edit_key, &edit_value, cx);
                            })),
                    )
                    .child(
                        Button::new(format!("env-remove:{key}"))
                            .label("移除")
                            .ghost()
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.remove_environment(&remove_key, cx);
                            })),
                    )
                    .into_any_element(),
            );
        }
        rows.push(
            row()
                .gap(px(10.))
                .py(px(10.))
                .child(
                    div()
                        .flex_1()
                        .child(Input::new(&self.preview.inputs["env-key"])),
                )
                .child(
                    div()
                        .flex_1()
                        .child(Input::new(&self.preview.inputs["env-value"])),
                )
                .child(
                    Button::new("env-save")
                        .label("保存变量")
                        .on_click(cx.listener(|this, _, _, cx| {
                            let key = this.preview.inputs["env-key"].read(cx).value().to_string();
                            let value =
                                this.preview.inputs["env-value"].read(cx).value().to_string();
                            this.save_environment(&key, &value, cx);
                        })),
                )
                .into_any_element(),
        );
        if let Some(reason) = self.environment_error.get(container) {
            rows.push(muted(reason.clone()).into_any_element());
        }
        self.section("environment", "环境变量", rows, cx)
    }

    fn demo_bottle_config(&self, cx: &Context<Self>) -> AnyElement {
        self.form(
            "bottle-config-scroll",
            vec![
                self.section(
                    "wine",
                    "Wine",
                    #[cfg(not(target_os = "linux"))]
                    vec![
                        self.choice(
                            "windows",
                            "Windows 版本",
                            &["Windows 11", "Windows 10", "Windows 7", "Windows XP"],
                            cx,
                        ),
                        self.field("build", "内部版本号"),
                        self.choice("retina", "Retina 模式", &["关闭", "开启"], cx),
                        self.choice("sync", "增强同步", &["MSync", "ESync", "关闭"], cx),
                        self.field("dpi", "屏幕分辨率（DPI）"),
                    ],
                    #[cfg(target_os = "linux")]
                    vec![
                        self.choice(
                            "windows",
                            "Windows 版本",
                            &["Windows 11", "Windows 10", "Windows 7", "Windows XP"],
                            cx,
                        ),
                        self.field("build", "内部版本号"),
                        self.choice("sync", "增强同步", &["FSync", "ESync", "关闭"], cx),
                        self.field("dpi", "屏幕分辨率（DPI）"),
                    ],
                    cx,
                ),
                self.section(
                    "launcher",
                    "启动器兼容性",
                    #[cfg(not(target_os = "linux"))]
                    vec![
                        self.toggle(
                            "launcher-mode",
                            "启动器兼容模式",
                            "为常见游戏启动器使用兼容设置。",
                            cx,
                        ),
                        self.choice("launcher-type", "检测模式", &["自动", "手动"], cx),
                        self.toggle("gpu-spoof", "GPU 伪装", "", cx),
                    ],
                    #[cfg(target_os = "linux")]
                    vec![
                        self.toggle(
                            "launcher-mode",
                            "启动器兼容模式",
                            "为常见游戏启动器使用兼容设置。",
                            cx,
                        ),
                        self.toggle("gpu-spoof", "GPU 伪装", "", cx),
                    ],
                    cx,
                ),
                self.section(
                    "input",
                    "输入与控制器",
                    vec![
                        self.toggle("controller", "控制器兼容性", "", cx),
                        self.toggle("hid", "禁用 HIDAPI", "", cx),
                        self.toggle("background-input", "允许后台输入", "", cx),
                    ],
                    cx,
                ),
                self.section(
                    "graphics",
                    "图形",
                    #[cfg(not(target_os = "linux"))]
                    vec![
                        self.choice("graphics-mode", "设置模式", &["简单", "高级"], cx),
                        self.choice(
                            "backend",
                            "图形后端",
                            &["推荐（自动）", "D3DMetal", "DXVK", "WineD3D"],
                            cx,
                        ),
                        self.toggle("metalfx", "DLSS→MetalFX 桥（仅 D3DMetal）", "", cx),
                        self.choice(
                            "gdi-upscaler",
                            "游戏超分算法",
                            &[
                                "关闭",
                                "MetalFX Spatial",
                                "Anime4K",
                                "Real-CUGAN",
                                "动态 MetalFX／静态 Real-CUGAN",
                                "AnimeVideo-v3",
                                "动态 MetalFX／静态 AnimeVideo-v3",
                            ],
                            cx,
                        ),
                        self.toggle("metal4", "Metal 4", "", cx),
                        self.toggle("framegen", "帧生成", "", cx),
                        self.action(
                            "graphics-detail",
                            "高级图形设置…",
                            Command::Sheet(PreviewSheet::Graphics),
                            cx,
                        ),
                    ],
                    #[cfg(target_os = "linux")]
                    vec![
                        self.choice("graphics-mode", "设置模式", &["简单", "高级"], cx),
                        self.choice(
                            "backend",
                            "图形后端",
                            &["推荐（自动）", "DXVK", "WineD3D"],
                            cx,
                        ),
                        self.action(
                            "graphics-detail",
                            "高级图形设置…",
                            Command::Sheet(PreviewSheet::Graphics),
                            cx,
                        ),
                    ],
                    cx,
                ),
                self.section(
                    "audio",
                    "音频",
                    #[cfg(not(target_os = "linux"))]
                    vec![
                        self.info("默认输出设备", "系统默认输出 · 48,000 Hz · 立体声"),
                        self.choice("audio-mode", "设置模式", &["简单", "高级"], cx),
                        self.choice(
                            "audio-driver",
                            "音频驱动",
                            &["自动", "CoreAudio", "禁用"],
                            cx,
                        ),
                        self.action(
                            "audio-test",
                            "测试音频",
                            Command::Sheet(PreviewSheet::Audio),
                            cx,
                        ),
                        self.action(
                            "audio-diagnosis",
                            "音频故障排查…",
                            Command::Sheet(PreviewSheet::Audio),
                            cx,
                        ),
                    ],
                    #[cfg(target_os = "linux")]
                    vec![
                        self.info("默认输出设备", "系统默认输出 · 48,000 Hz · 立体声"),
                        self.choice("audio-mode", "设置模式", &["简单", "高级"], cx),
                        self.choice(
                            "audio-driver",
                            "音频驱动",
                            &["自动", "PulseAudio", "ALSA", "禁用"],
                            cx,
                        ),
                    ],
                    cx,
                ),
                self.section(
                    "resolution",
                    "分辨率",
                    vec![
                        self.toggle("virtual-desktop", "虚拟桌面", "下次启动时生效。", cx),
                        self.choice(
                            "desktop-size",
                            "桌面大小",
                            &["匹配显示器", "1920 × 1080", "1280 × 720", "自定义"],
                            cx,
                        ),
                        self.field("desktop-width", "宽度"),
                        self.field("desktop-height", "高度"),
                    ],
                    cx,
                ),
                self.section(
                    "performance",
                    "性能",
                    #[cfg(not(target_os = "linux"))]
                    vec![
                        self.toggle(
                            "shader",
                            "着色器缓存",
                            "缓存编译后的着色器，减少重复编译。",
                            cx,
                        ),
                        self.toggle(
                            "appnap",
                            "禁用 App Nap",
                            "游戏运行期间防止应用被系统暂停。",
                            cx,
                        ),
                        self.action(
                            "vcredist",
                            "安装 Visual C++ 运行库…",
                            Command::Sheet(PreviewSheet::Winetricks),
                            cx,
                        ),
                    ],
                    #[cfg(target_os = "linux")]
                    vec![
                        self.toggle(
                            "shader",
                            "着色器缓存",
                            "缓存编译后的着色器，减少重复编译。",
                            cx,
                        ),
                        self.action(
                            "vcredist",
                            "安装 Visual C++ 运行库…",
                            Command::Sheet(PreviewSheet::Winetricks),
                            cx,
                        ),
                    ],
                    cx,
                ),
                self.section(
                    "dll",
                    "DLL 覆盖",
                    vec![
                        self.info("d3dcompiler_47", "原生优先，内建后备"),
                        self.action(
                            "dll-edit",
                            "编辑 DLL 覆盖…",
                            Command::Sheet(PreviewSheet::Dll),
                            cx,
                        ),
                    ],
                    cx,
                ),
                self.section(
                    "dependencies",
                    "依赖组件",
                    vec![
                        self.info("Visual C++ 2015–2022", "已安装"),
                        self.action(
                            "deps",
                            "管理组件…",
                            Command::Sheet(PreviewSheet::Winetricks),
                            cx,
                        ),
                    ],
                    cx,
                ),
                self.section(
                    "diagnostics",
                    "诊断",
                    #[cfg(not(target_os = "linux"))]
                    vec![
                        self.action(
                            "guided",
                            "开始引导式故障排查…",
                            Command::Sheet(PreviewSheet::Diagnostics),
                            cx,
                        ),
                        self.action("export", "导出诊断报告…", Command::ExportDiagnostics, cx),
                        self.action("repair", "修复容器…", Command::BottleRepair, cx),
                    ],
                    #[cfg(target_os = "linux")]
                    vec![
                        self.action("export", "导出诊断报告…", Command::ExportDiagnostics, cx),
                    ],
                    cx,
                ),
                self.section(
                    "cleanup",
                    "存储与清理",
                    #[cfg(not(target_os = "linux"))]
                    vec![
                        self.info("容器大小", "2.4 GB"),
                        self.action(
                            "cache-clean",
                            "清理着色器缓存…",
                            Command::CleanShaderCache,
                            cx,
                        ),
                    ],
                    #[cfg(target_os = "linux")]
                    vec![self.info("容器大小", "2.4 GB")],
                    cx,
                ),
            ],
        )
    }
    /// Installed programs. The demo keeps its static design snapshot; a live
    /// bottle renders `programs.list` with pin/block/Play rows.
    fn programs(&self, cx: &Context<Self>) -> AnyElement {
        if self.demo {
            return self.demo_programs(cx);
        }
        let Some(container) = self.selected_container() else {
            return self.form(
                "programs-scroll",
                vec![self.section(
                    "program-list",
                    "程序",
                    vec![muted("请先在侧边栏选择一个容器。").into_any_element()],
                    cx,
                )],
            );
        };
        let page = self
            .programs
            .as_ref()
            .filter(|page| page.container == container);
        let Some(page) = page else {
            return self.programs_status("正在读取程序…", cx);
        };
        if page.loading {
            return self.programs_status("正在读取程序…", cx);
        }
        if let Some(reason) = &page.error {
            return self.form(
                "programs-scroll",
                vec![self.section(
                    "program-list",
                    "程序",
                    vec![
                        muted(reason.clone()).into_any_element(),
                        row()
                            .py(px(8.))
                            .child(
                                Button::new("programs-retry")
                                    .label("重试")
                                    .on_click(cx.listener(|this, _, _, cx| this.reload_programs(cx))),
                            )
                            .into_any_element(),
                    ],
                    cx,
                )],
            );
        }
        let mut rows: Vec<AnyElement> = vec![row()
            .justify_end()
            .py(px(8.))
            .child(self.action("add-program", "添加程序…", Command::AddProgram, cx))
            .into_any_element()];
        if page.table.is_empty() {
            rows.push(muted(crate::programs::EMPTY_PROGRAMS).into_any_element());
        }
        for program in page.table.ordered() {
            let path = program.path.clone();
            let pin_path = path.clone();
            let block_path = path.clone();
            let play_path = path.clone();
            let pinned = program.pinned;
            let blocked = program.blocked;
            let launchable = program.available && !program.blocked;
            let (top, bottom) = theme::placeholder_gradient();
            rows.push(
                row()
                    .id(path.clone())
                    .gap(px(15.))
                    .p(px(13.))
                    .border_b_1()
                    .border_color(rgba(theme::divider()))
                    .child(
                        div()
                            .w(px(32.))
                            .h(px(40.))
                            .rounded(px(4.))
                            .bg(gradient(top, bottom))
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(icon("package", 14.).text_color(rgb(theme::muted_color()))),
                    )
                    .child(
                        col()
                            .flex_1()
                            .min_w_0()
                            .gap(px(4.))
                            .child(
                                row()
                                    .gap(px(6.))
                                    .child(div().truncate().font_weight(FontWeight::MEDIUM).child(program.name.clone()))
                                    .when(pinned, |d| {
                                        d.child(
                                            div()
                                                .px(px(6.))
                                                .py(px(1.))
                                                .rounded(px(4.))
                                                .bg(rgba(theme::accent_subtle_bg()))
                                                .text_size(px(10.))
                                                .text_color(rgb(theme::accent_fg()))
                                                .child("已固定"),
                                        )
                                    })
                                    .when(blocked, |d| {
                                        d.child(
                                            div()
                                                .px(px(6.))
                                                .py(px(1.))
                                                .rounded(px(4.))
                                                .bg(rgba(theme::badge_bg()))
                                                .text_size(px(10.))
                                                .text_color(rgb(theme::muted_color()))
                                                .child("已屏蔽"),
                                        )
                                    }),
                            )
                            .child(muted(path.clone()).text_size(px(11.)).truncate()),
                    )
                    .child(
                        Button::new(format!("program-pin:{path}"))
                            .label(if pinned { "取消固定" } else { "固定" })
                            .ghost()
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.toggle_program_pin(&pin_path, cx);
                            })),
                    )
                    .child(
                        Button::new(format!("program-block:{path}"))
                            .label(if blocked { "取消屏蔽" } else { "屏蔽" })
                            .ghost()
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.toggle_program_block(&block_path, cx);
                            })),
                    )
                    .when(launchable, |d| {
                        d.child(
                            Button::new(format!("program-play:{path}"))
                                .label("运行")
                                .ghost()
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.play_program(&play_path, cx);
                                })),
                        )
                    })
                    .into_any_element(),
            );
        }
        self.form(
            "programs-scroll",
            vec![self.section("program-list", "程序", rows, cx)],
        )
    }

    fn programs_status(&self, message: &'static str, cx: &Context<Self>) -> AnyElement {
        self.form(
            "programs-scroll",
            vec![self.section(
                "program-list",
                "程序",
                vec![
                    row()
                        .gap(px(8.))
                        .py(px(10.))
                        .child(Spinner::new().with_size(px(14.)))
                        .child(muted(message))
                        .into_any_element(),
                ],
                cx,
            )],
        )
    }

    fn demo_programs(&self, cx: &Context<Self>) -> AnyElement {
        let slot = self.bottle_slot();
        let rows = self
            .games()
            .iter()
            .enumerate()
            .filter(|(_, game)| game.bottle == slot)
            .map(|(i, game)| {
                let path = format!("C:\\Games\\{}\\game.exe", i + 1);
                let (top, bottom) = theme::placeholder_gradient();
                row()
                    .id(game.id.clone())
                    .gap(px(15.))
                    .p(px(13.))
                    .border_b_1()
                    .border_color(rgba(theme::divider()))
                    .child(match self.artwork(i) {
                        Some(artwork) => self.artwork_image(artwork)
                            .w(px(32.))
                            .h(px(40.))
                            .rounded(px(4.))
                            .object_fit(ObjectFit::Cover)
                            .into_any_element(),
                        None => div()
                            .w(px(32.))
                            .h(px(40.))
                            .rounded(px(4.))
                            .bg(gradient(top, bottom))
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(icon("package", 14.).text_color(rgb(theme::muted_color())))
                            .into_any_element(),
                    })
                    .child(
                        col()
                            .flex_1()
                            .min_w_0()
                            .gap(px(4.))
                            .child(div().truncate().child(game.title.clone()))
                            .when(!path.is_empty(), |d| d.child(muted(path).truncate())),
                    )
                    .child(self.game_options(i, cx))
                    .context_menu(self.game_menu(i, cx))
                    .into_any_element()
            })
            .collect();
        self.form(
            "programs-scroll",
            vec![self.section("program-list", "程序", rows, cx)],
        )
    }
    /// Running processes. The demo keeps its static design snapshot; a live
    /// bottle polls `processes.list` and renders each row in the demo list's
    /// two-column treatment with a kill action. The form scrolls, so the row
    /// count is unbounded.
    fn processes(&self, cx: &Context<Self>) -> AnyElement {
        if self.demo {
            return self.demo_processes(cx);
        }
        let Some(container) = self.selected_container() else {
            return self.form(
                "processes-scroll",
                vec![self.section(
                    "process-list",
                    "运行中的进程",
                    vec![muted("请先在侧边栏选择一个容器。").into_any_element()],
                    cx,
                )],
            );
        };
        let page = self
            .processes
            .as_ref()
            .filter(|page| page.container == container);
        let has_processes = page.is_some_and(|p| !p.table.is_empty());
        let mut rows: Vec<AnyElement> = vec![
            row()
                .gap(px(18.))
                .py(px(8.))
                .border_b_1()
                .border_color(rgba(theme::divider()))
                .child(muted("进程名称").flex_1().font_weight(FontWeight::SEMIBOLD).text_size(px(11.)))
                .child(muted("PID / 内存").text_size(px(11.)).font_weight(FontWeight::SEMIBOLD))
                .into_any_element(),
        ];
        match page {
            None => rows.push(self.process_status_row()),
            Some(page) => {
                if let Some(reason) = &page.error {
                    rows.push(muted(reason.clone()).py(px(10.)).into_any_element());
                } else if page.table.is_empty() {
                    if page.loading {
                        rows.push(self.process_status_row());
                    } else {
                        rows.push(muted("当前容器没有运行中的 Wine 进程。").py(px(14.)).into_any_element());
                    }
                }
                for process in page.table.rows() {
                    let pid = process.pid;
                    let value = match &process.memory {
                        Some(memory) => format!("{pid} · {memory}"),
                        None => format!("{pid}"),
                    };
                    rows.push(
                        row()
                            .gap(px(16.))
                            .py(px(9.))
                            .border_b_1()
                            .border_color(rgba(theme::divider()))
                            .child(div().flex_1().min_w_0().truncate().font_weight(FontWeight::MEDIUM).child(process.name.clone()))
                            .child(muted(value).font_family("monospace").text_size(px(11.)))
                            .child(
                                Button::new(format!("process-kill:{pid}"))
                                    .label("结束")
                                    .ghost()
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.kill_process(pid, cx);
                                    })),
                            )
                            .into_any_element(),
                    );
                }
            }
        }
        rows.push(
            row()
                .justify_end()
                .gap(px(8.))
                .pt(px(10.))
                .pb(px(4.))
                .child(
                    Button::new("refresh-processes")
                        .label("刷新")
                        .on_click(cx.listener(|this, _, _, cx| this.refresh_processes(cx))),
                )
                .child(
                    Button::new("stop-processes")
                        .label("停止所有进程")
                        .danger()
                        .disabled(!has_processes)
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.command(Command::StopAllProcesses, cx);
                        })),
                )
                .into_any_element(),
        );
        self.form(
            "processes-scroll",
            vec![self.section("process-list", "运行中的进程", rows, cx)],
        )
    }

    fn process_status_row(&self) -> AnyElement {
        row()
            .gap(px(8.))
            .py(px(10.))
            .child(Spinner::new().with_size(px(14.)))
            .child(muted("正在读取进程…"))
            .into_any_element()
    }

    fn demo_processes(&self, cx: &Context<Self>) -> AnyElement {
        self.form(
            "processes-scroll",
            vec![self.section(
                "process-list",
                "运行中的进程",
                vec![
                    row()
                        .gap(px(18.))
                        .py(px(8.))
                        .border_b_1()
                        .border_color(rgba(theme::divider()))
                        .child(muted("进程名称").flex_1().font_weight(FontWeight::SEMIBOLD).text_size(px(11.)))
                        .child(muted("PID / 内存").text_size(px(11.)).font_weight(FontWeight::SEMIBOLD))
                        .into_any_element(),
                    muted("当前容器没有运行中的 Wine 进程。").py(px(14.)).into_any_element(),
                    row()
                        .justify_end()
                        .gap(px(8.))
                        .pt(px(10.))
                        .pb(px(4.))
                        .child(self.action("refresh-processes", "刷新", Command::RefreshProcesses, cx))
                        .child(
                            Button::new("stop-processes")
                                .label("停止所有进程")
                                .danger()
                                .disabled(true)
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.command(Command::StopAllProcesses, cx);
                                })),
                        )
                        .into_any_element(),
                ],
                cx,
            )],
        )
    }
    fn game_configs(&self, cx: &Context<Self>) -> AnyElement {
        let slot = self.bottle_slot();
        let games: Vec<(usize, &crate::model::Game)> = self
            .games()
            .iter()
            .enumerate()
            .filter(|(_, game)| slot == 0 || game.bottle == slot)
            .collect();
        let mut rows: Vec<AnyElement> = vec![muted(
            "本地 GameDB 会按可执行文件名与 Steam App ID 匹配社区验证的配置；打开游戏资料页可预览并应用推荐设置。",
        )
        .text_size(px(11.))
        .into_any_element()];
        if games.is_empty() {
            rows.push(muted("当前容器还没有可匹配的游戏。").into_any_element());
        }
        for (index, game) in games {
            rows.push(
                row()
                    .gap(px(14.))
                    .p(px(11.))
                    .border_b_1()
                    .border_color(rgba(theme::divider()))
                    .child(
                        col()
                            .flex_1()
                            .min_w_0()
                            .gap(px(3.))
                            .child(div().truncate().child(game.title.clone()))
                            .when(!game.is_folder, |d| {
                                d.child(
                                    muted(
                                        game.executable
                                            .as_ref()
                                            .and_then(|path| path.file_name())
                                            .map(|name| name.to_string_lossy().into_owned())
                                            .unwrap_or_default(),
                                    )
                                    .text_size(px(11.)),
                                )
                            }),
                    )
                    .child(
                        Button::new(("game-info", index))
                            .label("资料与配置…")
                            .ghost()
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.command(Command::GameInfo(index), cx);
                            })),
                    )
                    .into_any_element(),
            );
        }
        rows.push(
            row()
                .justify_end()
                .py(px(8.))
                .child(self.action(
                    "sync-metadata",
                    "扫描并同步游戏信息",
                    Command::SyncMetadata,
                    cx,
                ))
                .into_any_element(),
        );
        self.form(
            "game-configs-scroll",
            vec![self.section("game-rules", "游戏配置", rows, cx)],
        )
    }
}

impl WhiskyApp {
    /// The bound Wine engine row on the bottle configuration page: current
    /// engine, availability and a picker. Rebinding an existing prefix goes
    /// through `EngineDialogKind::Select`; on old helpers without the API the
    /// whole section disappears.
    fn engine_section(&self, container: &str, cx: &Context<Self>) -> Option<AnyElement> {
        if !self.service_available("wine.engines.selection") {
            return None;
        }
        let selection = self.engine_selections.get(container);
        let engine = selection.map(|selection| &selection.engine);
        let current_id = selection
            .map(|selection| selection.engine_id.clone())
            .unwrap_or_else(|| "managed".to_owned());
        let title = engine
            .map(|engine| engine.name.clone())
            .unwrap_or_else(|| "Whisky Wine".to_owned());
        let unavailable_reason = engine.and_then(|engine| engine.error.clone());
        let has_engines = !self.wine_engines.is_empty();
        let view = cx.entity().downgrade();
        let container_owned = container.to_owned();
        let engines = self.wine_engines.clone();

        let mut rows = vec![self.info(
            "当前引擎",
            if engine.is_some_and(|engine| engine.available) || engine.is_none() {
                title.clone()
            } else {
                format!("{title} · 不可用")
            },
        )];
        if let Some(reason) = unavailable_reason {
            rows.push(muted(reason).text_size(px(11.)).into_any_element());
        }
        rows.push(
            row()
                .py(px(6.))
                .child(
                    Button::new("engine-select")
                        .label("更换引擎  ⌄")
                        .disabled(!has_engines)
                        .dropdown_menu(move |mut menu, _, _| {
                            if engines.is_empty() {
                                menu = menu.item(
                                    PopupMenuItem::new("（仅受管运行时）").disabled(true),
                                );
                            }
                            for engine in &engines {
                                let view = view.clone();
                                let container = container_owned.clone();
                                let engine_id = engine.id.clone();
                                let label = if engine.available {
                                    engine.name.clone()
                                } else {
                                    format!("{} · 不可用", engine.name)
                                };
                                menu = menu.item(
                                    PopupMenuItem::new(label)
                                        .disabled(!engine.available)
                                        .checked(engine.id == current_id)
                                        .on_click(move |_, _, cx| {
                                            let _ = view.update(cx, |this, cx| {
                                                this.request_engine_select(
                                                    &container, &engine_id, cx,
                                                );
                                            });
                                        }),
                                );
                            }
                            menu
                        }),
                )
                .into_any_element(),
        );
        rows.push(
            #[cfg(not(target_os = "linux"))]
            muted("引擎更换不会迁移容器前缀；请先停止容器内所有进程。外部引擎只读使用，更新与 GPTK 部署仅作用于受管运行时。")
                .text_size(px(11.))
                .line_height(relative(1.4))
                .into_any_element(),
            #[cfg(target_os = "linux")]
            muted("引擎更换不会迁移容器前缀；请先停止容器内所有进程。外部引擎只读使用，运行时更新仅作用于受管运行时。")
                .text_size(px(11.))
                .line_height(relative(1.4))
                .into_any_element(),
        );

        // Capability section: every feature the engine reports, its state,
        // and a revoke control for approvals — revoking is separate from
        // turning a setting off, since several settings can share a feature.
        if let Some(selection) = selection {
            let container_features = container.to_owned();
            let interesting: Vec<_> = selection
                .features
                .iter()
                .filter(|feature| feature.state != "supported")
                .collect();
            if !interesting.is_empty() {
                for feature in interesting {
                    let state_label = match feature.state.as_str() {
                        "unverified" if feature.enabled => "已确认",
                        "unverified" => "未验证",
                        _ => "不可用",
                    };
                    let reason = feature.reason.clone().unwrap_or_default();
                    let mut line = col().gap(px(2.)).py(px(4.)).child(
                        row()
                            .gap(px(10.))
                            .child(div().flex_1().min_w_0().child(format!(
                                "{} · {state_label}",
                                engine_feature_label(&feature.id)
                            )))
                            .when(feature.enabled, |d| {
                                let container = container_features.clone();
                                let feature_id = feature.id.clone();
                                d.child(
                                    Button::new(format!("engine-revoke:{}", feature.id))
                                        .label("撤销确认")
                                        .on_click(cx.listener(move |this, _, _, cx| {
                                            this.revoke_engine_feature(&container, &feature_id);
                                            cx.notify();
                                        })),
                                )
                            }),
                    );
                    if !reason.is_empty() {
                        line =
                            line.child(muted(reason).text_size(px(11.)).line_height(relative(1.4)));
                    }
                    rows.push(line.into_any_element());
                }
            }
        }
        Some(self.section("wine-engine", "Wine 引擎", rows, cx))
    }
}

/// Display label for a `wine.engines` feature id.
fn engine_feature_label(id: &str) -> &str {
    match id {
        "dxvk" => "DXVK",
        "dxmt" => "DXMT",
        "d3dMetal" => "D3DMetal",
        "esync" => "ESync",
        "msync" => "MSync",
        "avx" => "AVX",
        "gdiUpscaling" => "GDI 超分",
        "gdiCoreML" => "GDI CoreML",
        "metal" => "Metal 选项",
        "metalFX" => "MetalFX 桥",
        "frameGeneration" => "帧生成",
        "shadowImportedHostMemory" => "32 位 Vulkan 内存导入",
        "dxvkAsync" => "DXVK Async",
        _ => id,
    }
}
