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
use crate::theme::MUTED;

impl WhiskyApp {
    pub(crate) fn bottle_bar(&self, cx: &Context<Self>) -> AnyElement {
        row()
            .flex_shrink_0()
            .justify_end()
            .flex_wrap()
            .gap(px(9.))
            .p(px(14.))
            .border_t_1()
            .border_color(rgba(0xffffff0d))
            .child(self.action("bottle-c-drive", "打开 C: 盘", Command::OpenDrive, cx))
            .child(self.action(
                "bottle-tricks",
                "Winetricks…",
                Command::Sheet(PreviewSheet::Winetricks),
                cx,
            ))
            .child(self.action("bottle-run", "运行…", Command::Notice, cx))
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
            PreviewPage::Library => unreachable!(),
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
                    .border_color(rgba(0xffffff0d))
                    .child(self.action("control", "控制面板", Command::Notice, cx))
                    .child(self.action("regedit", "注册表编辑器", Command::Notice, cx))
                    .child(self.action("winecfg", "Wine 配置", Command::Notice, cx))
                    .into_any_element()
            } else {
                self.bottle_bar(cx)
            })
            .into_any_element()
    }
    fn bottle_home(&self, cx: &Context<Self>) -> AnyElement {
        let slot = self.bottle_slot();
        let pins: Vec<_> = self
            .games()
            .iter()
            .enumerate()
            .filter(|(_, game)| game.bottle == slot)
            .take(5)
            .map(|(i, game)| {
                col()
                    .w(px(110.))
                    .gap(px(9.))
                    .items_center()
                    .child(
                        div()
                            .id(("pin", i))
                            .cursor_pointer()
                            .on_click(cx.listener(move |this, _, _, cx| this.open_detail(i, cx)))
                            .child(match self.artwork(i) {
                                Some(path) => img(path)
                                    .w(px(76.))
                                    .h(px(90.))
                                    .rounded(px(9.))
                                    .object_fit(ObjectFit::Cover)
                                    .into_any_element(),
                                None => div()
                                    .w(px(76.))
                                    .h(px(90.))
                                    .rounded(px(9.))
                                    .bg(gradient(0xffffff12, 0xffffff04))
                                    .flex()
                                    .items_center()
                                    .justify_center()
                                    .child(icon("package", 22.).text_color(rgb(MUTED)))
                                    .into_any_element(),
                            })
                            .context_menu(self.game_menu(i, cx)),
                    )
                    .child(
                        div()
                            .w_full()
                            .text_size(px(11.))
                            .text_center()
                            .line_clamp(2)
                            .child(game.title.clone()),
                    )
                    .into_any_element()
            })
            .collect();
        let pins_empty = pins.is_empty();
        let mut links = col().rounded(px(10.)).bg(rgba(0xffffff08));
        for (i, (label, page)) in [
            ("已安装的程序", PreviewPage::Programs),
            ("Configure Bottle", PreviewPage::ConfigureBottle),
            ("运行中的进程", PreviewPage::Processes),
            ("游戏配置", PreviewPage::GameConfigs),
        ]
        .into_iter()
        .enumerate()
        {
            links = links.child(
                row()
                    .id(("bottle-link", i))
                    .px(px(18.))
                    .h(px(51.))
                    .gap(px(12.))
                    .cursor_pointer()
                    .hover(|d| d.bg(rgba(0xffffff0b)))
                    .on_click(cx.listener(move |this, _, _, cx| this.navigate(page, cx)))
                    .child(div().flex_1().child(label))
                    .child(muted("›")),
            );
        }
        self.preview_scroll(
            "bottle-home-scroll",
            col()
                .p(px(26.))
                .gap(px(30.))
                .child(row().items_start().flex_wrap().gap(px(16.)).children(pins))
                .when(pins_empty, |d| {
                    d.child(muted("No games in this bottle").p(px(4.)))
                })
                .child(links)
                .child(muted("自动选择图形后端 · Windows 11 · WhiskyWine")),
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
                rows.push(self.config_row(field, &value, enabled, window, cx));
            }
            sections.push(self.section(group.spec.id, group.spec.title, rows, cx));
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
        field: &ConfigField,
        value: &serde_json::Value,
        enabled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        match &field.kind {
            config::FieldKind::Toggle => {
                let id = field.id.clone();
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
                            .when(!enabled, |d| {
                                d.child(muted("需要 Wine 主机适配器").line_height(relative(1.4)))
                            }),
                    )
                    .child(
                        Switch::new(format!("config-toggle:{}", field.id))
                            .checked(value.as_bool().unwrap_or(false))
                            .disabled(!enabled)
                            .on_change(cx.listener(move |this, checked, _, cx| {
                                this.set_config_value(
                                    &id,
                                    serde_json::Value::Bool(*checked),
                                    cx,
                                );
                            })),
                    )
                    .into_any_element()
            }
            config::FieldKind::Choice { options } => {
                let id = field.id.clone();
                let selected = value.as_str().unwrap_or_default().to_owned();
                let title = config::display_value(field, value).unwrap_or_default();
                let options: Vec<(String, String)> = options
                    .iter()
                    .map(|option| (option.id.clone(), option.title.clone()))
                    .collect();
                let view = cx.entity().downgrade();
                row()
                    .py(px(10.))
                    .gap(px(16.))
                    .child(div().flex_1().min_w_0().child(field.title.clone()))
                    .child(
                        Button::new(format!("config-choice:{}", field.id))
                            .label(format!("{title}  ⌄"))
                            .disabled(!enabled)
                            .dropdown_menu(move |mut menu, _, _| {
                                for (option_id, option_title) in &options {
                                    let view = view.clone();
                                    let id = id.clone();
                                    let option_id = option_id.clone();
                                    menu = menu.item(
                                        PopupMenuItem::new(option_title.clone())
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
                    .child(Input::new(&input).disabled(!enabled))
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
                    cx,
                ),
                self.section(
                    "launcher",
                    "启动器兼容性",
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
                    vec![
                        self.choice("graphics-mode", "设置模式", &["简单", "高级"], cx),
                        self.choice(
                            "backend",
                            "图形后端",
                            &["推荐（自动）", "D3DMetal", "DXVK", "WineD3D"],
                            cx,
                        ),
                        self.toggle("metalfx", "MetalFX 超分辨率", "", cx),
                        self.toggle("metal4", "Metal 4", "", cx),
                        self.toggle("framegen", "帧生成", "", cx),
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
                    vec![
                        self.info("默认输出设备", "系统默认输出 · 48,000 Hz · 立体声"),
                        self.choice("audio-mode", "设置模式", &["简单", "高级"], cx),
                        self.choice(
                            "audio-driver",
                            "音频驱动",
                            &["自动", "CoreAudio", "禁用"],
                            cx,
                        ),
                        self.action("audio-test", "测试音频", Command::Notice, cx),
                        self.action(
                            "audio-diagnosis",
                            "音频故障排查…",
                            Command::Sheet(PreviewSheet::Audio),
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
                    vec![
                        self.action(
                            "guided",
                            "开始引导式故障排查…",
                            Command::Sheet(PreviewSheet::Diagnostics),
                            cx,
                        ),
                        self.action("export", "导出诊断报告…", Command::Notice, cx),
                        self.action("repair", "修复容器…", Command::Notice, cx),
                    ],
                    cx,
                ),
                self.section(
                    "cleanup",
                    "存储与清理",
                    vec![
                        self.info("容器大小", "2.4 GB"),
                        self.action("cache-clean", "清理着色器缓存…", Command::Notice, cx),
                    ],
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
        let mut rows: Vec<AnyElement> = Vec::new();
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
            let launchable = self.program_entry_id(&container, program).is_some();
            rows.push(
                row()
                    .id(path.clone())
                    .gap(px(15.))
                    .p(px(13.))
                    .border_b_1()
                    .border_color(rgba(0xffffff0a))
                    .child(
                        div()
                            .w(px(32.))
                            .h(px(40.))
                            .rounded(px(4.))
                            .bg(gradient(0xffffff12, 0xffffff04))
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(icon("package", 14.).text_color(rgb(MUTED))),
                    )
                    .child(
                        col()
                            .flex_1()
                            .min_w_0()
                            .gap(px(4.))
                            .child(div().truncate().child(program.name.clone()))
                            .child(muted(path.clone()).truncate())
                            .when(blocked, |d| d.child(muted("已屏蔽"))),
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
                row()
                    .id(game.id.clone())
                    .gap(px(15.))
                    .p(px(13.))
                    .border_b_1()
                    .border_color(rgba(0xffffff0a))
                    .child(match self.artwork(i) {
                        Some(artwork) => img(artwork)
                            .w(px(32.))
                            .h(px(40.))
                            .rounded(px(4.))
                            .object_fit(ObjectFit::Cover)
                            .into_any_element(),
                        None => div()
                            .w(px(32.))
                            .h(px(40.))
                            .rounded(px(4.))
                            .bg(gradient(0xffffff12, 0xffffff04))
                            .flex()
                            .items_center()
                            .justify_center()
                            .child(icon("package", 14.).text_color(rgb(MUTED)))
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
        let mut rows: Vec<AnyElement> = vec![self.info("进程名称", "PID")];
        match page {
            None => rows.push(self.process_status_row()),
            Some(page) => {
                if let Some(reason) = &page.error {
                    rows.push(muted(reason.clone()).into_any_element());
                } else if page.table.is_empty() {
                    if page.loading {
                        rows.push(self.process_status_row());
                    } else {
                        rows.push(self.info("当前没有运行中的进程", "0"));
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
                            .gap(px(18.))
                            .py(px(10.))
                            .items_start()
                            .child(div().flex_1().min_w_0().child(process.name.clone()))
                            .child(muted(value).max_w(relative(0.65)))
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
            Button::new("refresh-processes")
                .label("刷新")
                .on_click(cx.listener(|this, _, _, cx| this.refresh_processes(cx)))
                .into_any_element(),
        );
        rows.push(self.action("stop-processes", "停止所有进程", Command::Notice, cx));
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
                    self.info("进程名称", "PID"),
                    self.info("当前没有运行中的进程", "0"),
                    self.action("refresh-processes", "刷新", Command::Notice, cx),
                    self.action("stop-processes", "停止所有进程", Command::Notice, cx),
                ],
                cx,
            )],
        )
    }
    fn game_configs(&self, cx: &Context<Self>) -> AnyElement {
        self.form(
            "game-configs-scroll",
            vec![self.section(
                "game-rules",
                "游戏配置",
                vec![
                    self.info("匹配游戏专用兼容配置", "本地规则库"),
                    self.info("推荐配置", "字体、视频播放与运行库"),
                    self.action(
                        "rule-detail",
                        "查看推荐配置…",
                        Command::Sheet(PreviewSheet::Diagnostics),
                        cx,
                    ),
                ],
                cx,
            )],
        )
    }
}
