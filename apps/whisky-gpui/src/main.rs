//! Application entry, root view composition, and visual-test capture hook.

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

use gpui_kit::base::{Presence, Spring, spring};
use gpui_kit::component::theme::{Theme, ThemeMode};
use gpui_kit::{prelude::*, *};

mod bridge;
mod config;
mod controls;
mod create_bottle;
mod container_import;
mod library_layout;
mod library_view;
mod model;
mod platform;
#[cfg(feature = "visual-test")]
mod motion_capture;
mod preferences;
mod processes;
mod program_settings;
mod programs;
mod runtime;
mod scan;
mod state;
mod theme;
mod ui_state;
mod views;
mod winetricks;

use crate::controls::{col, icon, row};
#[cfg(feature = "visual-test")]
use crate::model::demo_data;
use crate::state::{PreviewPage, WhiskyApp};
#[cfg(feature = "visual-test")]
use crate::state::PreviewSheet;
use crate::theme::{ACCENT, BG, DETAIL_MS, NOTICE_MS, SIDEBAR_MS, TEXT};

gpui_kit::actions!(
    whisky_preview,
    [
        DismissPreview,
        QuitPreview,
        ToggleMotion,
        RefreshLibrary,
        ShowAbout,
        ShowSettings,
        ToggleSidebar,
        MinimizeWindow,
        ZoomWindow,
        ToggleFullScreen
    ]
);

impl Render for WhiskyApp {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.scroll_needs_measurement.set(false);
        let ww = f32::from(window.viewport_size().width);
        let wh = f32::from(window.viewport_size().height);
        let sw = spring(
            "sidebar-width",
            if self.sidebar { 200_f32 } else { 0. },
            Spring::new(Duration::from_millis(SIDEBAR_MS))
                .with_epsilon(0.1)
                .with_travel(self.motion),
            window,
            cx,
        );
        let width = ww - sw;
        let backdrop = self.backdrop(window, cx);
        let body = if self.settings {
            self.application_settings(cx)
        } else if self.preview.page != PreviewPage::Library {
            self.preview_page(window, cx)
        } else {
            self.library_page(width, window, cx)
        };
        let presence = Presence::new("detail-presence", self.detail_open)
            .transition(self.timing(DETAIL_MS))
            .sample(window, cx);
        let notification = Presence::new("notice-presence", self.notice.is_some())
            .transition(self.timing(NOTICE_MS))
            .sample(window, cx);
        let mut root = row()
            .track_focus(&self.focus_handle)
            .relative()
            .size_full()
            .items_start()
            .overflow_hidden()
            .bg(rgb(BG))
            .font_family(platform::UI_FONT)
            .text_color(rgb(TEXT))
            .text_size(px(13.))
            .on_drop(cx.listener(|this, paths: &ExternalPaths, _, cx| {
                if let Some(path) = paths.0.first() {
                    this.open_external_file(path.clone(), cx);
                }
            }))
            .on_action(cx.listener(|this, _: &ToggleMotion, _, cx| {
                this.motion = !this.motion;
                cx.notify();
            }))
            .on_action(cx.listener(|this, _: &RefreshLibrary, _, cx| {
                if this.demo {
                    this.show_notice(crate::state::DEMO_NOTICE, cx);
                } else {
                    this.refresh_library(cx);
                }
            }))
            .on_action(cx.listener(|this, _: &ShowAbout, _, cx| this.show_about(cx)))
            .on_action(cx.listener(|this, _: &ShowSettings, _, cx| this.open_settings(cx)))
            .on_action(cx.listener(|this, _: &ToggleSidebar, _, cx| {
                this.sidebar = !this.sidebar;
                cx.notify();
            }))
            .on_action(cx.listener(|this, _: &QuitPreview, window, cx| {
                this.request_quit(window, cx);
            }))
            .on_action(cx.listener(|_, _: &MinimizeWindow, window, _| {
                window.minimize_window();
            }))
            .on_action(cx.listener(|_, _: &ZoomWindow, window, _| {
                window.zoom_window();
            }))
            .on_action(cx.listener(|_, _: &ToggleFullScreen, window, _| {
                window.toggle_fullscreen();
            }))
            .on_action(cx.listener(|this, _: &DismissPreview, window, cx| {
                if this.import_bottles.is_some() {
                    if !this.import_bottles.as_ref().is_some_and(|state| state.importing) {
                        this.import_bottles = None;
                    }
                } else if this.bottle_dialog.is_some() {
                    this.dismiss_bottle_dialog(cx);
                } else if this.setup_dialog && !this.setup_installing {
                    this.dismiss_setup(cx);
                } else if this.about {
                    this.about = false;
                } else if this.preview.sheet.is_some() {
                    this.preview_dismiss(cx);
                } else {
                    this.detail_open = false;
                }
                this.focus_handle.focus(window, cx);
                cx.notify();
            }))
            .child(
                div()
                    .w(px(sw))
                    .min_w(px(sw))
                    .h_full()
                    .overflow_hidden()
                    .flex_shrink_0()
                    .child(div().w(px(200.)).h_full().child(self.sidebar(cx))),
            )
            .child(
                col()
                    .relative()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .child(backdrop)
                    .child(div().relative().child(self.toolbar(cx)))
                    .child(div().relative().flex_1().min_h_0().w_full().child(body)),
            );
        if presence.should_render() {
            if let Some(index) = self.detail {
                root = root.child(self.detail_panel(index, presence.progress, ww, wh, cx));
            }
        }
        if let Some(sheet) = self.preview.sheet {
            root = root.child(self.preview_sheet(sheet, ww, wh, window, cx));
        }
        if self.bridge_dialog {
            root = root.child(self.bridge_status_dialog(ww, wh, cx));
        }
        if self.clipboard_prompt.is_some() {
            root = root.child(self.clipboard_dialog(ww, wh, cx));
        }
        if self.bottle_dialog.is_some() {
            root = root.child(self.bottle_dialog_view(ww, wh, window, cx));
        }
        if self.import_bottles.is_some() {
            root = root.child(self.import_bottles_view(ww, wh, cx));
        }
        if self.setup_dialog {
            root = root.child(self.setup_dialog_view(ww, wh, cx));
        }
        if self.about {
            root = root.child(self.about_dialog(ww, wh, cx));
        }
        if notification.should_render() {
            let message = self.notice.clone().unwrap_or_default();
            root = root.child(
                row()
                    .absolute()
                    .bottom(px(24.))
                    .left(px(sw + 24.))
                    .gap(px(8.))
                    .px(px(16.))
                    .py(px(12.))
                    .rounded(px(12.))
                    .bg(rgb(0x3b3b40))
                    .border_1()
                    .border_color(rgba(0xffffff20))
                    .shadow_lg()
                    .opacity(notification.progress)
                    .child(icon("info", 16.).text_color(rgb(ACCENT)))
                    .child(message),
            );
        }
        if self.scroll_needs_measurement.get() {
            window.request_animation_frame();
        }
        root
    }
}
#[cfg(feature = "visual-test")]
fn capture_preview(handle: AnyWindowHandle, view: Entity<WhiskyApp>, cx: &mut App) {
    cx.spawn(async move |cx| {
        let out = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("screenshots");
        std::fs::create_dir_all(&out).unwrap();
        let names = [
            "library",
            "timeline",
            "details",
            "settings",
            "compact",
            "classic",
            "bottle",
            "configure-bottle",
            "programs",
            "run-settings",
            "scan-settings",
            "winetricks",
            "compact-bottle",
        ];
        for (stage, name) in names.into_iter().enumerate() {
            handle
                .update(cx, |_, window, cx| {
                    view.update(cx, |this, cx| {
                        this.settings = false;
                        this.detail_open = false;
                        this.preview.sheet = None;
                        this.preview.page = PreviewPage::Library;
                        this.mode = 0;
                        this.selected_bottle = None;
                        match stage {
                            0 => window.resize(size(px(1280.), px(820.))),
                            1 => this.mode = 1,
                            2 => {
                                this.mode = 1;
                                this.open_detail(
                                    demo_data()
                                        .iter()
                                        .position(|g| g.title.starts_with("Saltlight"))
                                        .unwrap(),
                                    cx,
                                );
                            }
                            3 => this.settings = true,
                            4 => window.resize(size(px(900.), px(650.))),
                            5 => this.mode = 2,
                            6 => {
                                window.resize(size(px(1280.), px(820.)));
                                this.selected_bottle = Some(0);
                                this.preview.page = PreviewPage::Bottle;
                            }
                            7 => {
                                this.selected_bottle = Some(0);
                                this.preview.page = PreviewPage::ConfigureBottle;
                            }
                            8 => {
                                this.selected_bottle = Some(0);
                                this.preview.page = PreviewPage::Programs;
                            }
                            9 => this.open_preview_sheet(PreviewSheet::RunSettings(0), cx),
                            10 => this.open_preview_sheet(PreviewSheet::Scan, cx),
                            11 => this.open_preview_sheet(PreviewSheet::Winetricks, cx),
                            _ => {
                                window.resize(size(px(800.), px(580.)));
                                this.selected_bottle = Some(0);
                                this.preview.page = PreviewPage::ConfigureBottle;
                            }
                        }
                        cx.notify();
                    });
                })
                .unwrap();
            cx.background_executor()
                .timer(Duration::from_millis(750))
                .await;
            handle
                .update(cx, |_, window, _| {
                    window
                        .render_to_image()
                        .expect("GPU capture failed")
                        .save(out.join(format!("{name}.png")))
                        .unwrap();
                })
                .unwrap();
        }
        cx.update(|cx| cx.quit());
    })
    .detach();
}

/// Value following `flag`, if the flag is present. `None` when absent, `Err`
/// when the flag has no value (so the caller can print usage).
fn cli_value<'a>(arguments: &'a [String], flag: &str) -> Result<Option<&'a str>, ()> {
    match arguments.iter().position(|argument| argument == flag) {
        Some(index) => match arguments.get(index + 1) {
            Some(value) if !value.starts_with("--") => Ok(Some(value.as_str())),
            _ => Err(()),
        },
        None => Ok(None),
    }
}

/// Native menu bar. GPUI does not add the standard macOS app menu, so About,
/// Settings and Quit are declared explicitly; text fields rely on the Editing
/// OS actions for their standard shortcuts.
fn install_menus(cx: &mut App) {
    cx.set_menus(vec![
        Menu::new("Whisky").items(vec![
            MenuItem::action("关于 Whisky", ShowAbout),
            MenuItem::separator(),
            MenuItem::action("设置…", ShowSettings),
            MenuItem::separator(),
            MenuItem::action("退出 Whisky", QuitPreview),
        ]),
        Menu::new("编辑").items(vec![
            MenuItem::os_action("撤销", NoAction, OsAction::Undo),
            MenuItem::os_action("重做", NoAction, OsAction::Redo),
            MenuItem::separator(),
            MenuItem::os_action("剪切", NoAction, OsAction::Cut),
            MenuItem::os_action("复制", NoAction, OsAction::Copy),
            MenuItem::os_action("粘贴", NoAction, OsAction::Paste),
            MenuItem::os_action("全选", NoAction, OsAction::SelectAll),
        ]),
        Menu::new("显示").items(vec![
            MenuItem::action("刷新游戏库", RefreshLibrary),
            MenuItem::separator(),
            MenuItem::action("显示/隐藏侧边栏", ToggleSidebar),
            MenuItem::separator(),
            MenuItem::action("设置…", ShowSettings),
        ]),
        Menu::new("窗口").items(vec![
            MenuItem::action("最小化", MinimizeWindow),
            MenuItem::action("缩放", ZoomWindow),
            MenuItem::separator(),
            MenuItem::action("进入全屏幕", ToggleFullScreen),
        ]),
    ]);
}

fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments.iter().any(|argument| argument == "--print-bridge-status") {
        std::process::exit(bridge::print_status());
    }
    if arguments.iter().any(|argument| argument == "--print-runtime") {
        std::process::exit(bridge::print_runtime());
    }
    if arguments.iter().any(|argument| argument == "--print-config") {
        const USAGE: &str = "usage: whisky-gpui --print-config [--bottle <name-or-path>]";
        let bottle = match cli_value(&arguments, "--bottle") {
            Ok(bottle) => bottle,
            Err(()) => {
                eprintln!("{USAGE}");
                std::process::exit(2);
            }
        };
        std::process::exit(bridge::print_config(bottle));
    }
    if arguments.iter().any(|argument| argument == "--print-folders") {
        const USAGE: &str = "usage: whisky-gpui --print-folders [--bottle <name-or-path>]";
        let bottle = match cli_value(&arguments, "--bottle") {
            Ok(bottle) => bottle,
            Err(()) => {
                eprintln!("{USAGE}");
                std::process::exit(2);
            }
        };
        std::process::exit(bridge::print_folders(bottle));
    }
    if arguments.iter().any(|argument| argument == "--print-winetricks") {
        const USAGE: &str = "usage: whisky-gpui --print-winetricks [--bottle <name-or-path>]";
        let bottle = match cli_value(&arguments, "--bottle") {
            Ok(bottle) => bottle,
            Err(()) => {
                eprintln!("{USAGE}");
                std::process::exit(2);
            }
        };
        std::process::exit(bridge::print_winetricks(bottle));
    }
    if arguments.iter().any(|argument| argument == "--print-programs") {
        const USAGE: &str = "usage: whisky-gpui --print-programs [--bottle <name-or-path>]";
        let bottle = match cli_value(&arguments, "--bottle") {
            Ok(bottle) => bottle,
            Err(()) => {
                eprintln!("{USAGE}");
                std::process::exit(2);
            }
        };
        std::process::exit(bridge::print_programs(bottle));
    }
    if arguments.iter().any(|argument| argument == "--print-processes") {
        const USAGE: &str = "usage: whisky-gpui --print-processes [--bottle <name-or-path>]";
        let bottle = match cli_value(&arguments, "--bottle") {
            Ok(bottle) => bottle,
            Err(()) => {
                eprintln!("{USAGE}");
                std::process::exit(2);
            }
        };
        std::process::exit(bridge::print_processes(bottle));
    }
    if arguments.iter().any(|argument| argument == "--runtime-watch") {
        const USAGE: &str =
            "usage: whisky-gpui --runtime-watch [--seconds N] [--bottle <name-or-path>]";
        let seconds = match cli_value(&arguments, "--seconds") {
            Ok(Some(raw)) => match raw.parse::<u64>() {
                Ok(seconds) => seconds,
                Err(_) => {
                    eprintln!("{USAGE}");
                    std::process::exit(2);
                }
            },
            Ok(None) => 5,
            Err(()) => {
                eprintln!("{USAGE}");
                std::process::exit(2);
            }
        };
        let bottle = match cli_value(&arguments, "--bottle") {
            Ok(bottle) => bottle,
            Err(()) => {
                eprintln!("{USAGE}");
                std::process::exit(2);
            }
        };
        std::process::exit(bridge::watch_runtime(bottle, seconds));
    }
    if arguments.iter().any(|argument| argument == "--diagnose-launch") {
        const USAGE: &str =
            "usage: whisky-gpui --diagnose-launch --bottle <name-or-path> [--entry <substring>]";
        let bottle = match cli_value(&arguments, "--bottle") {
            Ok(Some(bottle)) => Some(bottle),
            Ok(None) => {
                eprintln!("{USAGE}");
                std::process::exit(2);
            }
            Err(()) => {
                eprintln!("{USAGE}");
                std::process::exit(2);
            }
        };
        let entry = match cli_value(&arguments, "--entry") {
            Ok(entry) => entry,
            Err(()) => {
                eprintln!("{USAGE}");
                std::process::exit(2);
            }
        };
        std::process::exit(bridge::diagnose_launch(bottle, entry));
    }
    if arguments.iter().any(|argument| argument == "--print-library") {
        let all = arguments.iter().any(|argument| argument == "--all");
        let bottle = match arguments.iter().position(|argument| argument == "--bottle") {
            Some(index) => match arguments.get(index + 1) {
                Some(value) if !value.starts_with("--") => Some(value.as_str()),
                _ => {
                    eprintln!(
                        "usage: whisky-gpui --print-library [--bottle <name-or-path>] [--all]"
                    );
                    std::process::exit(2);
                }
            },
            None => None,
        };
        std::process::exit(bridge::print_library(bottle, all));
    }
    let pending_urls: Rc<RefCell<Vec<PathBuf>>> = Rc::new(RefCell::new(Vec::new()));
    let url_dispatch: Rc<RefCell<Option<Box<dyn FnMut(Vec<PathBuf>)>>>> =
        Rc::new(RefCell::new(None));
    let application = gpui_kit::application().with_assets(gpui_kit::assets::AllAssets);
    {
        let pending_urls = pending_urls.clone();
        let url_dispatch = url_dispatch.clone();
        application.on_open_urls(move |urls| {
            let paths = urls
                .iter()
                .map(|raw| ui_state::path_from_open_url(raw))
                .collect::<Vec<_>>();
            if let Some(dispatch) = url_dispatch.borrow_mut().as_mut() {
                dispatch(paths);
            } else {
                // The launch URL can arrive before the window exists.
                pending_urls.borrow_mut().extend(paths);
            }
        });
    }
    application.run(move |cx| {
            gpui_kit::init(cx);
            cx.bind_keys([
                KeyBinding::new("escape", DismissPreview, None),
                KeyBinding::new(platform::SHORTCUTS[0], QuitPreview, None),
                KeyBinding::new(platform::SHORTCUTS[1], RefreshLibrary, None),
                KeyBinding::new(platform::SHORTCUTS[2], ToggleMotion, None),
                KeyBinding::new(platform::SHORTCUTS[3], ShowSettings, None),
                KeyBinding::new(platform::SHORTCUTS[4], ToggleSidebar, None),
                KeyBinding::new(platform::SHORTCUTS[5], MinimizeWindow, None),
            ]);
            install_menus(cx);
            Theme::change(ThemeMode::Dark, None, cx);
            cx.on_window_closed(|cx, _| {
                if cx.windows().is_empty() {
                    cx.quit();
                }
            })
            .detach();
            let bounds = ui_state::initial_window_bounds(cx);
            let (_handle, _view) = gpui_kit::open_window(
                WindowOptions {
                    titlebar: Some(TitlebarOptions {
                        title: Some("Whisky".into()),
                        appears_transparent: true,
                        traffic_light_position: Some(point(px(15.), px(21.))),
                    }),
                    window_bounds: Some(bounds),
                    window_min_size: Some(size(px(800.), px(580.))),
                    ..Default::default()
                },
                cx,
                |window, cx| cx.new(|cx| WhiskyApp::new(window, cx)),
            )
            .expect("Failed to open GPUI preview");
            let async_cx = cx.to_async();
            let url_view = _view.clone();
            for path in std::mem::take(&mut *pending_urls.borrow_mut()) {
                let _ = url_view.update(cx, |this, cx| this.open_external_file(path, cx));
            }
            *url_dispatch.borrow_mut() = Some(Box::new(move |paths| {
                let cx = async_cx.clone();
                let view = url_view.clone();
                cx.update(|cx| {
                    let _ = view.update(cx, |this, cx| {
                        for path in paths {
                            this.open_external_file(path, cx);
                        }
                    });
                });
            }));
            cx.activate(true);
            #[cfg(feature = "visual-test")]
            if std::env::var_os("WHISKY_MOTION_CAPTURE").is_some() {
                motion_capture::run(_handle, _view.clone(), cx);
            }
            #[cfg(feature = "visual-test")]
            if std::env::var_os("WHISKY_DEMO_CAPTURE").is_some() {
                capture_preview(_handle, _view, cx);
            }
        });
}
