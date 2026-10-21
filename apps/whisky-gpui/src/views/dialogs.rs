//! Modal sheets: run settings, scan folders, winetricks, create bottle, and diagnostics.

use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::input::Input;
use gpui_kit::{prelude::*, *};

use super::Command;
use crate::controls::*;
use crate::model::demo_data;
use crate::state::{PreviewSheet, WhiskyApp};

impl WhiskyApp {
    fn run_settings(&self, index: usize, cx: &Context<Self>) -> AnyElement {
        self.form(
            "run-settings-scroll",
            vec![
                self.section(
                    "run-config",
                    "运行设置",
                    vec![
                        self.info("程序", demo_data()[index].title),
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
    pub(crate) fn preview_sheet(
        &self,
        sheet: PreviewSheet,
        width: f32,
        height: f32,
        cx: &Context<Self>,
    ) -> AnyElement {
        let title = match sheet {
            PreviewSheet::RunSettings(_) => "运行设置",
            PreviewSheet::Scan => "管理扫描文件夹",
            PreviewSheet::Winetricks => "Winetricks",
            PreviewSheet::CreateBottle => "创建容器",
            PreviewSheet::Diagnostics => "故障排查",
            PreviewSheet::Audio => "音频故障排查",
            PreviewSheet::Dll => "DLL 覆盖",
            PreviewSheet::Graphics => "高级图形设置",
        };
        let content = match sheet {
            PreviewSheet::RunSettings(i) => self.run_settings(i, cx),
            PreviewSheet::Scan => self.form(
                "scan-settings-scroll",
                vec![self.section(
                    "scan-folders",
                    "扫描文件夹",
                    vec![
                        self.info("~/Games", "递归扫描"),
                        self.field("scan-path", "添加文件夹"),
                        self.toggle("recursive", "包含子文件夹", "", cx),
                        self.toggle("scan-startup", "启动时扫描", "", cx),
                        self.action("scan-add", "添加文件夹", Command::Notice, cx),
                    ],
                    cx,
                )],
            ),
            PreviewSheet::Winetricks => self.form(
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
            ),
            PreviewSheet::CreateBottle => self.form(
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
                        self.info("位置", "~/Library/Containers/Whisky/Bottles"),
                        self.info("架构", "64 位"),
                    ],
                    cx,
                )],
            ),
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
                                d.child(self.action(
                                    "shortcut",
                                    "创建快捷方式",
                                    Command::Notice,
                                    cx,
                                ))
                                .child(self.action(
                                    "reveal",
                                    "在访达中显示",
                                    Command::Notice,
                                    cx,
                                ))
                            })
                            .child(
                                Button::new("sheet-done")
                                    .label(if matches!(sheet, PreviewSheet::CreateBottle) {
                                        "创建"
                                    } else if matches!(sheet, PreviewSheet::Winetricks) {
                                        "安装选中组件"
                                    } else {
                                        "完成"
                                    })
                                    .primary()
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.preview.sheet = None;
                                        this.preview.sheet_history.clear();
                                        cx.notify();
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }
}
