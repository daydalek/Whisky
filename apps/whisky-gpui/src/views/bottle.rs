//! Bottle surfaces: home, configuration, programs, processes, and game rules.

use gpui_kit::component::button::{Button, ButtonVariants};
use gpui_kit::component::menu::ContextMenuExt;
use gpui_kit::{prelude::*, *};

use super::Command;
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
            .child(self.action("bottle-c-drive", "打开 C: 盘", Command::Notice, cx))
            .child(self.action(
                "bottle-tricks",
                "Winetricks…",
                Command::Sheet(PreviewSheet::Winetricks),
                cx,
            ))
            .child(self.action("bottle-run", "运行…", Command::Notice, cx))
            .into_any_element()
    }
    pub(crate) fn preview_page(&self, cx: &mut Context<Self>) -> AnyElement {
        let body = match self.preview.page {
            PreviewPage::Bottle => match self.visible_load_error() {
                Some(error) => self.library_error_surface(error, cx),
                None => self.bottle_home(cx),
            },
            PreviewPage::ConfigureBottle => self.bottle_config(cx),
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
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.preview.page =
                                    this.preview.history.pop().unwrap_or(PreviewPage::Bottle);
                                cx.notify();
                            })),
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
    fn bottle_config(&self, cx: &Context<Self>) -> AnyElement {
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
    fn programs(&self, cx: &Context<Self>) -> AnyElement {
        let slot = self.bottle_slot();
        let rows = self
            .games()
            .iter()
            .enumerate()
            .filter(|(_, game)| game.bottle == slot)
            .map(|(i, game)| {
                let path = if self.demo {
                    format!("C:\\Games\\{}\\game.exe", i + 1)
                } else {
                    game.executable
                        .as_ref()
                        .map(|path| path.display().to_string())
                        .unwrap_or_default()
                };
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
    fn processes(&self, cx: &Context<Self>) -> AnyElement {
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
