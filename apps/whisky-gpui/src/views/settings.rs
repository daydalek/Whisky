//! Application settings surface.

#[cfg(target_os = "linux")]
use gpui_kit::component::Disableable;
use gpui_kit::component::button::Button;
#[cfg(target_os = "linux")]
use gpui_kit::component::menu::{DropdownMenu, PopupMenuItem};
use gpui_kit::{prelude::*, *};

use crate::controls::{muted, row};
use crate::preferences;
use crate::state::WhiskyApp;

#[cfg(not(target_os = "linux"))]
const TERMINALS: [(&str, &str); 3] = [
    ("Terminal", preferences::TERMINAL_VALUES[0]),
    ("iTerm2", preferences::TERMINAL_VALUES[1]),
    ("Warp", preferences::TERMINAL_VALUES[2]),
];

#[cfg(target_os = "linux")]
const TERMINALS: [(&str, &str); 4] = [
    ("自动选择", preferences::TERMINAL_VALUES[0]),
    ("系统终端", preferences::TERMINAL_VALUES[1]),
    ("GNOME Terminal", preferences::TERMINAL_VALUES[2]),
    ("XTerm", preferences::TERMINAL_VALUES[3]),
];

impl WhiskyApp {
    fn terminal_preferences(&self, cx: &Context<Self>) -> AnyElement {
        #[cfg(not(target_os = "linux"))]
        {
            return self.choice_pairs("terminal", "首选终端", &TERMINALS, cx);
        }
        #[cfg(target_os = "linux")]
        {
            let selected = self
                .preview
                .choices
                .get("terminal")
                .map(|value| value.as_ref())
                .unwrap_or("auto");
            let label = TERMINALS
                .iter()
                .find(|(_, id)| *id == selected)
                .map(|(label, _)| *label)
                .unwrap_or("已配置的终端");
            let choices = TERMINALS
                .iter()
                .copied()
                .filter(|(_, id)| {
                    *id == "auto"
                        || self.host_terminals.as_ref().is_some_and(|status| {
                            status.available.iter().any(|term| term.id == *id)
                        })
                })
                .collect::<Vec<_>>();
            let status =
                self.host_terminal_error
                    .clone()
                    .unwrap_or_else(|| match &self.host_terminals {
                        Some(status) if status.available.is_empty() => {
                            "请安装系统终端、GNOME Terminal 或 XTerm".to_owned()
                        }
                        Some(status)
                            if selected != "auto"
                                && !status.available.iter().any(|term| term.id == selected) =>
                        {
                            "首选终端暂不可用，请重新选择".to_owned()
                        }
                        Some(status) if !status.display_available => {
                            "图形会话连接后可打开终端".to_owned()
                        }
                        Some(status) => status
                            .available
                            .iter()
                            .map(|term| format!("{} · {}", term.name, term.path))
                            .collect::<Vec<_>>()
                            .join("；"),
                        None => "正在发现 Linux 终端…".to_owned(),
                    });
            let view = cx.entity().downgrade();
            let enabled = self
                .host_terminals
                .as_ref()
                .is_some_and(|status| !status.available.is_empty());
            crate::controls::col()
                .gap(px(6.))
                .child(
                    row()
                        .py(px(10.))
                        .gap(px(16.))
                        .child(div().flex_1().child("首选终端"))
                        .child(
                            Button::new("linux-terminal")
                                .label(format!("{label}  ⌄"))
                                .disabled(!enabled)
                                .dropdown_menu(move |mut menu, _, _| {
                                    for &(label, id) in &choices {
                                        let view = view.clone();
                                        menu = menu.item(PopupMenuItem::new(label).on_click(
                                            move |_, _, cx| {
                                                let _ = view.update(cx, |this, cx| {
                                                    this.command(
                                                        super::Command::Choose("terminal", id),
                                                        cx,
                                                    )
                                                });
                                            },
                                        ));
                                    }
                                    menu
                                }),
                        )
                        .child(
                            Button::new("refresh-terminals").label("重新检测").on_click(
                                cx.listener(|this, _, _, _| this.bridge.load_terminals()),
                            ),
                        ),
                )
                .child(muted(status).text_size(px(11.)))
                .into_any_element()
        }
    }

    #[cfg(target_os = "linux")]
    fn desktop_preferences(&self, cx: &Context<Self>) -> AnyElement {
        let installed = self
            .desktop_status
            .as_ref()
            .is_some_and(|status| status.installed);
        let message = self
            .desktop_error
            .clone()
            .or_else(|| {
                self.desktop_status
                    .as_ref()
                    .map(|status| status.path.clone())
            })
            .unwrap_or_else(|| "正在读取桌面集成状态…".into());
        crate::controls::col()
            .gap(px(6.))
            .child(
                row()
                    .py(px(10.))
                    .gap(px(16.))
                    .child(div().flex_1().child("桌面入口与打开方式"))
                    .child(
                        Button::new("install-desktop")
                            .label(if self.desktop_installing {
                                "正在添加…"
                            } else if self.desktop_status.as_ref().is_some_and(|status| status.needs_update) {
                                "更新…"
                            } else if installed {
                                "已添加"
                            } else {
                                "添加…"
                            })
                            .disabled(
                                self.desktop_installing
                                    || !matches!(
                                        self.bridge_status,
                                        crate::bridge::BridgeStatus::Connected { .. }
                                    ),
                            )
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.desktop_installing = true;
                                this.desktop_error = None;
                                this.bridge.desktop_integration(true);
                                cx.notify();
                            })),
                    ),
            )
            .child(muted(message).text_size(px(11.)))
            .into_any_element()
    }

    pub(crate) fn application_settings(&self, cx: &Context<Self>) -> AnyElement {
        let bottle_location = self
            .default_bottle_location
            .clone()
            .unwrap_or_else(|| "~/Library/Containers/com.franke.Whisky/Bottles".into());
        let terminal = self.terminal_preferences(cx);
        #[cfg(target_os = "linux")]
        let terminal = crate::controls::col()
            .gap(px(8.))
            .child(terminal)
            .child(self.desktop_preferences(cx))
            .into_any_element();
        self.form(
            "app-settings-scroll",
            vec![
                self.section(
                    "general",
                    "通用",
                    vec![
                        self.toggle(
                            "kill",
                            "退出 Whisky 时结束所有进程",
                            "关闭后，退出应用不会终止仍在运行的 Windows 程序。",
                            cx,
                        ),
                        // "在菜单栏显示 Whisky" is deliberately absent: the
                        // GPUI toolkit has no menu-bar/status-item API, so
                        // the toggle would write a shared default nothing
                        // reads here. It stays in the schema for SwiftUI.
                        terminal,
                        row()
                            .py(px(10.))
                            .gap(px(16.))
                            .child(div().flex_1().min_w_0().child("默认容器位置"))
                            .child(
                                muted(bottle_location.clone())
                                    .max_w(relative(0.5))
                                    .truncate(),
                            )
                            .child(
                                Button::new("choose-bottle-location")
                                    .label("更改…")
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        this.choose_bottle_location(cx);
                                    })),
                            )
                            .into_any_element(),
                    ],
                    cx,
                ),
                self.section(
                    "library-prefs",
                    "游戏库",
                    vec![
                        self.toggle("refresh", "退出游戏后刷新游戏库", "", cx),
                        self.toggle(
                            "mixed",
                            "混合封面布局",
                            "横版封面跨两列，竖版封面占一列。",
                            cx,
                        ),
                        self.toggle("single-title", "单行显示标题", "", cx),
                        self.toggle(
                            "center-cover-text",
                            "宽封面文字居中",
                            "横版封面上的标题与信息居中对齐。",
                            cx,
                        ),
                        // The SwiftUI-only display preferences (detail blur,
                        // blurred cover fill, fill style, detail layout) are
                        // deliberately absent here: this renderer has no blur
                        // primitive, crops covers with object-fit so a fill
                        // never shows, and implements one detail layout. They
                        // stay in the shared preference schema and still
                        // affect the SwiftUI app.
                        self.toggle(
                            "motion",
                            "界面动画",
                            "滚动回弹、卡片弹簧重排、悬停与详情页过渡。",
                            cx,
                        ),
                    ],
                    cx,
                ),
                self.section(
                    "runtime",
                    "Wine 运行时",
                    vec![
                        self.info(
                            "状态",
                            self.setup_status.as_ref().map_or_else(
                                || "未知".to_owned(),
                                |status| {
                                    if status.installed {
                                        status.version.clone().map_or_else(
                                            || "已安装".to_owned(),
                                            |version| format!("已安装 · {version}"),
                                        )
                                    } else {
                                        "未安装".to_owned()
                                    }
                                },
                            ),
                        ),
                        self.action(
                            "runtime-install",
                            "安装或更新运行时…",
                            crate::views::Command::InstallWineRuntime,
                            cx,
                        ),
                    ],
                    cx,
                ),
                self.section(
                    "network",
                    "网络与更新",
                    vec![
                        self.toggle(
                            "offline",
                            "离线模式",
                            "阻止 Whisky 自身的联网请求；游戏不受影响。",
                            cx,
                        ),
                        self.toggle("updates", "检查 WhiskyWine 更新", "", cx),
                    ],
                    cx,
                ),
            ],
        )
    }
}
