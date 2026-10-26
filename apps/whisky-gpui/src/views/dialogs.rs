//! Modal sheets: run settings, scan folders, winetricks, create bottle, and diagnostics.

use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::switch::Switch;
use gpui_kit::component::{Disableable, Sizable};
use gpui_kit::{prelude::*, *};

use super::Command;
use crate::bridge::dto::FoldersDto;
use crate::bridge::{BridgeStatus, FolderEdit};
use crate::controls::*;
use crate::program_settings::{self, ProgramSettingsDto, RunEntryDto};
use crate::runtime::ClipboardDecision;
use crate::scan::{self, JobStatus};
use crate::state::{BottleDialogKind, PreviewSheet, ScanState, WhiskyApp};
use crate::theme::{MUTED, OVERLAY, RADIUS_LG, SURFACE, SURFACE_BORDER};
use crate::winetricks::{category_label, filtered_verbs};

const PROGRAM_LOCALES: &[(&str, &str)] = &[
    ("", "自动"),
    ("ja_JP.UTF-8", "日本語"),
    ("zh_CN.UTF-8", "简体中文"),
    ("zh_TW.UTF-8", "繁體中文"),
    ("en_US.UTF-8", "English"),
    ("de_DE.UTF-8", "Deutsch"),
    ("es_ES.UTF-8", "Español"),
    ("fr_FR.UTF-8", "Français"),
    ("it_IT.UTF-8", "Italiano"),
    ("ko_KR.UTF-8", "한국어"),
    ("ru_RU.UTF-8", "Русский"),
    ("uk_UA.UTF-8", "Українська"),
    ("th_TH.UTF-8", "ไทย"),
];
const GRAPHICS_BACKENDS: &[(&str, &str)] = &[
    ("recommended", "自动推荐"),
    #[cfg(not(target_os = "linux"))]
    ("d3dMetal", "D3DMetal"),
    ("dxvk", "DXVK"),
    #[cfg(not(target_os = "linux"))]
    ("dxmt", "DXMT"),
    ("wined3d", "WineD3D"),
];
const DXVK_HUDS: &[(&str, &str)] = &[
    ("full", "完整"),
    ("partial", "部分"),
    ("fps", "仅 FPS"),
    ("off", "关闭"),
];
const SYNC_MODES: &[(&str, &str)] = &[
    ("none", "关闭"),
    ("esync", "ESync"),
    #[cfg(not(target_os = "linux"))]
    ("msync", "MSync"),
];
const RESOLUTIONS: &[(&str, &str)] = &[
    ("r1280x720", "1280 × 720"),
    ("r1600x900", "1600 × 900"),
    ("r1920x1080", "1920 × 1080"),
    ("r2560x1440", "2560 × 1440"),
    ("r3840x2160", "3840 × 2160"),
    #[cfg(not(target_os = "linux"))]
    ("matchDisplay", "匹配显示器"),
    ("custom", "自定义"),
];
const DLL_MODES: &[(&str, &str)] = &[
    ("b", "仅内建"),
    ("n", "仅原生"),
    ("n,b", "原生优先"),
    ("b,n", "内建优先"),
    ("", "禁用"),
];

impl WhiskyApp {
    fn demo_run_settings(&self, index: usize, cx: &Context<Self>) -> AnyElement {
        self.form(
            "run-settings-scroll",
            vec![
                self.section(
                    "run-config",
                    "运行设置",
                    vec![
                        self.info(
                            "程序",
                            self.game(index)
                                .map(|game| game.title.clone())
                                .unwrap_or_default(),
                        ),
                        self.choice(
                            "locale",
                            "区域设置",
                            &[
                                "继承容器",
                                "日语（日本）",
                                "简体中文（中国）",
                                "英语（美国）",
                            ],
                            cx,
                        ),
                        self.field("arguments", "启动参数"),
                    ],
                    cx,
                ),
                self.section(
                    "env-presets",
                    "环境预设",
                    vec![self.choice(
                        "environment-preset",
                        "预设",
                        &["默认", "日语游戏", "旧版视觉小说", "自定义"],
                        cx,
                    )],
                    cx,
                ),
                self.section(
                    "environment",
                    "环境变量",
                    vec![
                        row()
                            .gap(px(10.))
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
                            .into_any_element(),
                        self.action("add-env", "添加环境变量", Command::Notice, cx),
                    ],
                    cx,
                ),
                self.section(
                    "overrides",
                    "程序专属覆盖",
                    vec![
                        self.toggle(
                            "override-graphics",
                            "覆盖图形设置",
                            "关闭时继承容器设置。",
                            cx,
                        ),
                        self.choice(
                            "program-backend",
                            "图形后端",
                            #[cfg(not(target_os = "linux"))]
                            &["继承容器", "D3DMetal", "DXVK", "WineD3D"],
                            #[cfg(target_os = "linux")]
                            &["继承容器", "DXVK", "WineD3D"],
                            cx,
                        ),
                        self.toggle("override-sync", "覆盖同步设置", "", cx),
                        self.toggle("override-input", "覆盖输入设置", "", cx),
                        self.toggle("override-display", "覆盖显示设置", "", cx),
                        self.action(
                            "program-dll",
                            "DLL 覆盖…",
                            Command::Sheet(PreviewSheet::Dll),
                            cx,
                        ),
                    ],
                    cx,
                ),
                self.section(
                    "run-diagnostics",
                    "诊断",
                    vec![
                        self.info("最近一次运行", "正常退出 · 8 分钟"),
                        self.action(
                            "run-troubleshoot",
                            "故障排查…",
                            Command::Sheet(PreviewSheet::Diagnostics),
                            cx,
                        ),
                    ],
                    cx,
                ),
                self.section(
                    "console",
                    "控制台与运行历史",
                    vec![
                        self.info("今天 19:39", "退出代码 0"),
                        muted("[wine] Program started\n[wine] Process exited successfully")
                            .font_family("monospace")
                            .p(px(12.))
                            .into_any_element(),
                    ],
                    cx,
                ),
            ],
        )
    }
    /// Real run settings: the draft lives in `program_settings`, and the
    /// footer's save sends one `programs.settings.set` patch.
    fn run_settings(
        &mut self,
        _index: usize,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if self.demo {
            return self.demo_run_settings(_index, cx);
        }
        if self.program_settings.loading && self.program_settings.settings.is_none() {
            return self.form(
                "run-settings-scroll",
                vec![self.section(
                    "program-loading",
                    "程序配置",
                    vec![
                        row()
                            .gap(px(8.))
                            .py(px(12.))
                            .child(Spinner::new().with_size(px(14.)))
                            .child(muted("正在读取程序设置…"))
                            .into_any_element(),
                    ],
                    cx,
                )],
            );
        }
        let Some(settings) = self.program_settings.settings.clone() else {
            let reason = self
                .program_settings
                .error
                .clone()
                .unwrap_or_else(|| "没有可用的程序设置。".to_owned());
            return self.form(
                "run-settings-scroll",
                vec![self.section(
                    "program-load-error",
                    "程序配置",
                    vec![
                        muted(reason).py(px(10.)).into_any_element(),
                        Button::new("program-settings-retry")
                            .label("重试")
                            .on_click(
                                cx.listener(|this, _, _, cx| this.retry_program_settings(cx)),
                            )
                            .into_any_element(),
                    ],
                    cx,
                )],
            );
        };

        let mut sections = Vec::new();
        if let Some(error) = &self.program_settings.error {
            sections.push(self.section(
                "program-settings-error",
                "保存失败",
                vec![muted(error.clone()).into_any_element()],
                cx,
            ));
        }
        sections.push(self.program_config_section(&settings, window, cx));
        sections.push(self.program_env_section(window, cx));
        sections.extend(self.program_override_sections(&settings, window, cx));
        sections.push(self.program_history_section(cx));
        sections.push(self.program_shortcut_section(window, cx));
        self.form("run-settings-scroll", sections)
    }

    fn program_input(
        &mut self,
        key: &str,
        value: &str,
        placeholder: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<InputState> {
        let key = key.to_owned();
        if let Some(input) = self.preview.program_inputs.get(&key) {
            return input.clone();
        }
        let value = value.to_owned();
        let input = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(placeholder)
                .default_value(value)
        });
        self.preview.program_inputs.insert(key, input.clone());
        input
    }

    fn program_switch(
        &self,
        id: String,
        label: &'static str,
        checked: bool,
        on_change: impl Fn(&mut WhiskyApp, bool) + 'static,
        cx: &Context<Self>,
    ) -> AnyElement {
        Switch::new(id)
            .label(label)
            .checked(checked)
            .on_change(cx.listener(move |this, checked, _, cx| {
                on_change(this, *checked);
                cx.notify();
            }))
            .into_any_element()
    }

    fn program_choice(
        &self,
        id: String,
        current: String,
        options: &'static [(&'static str, &'static str)],
        field: &'static str,
        cx: &Context<Self>,
    ) -> AnyElement {
        let view = cx.entity().downgrade();
        Button::new(id)
            .label(format!("{current}  ⌄"))
            .dropdown_menu(move |mut menu, _, _| {
                for &(raw, display) in options {
                    let view = view.clone();
                    menu = menu.item(
                        PopupMenuItem::new(display).on_click(move |_, _, cx| {
                            let _ = view.update(cx, |this, cx| {
                                if field == "locale" {
                                    this.set_program_locale(raw.to_owned(), cx);
                                } else {
                                    this.set_program_choice(field, raw);
                                    cx.notify();
                                }
                            });
                        }),
                    );
                }
                menu
            })
            .into_any_element()
    }

    fn program_choice_row(&self, label: &'static str, control: AnyElement) -> AnyElement {
        row()
            .gap(px(16.))
            .py(px(10.))
            .child(div().flex_1().min_w_0().child(label))
            .child(control)
            .into_any_element()
    }

    fn program_config_section(
        &mut self,
        settings: &ProgramSettingsDto,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let arguments = self.program_input(
            "ps-args",
            &settings.arguments,
            "启动参数，例如 -windowed",
            window,
            cx,
        );
        let locale = self.program_choice(
            "ps-locale".into(),
            program_settings::locale_label(&settings.locale).to_owned(),
            PROGRAM_LOCALES,
            "locale",
            cx,
        );
        self.section(
            "program-config",
            "程序配置",
            vec![
                self.info("程序", settings.program_name.clone()),
                self.info(
                    "可执行文件",
                    if settings.available {
                        "可用"
                    } else {
                        "文件已缺失"
                    },
                ),
                self.program_choice_row("语言区域", locale),
                col()
                    .gap(px(7.))
                    .py(px(8.))
                    .child("启动参数")
                    .child(Input::new(&arguments))
                    .into_any_element(),
            ],
            cx,
        )
    }

    fn program_env_section(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let rows = self.program_settings.env_rows.clone();
        let mut children: Vec<AnyElement> = vec![self.program_env_presets(cx)];
        if rows.is_empty() {
            children.push(muted("没有程序专属环境变量。").py(px(8.)).into_any_element());
        }
        for env_row in rows {
            let key = self.program_input(
                &format!("ps-env-key-{}", env_row.id),
                &env_row.key,
                "变量名",
                window,
                cx,
            );
            let value = self.program_input(
                &format!("ps-env-value-{}", env_row.id),
                &env_row.value,
                "变量值",
                window,
                cx,
            );
            let id = env_row.id;
            children.push(
                row()
                    .gap(px(10.))
                    .py(px(5.))
                    .child(div().flex_1().min_w_0().child(Input::new(&key)))
                    .child(div().flex_1().min_w_0().child(Input::new(&value)))
                    .child(
                        Button::new(format!("ps-env-remove-{id}"))
                            .label("−")
                            .ghost()
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.remove_program_env_row(id, cx);
                            })),
                    )
                    .into_any_element(),
            );
        }
        children.push(
            row()
                .py(px(6.))
                .child(
                    Button::new("ps-env-add")
                        .label("添加环境变量")
                        .on_click(cx.listener(|this, _, _, cx| this.add_program_env_row(cx))),
                )
                .into_any_element(),
        );
        self.section("program-env", "环境变量", children, cx)
    }

    /// One selectable pill of the quick-add presets.
    fn preset_chip(
        &self,
        id: String,
        label: &'static str,
        selected: bool,
        on_click: impl Fn(&mut WhiskyApp, &mut Context<WhiskyApp>) + 'static,
        cx: &Context<Self>,
    ) -> AnyElement {
        row()
            .id(SharedString::from(id))
            .gap(px(5.))
            .items_center()
            .h(px(26.))
            .px(px(11.))
            .rounded(px(13.))
            .border_1()
            .cursor_pointer()
            .text_size(px(12.))
            .border_color(rgba(if selected { 0xff891b99 } else { 0xffffff1f }))
            .bg(rgba(if selected { 0xff891b26 } else { 0xffffff08 }))
            .text_color(rgb(if selected { 0xffffff } else { 0xc4c4c9 }))
            .hover(|s| s.bg(rgba(if selected { 0xff891b33 } else { 0xffffff14 })))
            .when(selected, |d| {
                d.child(icon("check", 11.).text_color(rgb(crate::theme::ACCENT)))
            })
            .child(label)
            .on_click(cx.listener(move |this, _, _, cx| on_click(this, cx)))
            .into_any_element()
    }

    /// Quick presets from the SwiftUI editor: locale and WineD3D renderer.
    /// They rewrite LANG/LC_ALL and WINE_D3D_CONFIG in the draft rows below.
    fn program_env_presets(&self, cx: &Context<Self>) -> AnyElement {
        let locale = self
            .program_settings
            .settings
            .as_ref()
            .map(|settings| settings.locale.clone())
            .unwrap_or_default();
        let lang = self.program_env_value("LANG").map(str::to_owned);
        let lc_all = self.program_env_value("LC_ALL").map(str::to_owned);
        let locale_selected = |value: &str| {
            if value.is_empty() {
                locale.is_empty() && lang.is_none() && lc_all.is_none()
            } else {
                locale == value
                    && lang.as_deref() == Some(value)
                    && lc_all.as_deref() == Some(value)
            }
        };
        let mut locales = row().gap(px(8.)).flex_wrap();
        for (value, label) in [
            ("ja_JP.UTF-8", "日本語"),
            ("zh_CN.UTF-8", "简体中文"),
            ("zh_TW.UTF-8", "繁體中文"),
            ("", "自动"),
        ] {
            locales = locales.child(self.preset_chip(
                format!("env-locale-{value}"),
                label,
                locale_selected(value),
                move |this, cx| this.set_program_locale(value.to_owned(), cx),
                cx,
            ));
        }
        let renderer = self.program_d3d_renderer();
        let mut renderers = row().gap(px(8.)).flex_wrap();
        for (value, label) in [
            ("", "默认"),
            ("gdi", "GDI"),
            ("gl", "OpenGL"),
            ("vulkan", "Vulkan"),
        ] {
            renderers = renderers.child(self.preset_chip(
                format!("env-renderer-{value}"),
                label,
                renderer.as_deref() == Some(value),
                move |this, cx| this.set_program_renderer(value, cx),
                cx,
            ));
        }
        let group = |title: &'static str, chips: Div| {
            col()
                .gap(px(7.))
                .child(muted(title).text_size(px(11.)).font_weight(FontWeight::SEMIBOLD))
                .child(chips)
        };
        col()
            .gap(px(14.))
            .py(px(8.))
            .child(group("语言区域", locales))
            .child(
                group("WineD3D 渲染器", renderers)
            )
            .child(
                muted("预设会写入下方的 LANG、LC_ALL 与 WINE_D3D_CONFIG；渲染器仅在使用 WineD3D 时生效，其他 WineD3D 选项会保留。")
                    .text_size(px(11.))
                    .line_height(relative(1.4)),
            )
            .child(div().h(px(1.)).bg(rgba(SURFACE_BORDER)).mt(px(2.)))
            .into_any_element()
    }

    fn program_override_sections(
        &mut self,
        settings: &ProgramSettingsDto,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        vec![
            self.program_graphics_section(settings, cx),
            self.program_sync_section(settings, cx),
            self.program_performance_section(settings, cx),
            self.program_input_section(settings, cx),
            self.program_display_section(settings, window, cx),
            self.program_dll_section(settings, window, cx),
        ]
    }

    fn program_graphics_section(
        &self,
        settings: &ProgramSettingsDto,
        cx: &Context<Self>,
    ) -> AnyElement {
        let enabled = settings.graphics_enabled();
        let overrides = settings.overrides.as_ref();
        let defaults = &settings.defaults;
        let mut children = vec![self.program_switch(
            "ps-override-graphics".into(),
            "覆盖图形设置",
            enabled,
            |this, on| this.set_program_override_group("graphics", on),
            cx,
        )];
        if enabled {
            let backend = overrides
                .and_then(|value| value.graphics_backend.clone())
                .or_else(|| defaults.graphics_backend.clone())
                .unwrap_or_else(|| "recommended".into());
            children.push(self.program_choice_row(
                "图形后端",
                self.program_choice(
                    "ps-graphics-backend".into(),
                    program_settings::graphics_label(&backend).to_owned(),
                    GRAPHICS_BACKENDS,
                    "graphicsBackend",
                    cx,
                ),
            ));
            let async_on = overrides
                .and_then(|value| value.dxvk_async)
                .or(defaults.dxvk_async)
                .unwrap_or(true);
            children.push(self.program_switch(
                "ps-dxvk-async".into(),
                "DXVK Async",
                async_on,
                |this, on| this.set_program_override_bool("dxvkAsync", on),
                cx,
            ));
            let hud = overrides
                .and_then(|value| value.dxvk_hud.clone())
                .or_else(|| defaults.dxvk_hud.clone())
                .unwrap_or_else(|| "off".into());
            children.push(self.program_choice_row(
                "DXVK HUD",
                self.program_choice(
                    "ps-dxvk-hud".into(),
                    program_settings::hud_label(&hud).to_owned(),
                    DXVK_HUDS,
                    "dxvkHud",
                    cx,
                ),
            ));
            #[cfg(not(target_os = "linux"))]
            {
            let metal4 = overrides
                .and_then(|value| value.metal4_enabled)
                .or(defaults.metal4_enabled)
                .unwrap_or(false);
            children.push(self.program_switch(
                "ps-metal4".into(),
                "Metal 4 命令编码",
                metal4,
                |this, on| this.set_program_override_bool("metal4Enabled", on),
                cx,
            ));
            }
        } else {
            let backend = defaults.graphics_backend.as_deref().unwrap_or("recommended");
            let hud = defaults.dxvk_hud.as_deref().unwrap_or("off");
            children.push(
                muted(format!(
                    "继承：{} · HUD {}",
                    program_settings::graphics_label(backend),
                    program_settings::hud_label(hud)
                ))
                .into_any_element(),
            );
        }
        self.section("override-graphics", "图形", children, cx)
    }

    fn program_sync_section(
        &self,
        settings: &ProgramSettingsDto,
        cx: &Context<Self>,
    ) -> AnyElement {
        let enabled = settings.sync_enabled();
        let defaults = &settings.defaults;
        let mut children = vec![self.program_switch(
            "ps-override-sync".into(),
            "覆盖同步设置",
            enabled,
            |this, on| this.set_program_override_group("sync", on),
            cx,
        )];
        if enabled {
            let sync = settings
                .overrides
                .as_ref()
                .and_then(|value| value.enhanced_sync.clone())
                .or_else(|| defaults.enhanced_sync.clone())
                .unwrap_or_else(|| "msync".into());
            children.push(self.program_choice_row(
                "同步模式",
                self.program_choice(
                    "ps-sync-mode".into(),
                    program_settings::sync_label(&sync).to_owned(),
                    SYNC_MODES,
                    "enhancedSync",
                    cx,
                ),
            ));
        } else {
            let sync = defaults.enhanced_sync.as_deref().unwrap_or("msync");
            children.push(
                muted(format!("继承：{}", program_settings::sync_label(sync))).into_any_element(),
            );
        }
        self.section("override-sync", "同步", children, cx)
    }

    fn program_performance_section(
        &self,
        settings: &ProgramSettingsDto,
        cx: &Context<Self>,
    ) -> AnyElement {
        let enabled = settings.performance_enabled();
        let defaults = &settings.defaults;
        let mut children = vec![self.program_switch(
            "ps-override-performance".into(),
            "覆盖性能设置",
            enabled,
            |this, on| this.set_program_override_group("performance", on),
            cx,
        )];
        if enabled {
            let shader_cache = settings
                .overrides
                .as_ref()
                .and_then(|value| value.shader_cache_enabled)
                .or(defaults.shader_cache_enabled)
                .unwrap_or(true);
            children.push(self.program_switch(
                "ps-shader-cache".into(),
                "着色器缓存",
                shader_cache,
                |this, on| this.set_program_override_bool("shaderCacheEnabled", on),
                cx,
            ));
        } else {
            children.push(
                muted(format!(
                    "继承：着色器缓存 {}",
                    if defaults.shader_cache_enabled.unwrap_or(true) { "开" } else { "关" }
                ))
                .into_any_element(),
            );
        }
        self.section("override-performance", "性能", children, cx)
    }

    fn program_input_section(
        &self,
        settings: &ProgramSettingsDto,
        cx: &Context<Self>,
    ) -> AnyElement {
        let enabled = settings.input_enabled();
        let defaults = &settings.defaults;
        let overrides = settings.overrides.as_ref();
        let mut children = vec![self.program_switch(
            "ps-override-input".into(),
            "覆盖输入设置",
            enabled,
            |this, on| this.set_program_override_group("input", on),
            cx,
        )];
        if enabled {
            for (id, label, field) in [
                ("ps-controller-compat", "控制器兼容模式", "controllerCompatibilityMode"),
                ("ps-disable-hidapi", "禁用 HIDAPI", "disableHIDAPI"),
                ("ps-background-events", "后台允许手柄事件", "allowBackgroundEvents"),
                ("ps-disable-mapping", "禁用 SDL 映射", "disableControllerMapping"),
                ("ps-button-labels", "使用原生按键标签", "useButtonLabels"),
            ] {
                let checked = match field {
                    "controllerCompatibilityMode" => overrides
                        .and_then(|value| value.controller_compatibility_mode)
                        .or(defaults.controller_compatibility_mode)
                        .unwrap_or(false),
                    "disableHIDAPI" => overrides
                        .and_then(|value| value.disable_hidapi)
                        .or(defaults.disable_hidapi)
                        .unwrap_or(false),
                    "allowBackgroundEvents" => overrides
                        .and_then(|value| value.allow_background_events)
                        .or(defaults.allow_background_events)
                        .unwrap_or(false),
                    "disableControllerMapping" => overrides
                        .and_then(|value| value.disable_controller_mapping)
                        .or(defaults.disable_controller_mapping)
                        .unwrap_or(false),
                    _ => overrides
                        .and_then(|value| value.use_button_labels)
                        .or(defaults.use_button_labels)
                        .unwrap_or(false),
                };
                children.push(self.program_switch(
                    id.to_owned(),
                    label,
                    checked,
                    move |this, on| this.set_program_override_bool(field, on),
                    cx,
                ));
            }
        } else {
            children.push(
                muted(format!(
                    "继承：控制器兼容 {} · 原生标签 {}",
                    if defaults.controller_compatibility_mode.unwrap_or(false) {
                        "开"
                    } else {
                        "关"
                    },
                    if defaults.use_button_labels.unwrap_or(false) {
                        "开"
                    } else {
                        "关"
                    }
                ))
                .into_any_element(),
            );
        }
        self.section("override-input", "输入", children, cx)
    }

    fn program_display_section(
        &mut self,
        settings: &ProgramSettingsDto,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let enabled = settings.display_enabled();
        let defaults = &settings.defaults;
        let overrides = settings.overrides.as_ref();
        let mut children = vec![self.program_switch(
            "ps-override-display".into(),
            "覆盖显示设置",
            enabled,
            |this, on| this.set_program_override_group("display", on),
            cx,
        )];
        if enabled {
            let virtual_desktop = overrides
                .and_then(|value| value.virtual_desktop_enabled)
                .or(defaults.virtual_desktop_enabled)
                .unwrap_or(false);
            children.push(self.program_switch(
                "ps-virtual-desktop".into(),
                "启用虚拟桌面",
                virtual_desktop,
                |this, on| this.set_program_override_bool("virtualDesktopEnabled", on),
                cx,
            ));
            if virtual_desktop {
                let preset = overrides
                    .and_then(|value| value.resolution_preset.clone())
                    .or_else(|| defaults.resolution_preset.clone())
                    .unwrap_or_else(|| "r1920x1080".into());
                children.push(self.program_choice_row(
                    "分辨率",
                    self.program_choice(
                        "ps-resolution".into(),
                        program_settings::resolution_label(&preset).to_owned(),
                        RESOLUTIONS,
                        "resolutionPreset",
                        cx,
                    ),
                ));
                if preset == "custom" {
                    let width = overrides
                        .and_then(|value| value.custom_resolution_width)
                        .or(defaults.custom_resolution_width)
                        .unwrap_or(1920);
                    let height = overrides
                        .and_then(|value| value.custom_resolution_height)
                        .or(defaults.custom_resolution_height)
                        .unwrap_or(1080);
                    let width_input = self.program_input(
                        "ps-res-width",
                        &width.to_string(),
                        "1920",
                        window,
                        cx,
                    );
                    let height_input = self.program_input(
                        "ps-res-height",
                        &height.to_string(),
                        "1080",
                        window,
                        cx,
                    );
                    children.push(
                        row()
                            .gap(px(10.))
                            .py(px(6.))
                            .child(div().w(px(110.)).child(Input::new(&width_input)))
                            .child(muted("×"))
                            .child(div().w(px(110.)).child(Input::new(&height_input)))
                            .into_any_element(),
                    );
                }
            }
        } else {
            children.push(
                muted(format!(
                    "继承：{} · {}",
                    if defaults.virtual_desktop_enabled.unwrap_or(false) {
                        "虚拟桌面开"
                    } else {
                        "虚拟桌面关"
                    },
                    program_settings::resolution_label(
                        defaults.resolution_preset.as_deref().unwrap_or("r1920x1080")
                    )
                ))
                .into_any_element(),
            );
        }
        self.section("override-display", "显示", children, cx)
    }

    fn program_dll_section(
        &mut self,
        settings: &ProgramSettingsDto,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let enabled = settings.dll_enabled();
        let mut children = vec![self.program_switch(
            "ps-override-dll".into(),
            "覆盖 DLL 设置",
            enabled,
            |this, on| this.set_program_override_group("dll", on),
            cx,
        )];
        if enabled {
            let entries = settings
                .overrides
                .as_ref()
                .and_then(|value| value.dll_overrides.clone())
                .unwrap_or_default();
            if entries.is_empty() {
                children.push(muted("没有程序专属 DLL 覆盖。").py(px(6.)).into_any_element());
            }
            for (index, entry) in entries.iter().enumerate() {
                let mode = program_settings::dll_mode_label(&entry.mode);
                children.push(
                    row()
                        .gap(px(12.))
                        .py(px(5.))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .font_family("monospace")
                                .truncate()
                                .child(entry.dll_name.clone()),
                        )
                        .child(muted(mode.to_owned()))
                        .child(
                            Button::new(format!("ps-dll-remove-{index}"))
                                .label("−")
                                .ghost()
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.remove_program_dll_override(index);
                                    cx.notify();
                                })),
                        )
                        .into_any_element(),
                );
            }
            let name = self.program_input("ps-dll-name", "", "例如 dxgi", window, cx);
            let mode = self.program_settings.dll_new_mode.clone();
            let mode_control = self.program_choice(
                "ps-dll-new-mode".into(),
                program_settings::dll_mode_label(&mode).to_owned(),
                DLL_MODES,
                "dllNewMode",
                cx,
            );
            children.push(
                row()
                    .gap(px(10.))
                    .py(px(8.))
                    .child(div().flex_1().min_w_0().child(Input::new(&name)))
                    .child(mode_control)
                    .child(
                        Button::new("ps-dll-add")
                            .label("添加")
                            .on_click(cx.listener(|this, _, _, cx| {
                                let name = this
                                    .preview
                                    .program_inputs
                                    .get("ps-dll-name")
                                    .map(|input| input.read(cx).value().to_string())
                                    .unwrap_or_default();
                                this.add_program_dll_override(name, cx);
                            })),
                    )
                    .into_any_element(),
            );
        } else {
            let count = settings
                .defaults
                .dll_overrides
                .as_ref()
                .map_or(0, Vec::len);
            children.push(
                muted(format!("继承：容器级 {count} 条 DLL 覆盖")).into_any_element(),
            );
        }
        self.section("override-dll", "DLL 覆盖", children, cx)
    }

    fn program_history_section(&self, cx: &Context<Self>) -> AnyElement {
        let mut children: Vec<AnyElement> = Vec::new();
        if self.program_settings.history_loading {
            children.push(
                row()
                    .gap(px(8.))
                    .py(px(10.))
                    .child(Spinner::new().with_size(px(14.)))
                    .child(muted("正在读取运行历史…"))
                    .into_any_element(),
            );
        } else if let Some(error) = &self.program_settings.history_error {
            children.push(muted(error.clone()).py(px(8.)).into_any_element());
            children.push(
                Button::new("program-history-retry")
                    .label("重试")
                    .on_click(cx.listener(|this, _, _, cx| this.reload_program_history(cx)))
                    .into_any_element(),
            );
        } else if self.program_settings.history.is_empty() {
            children.push(muted("还没有运行记录。").py(px(8.)).into_any_element());
        } else {
            let container = self.program_settings.container.clone().unwrap_or_default();
            for entry in self
                .program_settings
                .history_entries_newest_first()
                .into_iter()
                .cloned()
                .collect::<Vec<RunEntryDto>>()
            {
                children.push(self.program_history_row(&container, &entry, cx));
            }
            children.push(
                row()
                    .py(px(6.))
                    .child(
                        Button::new("program-history-clear")
                            .label("清空历史")
                            .ghost()
                            .on_click(cx.listener(|this, _, _, cx| this.clear_program_history(cx))),
                    )
                    .into_any_element(),
            );
        }
        self.section("program-history", "运行历史", children, cx)
    }

    fn program_history_row(
        &self,
        container: &str,
        entry: &RunEntryDto,
        cx: &Context<Self>,
    ) -> AnyElement {
        let log_path = entry.log_path.clone();
        let container = container.to_owned();
        let run_id = entry.id.clone();
        let exit = entry
            .exit_code
            .map(|code| format!("退出 {code}"))
            .unwrap_or_else(|| "运行中".to_owned());
        row()
            .gap(px(12.))
            .py(px(8.))
            .border_b_1()
            .border_color(rgba(0xffffff08))
            .child(
                col()
                    .flex_1()
                    .min_w_0()
                    .gap(px(2.))
                    .child(program_settings::relative_time(entry.start_time))
                    .child(
                        muted(format!(
                            "{} · {}",
                            program_settings::duration_label(entry.duration),
                            exit
                        ))
                        .truncate(),
                    ),
            )
            .when(!log_path.is_empty(), |d| {
                d.child(
                    Button::new(format!("program-log-{run_id}"))
                        .label("打开日志")
                        .ghost()
                        .on_click(cx.listener(move |this, _, _, _| {
                            this.bridge.open(&container, &log_path);
                        })),
                )
            })
            .child(
                Button::new(format!("program-run-delete-{run_id}"))
                    .label("删除")
                    .ghost()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.delete_program_run(run_id.clone(), cx);
                    })),
            )
            .into_any_element()
    }

    fn program_shortcut_section(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let destination = self.program_settings.shortcut_destination.clone();
        let input = self.program_input("ps-shortcut-dest", &destination, if cfg!(target_os = "linux") { "~/.local/share/applications" } else { "~/Applications" }, window, cx);
        let mut children: Vec<AnyElement> = vec![
            col()
                .gap(px(7.))
                .py(px(8.))
                .child("快捷方式位置")
                .child(Input::new(&input))
                .into_any_element(),
            muted(if cfg!(target_os = "linux") { "在目标目录创建指向该容器和程序的 .desktop 快捷方式。" } else { "在目标目录创建可双击启动该程序的 .app。" })
                .into_any_element(),
        ];
        if let Some(path) = &self.program_settings.shortcut_path {
            children.push(muted(format!("已创建：{path}")).into_any_element());
        }
        if let Some(error) = &self.program_settings.shortcut_error {
            children.push(muted(error.clone()).into_any_element());
        }
        children.push(
            row()
                .py(px(6.))
                .child(
                    Button::new("ps-shortcut-create")
                        .label("创建快捷方式")
                        .on_click(cx.listener(|this, _, _, cx| this.create_program_shortcut(cx))),
                )
                .into_any_element(),
        );
        self.section("program-shortcut", "快捷方式", children, cx)
    }

    /// Scan folders for one bottle. Roots, assignment, exclusion and the
    /// executable are all `folders.*` calls; the scan itself is a bridge job.
    fn scan_settings(&mut self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        if self.demo {
            return self.demo_scan_settings(cx);
        }
        let Some(container) = self.scan_container() else {
            return self.form(
                "scan-settings-scroll",
                vec![self.section(
                    "scan-folders",
                    "扫描文件夹",
                    vec![muted("请先在侧边栏选择一个容器。").into_any_element()],
                    cx,
                )],
            );
        };
        let mut rows: Vec<AnyElement> = Vec::new();
        match self.folders.get(&container).cloned() {
            Some(folders) => {
                rows.push(
                    row()
                        .py(px(10.))
                        .gap(px(16.))
                        .child(div().flex_1().min_w_0().child("自动读取元数据"))
                        .child(
                            Switch::new("scan-automatic-metadata")
                                .checked(folders.automatic_metadata)
                                .on_change(cx.listener(|this, checked, _, cx| {
                                    this.edit_folder(
                                        FolderEdit::AutomaticMetadata(*checked),
                                        cx,
                                    );
                                })),
                        )
                        .into_any_element(),
                );
                rows.push(
                    row()
                        .py(px(10.))
                        .gap(px(16.))
                        .child(
                            col()
                                .flex_1()
                                .min_w_0()
                                .gap(px(3.))
                                .child("包含固定程序与 Steam 游戏")
                                .child(muted("关闭后游戏库只显示扫描文件夹中的游戏。").text_size(px(11.))),
                        )
                        .child(
                            Switch::new("scan-include-pinned-steam")
                                .checked(folders.include_pinned_and_steam)
                                .on_change(cx.listener(|this, checked, _, cx| {
                                    this.edit_folder(FolderEdit::Visibility(*checked), cx);
                                })),
                        )
                        .into_any_element(),
                );
                if folders.roots.is_empty() {
                    rows.push(muted("尚未添加扫描文件夹").into_any_element());
                }
                for root in folders.roots.clone() {
                    rows.push(self.scan_root_row(&container, &folders, &root, window, cx));
                }
                rows.push(
                    row()
                        .gap(px(10.))
                        .py(px(10.))
                        .child(
                            Button::new("scan-add-picker")
                                .label("选择文件夹…")
                                .primary()
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.choose_scan_roots(cx);
                                })),
                        )
                        .child(muted("可多选，从容器 C: 盘开始").text_size(px(11.)))
                        .into_any_element(),
                );
                rows.push(
                    row()
                        .gap(px(10.))
                        .py(px(10.))
                        .child(
                            div()
                                .flex_1()
                                .child(Input::new(&self.preview.inputs["scan-path"])),
                        )
                        .child(
                            Button::new("scan-add")
                                .label("添加路径")
                                .on_click(cx.listener(|this, _, _, cx| {
                                    let path =
                                        this.preview.inputs["scan-path"].read(cx).value().to_string();
                                    this.add_scan_root(&path, cx);
                                })),
                        )
                        .into_any_element(),
                );
            }
            None if self.folders_pending.contains(&container) => rows.push(
                row()
                    .gap(px(8.))
                    .py(px(10.))
                    .child(Spinner::new().with_size(px(14.)))
                    .child(muted("正在读取扫描文件夹…"))
                    .into_any_element(),
            ),
            None => {
                let reason = self
                    .folders_error
                    .get(&container)
                    .cloned()
                    .unwrap_or_else(|| "尚未读取扫描文件夹。".to_owned());
                rows.push(muted(reason).into_any_element());
                rows.push(
                    row()
                        .py(px(8.))
                        .child(
                            Button::new("scan-folders-retry")
                                .label("重试")
                                .on_click(cx.listener(|this, _, _, cx| this.reload_folders(cx))),
                        )
                        .into_any_element(),
                );
            }
        }
        rows.extend(self.scan_controls(&container, cx));
        self.form(
            "scan-settings-scroll",
            vec![self.section("scan-folders", "扫描文件夹", rows, cx)],
        )
    }

    fn scan_root_row(
        &mut self,
        container: &str,
        folders: &FoldersDto,
        root: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let assigned = folders.is_assigned(root);
        let excluded = folders.is_excluded(root);
        let executable = folders.executable_for(root).unwrap_or_default().to_owned();
        let display = if executable.is_empty() {
            "未设置可执行文件".to_owned()
        } else {
            executable.clone()
        };
        let input = self.folder_input(root, &executable, window, cx);
        let assign_root = root.to_owned();
        let exclude_root = root.to_owned();
        let remove_root = root.to_owned();
        let executable_root = root.to_owned();
        let executable_key = format!("scan-exe:{root}");
        let other_bottles: Vec<(usize, String)> = self
            .bottles
            .iter()
            .enumerate()
            .filter(|(_, bottle)| bottle.available && bottle.path != container)
            .map(|(index, bottle)| (index, bottle.name.clone()))
            .collect();
        let move_button = if other_bottles.is_empty() {
            None
        } else {
            let view = cx.entity().downgrade();
            let menu_root = root.to_owned();
            Some(
                Button::new(format!("scan-move:{root}"))
                    .label("移动…")
                    .ghost()
                    .dropdown_menu(move |mut menu, _, _| {
                        for (index, name) in other_bottles.clone() {
                            let view = view.clone();
                            let menu_root = menu_root.clone();
                            menu = menu.item(PopupMenuItem::new(name).on_click(
                                move |_, _, cx| {
                                    let _ = view.update(cx, |this, cx| {
                                        this.move_scan_root(&menu_root, index, cx);
                                    });
                                },
                            ));
                        }
                        menu
                    }),
            )
        };
        col()
            .gap(px(8.))
            .py(px(10.))
            .child(
                row()
                    .gap(px(10.))
                    .child(
                        col()
                            .flex_1()
                            .min_w_0()
                            .gap(px(4.))
                            .child(div().truncate().child(root.to_owned()))
                            .child(muted(display).truncate()),
                    )
                    .child(
                        Switch::new(format!("scan-assign:{root}"))
                            .label("游戏库")
                            .checked(assigned)
                            .on_change(cx.listener(move |this, checked, _, cx| {
                                this.edit_folder(
                                    FolderEdit::Assign {
                                        path: assign_root.clone(),
                                        assigned: *checked,
                                    },
                                    cx,
                                );
                            })),
                    )
                    .child(
                        Switch::new(format!("scan-exclude:{root}"))
                            .label("排除")
                            .checked(excluded)
                            .on_change(cx.listener(move |this, checked, _, cx| {
                                this.edit_folder(
                                    FolderEdit::Exclude {
                                        path: exclude_root.clone(),
                                        excluded: *checked,
                                    },
                                    cx,
                                );
                            })),
                    )
                    .when_some(move_button, |d, button| d.child(button))
                    .child(
                        Button::new(format!("scan-remove:{root}"))
                            .label("−")
                            .ghost()
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.edit_folder(
                                    FolderEdit::RemoveRoot(remove_root.clone()),
                                    cx,
                                );
                            })),
                    ),
            )
            .child(
                row()
                    .gap(px(10.))
                    .child(div().flex_1().child(Input::new(&input)))
                    .child(
                        Button::new(format!("scan-exe:{root}"))
                            .label("设置可执行文件")
                            .on_click(cx.listener(move |this, _, _, cx| {
                                let text = this
                                    .preview
                                    .folder_inputs
                                    .get(&executable_key)
                                    .map(|input| input.read(cx).value().to_string())
                                    .unwrap_or_default();
                                let executable = (!text.trim().is_empty())
                                    .then(|| text.trim().to_owned());
                                this.edit_folder(
                                    FolderEdit::Executable {
                                        path: executable_root.clone(),
                                        executable,
                                    },
                                    cx,
                                );
                            })),
                    ),
            )
            .child(muted(format!("容器：{container}")).text_size(px(10.)))
            .into_any_element()
    }

    fn folder_input(
        &mut self,
        root: &str,
        value: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Entity<InputState> {
        let key = format!("scan-exe:{root}");
        if let Some(input) = self.preview.folder_inputs.get(&key) {
            return input.clone();
        }
        let entity = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder("/路径/游戏.exe")
                .default_value(value.to_owned())
        });
        self.preview.folder_inputs.insert(key, entity.clone());
        entity
    }

    /// Start / progress / cancel, using the sheet's existing spinner treatment.
    fn scan_controls(&self, container: &str, cx: &Context<Self>) -> Vec<AnyElement> {
        let scan = self.scan_for(container);
        let elsewhere = self
            .scan
            .as_ref()
            .is_some_and(|scan| scan.container != container && scan.running());
        let mut rows: Vec<AnyElement> = Vec::new();
        if let Some(state) = scan {
            let status = state.status.unwrap_or(JobStatus::Queued);
            let label = scan::progress_label(status, state.stage.as_deref());
            let counts = state
                .total
                .map(|total| format!("{} / {total}", state.loaded))
                .unwrap_or_default();
            let mut line = row()
                .gap(px(8.))
                .py(px(10.))
                .child(if state.running() {
                    Spinner::new().with_size(px(14.)).into_any_element()
                } else {
                    div().into_any_element()
                })
                .child(div().child(label));
            if !counts.is_empty() {
                line = line.child(muted(counts));
            }
            rows.push(line.into_any_element());
            if let Some(error) = &state.error {
                rows.push(muted(error.clone()).into_any_element());
            }
        }
        if scan.is_some_and(ScanState::running) {
            rows.push(
                row()
                    .py(px(6.))
                    .child(
                        Button::new("scan-cancel")
                            .label("取消扫描")
                            .on_click(cx.listener(|this, _, _, cx| this.cancel_scan(cx))),
                    )
                    .into_any_element(),
            );
        } else {
            rows.push(
                row()
                    .gap(px(10.))
                    .py(px(6.))
                    .child(
                        Button::new("scan-start")
                            .label(if scan.is_some() { "再次扫描" } else { "立即扫描" })
                            .primary()
                            .disabled(elsewhere)
                            .on_click(cx.listener(|this, _, _, cx| this.start_scan(cx))),
                    )
                    .when(elsewhere, |d| d.child(muted("另一个容器的扫描正在进行")))
                    .into_any_element(),
            );
        }
        rows
    }

    fn demo_scan_settings(&self, cx: &Context<Self>) -> AnyElement {
        self.form(
            "scan-settings-scroll",
            vec![self.section(
                "scan-folders",
                "扫描文件夹",
                vec![
                    self.info("~/Games", "递归扫描"),
                    self.field("scan-path", "添加文件夹"),
                    self.action("scan-add", "添加文件夹", Command::Notice, cx),
                ],
                cx,
            )],
        )
    }

    /// Every `.exe` the helper found under the folder, newest section first.
    /// Choosing one records it; Play opened the picker, so it also starts.
    fn executable_picker(&self, cx: &Context<Self>) -> AnyElement {
        let Some(picker) = self.executable_picker.as_ref() else {
            return self.form(
                "executable-scroll",
                vec![self.section(
                    "executable-empty",
                    "启动程序",
                    vec![self.info("没有找到可启动的程序", "该文件夹下没有 .exe")],
                    cx,
                )],
            );
        };
        let folder = picker.folder.clone();
        let mut rows: Vec<AnyElement> = Vec::new();
        if picker.candidates.is_empty() {
            rows.push(
                row()
                    .gap(px(10.))
                    .py(px(14.))
                    .justify_center()
                    .child(Spinner::new().with_size(px(14.)))
                    .child(muted("正在递归扫描该文件夹下的可执行程序…"))
                    .into_any_element(),
            );
        }
        for (i, candidate) in picker.candidates.iter().enumerate() {
            let path = candidate.path.clone();
            let view = cx.entity().downgrade();
            let location = candidate.location(&folder);
            let is_root = location == "根目录";
            let row_id = SharedString::from(format!("exe-candidate-{}", i));
            rows.push(
                row()
                    .id(row_id)
                    .w_full()
                    .p(px(10.))
                    .my(px(3.))
                    .gap(px(12.))
                    .rounded(px(8.))
                    .bg(rgba(0xffffff05))
                    .border_1()
                    .border_color(rgba(0xffffff08))
                    .cursor_pointer()
                    .hover(|d| d.bg(rgba(0xffffff10)).border_color(rgba(0xffffff18)))
                    .on_click(move |_, _, cx| {
                        let _ = view.update(cx, |this, cx| {
                            this.choose_executable(&path, cx);
                        });
                    })
                    .child(
                        div()
                            .size(px(36.))
                            .rounded(px(7.))
                            .bg(gradient(0xffffff14, 0xffffff06))
                            .border_1()
                            .border_color(rgba(0xffffff0d))
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(icon("package", 16.).text_color(rgb(if is_root { 0xff891b } else { 0x97979b }))),
                    )
                    .child(
                        col()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(
                                row()
                                    .gap(px(6.))
                                    .items_center()
                                    .child(
                                        div()
                                            .font_weight(FontWeight::MEDIUM)
                                            .text_size(px(13.))
                                            .truncate()
                                            .child(candidate.name.clone()),
                                    )
                                    .when(is_root, |d| {
                                        d.child(
                                            div()
                                                .px(px(6.))
                                                .py(px(1.))
                                                .rounded(px(4.))
                                                .bg(rgba(0xff891b22))
                                                .text_size(px(10.))
                                                .text_color(rgb(0xff891b))
                                                .child("主程序"),
                                        )
                                    }),
                            )
                            .child(
                                div()
                                    .text_size(px(11.))
                                    .text_color(rgb(0x97979b))
                                    .truncate()
                                    .child(location),
                            ),
                    )
                    .child(
                        row()
                            .gap(px(4.))
                            .items_center()
                            .child(muted("选择"))
                            .child(muted("›")),
                    )
                    .into_any_element(),
            );
        }
        self.form(
            "executable-scroll",
            vec![
                self.section(
                    "executable-folder",
                    "游戏目录",
                    vec![self.info(&picker.title, &folder)],
                    cx,
                ),
                self.section("executable-list", "选择可执行程序 (.exe)", rows, cx),
            ],
        )
    }

    /// The live Winetricks sheet: catalog search, installed state and one
    /// helper-driven install job. `WHISKY_GPUI_DEMO_DATA=1` keeps the original
    /// static form so the visual baseline is unchanged.
    fn winetricks_sheet(&self, cx: &mut Context<Self>) -> AnyElement {
        if self.demo {
            return self.demo_winetricks(cx);
        }
        let Some(container) = self.selected_container() else {
            return self.form(
                "winetricks-scroll",
                vec![self.section(
                    "tricks",
                    "可用组件",
                    vec![muted("请先在侧边栏选择一个容器。").into_any_element()],
                    cx,
                )],
            );
        };

        let mut sections = Vec::new();
        let installed = self.winetricks.installed_for(&container);
        let mut filter_rows: Vec<AnyElement> = vec![self.field("dependency-search", "搜索组件")];
        if let Some(catalog) = &self.winetricks.catalog {
            let mut tabs = row().flex_wrap().gap(px(6.)).py(px(6.));
            for category in &catalog.categories {
                let id = category.id.clone();
                let active = self.winetricks.category.as_deref() == Some(id.as_str());
                let view = cx.entity().downgrade();
                let next = id.clone();
                let button = if active {
                    Button::new(format!("trick-category:{id}"))
                        .label(category_label(&id).to_owned())
                        .primary()
                } else {
                    Button::new(format!("trick-category:{id}"))
                        .label(category_label(&id).to_owned())
                };
                tabs = tabs.child(button.on_click(move |_, _, cx| {
                    let _ = view.update(cx, |this, cx| {
                        this.winetricks.category = Some(next.clone());
                        this.winetricks.selected = None;
                        cx.notify();
                    });
                }));
            }
            filter_rows.push(tabs.into_any_element());

            let mut filter_line = row().gap(px(14.)).py(px(6.));
            filter_line = filter_line.child(
                Switch::new("trick-installed-only")
                    .label("仅显示已安装")
                    .checked(self.flag("trick-installed-only"))
                    .on_change(cx.listener(|this, checked, _, cx| {
                        this.preview
                            .toggles
                            .insert("trick-installed-only", *checked);
                        cx.notify();
                    })),
            );
            if let Some(installed) = installed {
                filter_line = filter_line.child(muted(format!(
                    "已安装 {} 个 · 共 {} 个",
                    installed.len(),
                    catalog.verb_count()
                )));
            } else if self.winetricks.installed_pending.contains(&container) {
                filter_line = filter_line
                    .child(Spinner::new().with_size(px(12.)))
                    .child(muted("正在读取已安装组件…"));
            } else if let Some(error) = self.winetricks.installed_error.get(&container) {
                filter_line = filter_line.child(muted(error.clone())).child(
                    Button::new("trick-installed-error-retry")
                        .label("重试")
                        .on_click(
                            cx.listener(|this, _, _, cx| this.reload_installed_winetricks(cx)),
                        ),
                );
            }
            filter_rows.push(filter_line.into_any_element());
        }
        sections.push(self.section("trick-filter", "搜索与筛选", filter_rows, cx));

        match &self.winetricks.catalog {
            Some(catalog) => {
                let installed_only = self.flag("trick-installed-only");
                let installed_missing = installed_only && installed.is_none();
                let query = self.preview.inputs["dependency-search"]
                    .read(cx)
                    .value()
                    .to_string();
                let category = self
                    .winetricks
                    .category
                    .as_ref()
                    .and_then(|id| {
                        catalog
                            .categories
                            .iter()
                            .find(|category| &category.id == id)
                    })
                    .or_else(|| catalog.categories.first());

                if let Some(job) = self
                    .winetricks
                    .job
                    .as_ref()
                    .filter(|job| job.container == container)
                {
                    sections.push(self.section(
                        "trick-job",
                        "安装进度",
                        self.winetricks_job_rows(job, cx),
                        cx,
                    ));
                }

                let mut rows: Vec<AnyElement> = Vec::new();
                if installed_missing && self.winetricks.installed_pending.contains(&container) {
                    rows.push(
                        row()
                            .gap(px(8.))
                            .py(px(12.))
                            .child(Spinner::new().with_size(px(14.)))
                            .child(muted("正在读取已安装组件…"))
                            .into_any_element(),
                    );
                } else if installed_missing {
                    let reason = self
                        .winetricks
                        .installed_error
                        .get(&container)
                        .cloned()
                        .unwrap_or_else(|| "尚未读取已安装组件。".to_owned());
                    rows.push(muted(reason).py(px(10.)).into_any_element());
                    rows.push(
                        Button::new("trick-installed-retry")
                            .label("重试")
                            .on_click(
                                cx.listener(|this, _, _, cx| this.reload_installed_winetricks(cx)),
                            )
                            .into_any_element(),
                    );
                } else if let Some(category) = category {
                    let verbs = filtered_verbs(category, &query, installed_only, installed);
                    if verbs.is_empty() {
                        rows.push(
                            muted(if installed_only {
                                "该分类下还没有已安装的组件。"
                            } else {
                                "没有匹配的组件。"
                            })
                            .py(px(10.))
                            .into_any_element(),
                        );
                    }
                    for verb in verbs {
                        rows.push(self.winetricks_verb_row(
                            verb,
                            installed.is_some_and(|installed| installed.contains(&verb.name)),
                            cx,
                        ));
                    }
                } else {
                    rows.push(
                        muted("该容器没有可用的组件目录。")
                            .py(px(10.))
                            .into_any_element(),
                    );
                }
                sections.push(self.section("tricks", "可用组件", rows, cx));
            }
            None if self.winetricks.catalog_pending => {
                sections.push(self.section(
                    "trick-loading",
                    "可用组件",
                    vec![
                        row()
                            .gap(px(8.))
                            .py(px(12.))
                            .child(Spinner::new().with_size(px(14.)))
                            .child(muted("正在读取组件目录…"))
                            .into_any_element(),
                    ],
                    cx,
                ));
            }
            None => {
                let reason = self
                    .winetricks
                    .catalog_error
                    .clone()
                    .unwrap_or_else(|| "尚未读取组件目录。".to_owned());
                sections.push(self.section(
                    "trick-load-error",
                    "可用组件",
                    vec![
                        muted(reason).py(px(10.)).into_any_element(),
                        Button::new("trick-catalog-retry")
                            .label("重试")
                            .on_click(
                                cx.listener(|this, _, _, cx| this.reload_winetricks_catalog(cx)),
                            )
                            .into_any_element(),
                    ],
                    cx,
                ));
            }
        }
        self.form("winetricks-scroll", sections)
    }

    fn winetricks_job_rows(
        &self,
        job: &crate::winetricks::InstallJob,
        cx: &Context<Self>,
    ) -> Vec<AnyElement> {
        let mut rows: Vec<AnyElement> = Vec::new();
        let mut line = row().gap(px(8.)).py(px(8.)).child(div().child(job.label()));
        if job.running() {
            line = line.child(Spinner::new().with_size(px(14.)));
        }
        if let Some(count) = job.progress.count_label() {
            line = line.child(muted(count));
        }
        rows.push(line.into_any_element());
        if let Some(output) = &job.progress.line {
            rows.push(
                div()
                    .w_full()
                    .truncate()
                    .font_family("monospace")
                    .text_size(px(11.))
                    .text_color(rgb(MUTED))
                    .py(px(4.))
                    .child(output.clone())
                    .into_any_element(),
            );
        }
        for failure in &job.failed {
            rows.push(muted(format!("安装失败 · {}", failure.label())).into_any_element());
        }
        if let Some(error) = &job.error {
            rows.push(muted(error.clone()).into_any_element());
        }
        if job.running() {
            rows.push(
                Button::new("trick-cancel")
                    .label("取消安装")
                    .on_click(cx.listener(|this, _, _, cx| this.cancel_winetricks_install(cx)))
                    .into_any_element(),
            );
        }
        rows
    }

    fn winetricks_verb_row(
        &self,
        verb: &crate::winetricks::VerbDto,
        installed: bool,
        cx: &Context<Self>,
    ) -> AnyElement {
        let selected = self.winetricks.selected.as_deref() == Some(verb.name.as_str());
        let view = cx.entity().downgrade();
        let name = verb.name.clone();
        row()
            .id(SharedString::from(format!("trick-verb:{}", verb.name)))
            .w_full()
            .p(px(9.))
            .my(px(2.))
            .gap(px(11.))
            .rounded(px(8.))
            .bg(if selected {
                rgba(0xff891b1f)
            } else {
                rgba(0xffffff04)
            })
            .border_1()
            .border_color(if selected {
                rgba(0xff891b55)
            } else {
                rgba(0xffffff08)
            })
            .cursor_pointer()
            .hover(|d| d.bg(rgba(0xffffff0e)).border_color(rgba(0xffffff18)))
            .on_click(move |_, _, cx| {
                let name = name.clone();
                let _ = view.update(cx, |this, cx| {
                    this.winetricks.selected = Some(name);
                    cx.notify();
                });
            })
            .child(
                div()
                    .w(px(16.))
                    .flex()
                    .justify_center()
                    .text_size(px(13.))
                    .text_color(rgb(if installed { 0x67d68b } else { 0x77777c }))
                    .child(if installed { "✓" } else { "○" }),
            )
            .child(
                col()
                    .flex_1()
                    .min_w_0()
                    .gap(px(2.))
                    .child(
                        div()
                            .font_weight(FontWeight::MEDIUM)
                            .text_size(px(12.5))
                            .truncate()
                            .child(verb.name.clone()),
                    )
                    .child(
                        div()
                            .text_size(px(11.))
                            .text_color(rgb(MUTED))
                            .truncate()
                            .child(verb.description.clone()),
                    ),
            )
            .when(installed, |d| {
                d.child(
                    div()
                        .px(px(7.))
                        .py(px(2.))
                        .rounded(px(4.))
                        .bg(rgba(0x67d68b1f))
                        .text_size(px(10.))
                        .text_color(rgb(0x67d68b))
                        .child("已安装"),
                )
            })
            .into_any_element()
    }

    fn demo_winetricks(&self, cx: &Context<Self>) -> AnyElement {
        self.form(
            "winetricks-scroll",
            vec![
                self.field("dependency-search", "搜索组件"),
                self.section(
                    "tricks",
                    "可用组件",
                    [
                        ("vcrun2022", "Visual C++ 2015–2022"),
                        ("d3dx9", "DirectX 9"),
                        ("lavfilters", "LAV Filters"),
                        ("cjkfonts", "中日韩字体"),
                        ("dotnet48", ".NET Framework 4.8"),
                    ]
                    .into_iter()
                    .map(|(key, label)| self.toggle(key, label, "", cx))
                    .collect(),
                    cx,
                ),
            ],
        )
    }


    fn move_entry_sheet(&self, cx: &Context<Self>) -> AnyElement {
        let Some(state) = self.move_entry.as_ref() else {
            return self.form(
                "move-entry-scroll",
                vec![self.section(
                    "move-entry",
                    "选择目标容器",
                    vec![muted("没有待移动的条目。").into_any_element()],
                    cx,
                )],
            );
        };
        let mut rows: Vec<AnyElement> = vec![self.info("条目", state.title.clone())];
        if state.pending {
            rows.push(
                row()
                    .gap(px(8.))
                    .py(px(8.))
                    .child(Spinner::new().with_size(px(14.)))
                    .child(muted("正在移动并复制设置、元数据与游玩记录…"))
                    .into_any_element(),
            );
        }
        if let Some(error) = &state.error {
            rows.push(muted(error.clone()).py(px(8.)).into_any_element());
        }
        let mut targets = 0;
        for bottle in self
            .bottles
            .iter()
            .filter(|bottle| bottle.path != state.source_container)
        {
            targets += 1;
            let path = bottle.path.clone();
            let selected = state.target_container.as_deref() == Some(path.as_str());
            let button = if selected {
                Button::new(format!("move-target:{path}"))
                    .label(if state.pending { "移动中…" } else { "移动" })
                    .primary()
            } else {
                Button::new(format!("move-target:{path}"))
                    .label("移动")
            };
            rows.push(
                row()
                    .gap(px(14.))
                    .p(px(10.))
                    .my(px(3.))
                    .rounded(px(8.))
                    .bg(rgba(0xffffff05))
                    .border_1()
                    .border_color(rgba(0xffffff08))
                    .child(
                        col()
                            .flex_1()
                            .min_w_0()
                            .gap(px(3.))
                            .child(div().font_weight(FontWeight::MEDIUM).child(bottle.name.clone()))
                            .child(muted(bottle.path.clone()).truncate()),
                    )
                    .child(button.disabled(state.pending).on_click(cx.listener(
                        move |this, _, _, cx| this.start_move_entry(path.clone(), cx),
                    )))
                    .into_any_element(),
            );
        }
        if targets == 0 {
            rows.push(muted("没有其他容器可接收该条目。").py(px(8.)).into_any_element());
        }
        self.form(
            "move-entry-scroll",
            vec![self.section("move-entry", "选择目标容器", rows, cx)],
        )
    }

    fn open_file_sheet(&self, cx: &Context<Self>) -> AnyElement {
        let Some(state) = self.open_file.as_ref() else {
            return self.form(
                "open-file-scroll",
                vec![self.section(
                    "open-file",
                    "选择容器",
                    vec![muted("没有待运行的文件。").into_any_element()],
                    cx,
                )],
            );
        };
        let mut rows: Vec<AnyElement> = vec![
            self.info("文件", state.name.clone()),
            self.info("位置", state.path.clone()),
        ];
        for (index, bottle) in self.bottles.iter().enumerate() {
            rows.push(
                row()
                    .gap(px(14.))
                    .p(px(10.))
                    .my(px(3.))
                    .rounded(px(8.))
                    .bg(rgba(0xffffff05))
                    .border_1()
                    .border_color(rgba(0xffffff08))
                    .child(
                        col()
                            .flex_1()
                            .min_w_0()
                            .gap(px(3.))
                            .child(div().font_weight(FontWeight::MEDIUM).child(bottle.name.clone()))
                            .child(muted(bottle.path.clone()).truncate()),
                    )
                    .child(
                        Button::new(format!("run-in:{}", bottle.path))
                            .label(if bottle.available { "运行" } else { "不可用" })
                            .primary()
                            .disabled(!bottle.available)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.start_open_file(index, cx);
                            })),
                    )
                    .into_any_element(),
            );
        }
        self.form(
            "open-file-scroll",
            vec![self.section("open-file", "选择容器", rows, cx)],
        )
    }

    /// Metadata search, cover choice and local GameDB recommendations for the
    /// card that opened the sheet.
    fn game_info_sheet(&mut self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let Some(page) = self.game_info.as_ref() else {
            return div().into_any_element();
        };
        let title = page.title.clone();
        let searching = page.searching;
        let applying = page.applying;
        let error = page.error.clone();
        let groups = page.groups.clone();
        let matches = page.matches.clone();
        let config_message = page.config_message.clone();
        let input = self.game_info_input(window, cx);

        let search_row = row()
            .id("metadata-search-row")
            .gap(px(8.))
            .py(px(8.))
            .child(div().flex_1().min_w_0().child(Input::new(&input)))
            .child(
                Button::new("metadata-search")
                    .label(if searching { "搜索中…" } else { "搜索" })
                    .primary()
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.command(Command::MetadataSearch, cx);
                    })),
            )
            .into_any_element();

        let mut metadata_rows = vec![
            self.info("当前标题", title.clone()),
            search_row,
            self.metadata_source_row(cx),
        ];
        if searching {
            metadata_rows.push(
                row()
                    .gap(px(8.))
                    .py(px(8.))
                    .child(Spinner::new().with_size(px(14.)))
                    .child(muted("正在向 Steam、Bangumi、VNDB 与月幕查询…"))
                    .into_any_element(),
            );
        }
        if let Some(error) = &error {
            metadata_rows.push(muted(error.clone()).into_any_element());
        }
        for (group_index, group) in groups.iter().enumerate() {
            metadata_rows.push(
                muted(source_label(&group.source))
                    .text_size(px(11.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .mt(px(6.))
                    .into_any_element(),
            );
            if let Some(provider_error) = &group.error {
                metadata_rows
                    .push(muted(format!("查询失败：{provider_error}")).text_size(px(11.)).into_any_element());
            }
            for (game_index, candidate) in group.games.iter().enumerate() {
                let mut details = candidate.developer.clone();
                if !candidate.release_date.is_empty() {
                    if !details.is_empty() {
                        details.push_str(" · ");
                    }
                    details.push_str(&candidate.release_date);
                }
                metadata_rows.push(
                    row()
                        .gap(px(12.))
                        .p(px(10.))
                        .my(px(3.))
                        .rounded(px(8.))
                        .bg(rgba(0xffffff05))
                        .border_1()
                        .border_color(rgba(0xffffff08))
                        .child(match &candidate.thumbnail {
                            // Narrow fixed-size thumbnail: the row stays
                            // compact, and a placeholder keeps the height
                            // consistent when a provider has no image.
                            Some(path) => img(path.clone())
                                .w(px(34.))
                                .h(px(48.))
                                .flex_shrink_0()
                                .rounded(px(5.))
                                .object_fit(ObjectFit::Cover)
                                .into_any_element(),
                            None => div()
                                .w(px(34.))
                                .h(px(48.))
                                .flex_shrink_0()
                                .rounded(px(5.))
                                .bg(gradient(0xffffff12, 0xffffff04))
                                .flex()
                                .items_center()
                                .justify_center()
                                .child(icon("package", 16.).text_color(rgb(MUTED)))
                                .into_any_element(),
                        })
                        .child(
                            col()
                                .flex_1()
                                .min_w_0()
                                .gap(px(3.))
                                .child(
                                    div()
                                        .font_weight(FontWeight::MEDIUM)
                                        .truncate()
                                        .child(candidate.title.clone()),
                                )
                                .when(!details.is_empty(), |d| d.child(muted(details).text_size(px(11.))))
                                .when(!candidate.summary.is_empty(), |d| {
                                    d.child(
                                        muted(candidate.summary.clone())
                                            .text_size(px(11.))
                                            .line_clamp(2),
                                    )
                                }),
                        )
                        .child(
                            Button::new(format!("metadata-apply:{group_index}:{game_index}"))
                                .label("应用")
                                .disabled(applying)
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.command(
                                        Command::MetadataApply(group_index, game_index),
                                        cx,
                                    );
                                })),
                        )
                        .into_any_element(),
                );
            }
        }
        if groups.is_empty() && !searching {
            metadata_rows.push(
                muted("输入名称开始搜索；候选资料来自各站点的公开接口。")
                    .text_size(px(11.))
                    .into_any_element(),
            );
        }
        metadata_rows.push(
            row()
                .justify_end()
                .py(px(6.))
                .child(self.action(
                    "metadata-clear",
                    "取消关联元数据",
                    Command::MetadataClear,
                    cx,
                ))
                .into_any_element(),
        );

        let cover_rows = vec![
            muted("自定义封面优先于在线元数据封面；导入后图片会复制到容器内，原文件可以移动或删除。")
                .text_size(px(11.))
                .into_any_element(),
            row()
                .gap(px(8.))
                .py(px(8.))
                .child(self.action("cover-import", "选择本地图片…", Command::MetadataCover, cx))
                .child(self.action(
                    "cover-reset",
                    "恢复默认封面",
                    Command::MetadataCoverReset,
                    cx,
                ))
                .when(applying, |d| d.child(Spinner::new().with_size(px(14.))))
                .into_any_element(),
        ];

        let mut config_rows: Vec<AnyElement> = Vec::new();
        match matches {
            None if self.game_info.as_ref().is_some_and(|page| page.config_error.is_some()) => {
                let reason = self.game_info.as_ref().and_then(|page| page.config_error.clone()).unwrap_or_default();
                config_rows.push(row().gap(px(12.)).py(px(10.))
                    .child(div().flex_1().child(muted(reason)))
                    .child(Button::new("gamedb-retry").label("重新读取")
                        .on_click(cx.listener(|this, _, _, cx| this.retry_game_db(cx))))
                    .into_any_element());
            }
            None => {
                config_rows.push(
                    row()
                        .gap(px(8.))
                        .py(px(8.))
                        .child(Spinner::new().with_size(px(14.)))
                        .child(muted("正在匹配本地 GameDB…"))
                        .into_any_element(),
                );
            }
            Some(matches) if matches.is_empty() => {
                config_rows.push(
                    muted("本地 GameDB 中没有匹配条目。仍可使用在线元数据或手动调整运行设置。")
                        .into_any_element(),
                );
            }
            Some(matches) => {
                for (index, matched) in matches.iter().enumerate() {
                    let entry_title = matched
                        .entry
                        .get("title")
                        .and_then(|value| value.as_str())
                        .unwrap_or("GameDB 条目");
                    let rating = matched
                        .entry
                        .get("rating")
                        .and_then(|value| value.as_str())
                        .unwrap_or("");
                    let mut detail = format!("{:.0}% 匹配", matched.confidence * 100.);
                    if matched.reference_platform == "macos" {
                        detail.push_str(" · macOS 参考记录");
                    }
                    if !rating.is_empty() {
                        detail.push_str(" · ");
                        detail.push_str(&compat_label(rating));
                    }
                    let mut rows = vec![
                        row()
                            .gap(px(12.))
                            .child(
                                col()
                                    .flex_1()
                                    .min_w_0()
                                    .gap(px(3.))
                                    .child(div().font_weight(FontWeight::MEDIUM).child(entry_title.to_owned()))
                                    .child(muted(detail).text_size(px(11.)))
                                    .when(!matched.explanation.is_empty(), |d| {
                                        d.child(muted(matched.explanation.clone()).text_size(px(11.)))
                                    }),
                            )
                            .child(
                                Button::new(format!("gamedb-apply:{index}"))
                                    .label(if matched.apply_available(self.service_available("gameConfig.apply")) {
                                        "应用推荐配置"
                                    } else { "配置参考" })
                                    .primary()
                                    .disabled(applying || !matched.apply_available(self.service_available("gameConfig.apply")))
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.command(Command::GameDbApply(index), cx);
                                    })),
                            )
                            .into_any_element(),
                    ];
                    if !matched.availability_reason.is_empty() {
                        rows.push(muted(matched.availability_reason.clone()).text_size(px(11.)).into_any_element());
                    }
                    for change in &matched.changes {
                        rows.push(
                            muted(format!(
                                "{}{} · {}：{} → {}",
                                if change.high_impact { "⚠ " } else { "" },
                                change.category,
                                change.setting,
                                change.current,
                                change.next
                            ))
                            .text_size(px(11.))
                            .into_any_element(),
                        );
                    }
                    config_rows.push(
                        col()
                            .gap(px(6.))
                            .p(px(10.))
                            .my(px(3.))
                            .rounded(px(8.))
                            .bg(rgba(0xffffff05))
                            .border_1()
                            .border_color(rgba(0xffffff08))
                            .children(rows)
                            .into_any_element(),
                    );
                }
            }
        }
        if let Some(message) = config_message {
            config_rows.push(muted(message).into_any_element());
        }

        self.form(
            "game-info-scroll",
            vec![
                self.section("game-metadata", "在线元数据", metadata_rows, cx),
                self.section("game-cover", "封面", cover_rows, cx),
                self.section("game-gamedb", if self.service_available("gameConfig.apply") { "GameDB 推荐配置" } else { "GameDB 配置参考" }, config_rows, cx),
            ],
        )
    }

    pub(crate) fn preview_sheet(
        &mut self,
        sheet: PreviewSheet,
        width: f32,
        height: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if !matches!(sheet, PreviewSheet::GameInfo(_)) {
            self.game_info = None;
        }
        let title = match sheet {
            PreviewSheet::RunSettings(_) => "运行设置",
            PreviewSheet::Scan => "管理扫描文件夹",
            PreviewSheet::Executable => "选择启动程序",
            PreviewSheet::Winetricks => "Winetricks",
            PreviewSheet::CreateBottle => "创建容器",
            PreviewSheet::MoveEntry(_) => "移动到容器",
            PreviewSheet::OpenFile => "运行文件",
            PreviewSheet::Diagnostics => {
                if cfg!(target_os = "linux") { "主机与容器诊断" } else { "故障排查" }
            },
            PreviewSheet::Audio => "音频故障排查",
            PreviewSheet::Dll => "DLL 覆盖",
            PreviewSheet::Graphics => "高级图形设置",
            PreviewSheet::GameInfo(_) => "游戏资料",
        };
        let content = match sheet {
            PreviewSheet::RunSettings(i) => self.run_settings(i, window, cx),
            PreviewSheet::MoveEntry(_) => self.move_entry_sheet(cx),
            PreviewSheet::OpenFile => self.open_file_sheet(cx),
            PreviewSheet::Scan => self.scan_settings(window, cx),
            PreviewSheet::Executable => self.executable_picker(cx),
            PreviewSheet::Winetricks => self.winetricks_sheet(cx),
            PreviewSheet::CreateBottle => {
                let state = self.create_bottle.as_ref();
                let running = state.is_some_and(|s| s.running());
                let finished = state.is_some_and(|s| s.finished);
                let progress = state.and_then(|s| {
                    s.status.and_then(|status| {
                        s.stage.as_ref().map(|stage| {
                            crate::create_bottle::progress_label(status, Some(stage)).to_owned()
                        })
                    })
                });
                let error = state.and_then(|s| s.error.clone());

                if running {
                    // The sheet stays open for the whole job; without an
                    // in-sheet cue the click reads as "nothing happened".
                    self.form(
                        "create-bottle-scroll",
                        vec![self.section(
                            "create-progress",
                            "创建中",
                            vec![row()
                                .gap(px(10.))
                                .items_center()
                                .py(px(10.))
                                .child(Spinner::new().with_size(px(14.)))
                                .child(
                                    progress.unwrap_or_else(|| "初始化中…".to_owned()),
                                )
                                .into_any_element()],
                            cx,
                        )],
                    )
                } else if finished {
                    let (title, content) = if error.is_some() {
                        ("创建失败", error.unwrap_or_else(|| "未知错误".to_owned()))
                    } else {
                        ("创建完成", "容器已成功创建并添加到库中".to_owned())
                    };
                    self.form(
                        "create-bottle-scroll",
                        vec![self.section(
                            "create-result",
                            title,
                            vec![self.info("详情", content)],
                            cx,
                        )],
                    )
                } else {
                    let location = self
                        .default_bottle_location
                        .as_ref()
                        .map(|path| crate::create_bottle::display_bottle_location(path))
                        .unwrap_or_else(|| "~/Library/Containers/Whisky/Bottles".to_owned());
                    self.form(
                        "create-bottle-scroll",
                        vec![self.section(
                            "create",
                            "新容器",
                            vec![
                                self.field("bottle-name", "名称"),
                                self.choice(
                                    "create-windows",
                                    "Windows 版本",
                                    crate::create_bottle::WINDOWS_LABELS,
                                    cx,
                                ),
                                self.info("位置", &location),
                                self.info("架构", "64 位"),
                            ],
                            cx,
                        )],
                    )
                }
            }
            PreviewSheet::GameInfo(_) => self.game_info_sheet(window, cx),
            PreviewSheet::Dll => self.form(
                "dll-scroll",
                vec![self.section(
                    "dll-overrides",
                    "DLL 覆盖",
                    vec![
                        self.info("d3dcompiler_47", "原生优先，内建后备"),
                        self.field("dll-name", "添加覆盖"),
                        self.choice(
                            "dll-mode",
                            "加载顺序",
                            &[
                                "原生优先，内建后备",
                                "内建优先，原生后备",
                                "仅原生",
                                "仅内建",
                                "禁用",
                            ],
                            cx,
                        ),
                    ],
                    cx,
                )],
            ),
            PreviewSheet::Graphics => self.form(
                "graphics-scroll",
                vec![self.section(
                    "advanced-graphics",
                    "图形调试",
                    #[cfg(not(target_os = "linux"))]
                    vec![
                        self.toggle("metal-hud", "Metal HUD", "", cx),
                        self.toggle("metal-trace", "Metal 跟踪", "", cx),
                        self.toggle("dxvk-async", "DXVK Async", "", cx),
                        self.choice("dxvk-hud", "DXVK HUD", &["关闭", "FPS", "完整"], cx),
                        self.toggle("dxr", "光线追踪（DXR）", "", cx),
                    ],
                    #[cfg(target_os = "linux")]
                    vec![
                        self.toggle("dxvk-async", "DXVK Async", "", cx),
                        self.choice("dxvk-hud", "DXVK HUD", &["关闭", "FPS", "完整"], cx),
                    ],
                    cx,
                )],
            ),
            PreviewSheet::Audio => {
                let mut rows = vec![
                    self.info("1. 输出设备", "系统默认输出"),
                    self.info("2. 测试方式", "Wine WinMM 440 Hz 测试音"),
                    self.action(
                        "test-audio",
                        if self.audio_pending {
                            "正在播放测试音…"
                        } else {
                            "播放测试音频"
                        },
                        Command::TestAudio,
                        cx,
                    ),
                ];
                if self.audio_pending {
                    rows.push(
                        row()
                            .gap(px(8.))
                            .py(px(8.))
                            .child(Spinner::new().with_size(px(14.)))
                            .child(muted("正在启动 Wine 音频测试…"))
                            .into_any_element(),
                    );
                }
                if let Some(error) = &self.audio_error {
                    rows.push(muted(error.clone()).into_any_element());
                }
                if let Some(result) = &self.audio_result {
                    let status = match result.status.as_str() {
                        "passed" => "通过",
                        "warning" => "警告",
                        "error" => "错误",
                        "skipped" => "跳过",
                        _ => result.status.as_str(),
                    };
                    rows.push(self.info("测试结果", status));
                    rows.push(self.info("摘要", result.summary.clone()));
                    for line in result.evidence.iter().take(12) {
                        rows.push(muted(line.clone()).text_size(px(11.)).into_any_element());
                    }
                    for finding in &result.findings {
                        rows.push(
                            self.info(
                                finding.description.clone(),
                                finding
                                    .suggested_action
                                    .clone()
                                    .unwrap_or_else(|| "检查 Wine 音频驱动设置".to_owned()),
                            ),
                        );
                    }
                    rows.push(
                        muted("若能听到测试音，说明 Wine 音频链路正常；若没有声音，请检查系统输出设备与音频驱动。")
                            .text_size(px(11.))
                            .into_any_element(),
                    );
                }
                self.form(
                    "audio-wizard-scroll",
                    vec![self.section("audio-check", "检查音频输出", rows, cx)],
                )
            }
            PreviewSheet::Diagnostics => {
                let mut rows = vec![
                    self.choice(
                        "diagnosis-symptom",
                        "遇到了什么问题？",
                        if cfg!(target_os = "linux") {
                            &["容器文件或导入异常", "文件权限或存储空间", "主机环境信息"][..]
                        } else {
                            &["游戏无法启动", "黑屏或画面异常", "没有声音", "文字乱码", "游戏运行缓慢"][..]
                        },
                        cx,
                    ),
                    self.action(
                        "checks",
                        if self.checks_pending {
                            "正在运行自动检查…"
                        } else {
                            "运行自动检查"
                        },
                        Command::RunBottleChecks,
                        cx,
                    ),
                    self.action(
                        "analyze",
                        if self.diagnostics_pending {
                            "正在收集诊断信息…"
                        } else {
                            if cfg!(target_os = "linux") { "收集主机与容器信息" } else { "分析运行日志" }
                        },
                        Command::RunDiagnostics,
                        cx,
                    ),
                ];
                if self.checks_pending {
                    rows.push(
                        row()
                            .gap(px(8.))
                            .py(px(8.))
                            .child(Spinner::new().with_size(px(14.)))
                            .child(muted("正在收集预检数据并运行检查项…"))
                            .into_any_element(),
                    );
                }
                if let Some(checks) = &self.diagnostic_checks {
                    for check in checks {
                        let (label, symbol) = match check.outcome.as_str() {
                            "pass" => ("通过", "check"),
                            "already_configured" => ("已配置", "check"),
                            "fail" => ("未通过", "info"),
                            "warning" => ("警告", "info"),
                            "error" => ("错误", "x"),
                            _ => ("未知", "info"),
                        };
                        let check_label = match check.check_id.as_str() {
                            "crash.log_classify" => "崩溃日志",
                            "launcher.type_check" => "启动器类型",
                            "process.running_check" => "运行中的 Wine 进程",
                            "audio.device_check" => "音频设备",
                            "audio.driver_check" => "音频驱动",
                            "game.config_available" => "GameDB 配置",
                            "diagnostics.can_enhance" => "诊断日志级别",
                            "host.container_metadata" => "容器元数据",
                            "host.drive_c" => "容器目录",
                            "host.container_write" => "文件权限",
                            "host.storage" => "可用空间",
                            _ => check.check_id.as_str(),
                        };
                        let mut detail = format!("{check_label}：{label} · {}", check.summary);
                        for (_, value) in check.evidence.iter().take(2) {
                            detail.push_str(" · ");
                            detail.push_str(value);
                        }
                        rows.push(
                            row()
                                .gap(px(8.))
                                .py(px(5.))
                                .child(icon(symbol, 13.).text_color(rgb(crate::theme::MUTED)))
                                .child(muted(detail).text_size(px(11.)))
                                .into_any_element(),
                        );
                    }
                }
                if self.diagnostics_pending {
                    rows.push(
                        row()
                            .gap(px(8.))
                            .py(px(8.))
                            .child(Spinner::new().with_size(px(14.)))
                            .child(muted("正在读取系统信息与最近日志…"))
                            .into_any_element(),
                    );
                }
                if let Some(error) = &self.diagnostics_error {
                    rows.push(muted(error.clone()).into_any_element());
                }
                if let Some(report) = &self.diagnostics_report {
                    rows.push(
                        div()
                            .id("diagnostics-report")
                            .max_h(px(280.))
                            .overflow_y_scroll()
                            .p(px(10.))
                            .rounded(px(8.))
                            .bg(rgba(0x00000040))
                            .border_1()
                            .border_color(rgba(0xffffff10))
                            .text_size(px(11.))
                            .line_height(relative(1.45))
                            .child(report.clone())
                            .into_any_element(),
                    );
                    rows.push(self.action(
                        "export",
                        "导出诊断报告…",
                        Command::ExportDiagnostics,
                        cx,
                    ));
                }
                if cfg!(target_os = "macos") {
                    rows.push(self.action(
                        "audio-link",
                        "音频故障排查…",
                        Command::Sheet(PreviewSheet::Audio),
                        cx,
                    ));
                }
                self.form(
                    "diagnostics-scroll",
                    vec![self.section(
                        "guided-diagnostics",
                        "引导式故障排查",
                        rows,
                        cx,
                    )],
                )
            }
        };
        let pw = (width - 64.).min(740.);
        let ph = (height - 64.).min(700.);
        div()
            .absolute()
            .inset_0()
            .occlude()
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .bg(rgba(0x00000088))
            .child(
                div()
                    .id("settings-dismiss")
                    .absolute()
                    .inset_0()
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.preview.sheet = None;
                        this.preview.sheet_history.clear();
                        this.focus_handle.focus(window, cx);
                        cx.notify();
                    })),
            )
            .child(
                col()
                    .id("preview-sheet-card")
                    .occlude()
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .absolute()
                    .left(px((width - pw) / 2.))
                    .top(px((height - ph) / 2.))
                    .w(px(pw))
                    .h(px(ph))
                    .rounded(px(14.))
                    .overflow_hidden()
                    .bg(rgb(0x29292c))
                    .border_1()
                    .border_color(rgba(0xffffff23))
                    .shadow_xl()
                    .child(
                        row()
                            .flex_shrink_0()
                            .h(px(54.))
                            .px(px(18.))
                            .gap(px(12.))
                            .border_b_1()
                            .border_color(rgba(0xffffff0c))
                            .when(!self.preview.sheet_history.is_empty(), |d| {
                                d.child(Button::new("sheet-back").label("‹").ghost().on_click(
                                    cx.listener(|this, _, _, cx| {
                                        this.preview.sheet = this.preview.sheet_history.pop();
                                        cx.notify();
                                    }),
                                ))
                            })
                            .child(
                                div()
                                    .flex_1()
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child(title),
                            )
                            .child(Button::new("sheet-close").label("×").ghost().on_click(
                                cx.listener(|this, _, window, cx| {
                                    this.preview.sheet = None;
                                    this.preview.sheet_history.clear();
                                    this.focus_handle.focus(window, cx);
                                    cx.notify();
                                }),
                            )),
                    )
                    .child(div().flex_1().min_h_0().child(content))
                    .child(
                        row()
                            .flex_shrink_0()
                            .justify_end()
                            .gap(px(8.))
                            .px(px(18.))
                            .py(px(13.))
                            .border_t_1()
                            .border_color(rgba(0xffffff0c))
                            .when(cfg!(target_os = "linux") && !self.demo
                                && matches!(sheet, PreviewSheet::CreateBottle), |d| {
                                d.child(Button::new("import-existing-bottle")
                                    .label("导入已有容器…")
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.preview.sheet = None;
                                        this.focus_handle.focus(window, cx);
                                        this.begin_import_scan(None, cx);
                                        cx.notify();
                                    })))
                            })
                            .when(matches!(sheet, PreviewSheet::RunSettings(_)), |d| {
                                let index = match sheet {
                                    PreviewSheet::RunSettings(index) => index,
                                    _ => 0,
                                };
                                d.child(self.action(
                                    "shortcut",
                                    "创建快捷方式",
                                    Command::Shortcut,
                                    cx,
                                ))
                                .child(self.action(
                                    "reveal",
                                    crate::platform::REVEAL_LABEL,
                                    Command::Reveal(index),
                                    cx,
                                ))
                            })
                            .child(
                                Button::new("sheet-done")
                                    .label(if !self.demo
                                        && matches!(sheet, PreviewSheet::RunSettings(_))
                                    {
                                        if self.program_settings.saving {
                                            "保存中…"
                                        } else {
                                            "保存"
                                        }
                                    } else if matches!(sheet, PreviewSheet::MoveEntry(_)) {
                                        if self.move_entry.as_ref().is_some_and(|state| state.pending) {
                                            "移动中…"
                                        } else {
                                            "取消"
                                        }
                                    } else if matches!(sheet, PreviewSheet::OpenFile) {
                                        "取消"
                                    } else if matches!(sheet, PreviewSheet::CreateBottle) {
                                        let state = self.create_bottle.as_ref();
                                        if state.is_some_and(|s| s.running()) {
                                            "创建中…"
                                        } else if state.is_some_and(|s| s.finished) {
                                            "关闭"
                                        } else {
                                            "创建"
                                        }
                                    } else if matches!(sheet, PreviewSheet::Winetricks) {
                                        let job = self.winetricks_job();
                                        if job.is_some_and(crate::winetricks::InstallJob::running) {
                                            "安装中…"
                                        } else if job.is_some_and(|job| job.finished) {
                                            "关闭"
                                        } else {
                                            "安装选中组件"
                                        }
                                    } else {
                                        "完成"
                                    })
                                    .primary()
                                    .disabled(
                                        (matches!(sheet, PreviewSheet::CreateBottle)
                                            && self.create_bottle.as_ref().is_some_and(|s| s.running()))
                                            || (!self.demo
                                                && matches!(sheet, PreviewSheet::RunSettings(_))
                                                && (self.program_settings.loading
                                                    || self.program_settings.saving
                                                    || self.program_settings.settings.is_none()))
                                            || (matches!(sheet, PreviewSheet::MoveEntry(_))
                                                && self.move_entry.as_ref().is_some_and(|state| state.pending))
                                            || (!self.demo
                                                && matches!(sheet, PreviewSheet::Winetricks)
                                                && self.winetricks_job().is_some_and(crate::winetricks::InstallJob::running))
                                            || (!self.demo
                                                && matches!(sheet, PreviewSheet::Winetricks)
                                                && !self.winetricks_job().is_some_and(|job| job.finished)
                                                && self.winetricks.selected.is_none()),
                                    )
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.focus_handle.focus(window, cx);
                                        if matches!(this.preview.sheet, Some(PreviewSheet::CreateBottle)) {
                                            let state = this.create_bottle.as_ref();
                                            if state.is_some_and(|s| s.running()) {
                                                // Do nothing while running
                                                return;
                                            }
                                            if state.is_some_and(|s| s.finished) {
                                                // Close on finished and clear state
                                                this.create_bottle = None;
                                                this.preview.sheet = None;
                                                this.preview.sheet_history.clear();
                                                cx.notify();
                                            } else {
                                                // Submit the form
                                                this.submit_create_bottle(cx);
                                            }
                                        } else if matches!(this.preview.sheet, Some(PreviewSheet::RunSettings(_))) {
                                            if this.demo {
                                                this.preview.sheet = None;
                                                this.preview.sheet_history.clear();
                                                cx.notify();
                                                return;
                                            }
                                            this.save_program_settings(cx);
                                        } else if matches!(this.preview.sheet, Some(PreviewSheet::Winetricks)) {
                                            if this.demo {
                                                this.preview.sheet = None;
                                                this.preview.sheet_history.clear();
                                                cx.notify();
                                                return;
                                            }
                                            if this.winetricks_job().is_some_and(crate::winetricks::InstallJob::running) {
                                                return;
                                            }
                                            if this.winetricks_job().is_some_and(|job| job.finished) {
                                                this.winetricks.job = None;
                                                this.preview.sheet = None;
                                                this.preview.sheet_history.clear();
                                                cx.notify();
                                            } else {
                                                this.start_winetricks_install(cx);
                                            }
                                        } else {
                                            this.preview.sheet = None;
                                            this.preview.sheet_history.clear();
                                            cx.notify();
                                        }
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }
    /// Clipboard preflight. The helper refuses to launch until it is told
    /// whether to keep or clear the clipboard, so this sheet sits between the
    /// first and second `runtime.launch` call.
    ///
    /// `LaunchInteractionBroker.resolve` accepts exactly `clear` and `keep`;
    /// both continue the launch. Dismissing sends nothing, so nothing starts.
    pub(crate) fn clipboard_dialog(
        &self,
        width: f32,
        height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(prompt) = &self.clipboard_prompt else {
            return div().into_any_element();
        };
        let content = if prompt.content_type.is_empty() {
            "未知内容".to_owned()
        } else {
            prompt.content_type.clone()
        };
        let detail = format!(
            "启动前检测到剪贴板中有 {content}（{}）。Wine 可能读取剪贴板，请选择如何处理。",
            clipboard_size(prompt.size_bytes)
        );
        let pw = 460_f32.min(width - 48.);
        let ph = 290_f32.min(height - 48.);
        div()
            .absolute()
            .inset_0()
            .occlude()
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .bg(rgba(OVERLAY))
            .child(
                div()
                    .id("clipboard-dismiss")
                    .absolute()
                    .inset_0()
                    .on_click(cx.listener(|this, _, _, cx| this.dismiss_clipboard(cx))),
            )
            .child(
                col()
                    .id("clipboard-dialog-card")
                    .occlude()
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .absolute()
                    .left(px((width - pw) / 2.))
                    .top(px((height - ph) / 2.))
                    .w(px(pw))
                    .h(px(ph))
                    .rounded(px(RADIUS_LG))
                    .overflow_hidden()
                    .bg(rgb(SURFACE))
                    .border_1()
                    .border_color(rgba(SURFACE_BORDER))
                    .shadow_xl()
                    .child(
                        row()
                            .flex_shrink_0()
                            .h(px(46.))
                            .px(px(16.))
                            .gap(px(12.))
                            .border_b_1()
                            .border_color(rgba(SURFACE_BORDER))
                            .child(
                                div()
                                    .flex_1()
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child("剪贴板内容"),
                            )
                            .child(
                                Button::new("clipboard-close")
                                    .label("×")
                                    .ghost()
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.dismiss_clipboard(cx);
                                    })),
                            ),
                    )
                    .child(
                        col()
                            .flex_1()
                            .min_h_0()
                            .px(px(18.))
                            .py(px(14.))
                            .gap(px(10.))
                            .child(muted(detail).line_height(relative(1.5)).line_clamp(3))
                            .when_some(prompt.preview.clone(), |d, preview| {
                                d.child(
                                    div()
                                        .flex_shrink_0()
                                        .p(px(10.))
                                        .rounded(px(8.))
                                        .bg(rgba(0xffffff0a))
                                        .font_family("monospace")
                                        .text_size(px(11.))
                                        .text_color(rgb(MUTED))
                                        .line_clamp(4)
                                        .child(preview),
                                )
                            }),
                    )
                    .child(
                        row()
                            .flex_shrink_0()
                            .justify_end()
                            .gap(px(8.))
                            .px(px(16.))
                            .py(px(12.))
                            .border_t_1()
                            .border_color(rgba(SURFACE_BORDER))
                            .child(Button::new("clipboard-cancel").label("取消").ghost().on_click(
                                cx.listener(|this, _, _, cx| this.dismiss_clipboard(cx)),
                            ))
                            .child(
                                Button::new("clipboard-keep")
                                    .label("保留并启动")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.resolve_clipboard(ClipboardDecision::Keep, cx);
                                    })),
                            )
                            .child(
                                Button::new("clipboard-clear")
                                    .label("清空并启动")
                                    .primary()
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.resolve_clipboard(ClipboardDecision::Clear, cx);
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }

    /// Submit the create-bottle form.
    fn submit_create_bottle(&mut self, cx: &mut Context<Self>) {
        use crate::create_bottle::windows_version_wire;

        let name = self
            .preview
            .inputs
            .get("bottle-name")
            .map(|input| input.read(cx).value().to_string())
            .unwrap_or_default();
        let name = name.trim();
        if name.is_empty() {
            self.show_notice("容器名称不能为空", cx);
            return;
        }

        let windows_label = self
            .preview
            .choices
            .get("create-windows")
            .cloned()
            .unwrap_or_else(|| "Windows 11".into());
        let windows_version = windows_version_wire(&windows_label);

        let parent = self
            .default_bottle_location
            .clone()
            .unwrap_or_else(|| {
                #[cfg(target_os = "macos")]
                {
                    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_owned());
                    format!("{}/Library/Containers/com.franke.Whisky/Bottles", home)
                }
                #[cfg(not(target_os = "macos"))]
                {
                    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_owned());
                    format!("{}/.local/share/whisky/Bottles", home)
                }
            });

        self.bridge.create_bottle(name, &parent, windows_version);
        // Keep the sheet open: the Started event switches it to the
        // running view, which is the only in-progress cue the user gets
        // while the prefix bootstrap runs.
        cx.notify();
    }

    /// Sidebar rename/duplicate/remove modal. Rename and duplicate share one
    /// text field; remove offers the two outcomes the SwiftUI alert exposes:
    /// deregister only, or delete the prefix as well.
    pub(crate) fn bottle_dialog_view(
        &mut self,
        width: f32,
        height: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(dialog) = self.bottle_dialog.as_ref() else {
            return div().into_any_element();
        };
        let kind = dialog.kind;
        let name = dialog.name.clone();
        let container = dialog.container.clone();
        let title = match kind {
            BottleDialogKind::Rename => "重命名容器",
            BottleDialogKind::Duplicate => "复制容器",
            BottleDialogKind::Remove => "删除容器",
        };
        let body: AnyElement = match kind {
            BottleDialogKind::Rename | BottleDialogKind::Duplicate => {
                let input = self.bottle_dialog_input(window, cx);
                col()
                    .gap(px(12.))
                    .child(muted(if kind == BottleDialogKind::Rename {
                        format!("为「{name}」输入新的名称。")
                    } else {
                        format!("将「{name}」克隆到同一位置，并复制全部设置与已安装程序。")
                    }))
                    .child(Input::new(&input))
                    .into_any_element()
            }
            BottleDialogKind::Remove => col()
                .gap(px(10.))
                .child(
                    div()
                        .font_weight(FontWeight::MEDIUM)
                        .child(format!("确定要移除「{name}」吗？")),
                )
                .child(muted("仅移除会保留磁盘上的容器文件；彻底删除会同时删除整个 Wine 前缀，且无法撤销。"))
                .child(muted(container).text_size(px(11.)))
                .into_any_element(),
        };
        let footer = if kind == BottleDialogKind::Remove {
            row()
                .flex_shrink_0()
                .justify_end()
                .gap(px(8.))
                .px(px(18.))
                .py(px(13.))
                .border_t_1()
                .border_color(rgba(SURFACE_BORDER))
                .child(
                    Button::new("bottle-remove-cancel")
                        .label("取消")
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.command(Command::BottleDialogCancel, cx);
                            this.focus_handle.focus(window, cx);
                        })),
                )
                .child(
                    Button::new("bottle-remove-keep")
                        .label("仅移除")
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.remove_bottle(false, cx);
                            this.focus_handle.focus(window, cx);
                        })),
                )
                .child(
                    Button::new("bottle-remove-delete")
                        .label("彻底删除")
                        .danger()
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.remove_bottle(true, cx);
                            this.focus_handle.focus(window, cx);
                        })),
                )
        } else {
            let confirm = if kind == BottleDialogKind::Rename {
                "重命名"
            } else {
                "复制"
            };
            row()
                .flex_shrink_0()
                .justify_end()
                .gap(px(8.))
                .px(px(18.))
                .py(px(13.))
                .border_t_1()
                .border_color(rgba(SURFACE_BORDER))
                .child(
                    Button::new("bottle-dialog-cancel")
                        .label("取消")
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.command(Command::BottleDialogCancel, cx);
                            this.focus_handle.focus(window, cx);
                        })),
                )
                .child(
                    Button::new("bottle-dialog-confirm")
                        .label(confirm)
                        .primary()
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.command(Command::BottleDialogConfirm, cx);
                            if this.bottle_dialog.is_none() {
                                this.focus_handle.focus(window, cx);
                            }
                        })),
                )
        };
        let pw = 460_f32.min(width - 48.);
        let ph = 260_f32.min(height - 48.);
        div()
            .absolute()
            .inset_0()
            .occlude()
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .bg(rgba(OVERLAY))
            .child(
                div()
                    .id("bottle-dialog-dismiss")
                    .absolute()
                    .inset_0()
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.dismiss_bottle_dialog(cx);
                        this.focus_handle.focus(window, cx);
                    })),
            )
            .child(
                col()
                    .id("clipboard-dialog-card")
                    .occlude()
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .absolute()
                    .left(px((width - pw) / 2.))
                    .top(px((height - ph) / 2.))
                    .w(px(pw))
                    .h(px(ph))
                    .rounded(px(RADIUS_LG))
                    .overflow_hidden()
                    .bg(rgb(SURFACE))
                    .border_1()
                    .border_color(rgba(SURFACE_BORDER))
                    .shadow_xl()
                    .child(
                        row()
                            .flex_shrink_0()
                            .h(px(46.))
                            .px(px(16.))
                            .border_b_1()
                            .border_color(rgba(SURFACE_BORDER))
                            .child(
                                div()
                                    .flex_1()
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child(title),
                            ),
                    )
                    .child(
                        col()
                            .flex_1()
                            .min_h_0()
                            .px(px(20.))
                            .py(px(18.))
                            .children([body]),
                    )
                    .child(footer),
            )
            .into_any_element()
    }

    /// First-run WhiskyWine runtime setup. The helper owns the download and
    /// install job; this surface only reports the stage.
    pub(crate) fn setup_dialog_view(
        &self,
        width: f32,
        height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let installed = self
            .setup_status
            .as_ref()
            .is_some_and(|status| status.installed);
        let version = self
            .setup_status
            .as_ref()
            .and_then(|status| status.version.clone());
        let stage = self.setup_stage.as_deref().map(|stage| match stage {
            "checking" => "正在检查最新运行时版本…",
            "downloading" => "正在下载 Wine 运行时…",
            "verifying" => "正在校验下载完整性…",
            "installing" => "正在解压并安装运行时…",
            "rosetta" => "正在安装 Rosetta 2…",
            _ => "正在准备…",
        });
        let mut rows: Vec<AnyElement> = vec![
            muted("Whisky 需要一个 Wine 运行时才能运行 Windows 程序。安装包来自项目的公开发布渠道，并会校验 SHA-256。")
                .line_height(relative(1.5))
                .into_any_element(),
        ];
        let apple_silicon = self
            .setup_status
            .as_ref()
            .is_some_and(|status| status.apple_silicon);
        let rosetta_installed = self
            .setup_status
            .as_ref()
            .is_some_and(|status| status.rosetta_installed);
        if apple_silicon {
            if rosetta_installed {
                rows.push(
                    row()
                        .gap(px(8.))
                        .child(icon("check", 14.).text_color(rgb(crate::theme::SUCCESS)))
                        .child(muted("Rosetta 2 已安装").text_size(px(11.)))
                        .into_any_element(),
                );
            } else {
                rows.push(
                    row()
                        .gap(px(8.))
                        .child(muted("未检测到 Rosetta 2；运行 x86_64 游戏前需要安装。").text_size(px(11.)))
                        .child(
                            Button::new("setup-rosetta")
                                .label("安装 Rosetta 2")
                                .disabled(self.setup_installing)
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.command(Command::InstallRosetta, cx);
                                })),
                        )
                        .into_any_element(),
                );
            }
        }
        if self.setup_installing {
            let progress_text = self.setup_progress.map(|(received, total)| {
                let mib = |bytes: u64| bytes as f64 / 1_048_576.0;
                if total > 0 {
                    format!(
                        "{:.0}%  ·  {:.1} / {:.1} MB",
                        (received as f64 / total as f64 * 100.0).min(100.0),
                        mib(received),
                        mib(total)
                    )
                } else {
                    format!("{:.1} MB", mib(received))
                }
            });
            rows.push(
                row()
                    .gap(px(10.))
                    .py(px(10.))
                    .child(Spinner::new().with_size(px(16.)))
                    .child(stage.unwrap_or("正在安装…").to_owned())
                    .into_any_element(),
            );
            if let Some((received, total)) = self.setup_progress.filter(|(_, total)| *total > 0) {
                let fraction = (received as f32 / total as f32).clamp(0., 1.);
                rows.push(
                    div()
                        .h(px(6.))
                        .w_full()
                        .rounded(px(3.))
                        .bg(rgba(0xffffff14))
                        .child(
                            div()
                                .h_full()
                                .w(relative(fraction))
                                .rounded(px(3.))
                                .bg(rgb(crate::theme::SUCCESS)),
                        )
                        .into_any_element(),
                );
            }
            if let Some(text) = progress_text {
                rows.push(muted(text).text_size(px(11.)).into_any_element());
            }
        } else if let Some(error) = &self.setup_error {
            rows.push(muted(error.clone()).into_any_element());
        } else if installed || version.is_some() {
            rows.push(
                row()
                    .gap(px(10.))
                    .py(px(10.))
                    .child(icon("check", 16.).text_color(rgb(crate::theme::SUCCESS)))
                    .child(version.clone().map_or_else(
                        || "Wine 运行时已安装".to_owned(),
                        |version| format!("Wine 运行时 {version} 已就绪"),
                    ))
                    .into_any_element(),
            );
        }
        let footer = row()
            .flex_shrink_0()
            .justify_end()
            .gap(px(8.))
            .px(px(18.))
            .py(px(13.))
            .border_t_1()
            .border_color(rgba(SURFACE_BORDER))
            .when(
                !self.setup_installing && (installed || version.is_some()),
                |d| {
                    d.child(
                        Button::new("setup-done")
                            .label("完成")
                            .primary()
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.command(Command::DismissSetup, cx);
                            })),
                    )
                },
            )
            .when(!self.setup_installing && !installed, |d| {
                d.child(
                    Button::new("setup-later")
                        .label("稍后")
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.command(Command::DismissSetup, cx);
                        })),
                )
                .child(
                    Button::new("setup-install")
                        .label(if self.setup_error.is_some() {
                            "重试安装"
                        } else {
                            "下载并安装"
                        })
                        .primary()
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.command(Command::InstallWineRuntime, cx);
                        })),
                )
            });
        let pw = 480_f32.min(width - 48.);
        let ph = 320_f32.min(height - 48.);
        div()
            .absolute()
            .inset_0()
            .occlude()
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .bg(rgba(OVERLAY))
            .child(
                col()
                    .id("clipboard-dialog-card")
                    .occlude()
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .absolute()
                    .left(px((width - pw) / 2.))
                    .top(px((height - ph) / 2.))
                    .w(px(pw))
                    .h(px(ph))
                    .rounded(px(RADIUS_LG))
                    .overflow_hidden()
                    .bg(rgb(SURFACE))
                    .border_1()
                    .border_color(rgba(SURFACE_BORDER))
                    .shadow_xl()
                    .child(
                        row()
                            .flex_shrink_0()
                            .h(px(46.))
                            .px(px(16.))
                            .border_b_1()
                            .border_color(rgba(SURFACE_BORDER))
                            .child(
                                div()
                                    .flex_1()
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child("安装 Wine 运行时"),
                            ),
                    )
                    .child(
                        col()
                            .flex_1()
                            .min_h_0()
                            .px(px(20.))
                            .py(px(18.))
                            .gap(px(10.))
                            .children(rows),
                    )
                    .child(footer),
            )
            .into_any_element()
    }

    pub(crate) fn about_dialog(
        &self,
        width: f32,
        height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let name = self
            .app_info
            .as_ref()
            .map(|info| info.app_name.clone())
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| "Whisky".into());
        let version = self
            .app_info
            .as_ref()
            .map_or_else(|| "预览版".to_owned(), |info| info.version_label());
        let os_version = self
            .app_info
            .as_ref()
            .map(|info| info.os_version.clone())
            .filter(|version| !version.is_empty())
            .unwrap_or_else(|| "macOS".into());
        let bundle = self
            .app_info
            .as_ref()
            .map(|info| info.bundle_identifier.clone())
            .unwrap_or_default();
        let bridge = match &self.bridge_status {
            BridgeStatus::Connected { version, .. } => version.clone(),
            BridgeStatus::Failed { .. } => "不可用".into(),
            BridgeStatus::Stopped => "已停止".into(),
            BridgeStatus::Locating | BridgeStatus::Starting => "连接中".into(),
        };
        let pw = 420_f32.min(width - 48.);
        let ph = 360_f32.min(height - 48.);
        let mut facts = vec![
            row()
                .gap(px(18.))
                .child(div().w(px(78.)).child(muted("版本")))
                .child(div().flex_1().child(version))
                .into_any_element(),
            row()
                .gap(px(18.))
                .child(div().w(px(78.)).child(muted("系统")))
                .child(div().flex_1().child(os_version))
                .into_any_element(),
            row()
                .gap(px(18.))
                .child(div().w(px(78.)).child(muted("桥接")))
                .child(div().flex_1().child(bridge))
                .into_any_element(),
        ];
        if !bundle.is_empty() {
            facts.push(
                row()
                    .gap(px(18.))
                    .child(div().w(px(78.)).child(muted("标识符")))
                    .child(div().flex_1().min_w_0().child(bundle))
                    .into_any_element(),
            );
        }
        div()
            .absolute()
            .inset_0()
            .occlude()
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .bg(rgba(OVERLAY))
            .child(
                div()
                    .id("about-dismiss")
                    .absolute()
                    .inset_0()
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.about = false;
                        cx.notify();
                    })),
            )
            .child(
                col()
                    .id("clipboard-dialog-card")
                    .occlude()
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .absolute()
                    .left(px((width - pw) / 2.))
                    .top(px((height - ph) / 2.))
                    .w(px(pw))
                    .h(px(ph))
                    .rounded(px(RADIUS_LG))
                    .overflow_hidden()
                    .bg(rgb(SURFACE))
                    .border_1()
                    .border_color(rgba(SURFACE_BORDER))
                    .shadow_xl()
                    .child(
                        row()
                            .flex_shrink_0()
                            .h(px(46.))
                            .px(px(16.))
                            .gap(px(12.))
                            .border_b_1()
                            .border_color(rgba(SURFACE_BORDER))
                            .child(
                                div()
                                    .flex_1()
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child("关于 Whisky"),
                            )
                            .child(
                                Button::new("about-close")
                                    .label("×")
                                    .ghost()
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.about = false;
                                        cx.notify();
                                    })),
                            ),
                    )
                    .child(
                        col()
                            .flex_1()
                            .min_h_0()
                            .px(px(20.))
                            .py(px(18.))
                            .gap(px(12.))
                            .child(div().text_size(px(22.)).font_weight(FontWeight::SEMIBOLD).child(name))
                            .child(muted("在 macOS 上运行 Windows 游戏。"))
                            .children(facts),
                    )
                    .child(
                        row()
                            .flex_shrink_0()
                            .justify_between()
                            .items_center()
                            .gap(px(12.))
                            .px(px(18.))
                            .py(px(13.))
                            .border_t_1()
                            .border_color(rgba(SURFACE_BORDER))
                            .child(muted("GNU GPL v3 · 自由软件").text_size(px(11.)))
                            .child(
                                Button::new("about-done")
                                    .label("关闭")
                                    .primary()
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.about = false;
                                        cx.notify();
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }

    pub(crate) fn bridge_status_dialog(
        &self,
        width: f32,
        height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let (title, detail) = match &self.bridge_status {
            BridgeStatus::Failed { reason, retryable } => (
                "Bridge unavailable",
                if *retryable {
                    reason.clone()
                } else {
                    format!("{reason}\n\nRetrying may not help until the helper is rebuilt.")
                },
            ),
            BridgeStatus::Connected {
                helper,
                version,
                methods,
            } => (
                "Bridge connected",
                format!("{helper}\n{version} · {methods} methods"),
            ),
            BridgeStatus::Stopped => ("Bridge stopped", "The helper is no longer running.".into()),
            BridgeStatus::Locating | BridgeStatus::Starting => (
                "Connecting",
                "The bridge helper is starting.".into(),
            ),
        };
        let (title, detail) = self.quit_error.as_ref()
            .map(|error| ("退出清理未完成", error.clone())).unwrap_or((title, detail));
        let retry = matches!(self.bridge_status, BridgeStatus::Failed { .. });
        let pw = 440_f32.min(width - 48.);
        let ph = 210_f32.min(height - 48.);
        div()
            .absolute()
            .inset_0()
            .occlude()
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .bg(rgba(OVERLAY))
            .child(
                div()
                    .id("bridge-dialog-dismiss")
                    .absolute()
                    .inset_0()
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.bridge_dialog = false;
                        cx.notify();
                    })),
            )
            .child(
                col()
                    .id("clipboard-dialog-card")
                    .occlude()
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .absolute()
                    .left(px((width - pw) / 2.))
                    .top(px((height - ph) / 2.))
                    .w(px(pw))
                    .h(px(ph))
                    .rounded(px(RADIUS_LG))
                    .overflow_hidden()
                    .bg(rgb(SURFACE))
                    .border_1()
                    .border_color(rgba(SURFACE_BORDER))
                    .shadow_xl()
                    .child(
                        row()
                            .flex_shrink_0()
                            .h(px(46.))
                            .px(px(16.))
                            .gap(px(12.))
                            .border_b_1()
                            .border_color(rgba(SURFACE_BORDER))
                            .child(div().flex_1().font_weight(FontWeight::SEMIBOLD).child(title))
                            .child(
                                Button::new("bridge-dialog-close")
                                    .label("×")
                                    .ghost()
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.bridge_dialog = false;
                                        cx.notify();
                                    })),
                            ),
                    )
                    .child(
                        col()
                            .flex_1()
                            .min_h_0()
                            .px(px(18.))
                            .py(px(14.))
                            .gap(px(10.))
                            .child(
                                muted(detail)
                                    .line_height(relative(1.5))
                                    .line_clamp(4),
                            ),
                    )
                    .child(
                        row()
                            .flex_shrink_0()
                            .justify_end()
                            .gap(px(8.))
                            .px(px(16.))
                            .py(px(12.))
                            .border_t_1()
                            .border_color(rgba(SURFACE_BORDER))
                            .child(
                                Button::new("bridge-dialog-done")
                                    .label("关闭")
                                    .ghost()
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.bridge_dialog = false;
                                        cx.notify();
                                    })),
                            )
                            .when(retry, |d| {
                                d.child(
                                    Button::new("bridge-retry")
                                        .label("Retry")
                                        .primary()
                                        .on_click(cx.listener(|this, _, _, cx| {
                                            this.bridge_retry(cx);
                                        })),
                                )
                            })
                            .when(self.quit_error.is_some(), |row| {
                                row.child(Button::new("quit-without-cleanup")
                                    .label("直接退出应用")
                                    .on_click(|_, _, cx| cx.quit()))
                            }),
                    ),
            )
            .into_any_element()
    }
}

impl WhiskyApp {
    /// Scraper source switches shared by the manual search and the bulk sync.
    fn metadata_source_row(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut line = row().gap(px(14.)).py(px(6.)).items_center().child(
            muted("刮削源").text_size(px(11.)),
        );
        for (key, _, label) in crate::state::METADATA_SOURCES {
            let checked = self.flag(key);
            line = line.child(
                row()
                    .gap(px(6.))
                    .items_center()
                    .child(Switch::new(key).checked(checked).on_change(cx.listener(
                        move |this, _, _, cx| this.command(Command::Toggle(key), cx),
                    )))
                    .child(muted(label).text_size(px(11.))),
            );
        }
        line.into_any_element()
    }
}

fn source_label(source: &str) -> &str {
    match source {
        "bangumi" => "Bangumi",
        "vndb" => "VNDB",
        "steam" => "Steam",
        "ymgal" => "月幕",
        "hikarinagi" => "Hikarinagi",
        _ => source,
    }
}

fn compat_label(rating: &str) -> &str {
    match rating {
        "unverified" => "待验证",
        "verified" => "已验证",
        "playable" => "可玩",
        "runs" => "可运行",
        "unplayable" => "不可玩",
        _ => rating,
    }
}

/// Bytes as the sheet shows them. The helper reports the raw byte count.
fn clipboard_size(bytes: i64) -> String {
    if bytes <= 0 {
        return "大小未知".to_owned();
    }
    if bytes < 1024 {
        return format!("{bytes} 字节");
    }
    format!("{:.1} KB", bytes as f64 / 1024.)
}
