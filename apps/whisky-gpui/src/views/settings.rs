//! Application settings surface.

use gpui_kit::{prelude::*, *};

use crate::state::WhiskyApp;

impl WhiskyApp {
    pub(crate) fn application_settings(&self, cx: &Context<Self>) -> AnyElement {
        self.form(
            "app-settings-scroll",
            vec![
                self.section(
                    "general",
                    "通用",
                    vec![
                        self.toggle("kill", "退出 Whisky 时结束所有进程", "", cx),
                        self.toggle("menubar", "在菜单栏显示 Whisky", "", cx),
                        self.choice("terminal", "首选终端", &["终端", "iTerm2"], cx),
                        self.info("默认容器位置", "~/Library/Containers/Whisky/Bottles"),
                    ],
                    cx,
                ),
                self.section(
                    "library-prefs",
                    "游戏库",
                    vec![
                        self.toggle("refresh", "退出游戏后刷新游戏库", "", cx),
                        self.toggle("blur", "详情页模糊背景", "", cx),
                        self.toggle(
                            "mixed",
                            "混合封面布局",
                            "横版封面跨两列，竖版封面占一列。",
                            cx,
                        ),
                        self.toggle("single-title", "单行显示标题", "", cx),
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
                    "network",
                    "网络与更新",
                    vec![
                        self.toggle("offline", "离线模式", "", cx),
                        self.toggle("updates", "检查 WhiskyWine 更新", "", cx),
                    ],
                    cx,
                ),
            ],
        )
    }
}
