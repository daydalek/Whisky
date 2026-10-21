//! Application entry, root view composition, and visual-test capture hook.

use std::time::Duration;

use gpui_kit::base::{Presence, Spring, spring};
use gpui_kit::component::theme::{Theme, ThemeMode};
use gpui_kit::{prelude::*, *};

mod bridge;
mod controls;
mod library_layout;
mod model;
#[cfg(feature = "visual-test")]
mod motion_capture;
mod state;
mod theme;
mod views;

use crate::controls::{col, icon, row};
#[cfg(feature = "visual-test")]
use crate::model::demo_data;
use crate::state::{PreviewPage, WhiskyApp};
#[cfg(feature = "visual-test")]
use crate::state::PreviewSheet;
use crate::theme::{ACCENT, BG, DETAIL_MS, NOTICE_MS, SIDEBAR_MS, TEXT};

gpui_kit::actions!(
    whisky_preview,
    [DismissPreview, QuitPreview, ReorderLibrary, ToggleMotion]
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
            self.preview_page(cx)
        } else {
            self.library_page(width, window, cx)
        };
        let presence = Presence::new("detail-presence", self.detail_open)
            .transition(self.timing(DETAIL_MS))
            .sample(window, cx);
        let notification = Presence::new("notice-presence", self.notice)
            .transition(self.timing(NOTICE_MS))
            .sample(window, cx);
        let mut root = row()
            .relative()
            .size_full()
            .items_start()
            .overflow_hidden()
            .bg(rgb(BG))
            .font_family(".AppleSystemUIFont")
            .text_color(rgb(TEXT))
            .text_size(px(13.))
            .on_action(cx.listener(|this, _: &ReorderLibrary, _, cx| {
                if this.preview.page == PreviewPage::Library
                    && !this.settings
                    && !this.detail_open
                    && this.preview.sheet.is_none()
                {
                    this.reorder_library(cx);
                }
            }))
            .on_action(cx.listener(|this, _: &ToggleMotion, _, cx| {
                this.motion = !this.motion;
                cx.notify();
            }))
            .on_action(cx.listener(|this, _: &DismissPreview, _, cx| {
                if this.preview.sheet.is_some() {
                    this.preview_dismiss(cx);
                } else {
                    this.detail_open = false;
                    cx.notify();
                }
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
            root = root.child(self.preview_sheet(sheet, ww, wh, cx));
        }
        if self.bridge_dialog {
            root = root.child(self.bridge_status_dialog(ww, wh, cx));
        }
        if notification.should_render() {
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
                    .child("外观演示 · 未启动游戏，也未修改容器"),
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

fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    if arguments.iter().any(|argument| argument == "--print-bridge-status") {
        std::process::exit(bridge::print_status());
    }
    if arguments.iter().any(|argument| argument == "--print-library") {
        let bottle = match arguments.iter().position(|argument| argument == "--bottle") {
            Some(index) => match arguments.get(index + 1) {
                Some(value) if !value.starts_with("--") => Some(value.as_str()),
                _ => {
                    eprintln!("usage: whisky-gpui --print-library [--bottle <name-or-path>]");
                    std::process::exit(2);
                }
            },
            None => None,
        };
        std::process::exit(bridge::print_library(bottle));
    }
    gpui_kit::application()
        .with_assets(gpui_kit::assets::AllAssets)
        .run(|cx| {
            gpui_kit::init(cx);
            cx.bind_keys([
                KeyBinding::new("escape", DismissPreview, None),
                KeyBinding::new("cmd-q", QuitPreview, None),
                KeyBinding::new("cmd-r", ReorderLibrary, None),
                KeyBinding::new("cmd-shift-m", ToggleMotion, None),
            ]);
            cx.on_action(|_: &QuitPreview, cx| cx.quit());
            Theme::change(ThemeMode::Dark, None, cx);
            cx.on_window_closed(|cx, _| {
                if cx.windows().is_empty() {
                    cx.quit();
                }
            })
            .detach();
            let (_handle, _view) = gpui_kit::open_window(
                WindowOptions {
                    titlebar: Some(TitlebarOptions {
                        title: Some("Whisky".into()),
                        appears_transparent: true,
                        traffic_light_position: Some(point(px(15.), px(21.))),
                    }),
                    window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                        None,
                        size(px(1280.), px(820.)),
                        cx,
                    ))),
                    window_min_size: Some(size(px(800.), px(580.))),
                    ..Default::default()
                },
                cx,
                |window, cx| cx.new(|cx| WhiskyApp::new(window, cx)),
            )
            .expect("Failed to open GPUI preview");
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
