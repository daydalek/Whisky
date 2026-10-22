//! Modal sheets: run settings, scan folders, winetricks, create bottle, and diagnostics.

use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Disableable, Sizable};
use gpui_kit::component::switch::Switch;
use gpui_kit::{prelude::*, *};

use super::Command;
use crate::bridge::dto::FoldersDto;
use crate::bridge::{BridgeStatus, FolderEdit};
use crate::controls::*;
use crate::runtime::ClipboardDecision;
use crate::program_settings::{self, ProgramSettingsDto, RunEntryDto};
use crate::scan::{self, JobStatus};
use crate::state::{PreviewSheet, ScanState, WhiskyApp};
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
    ("d3dMetal", "D3DMetal"),
    ("dxvk", "DXVK"),
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
    ("msync", "MSync"),
];
const RESOLUTIONS: &[(&str, &str)] = &[
    ("r1280x720", "1280 × 720"),
    ("r1600x900", "1600 × 900"),
    ("r1920x1080", "1920 × 1080"),
    ("r2560x1440", "2560 × 1440"),
    ("r3840x2160", "3840 × 2160"),
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
                            &["继承容器", "D3DMetal", "DXVK", "WineD3D"],
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
        let mut children: Vec<AnyElement> = Vec::new();
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
        let input = self.program_input("ps-shortcut-dest", &destination, "~/Applications", window, cx);
        let mut children: Vec<AnyElement> = vec![
            col()
                .gap(px(7.))
                .py(px(8.))
                .child("快捷方式位置")
                .child(Input::new(&input))
                .into_any_element(),
            muted("在目标目录创建可双击启动该程序的 .app。")
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
                rows.push(self.info(
                    "自动读取元数据",
                    if folders.automatic_metadata {
                        "已启用"
                    } else {
                        "已关闭"
                    },
                ));
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
                            div()
                                .flex_1()
                                .child(Input::new(&self.preview.inputs["scan-path"])),
                        )
                        .child(
                            Button::new("scan-add")
                                .label("添加文件夹")
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


    pub(crate) fn preview_sheet(
        &mut self,
        sheet: PreviewSheet,
        width: f32,
        height: f32,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let title = match sheet {
            PreviewSheet::RunSettings(_) => "运行设置",
            PreviewSheet::Scan => "管理扫描文件夹",
            PreviewSheet::Executable => "选择启动程序",
            PreviewSheet::Winetricks => "Winetricks",
            PreviewSheet::CreateBottle => "创建容器",
            PreviewSheet::Diagnostics => "故障排查",
            PreviewSheet::Audio => "音频故障排查",
            PreviewSheet::Dll => "DLL 覆盖",
            PreviewSheet::Graphics => "高级图形设置",
        };
        let content = match sheet {
            PreviewSheet::RunSettings(i) => self.run_settings(i, window, cx),
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
                    self.form(
                        "create-bottle-scroll",
                        vec![self.section(
                            "create-progress",
                            "创建中",
                            vec![self.info("状态", progress.unwrap_or_else(|| "初始化中…".to_owned()))],
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
                                    &["Windows 11", "Windows 10", "Windows 7"],
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
                    vec![
                        self.toggle("metal-hud", "Metal HUD", "", cx),
                        self.toggle("metal-trace", "Metal 跟踪", "", cx),
                        self.toggle("dxvk-async", "DXVK Async", "", cx),
                        self.choice("dxvk-hud", "DXVK HUD", &["关闭", "FPS", "完整"], cx),
                        self.toggle("dxr", "光线追踪（DXR）", "", cx),
                    ],
                    cx,
                )],
            ),
            PreviewSheet::Audio => self.form(
                "audio-wizard-scroll",
                vec![self.section(
                    "audio-check",
                    "检查音频输出",
                    vec![
                        self.info("1. 输出设备", "系统默认输出"),
                        self.info("2. 采样率", "48,000 Hz"),
                        self.info("3. 游戏音频组件", "等待测试"),
                        self.action("test-audio", "播放测试音频", Command::Notice, cx),
                    ],
                    cx,
                )],
            ),
            PreviewSheet::Diagnostics => self.form(
                "diagnostics-scroll",
                vec![self.section(
                    "guided-diagnostics",
                    "引导式故障排查",
                    vec![
                        self.choice(
                            "diagnosis-symptom",
                            "遇到了什么问题？",
                            &[
                                "游戏无法启动",
                                "黑屏或画面异常",
                                "没有声音",
                                "文字乱码",
                                "游戏运行缓慢",
                            ],
                            cx,
                        ),
                        self.info("最近一次运行", "正常退出"),
                        self.action("analyze", "分析运行日志", Command::Notice, cx),
                        self.action(
                            "audio-link",
                            "音频故障排查…",
                            Command::Sheet(PreviewSheet::Audio),
                            cx,
                        ),
                    ],
                    cx,
                )],
            ),
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
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.preview.sheet = None;
                        this.preview.sheet_history.clear();
                        cx.notify();
                    })),
            )
            .child(
                col()
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
                                cx.listener(|this, _, _, cx| {
                                    this.preview.sheet = None;
                                    this.preview.sheet_history.clear();
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
                                    "在访达中显示",
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
                                            || (!self.demo
                                                && matches!(sheet, PreviewSheet::Winetricks)
                                                && self.winetricks_job().is_some_and(crate::winetricks::InstallJob::running))
                                            || (!self.demo
                                                && matches!(sheet, PreviewSheet::Winetricks)
                                                && !self.winetricks_job().is_some_and(|job| job.finished)
                                                && self.winetricks.selected.is_none()),
                                    )
                                    .on_click(cx.listener(|this, _, _, cx| {
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
        self.preview.sheet = None;
        self.preview.sheet_history.clear();
        cx.notify();
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
                            }),
                    ),
            )
            .into_any_element()
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
