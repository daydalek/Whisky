//! The dedicated launcher surface: storefront clients (Steam etc.) that used
//! to sit among the games. Each row launches the client and carries the
//! per-launcher "open when Whisky starts" switch persisted through
//! `launchers.setAutoStart`.

use gpui_kit::component::{
    Disableable,
    button::{Button, ButtonVariants},
    switch::Switch,
};
use gpui_kit::{prelude::*, *};

use super::Command;
use crate::controls::*;
use crate::state::WhiskyApp;
use crate::theme;

impl WhiskyApp {
    /// `PreviewPage::Launchers`: every launcher entry across the bottles.
    pub(crate) fn launchers_page(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let indices = self.launchers();
        let mut rows: Vec<AnyElement> = Vec::new();
        if indices.is_empty() {
            rows.push(
                muted(if self.demo {
                    "Demo 模式没有启动器"
                } else {
                    "没有发现启动器。固定 steam.exe 等启动器程序，或在扫描文件夹中放入启动器目录后，它会出现在这里而不是游戏库中。"
                })
                .line_height(relative(1.5))
                .into_any_element(),
            );
        }
        for index in indices {
            rows.push(self.launcher_row(index, cx));
        }
        self.form(
            "launchers-scroll",
            vec![self.section("launchers", "启动器", rows, cx)],
        )
    }

    fn launcher_row(&mut self, index: usize, cx: &mut Context<Self>) -> AnyElement {
        let Some(game) = self.game(index) else {
            return div().into_any_element();
        };
        let (title, container) = (game.title.clone(), game.container.clone());
        let bottle = self
            .bottles
            .get(game.bottle.checked_sub(1).unwrap_or(usize::MAX))
            .map(|bottle| bottle.name.clone())
            .unwrap_or_else(|| container.clone());
        let path = game
            .executable
            .as_ref()
            .or_else(|| game.folder_path.as_ref())
            .map(|path| path.to_string_lossy().into_owned())
            .unwrap_or_else(|| game.id.clone());
        let needs_executable = game.needs_executable;
        let primary = self.primary_action(index);
        let auto_start = self.launcher_auto_start(index);
        let artwork = self.artwork(index).map(|path| {
            self.artwork_image(path)
                .size_full()
                .object_fit(ObjectFit::Cover)
                .into_any_element()
        });
        row()
            .gap(px(12.))
            .py(px(10.))
            .child(
                div()
                    .w(px(46.))
                    .h(px(46.))
                    .rounded(px(9.))
                    .overflow_hidden()
                    .bg(gradient(theme::placeholder_gradient().0, theme::placeholder_gradient().1))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(match artwork {
                        Some(image) => image,
                        None => icon("store", 20.)
                            .text_color(rgb(theme::muted_color()))
                            .into_any_element(),
                    }),
            )
            .child(
                col()
                    .flex_1()
                    .min_w_0()
                    .gap(px(3.))
                    .child(div().truncate().child(title))
                    .child(
                        muted(path)
                            .truncate()
                            .text_size(px(11.)),
                    )
                    .child(
                        muted(format!("容器：{bottle}"))
                            .truncate()
                            .text_size(px(11.)),
                    ),
            )
            .child(
                col()
                    .items_end()
                    .gap(px(6.))
                    .child(
                        Switch::new(("launcher-autostart", index))
                            .label("打开 Maltoria 时启动")
                            .checked(auto_start)
                            .on_change(cx.listener(move |this, _, _, cx| {
                                this.command(Command::LauncherAutoStart(index), cx);
                            })),
                    )
                    .child(
                        row()
                            .gap(px(8.))
                            .when(needs_executable, |d| {
                                d.child(
                                    Button::new(("launcher-exe", index))
                                        .label("选择可执行文件…")
                                        .ghost()
                                        .on_click(cx.listener(move |this, _, _, cx| {
                                            this.command(Command::Executable(index), cx);
                                        })),
                                )
                            })
                            .child(
                                Button::new(("launcher-run", index))
                                    .label(primary.label)
                                    .primary()
                                    .disabled(!primary.enabled || primary.busy)
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.command(Command::Runtime(index), cx);
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }
}
