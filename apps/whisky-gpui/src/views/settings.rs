//! Application settings surface.

use gpui_kit::component::button::Button;
use gpui_kit::{prelude::*, *};

use crate::controls::{muted, row};
use crate::preferences;
use crate::state::WhiskyApp;

const TERMINALS: [(&str, &str); 3] = [
    ("Terminal", preferences::TERMINAL_VALUES[0]),
    ("iTerm2", preferences::TERMINAL_VALUES[1]),
    ("Warp", preferences::TERMINAL_VALUES[2]),
];

impl WhiskyApp {
    pub(crate) fn application_settings(&self, cx: &Context<Self>) -> AnyElement {
        let bottle_location = self
            .default_bottle_location
            .clone()
            .unwrap_or_else(|| "~/Library/Containers/com.franke.Whisky/Bottles".into());
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
                        self.choice_pairs("terminal", "首选终端", &TERMINALS, cx),
                        row()
                            .py(px(10.))
                            .gap(px(16.))
                            .child(div().flex_1().min_w_0().child("默认容器位置"))
                            .child(muted(bottle_location.clone()).max_w(relative(0.5)).truncate())
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
                                        status
                                            .version
                                            .clone()
                                            .map_or_else(|| "已安装".to_owned(), |version| {
                                                format!("已安装 · {version}")
                                            })
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
