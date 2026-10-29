//! View layer: shared form widgets, menus, scrolling, and the page modules.

pub(crate) mod bottle;
pub(crate) mod dialogs;
pub(crate) mod import_bottles;
pub(crate) mod library;
pub(crate) mod settings;
pub(crate) mod onboarding;
pub(crate) mod walkthrough;
pub(crate) mod walkthrough_routes;
pub(crate) mod walkthrough_tree;

use gpui_kit::base::{ScrollBounce, ScrollBounceMotion};
use gpui_kit::component::{
    Disableable,
    button::{Button, ButtonVariants},
    input::Input,
    menu::{DropdownMenu, PopupMenu, PopupMenuItem},
    switch::Switch,
};
use gpui_kit::{prelude::*, *};

use crate::controls::*;
use crate::state::{PreviewPage, PreviewSheet, WhiskyApp};

#[derive(Clone, Copy)]
pub(crate) enum Command {
    Page(PreviewPage),
    Sheet(PreviewSheet),
    Details(usize),
    Configure(usize),
    /// Run the card's primary action (launch, cancel, or stop).
    Runtime(usize),
    /// Name the executable a folder entry starts, without running it.
    Executable(usize),
    Toggle(&'static str),
    Choose(&'static str, &'static str),
    Sort(usize),
    Notice,
    Hide(usize),
    /// Select the entry's executable (or folder) in Finder.
    Reveal(usize),
    /// Create a macOS shortcut for the entry's executable.
    Shortcut,
    /// Move an entry into another bottle.
    Move(usize),
    /// Open the selected bottle's `drive_c` in Finder.
    OpenDrive,
    /// Re-read the bottle catalogue and every bottle's entries.
    RefreshLibrary,
    /// Terminate all running processes in the selected bottle.
    StopAllProcesses,
    /// Sidebar bottle actions.
    BottleRename(usize),
    BottleDuplicate(usize),
    BottleRemove(usize),
    BottleMove(usize),
    BottleExport(usize),
    BottleReveal(usize),
    /// Close the rename/duplicate/remove modal.
    BottleDialogCancel,
    /// Accept the rename/duplicate modal.
    BottleDialogConfirm,
    /// Run a Windows file in the selected bottle through the native picker.
    BottleRun,
    /// Choose an arbitrary Windows file and add it to the library as a pin.
    AddProgram,
    /// Launch a Wine builtin (winecfg, regedit, control, terminal).
    BottleTool(&'static str),
    BottleRepair,
    CleanShaderCache,
    /// Collect `bottle.diagnostics` into the Diagnostics sheet.
    RunDiagnostics,
    /// Write the stability report to a chosen file.
    ExportDiagnostics,
    /// Run `audio.test` with the 440 Hz tone.
    TestAudio,
    /// Run the curated troubleshooting checks.
    RunBottleChecks,
    /// Re-read `processes.list` for the selected bottle.
    RefreshProcesses,
    /// Metadata, cover and GameDB sheet for one library card.
    GameInfo(usize),
    MetadataSearch,
    MetadataApply(usize, usize),
    MetadataClear,
    MetadataCover,
    MetadataCoverReset,
    GameDbApply(usize),
    /// Auto-match metadata for every folder entry in the selected bottle.
    SyncMetadata,
    InstallWineRuntime,
    InstallRosetta,
    DismissSetup,
}
#[derive(Clone)]
struct MenuEntry {
    label: SharedString,
    command: Option<Command>,
    checked: bool,
    view: WeakEntity<WhiskyApp>,
}
impl MenuEntry {
    fn checked(mut self, checked: bool) -> Self {
        self.checked = checked;
        self
    }
    fn separator(view: WeakEntity<WhiskyApp>) -> Self {
        Self {
            label: "".into(),
            command: None,
            checked: false,
            view,
        }
    }
    fn build(&self) -> PopupMenuItem {
        let Some(command) = self.command else {
            return PopupMenuItem::separator();
        };
        let view = self.view.clone();
        PopupMenuItem::new(self.label.clone())
            .checked(self.checked)
            .on_click(move |_, _, cx| {
                let _ = view.update(cx, |this, cx| this.command(command, cx));
            })
    }
}

impl WhiskyApp {
    fn menu_item(
        &self,
        label: impl Into<SharedString>,
        command: Command,
        cx: &Context<Self>,
    ) -> MenuEntry {
        let view = cx.entity().downgrade();
        MenuEntry {
            label: label.into(),
            command: Some(command),
            checked: false,
            view,
        }
    }
    pub(crate) fn options_menu(&self, cx: &Context<Self>) -> AnyElement {
        let is_library = self.preview.page == PreviewPage::Library && !self.settings;
        let mut items = vec![];
        if is_library {
            items.push(
                self.menu_item("退出游戏后刷新游戏库", Command::Toggle("refresh"), cx)
                    .checked(self.flag("refresh")),
            );
            items.push(MenuEntry::separator(cx.entity().downgrade()));
            items.push(
                self.menu_item(crate::platform::MOTION_MENU, Command::Toggle("motion"), cx)
                    .checked(self.motion),
            );
            items.push(
                self.menu_item("明显弹性（默认：柔和）", Command::Toggle("lively"), cx)
                    .checked(self.lively),
            );
            items.push(MenuEntry::separator(cx.entity().downgrade()));
            {
                // Mirrors `LibrarySort` (recent, name, bottle); the labels are
                // the GPUI app's existing Chinese copy.
                for (i, label) in ["最近游玩", "名称", "容器"].into_iter().enumerate()
                {
                    items.push(
                        self.menu_item(label, Command::Sort(i), cx)
                            .checked(self.preview.sort == i),
                    );
                }
            }
            if self.mode == 0 {
                items.push(
                    self.menu_item("混合封面布局", Command::Toggle("mixed"), cx)
                        .checked(self.mixed),
                );
                items.push(
                    self.menu_item("单行显示标题", Command::Toggle("single-title"), cx)
                        .checked(self.flag("single-title")),
                );
            }
            items.push(MenuEntry::separator(cx.entity().downgrade()));
            items.push(self.menu_item("扫描并同步游戏信息", Command::SyncMetadata, cx));
            items.push(self.menu_item("管理扫描文件夹…", Command::Sheet(PreviewSheet::Scan), cx));
            items.push(
                self.menu_item("显示隐藏的游戏", Command::Toggle("show-hidden"), cx)
                    .checked(self.flag("show-hidden")),
            );
            items.push(MenuEntry::separator(cx.entity().downgrade()));
            for (label, value) in crate::theme::APPEARANCE_OPTIONS {
                items.push(
                    self.menu_item(
                        format!("外观：{label}"),
                        Command::Choose("appearance", value),
                        cx,
                    )
                    .checked(self.appearance.wire() == value),
                );
            }
            items.push(MenuEntry::separator(cx.entity().downgrade()));
            items.push(self.menu_item("刷新", Command::RefreshLibrary, cx));
        } else {
            items.push(self.menu_item(
                "Configure Bottle",
                Command::Page(PreviewPage::ConfigureBottle),
                cx,
            ));
            items.push(self.menu_item("已安装的程序", Command::Page(PreviewPage::Programs), cx));
            items.push(self.menu_item("运行中的进程", Command::Page(PreviewPage::Processes), cx));
            items.push(MenuEntry::separator(cx.entity().downgrade()));
            items.push(self.menu_item("Winetricks…", Command::Sheet(PreviewSheet::Winetricks), cx));
            items.push(self.menu_item("复制容器…", Command::Sheet(PreviewSheet::CreateBottle), cx));
            items.push(MenuEntry::separator(cx.entity().downgrade()));
            for (label, value) in crate::theme::APPEARANCE_OPTIONS {
                items.push(
                    self.menu_item(
                        format!("外观：{label}"),
                        Command::Choose("appearance", value),
                        cx,
                    )
                    .checked(self.appearance.wire() == value),
                );
            }
        }
        Button::new("options-menu")
            .label("•••")
            .rounded_full()
            .w(px(34.))
            .h(px(34.))
            .tooltip("更多")
            .dropdown_menu(move |mut menu, _, _| {
                for item in &items {
                    menu = menu.item(item.build());
                }
                menu
            })
            .into_any_element()
    }
    pub(crate) fn game_menu(
        &self,
        index: usize,
        cx: &Context<Self>,
    ) -> impl Fn(PopupMenu, &mut Window, &mut Context<PopupMenu>) -> PopupMenu + 'static {
        let game = self.game(index);
        let hidden = game.is_some_and(|game| game.hidden);
        let is_folder = game.is_some_and(|game| game.is_folder);
        // SwiftUI offers Show in Finder only for program entries (pinned or
        // folder), which are exactly the ones that carry a path.
        let has_path = game.is_some_and(|game| game.executable.is_some());
        let mut items = vec![
            self.menu_item("运行", Command::Runtime(index), cx),
            MenuEntry::separator(cx.entity().downgrade()),
            self.menu_item(
                if hidden { "取消隐藏" } else { "隐藏游戏" },
                Command::Hide(index),
                cx,
            ),
            self.menu_item("游戏详情", Command::Details(index), cx),
            self.menu_item("游戏资料与封面…", Command::GameInfo(index), cx),
            self.menu_item(
                "运行设置…",
                Command::Sheet(PreviewSheet::RunSettings(index)),
                cx,
            ),
        ];
        if has_path {
            items.push(self.menu_item(crate::platform::REVEAL_LABEL, Command::Reveal(index), cx));
        }
        items.extend([
            MenuEntry::separator(cx.entity().downgrade()),
            self.menu_item("配置容器", Command::Configure(index), cx),
        ]);
        if has_path && self.service_available("entry.move")
            && !game.is_some_and(|game| game.id.starts_with("steam:")) {
            items.push(self.menu_item("移动到容器…", Command::Move(index), cx));
        }
        // Only a folder entry runs something the user picked; a pin or a Steam
        // app already names its own executable.
        if is_folder {
            items.push(MenuEntry::separator(cx.entity().downgrade()));
            items.push(self.menu_item("选择启动程序…", Command::Executable(index), cx));
        }
        move |mut menu, _, _| {
            for item in &items {
                menu = menu.item(item.build());
            }
            menu
        }
    }
    /// Sidebar context menu, mirroring the SwiftUI bottle list entry.
    pub(crate) fn bottle_menu(
        &self,
        index: usize,
        cx: &Context<Self>,
    ) -> impl Fn(PopupMenu, &mut Window, &mut Context<PopupMenu>) -> PopupMenu + 'static {
        let available = self.bottles.get(index).is_some_and(|bottle| bottle.available);
        let mut items = vec![];
        if available {
            items.push(self.menu_item("重命名…", Command::BottleRename(index), cx));
            items.push(self.menu_item("删除…", Command::BottleRemove(index), cx));
            items.push(MenuEntry::separator(cx.entity().downgrade()));
            items.push(self.menu_item("移动容器…", Command::BottleMove(index), cx));
            items.push(self.menu_item("复制容器…", Command::BottleDuplicate(index), cx));
            items.push(self.menu_item("导出容器…", Command::BottleExport(index), cx));
            items.push(MenuEntry::separator(cx.entity().downgrade()));
        }
        items.push(self.menu_item(crate::platform::REVEAL_LABEL, Command::BottleReveal(index), cx));
        move |mut menu, _, _| {
            for item in &items {
                menu = menu.item(item.build());
            }
            menu
        }
    }
    pub(crate) fn game_options(&self, index: usize, cx: &Context<Self>) -> AnyElement {
        Button::new(("game-options", index))
            .label("•••")
            .ghost()
            .tooltip("更多")
            .dropdown_menu(self.game_menu(index, cx))
            .into_any_element()
    }
    pub(crate) fn action(
        &self,
        id: &'static str,
        label: &'static str,
        command: Command,
        cx: &Context<Self>,
    ) -> AnyElement {
        Button::new(id)
            .label(label)
            .disabled(!self.command_available(command))
            .on_click(cx.listener(move |this, _, _, cx| this.command(command, cx)))
            .into_any_element()
    }
    pub(crate) fn toggle(
        &self,
        key: &'static str,
        label: &'static str,
        description: &'static str,
        cx: &Context<Self>,
    ) -> AnyElement {
        let checked = match key {
            "mixed" => self.mixed,
            "motion" => self.motion,
            _ => self.flag(key),
        };
        row()
            .gap(px(20.))
            .py(px(10.))
            .items_start()
            .child(
                col()
                    .flex_1()
                    .min_w_0()
                    .gap(px(4.))
                    .child(label)
                    .when(!description.is_empty(), |d| {
                        d.child(muted(description).line_height(relative(1.4)))
                    }),
            )
            .child(
                Switch::new(key)
                    .checked(checked)
                    .disabled(!self.toggle_available(key))
                    .on_change(cx.listener(move |this, _, _, cx| {
                        this.command(Command::Toggle(key), cx)
                    })),
            )
            .into_any_element()
    }
    pub(crate) fn choice(
        &self,
        key: &'static str,
        label: &'static str,
        options: &'static [&'static str],
        cx: &Context<Self>,
    ) -> AnyElement {
        let selected = self
            .preview
            .choices
            .get(key)
            .cloned()
            .unwrap_or_else(|| options[0].into());
        let view = cx.entity().downgrade();
        let current = selected.clone();
        row()
            .py(px(10.))
            .gap(px(16.))
            .child(div().flex_1().min_w_0().child(label))
            .child(
                Button::new(key)
                    .label(format!("{}  ⌄", selected))
                    .dropdown_menu(move |mut menu, _, _| {
                        for &option in options {
                            let view = view.clone();
                            menu = menu.item(
                                PopupMenuItem::new(option)
                                    .checked(current.as_ref() == option)
                                    .on_click(move |_, _, cx| {
                                        let _ = view.update(cx, |this, cx| {
                                            this.preview.choices.insert(key, option.into());
                                            cx.notify();
                                        });
                                    }),
                            );
                        }
                        menu
                    }),
            )
            .into_any_element()
    }
    /// A dropdown backed by raw values, showing the matching label. Used by
    /// settings controls whose stored value is a Swift enum raw value.
    pub(crate) fn choice_pairs(
        &self,
        key: &'static str,
        label: &'static str,
        options: &'static [(&'static str, &'static str)],
        cx: &Context<Self>,
    ) -> AnyElement {
        let selected = self
            .preview
            .choices
            .get(key)
            .map(AsRef::as_ref)
            .unwrap_or(options[0].1);
        let selected_label = options
            .iter()
            .find(|(_, value)| *value == selected)
            .map_or(options[0].0, |(label, _)| label);
        let view = cx.entity().downgrade();
        let current = SharedString::from(selected);
        row()
            .py(px(10.))
            .gap(px(16.))
            .child(div().flex_1().min_w_0().child(label))
            .child(
                Button::new(key)
                    .label(format!("{selected_label}  ⌄"))
                    .dropdown_menu(move |mut menu, _, _| {
                        for &(option_label, value) in options {
                            let view = view.clone();
                            let checked = current.as_ref() == value;
                            menu = menu.item(
                                PopupMenuItem::new(option_label).checked(checked).on_click(
                                    move |_, _, cx| {
                                        let _ = view.update(cx, |this, cx| {
                                            this.command(Command::Choose(key, value), cx);
                                        });
                                    },
                                ),
                            );
                        }
                        menu
                    }),
            )
            .into_any_element()
    }
    pub(crate) fn field(&self, key: &'static str, label: &'static str) -> AnyElement {
        col()
            .gap(px(7.))
            .py(px(8.))
            .child(label)
            .child(Input::new(&self.preview.inputs[key]))
            .into_any_element()
    }
    pub(crate) fn info(&self, label: impl Into<SharedString>, value: impl Into<SharedString>) -> AnyElement {
        row()
            .gap(px(18.))
            .py(px(10.))
            .items_start()
            .child(div().flex_1().min_w_0().child(label.into()))
            .child(muted(value).max_w(relative(0.65)))
            .into_any_element()
    }
    pub(crate) fn section(
        &self,
        key: &'static str,
        title: &'static str,
        children: Vec<AnyElement>,
        cx: &Context<Self>,
    ) -> AnyElement {
        let collapsed = self.preview.collapsed.contains(key);
        col()
            .flex_shrink_0()
            .gap(px(8.))
            .child(
                row()
                    .id(SharedString::from(format!("section-{key}")))
                    .gap(px(7.))
                    .py(px(5.))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if !this.preview.collapsed.remove(key) {
                            this.preview.collapsed.insert(key);
                        }
                        cx.notify();
                    }))
                    .child(muted(if collapsed { "›" } else { "⌄" }))
                    .child(div().font_weight(FontWeight::SEMIBOLD).child(title)),
            )
            .when(!collapsed, |d| {
                d.child(
                    col()
                        .px(px(17.))
                        .py(px(5.))
                        .rounded(px(10.))
                        .bg(rgba(crate::theme::section_bg()))
                        .border_1()
                        .border_color(rgba(crate::theme::section_border()))
                        .children(children),
                )
            })
            .into_any_element()
    }
    pub(crate) fn form(&self, id: &'static str, sections: Vec<AnyElement>) -> AnyElement {
        self.preview_scroll(
            id,
            col().w_full().p(px(26.)).gap(px(22.)).children(sections),
        )
    }
    pub(crate) fn preview_scroll(&self, id: &'static str, content: impl IntoElement) -> AnyElement {
        self.bouncing_scroll(id, &self.preview.form_scroll_handle(id), content)
    }
    pub(crate) fn bouncing_scroll(
        &self,
        id: impl Into<ElementId>,
        handle: &ScrollHandle,
        content: impl IntoElement,
    ) -> AnyElement {
        let id = id.into();
        // One follow-up frame resolves the document's initial scroll metrics.
        if handle.bounds().size.height == px(0.) {
            self.scroll_needs_measurement.set(true);
        }
        let viewport = div()
            .id((id.clone(), "viewport"))
            .size_full()
            .track_scroll(handle)
            .overflow_y_scroll()
            .child(content);
        ScrollBounce::new((id, "bounce"), handle, viewport)
            .enabled(self.motion)
            // Base's direct edge path also stretches documents that fit the viewport.
            .scroll_wheel(handle.max_offset().y > px(0.))
            .motion(ScrollBounceMotion::default())
            .into_any_element()
    }
    pub(crate) fn library_viewport(&self, mode: usize, content: impl IntoElement) -> AnyElement {
        self.bouncing_scroll(
            ("library-scroll", mode),
            &self.library_scroll[mode],
            content,
        )
    }
}
