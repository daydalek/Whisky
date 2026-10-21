use super::*;
use gpui_kit::component::{
    button::{Button, ButtonVariants},
    menu::{DropdownMenu, PopupMenu, PopupMenuItem},
};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum PreviewPage {
    Library,
    Bottle,
    ConfigureBottle,
    Programs,
    Processes,
    GameConfigs,
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum PreviewSheet {
    RunSettings(usize),
    Scan,
    Winetricks,
    CreateBottle,
    Diagnostics,
    Audio,
    Dll,
    Graphics,
}
#[derive(Clone, Copy)]
enum Command {
    Page(PreviewPage),
    Sheet(PreviewSheet),
    Details(usize),
    Configure(usize),
    Toggle(&'static str),
    Sort(usize),
    Reorder,
    Notice,
    Hide(usize),
    Move(usize, usize),
}
#[derive(Clone)]
struct MenuEntry {
    label: SharedString,
    command: Option<Command>,
    checked: bool,
    view: WeakEntity<Demo>,
}
impl MenuEntry {
    fn checked(mut self, checked: bool) -> Self {
        self.checked = checked;
        self
    }
    fn separator(view: WeakEntity<Demo>) -> Self {
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
pub(super) struct PreviewState {
    pub page: PreviewPage,
    pub history: Vec<PreviewPage>,
    pub sheet: Option<PreviewSheet>,
    sheet_history: Vec<PreviewSheet>,
    toggles: BTreeMap<&'static str, bool>,
    choices: BTreeMap<&'static str, SharedString>,
    collapsed: BTreeSet<&'static str>,
    inputs: BTreeMap<&'static str, Entity<InputState>>,
    hidden: BTreeSet<usize>,
    moved: BTreeMap<usize, usize>,
    sort: usize,
    // Retained per document, including forms mounted inside settings sheets.
    scroll_handles: std::cell::RefCell<BTreeMap<&'static str, ScrollHandle>>,
}
impl PreviewState {
    pub(super) fn form_scroll_handle(&self, id: &'static str) -> ScrollHandle {
        self.scroll_handles
            .borrow_mut()
            .entry(id)
            .or_insert_with(ScrollHandle::new)
            .clone()
    }
    pub fn new(window: &mut Window, cx: &mut Context<Demo>) -> Self {
        let mut inputs = BTreeMap::new();
        for (key, placeholder) in [
            ("arguments", "启动参数，例如 -windowed"),
            ("env-key", "变量名"),
            ("env-value", "变量值"),
            ("scan-path", "~/Games"),
            ("bottle-name", "新建容器"),
            ("dll-name", "例如 d3dcompiler_47"),
            ("build", "26100"),
            ("dpi", "96"),
            ("desktop-width", "1920"),
            ("desktop-height", "1080"),
            ("dependency-search", "搜索组件…"),
        ] {
            inputs.insert(
                key,
                cx.new(|cx| InputState::new(window, cx).placeholder(placeholder)),
            );
        }
        Self {
            page: PreviewPage::Library,
            history: vec![],
            sheet: None,
            sheet_history: vec![],
            inputs,
            toggles: [
                ("refresh", true),
                ("shader", true),
                ("appnap", true),
                ("kill", true),
                ("blur", true),
                ("updates", true),
            ]
            .into(),
            choices: BTreeMap::new(),
            collapsed: [
                "launcher",
                "input",
                "dll",
                "cleanup",
                "overrides",
                "console",
            ]
            .into(),
            hidden: BTreeSet::new(),
            moved: BTreeMap::new(),
            sort: 0,
            scroll_handles: Default::default(),
        }
    }
}
impl Demo {
    fn command(&mut self, command: Command, cx: &mut Context<Self>) {
        match command {
            Command::Page(page) => self.navigate(page, cx),
            Command::Sheet(sheet) => self.open_preview_sheet(sheet, cx),
            Command::Details(i) => self.open_detail(i, cx),
            Command::Configure(i) => {
                self.bottle = self
                    .preview
                    .moved
                    .get(&i)
                    .copied()
                    .unwrap_or(GAMES[i].bottle);
                self.navigate(PreviewPage::ConfigureBottle, cx);
            }
            Command::Toggle(key) => match key {
                "mixed" => self.mixed = !self.mixed,
                "motion" => self.motion = !self.motion,
                "lively" => self.lively = !self.lively,
                _ => {
                    let value = self.preview.toggles.entry(key).or_default();
                    *value = !*value;
                }
            },
            Command::Sort(i) => self.preview.sort = i,
            Command::Reorder => self.reorder_library(cx),
            Command::Hide(i) => {
                if !self.preview.hidden.remove(&i) {
                    self.preview.hidden.insert(i);
                }
            }
            Command::Move(i, bottle) => {
                self.preview.moved.insert(i, bottle);
            }
            Command::Notice => self.show_notice(cx),
        }
        cx.notify();
    }
    fn navigate(&mut self, page: PreviewPage, cx: &mut Context<Self>) {
        if page != self.preview.page {
            self.preview.history.push(self.preview.page);
        }
        self.preview.page = page;
        self.settings = false;
        self.detail_open = false;
        self.preview.sheet = None;
        self.hovered = None;
        cx.notify();
    }
    pub(super) fn open_preview_sheet(&mut self, sheet: PreviewSheet, cx: &mut Context<Self>) {
        if let Some(previous) = self.preview.sheet {
            self.preview.sheet_history.push(previous);
        } else {
            self.preview.sheet_history.clear();
        }
        self.preview.sheet = Some(sheet);
        self.detail_open = false;
        self.hovered = None;
        cx.notify();
    }
    pub(super) fn preview_title(&self) -> &'static str {
        if self.settings {
            return "设置";
        }
        match self.preview.page {
            PreviewPage::Library => "Library",
            PreviewPage::Bottle => {
                if self.bottle == 2 {
                    "galgame-win7"
                } else {
                    "galgame"
                }
            }
            PreviewPage::ConfigureBottle => "Configure Bottle",
            PreviewPage::Programs => "已安装的程序",
            PreviewPage::Processes => "运行中的进程",
            PreviewPage::GameConfigs => "游戏配置",
        }
    }
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
    pub(super) fn options_menu(&self, cx: &Context<Self>) -> AnyElement {
        let is_library = self.preview.page == PreviewPage::Library && !self.settings;
        let mut items = vec![];
        if is_library {
            items.push(
                self.menu_item("退出游戏后刷新游戏库", Command::Toggle("refresh"), cx)
                    .checked(self.flag("refresh")),
            );
            items.push(MenuEntry::separator(cx.entity().downgrade()));
            items.push(
                self.menu_item("界面动画 · ⌘⇧M", Command::Toggle("motion"), cx)
                    .checked(self.motion),
            );
            items.push(
                self.menu_item("明显弹性（默认：柔和）", Command::Toggle("lively"), cx)
                    .checked(self.lively),
            );
            items.push(
                self.menu_item("反转顺序 · ⌘R", Command::Reorder, cx)
                    .checked(self.reversed),
            );
            items.push(MenuEntry::separator(cx.entity().downgrade()));
            {
                for (i, label) in ["默认顺序", "名称", "反向顺序"].into_iter().enumerate()
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
            items.push(self.menu_item("扫描并同步游戏信息", Command::Notice, cx));
            items.push(self.menu_item("管理扫描文件夹…", Command::Sheet(PreviewSheet::Scan), cx));
            items.push(
                self.menu_item("显示隐藏的游戏", Command::Toggle("show-hidden"), cx)
                    .checked(self.flag("show-hidden")),
            );
            items.push(MenuEntry::separator(cx.entity().downgrade()));
            items.push(self.menu_item("刷新", Command::Notice, cx));
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
    pub(super) fn game_menu(
        &self,
        index: usize,
        cx: &Context<Self>,
    ) -> impl Fn(PopupMenu, &mut Window, &mut Context<PopupMenu>) -> PopupMenu + 'static {
        let items = vec![
            self.menu_item("运行", Command::Notice, cx),
            MenuEntry::separator(cx.entity().downgrade()),
            self.menu_item(
                if self.preview.hidden.contains(&index) {
                    "取消隐藏"
                } else {
                    "隐藏游戏"
                },
                Command::Hide(index),
                cx,
            ),
            self.menu_item("游戏详情", Command::Details(index), cx),
            self.menu_item(
                "运行设置…",
                Command::Sheet(PreviewSheet::RunSettings(index)),
                cx,
            ),
            self.menu_item("在访达中显示", Command::Notice, cx),
            MenuEntry::separator(cx.entity().downgrade()),
            self.menu_item("配置容器", Command::Configure(index), cx),
        ];
        let targets = [
            self.menu_item("galgame", Command::Move(index, 1), cx)
                .checked(
                    self.preview
                        .moved
                        .get(&index)
                        .copied()
                        .unwrap_or(GAMES[index].bottle)
                        == 1,
                ),
            self.menu_item("galgame-win7", Command::Move(index, 2), cx)
                .checked(
                    self.preview
                        .moved
                        .get(&index)
                        .copied()
                        .unwrap_or(GAMES[index].bottle)
                        == 2,
                ),
        ];
        move |mut menu, window, cx| {
            for item in &items {
                menu = menu.item(item.build());
            }
            let targets = targets.clone();
            menu.submenu("目标容器", window, cx, move |mut menu, _, _| {
                for item in &targets {
                    menu = menu.item(item.build());
                }
                menu
            })
        }
    }
    pub(super) fn game_options(&self, index: usize, cx: &Context<Self>) -> AnyElement {
        Button::new(("game-options", index))
            .label("•••")
            .ghost()
            .tooltip("更多")
            .dropdown_menu(self.game_menu(index, cx))
            .into_any_element()
    }
    fn flag(&self, key: &'static str) -> bool {
        self.preview.toggles.get(key).copied().unwrap_or(false)
    }
    fn action(
        &self,
        id: &'static str,
        label: &'static str,
        command: Command,
        cx: &Context<Self>,
    ) -> AnyElement {
        Button::new(id)
            .label(label)
            .on_click(cx.listener(move |this, _, _, cx| this.command(command, cx)))
            .into_any_element()
    }
    fn toggle(
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
            .child(Switch::new(key).checked(checked).on_change(
                cx.listener(move |this, _, _, cx| this.command(Command::Toggle(key), cx)),
            ))
            .into_any_element()
    }
    fn choice(
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
    fn field(&self, key: &'static str, label: &'static str) -> AnyElement {
        col()
            .gap(px(7.))
            .py(px(8.))
            .child(label)
            .child(Input::new(&self.preview.inputs[key]))
            .into_any_element()
    }
    fn info(&self, label: &'static str, value: impl Into<SharedString>) -> AnyElement {
        row()
            .gap(px(18.))
            .py(px(10.))
            .items_start()
            .child(div().flex_1().min_w_0().child(label))
            .child(muted(value).max_w(relative(0.65)))
            .into_any_element()
    }
    fn section(
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
                        .bg(rgba(0xffffff08))
                        .border_1()
                        .border_color(rgba(0xffffff0a))
                        .children(children),
                )
            })
            .into_any_element()
    }
    fn form(&self, id: &'static str, sections: Vec<AnyElement>) -> AnyElement {
        self.preview_scroll(
            id,
            col().w_full().p(px(26.)).gap(px(22.)).children(sections),
        )
    }
    fn preview_scroll(&self, id: &'static str, content: impl IntoElement) -> AnyElement {
        self.bouncing_scroll(id, &self.preview.form_scroll_handle(id), content)
    }
    fn bottle_bar(&self, cx: &Context<Self>) -> AnyElement {
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
    pub(super) fn preview_page(&self, cx: &Context<Self>) -> AnyElement {
        let body = match self.preview.page {
            PreviewPage::Bottle => self.bottle_home(cx),
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
                    .child(muted(if self.bottle == 2 {
                        "galgame-win7"
                    } else {
                        "galgame"
                    })),
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
        let pins: Vec<_> = GAMES
            .iter()
            .enumerate()
            .filter(|(_, g)| g.bottle == self.bottle)
            .take(5)
            .map(|(i, g)| {
                col()
                    .w(px(110.))
                    .gap(px(9.))
                    .items_center()
                    .child(
                        div()
                            .id(("pin", i))
                            .cursor_pointer()
                            .on_click(cx.listener(move |this, _, _, cx| this.open_detail(i, cx)))
                            .child(
                                img(art(i))
                                    .w(px(76.))
                                    .h(px(90.))
                                    .rounded(px(9.))
                                    .object_fit(ObjectFit::Cover),
                            )
                            .context_menu(self.game_menu(i, cx)),
                    )
                    .child(
                        div()
                            .w_full()
                            .text_size(px(11.))
                            .text_center()
                            .line_clamp(2)
                            .child(g.title),
                    )
                    .into_any_element()
            })
            .collect();
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
        let rows = GAMES
            .iter()
            .enumerate()
            .filter(|(_, g)| g.bottle == self.bottle)
            .map(|(i, g)| {
                row()
                    .id(("program-row", i))
                    .gap(px(15.))
                    .p(px(13.))
                    .border_b_1()
                    .border_color(rgba(0xffffff0a))
                    .child(
                        img(art(i))
                            .w(px(32.))
                            .h(px(40.))
                            .rounded(px(4.))
                            .object_fit(ObjectFit::Cover),
                    )
                    .child(
                        col()
                            .flex_1()
                            .min_w_0()
                            .gap(px(4.))
                            .child(div().truncate().child(g.title))
                            .child(muted(format!("C:\\Games\\{}\\game.exe", i + 1)).truncate()),
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
    pub(super) fn application_settings(&self, cx: &Context<Self>) -> AnyElement {
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
    fn run_settings(&self, index: usize, cx: &Context<Self>) -> AnyElement {
        self.form(
            "run-settings-scroll",
            vec![
                self.section(
                    "run-config",
                    "运行设置",
                    vec![
                        self.info("程序", GAMES[index].title),
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
    pub(super) fn preview_sheet(
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
    pub(super) fn preview_single_line(&self) -> bool {
        self.flag("single-title")
    }
    pub(super) fn preview_dismiss(&mut self, cx: &mut Context<Self>) {
        self.preview.sheet = None;
        self.preview.sheet_history.clear();
        cx.notify();
    }
    pub(super) fn preview_visible(&self, index: usize) -> bool {
        self.flag("show-hidden") || !self.preview.hidden.contains(&index)
    }
    pub(super) fn preview_bottle(&self, index: usize) -> usize {
        self.preview
            .moved
            .get(&index)
            .copied()
            .unwrap_or(GAMES[index].bottle)
    }
    pub(super) fn preview_sort(&self, indices: &mut [usize]) {
        match self.preview.sort {
            1 => indices.sort_by_key(|&i| GAMES[i].title),
            2 => indices.reverse(),
            _ => {}
        }
    }
}
