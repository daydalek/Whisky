//! Native-window regression capture. Available only with `visual-test`.
use super::*;
use std::path::PathBuf;
use crate::library_layout::CardRect;
use crate::state::WhiskyApp;

async fn advance(handle: AnyWindowHandle, cx: &mut AsyncApp, milliseconds: u64) {
    // Pump real render frames even while this test window is in the background.
    for _ in 0..milliseconds.div_ceil(16) {
        cx.background_executor()
            .timer(Duration::from_millis(16))
            .await;
        handle
            .update(cx, |_, window, cx| {
                window.refresh();
                window.draw(cx).clear(cx);
            })
            .unwrap();
    }
}

fn active_scroll(demo: &WhiskyApp, stage: usize) -> ScrollHandle {
    match stage {
        0..=2 => demo.library_scroll[stage].clone(),
        3 => demo.detail_scroll.clone(),
        _ => demo.preview.form_scroll_handle(match stage {
            4 => "app-settings-scroll",
            5 => "run-settings-scroll",
            _ => "bottle-config-scroll",
        }),
    }
}

pub(super) fn run(handle: AnyWindowHandle, view: Entity<WhiskyApp>, cx: &mut App) {
    cx.spawn(async move |cx| {
        let out = PathBuf::from(std::env::var_os("WHISKY_MOTION_CAPTURE").unwrap());
        std::fs::create_dir_all(&out).unwrap();
        let mut report = String::from("surface,edge,stretch_px,residual_px,background_scroll_px\n");
        for (stage, name) in [
            "shelf",
            "timeline",
            "classic",
            "detail",
            "settings",
            "run-settings",
            "bottle-settings",
        ]
        .into_iter()
        .enumerate()
        .filter(|_| std::env::var_os("WHISKY_MOTION_REFLOW_ONLY").is_none())
        {
            handle
                .update(cx, |_, window, cx| {
                    window.resize(size(px(1280.), px(820.)));
                    view.update(cx, |demo, cx| {
                        demo.settings = stage == 4;
                        demo.preview.page = if stage == 6 {
                            PreviewPage::ConfigureBottle
                        } else {
                            PreviewPage::Library
                        };
                        demo.preview.sheet = if stage == 5 {
                            Some(PreviewSheet::RunSettings(0))
                        } else {
                            None
                        };
                        demo.mode = stage.min(2);
                        demo.motion = true;
                        demo.detail_open = false;
                        demo.reversed = false;
                        if stage == 3 {
                            demo.open_detail(0, cx);
                        }
                        cx.notify();
                    });
                })
                .unwrap();
            advance(handle, cx, 1000).await;
            let scroll = handle
                .update(cx, |_, _, cx| active_scroll(view.read(cx), stage))
                .unwrap();
            for (edge, delta) in [("top", 400.), ("bottom", -400.)] {
                handle
                    .update(cx, |_, _, cx| {
                        scroll.set_offset(point(
                            px(0.),
                            if edge == "top" {
                                px(0.)
                            } else {
                                -scroll.max_offset().y
                            },
                        ));
                        view.update(cx, |_, cx| cx.notify());
                    })
                    .unwrap();
                advance(handle, cx, 100).await;
                handle
                    .update(cx, |_, window, cx| {
                        window.refresh();
                        window.draw(cx).clear(cx);
                    })
                    .unwrap();
                // Retained scroll metrics become available during the first prepaint.
                handle
                    .update(cx, |_, window, cx| {
                        window.refresh();
                        window.draw(cx).clear(cx);
                    })
                    .unwrap();
                let before = scroll.bounds().origin.y;
                handle
                    .update(cx, |_, _, cx| {
                        eprintln!(
                            "{name} {edge}: bounds={:?} max={:?} reduced={}",
                            scroll.bounds(),
                            scroll.max_offset(),
                            cx.reduce_motion()
                        )
                    })
                    .unwrap();
                let background = handle
                    .update(cx, |_, _, cx| view.read(cx).library_scroll[2].offset().y)
                    .unwrap();
                handle
                    .update(cx, |_, window, cx| {
                        window
                            .render_to_image()
                            .unwrap()
                            .save(out.join(format!("{name}-{edge}-rest.png")))
                            .unwrap();
                        let position = scroll.bounds().center();
                        window.dispatch_event(
                            PlatformInput::ScrollWheel(ScrollWheelEvent {
                                position,
                                delta: ScrollDelta::Pixels(point(px(0.), px(delta))),
                                touch_phase: TouchPhase::Started,
                                ..Default::default()
                            }),
                            cx,
                        );
                    })
                    .unwrap();
                advance(handle, cx, 80).await;
                handle
                    .update(cx, |_, window, cx| {
                        window.refresh();
                        window.draw(cx).clear(cx);
                    })
                    .unwrap();
                let stretch = f32::from(scroll.bounds().origin.y - before);
                handle
                    .update(cx, |_, window, cx| {
                        window
                            .render_to_image()
                            .unwrap()
                            .save(out.join(format!("{name}-{edge}-stretch.png")))
                            .unwrap();
                        window.dispatch_event(
                            PlatformInput::ScrollWheel(ScrollWheelEvent {
                                position: scroll.bounds().center(),
                                delta: ScrollDelta::Pixels(point(px(0.), px(0.))),
                                touch_phase: TouchPhase::Ended,
                                ..Default::default()
                            }),
                            cx,
                        );
                    })
                    .unwrap();
                advance(handle, cx, 1100).await;
                handle
                    .update(cx, |_, window, cx| {
                        window.refresh();
                        window.draw(cx).clear(cx);
                    })
                    .unwrap();
                let residual = f32::from(scroll.bounds().origin.y - before);
                let background_delta = handle
                    .update(cx, |_, _, cx| {
                        f32::from(view.read(cx).library_scroll[2].offset().y - background)
                    })
                    .unwrap();
                report.push_str(&format!(
                    "{name},{edge},{stretch:.3},{residual:.3},{background_delta:.3}\n"
                ));
                // Write evidence before asserting so failures retain their diagnostics.
                std::fs::write(out.join("scroll.csv"), &report).unwrap();
                assert!(
                    stretch * delta > 0. && stretch.abs() > 1.,
                    "{name} {edge}: missing displacement ({stretch})"
                );
                assert!(
                    residual.abs() < 0.2,
                    "{name} {edge}: unsettled ({residual})"
                );
                if stage >= 3 {
                    assert!(background_delta.abs() < 0.01, "modal scrolled library");
                }
            }
        }
        // Exercise real keyed spring state across reordering and an interrupted return.
        let mut reflow = String::from("layout,moving_cards,max_settled_error_px\n");
        for mode in 0..3 {
            handle
                .update(cx, |_, _, cx| {
                    view.update(cx, |demo, cx| {
                        demo.settings = false;
                        demo.detail_open = false;
                        demo.preview.sheet = None;
                        demo.preview.page = PreviewPage::Library;
                        demo.mode = mode;
                        demo.reversed = false;
                        demo.library_scroll[mode].set_offset(point(px(0.), px(0.)));
                        cx.notify();
                    })
                })
                .unwrap();
            advance(handle, cx, 1100).await;
            let original = handle
                .update(cx, |_, _, cx| view.read(cx).motion_samples.borrow().clone())
                .unwrap();
            handle
                .update(cx, |_, _, cx| {
                    view.update(cx, |demo, cx| demo.reorder_library(cx))
                })
                .unwrap();
            advance(handle, cx, 80).await;
            let midway = handle
                .update(cx, |_, window, cx| {
                    window
                        .render_to_image()
                        .unwrap()
                        .save(out.join(format!("reorder-{mode}-80ms.png")))
                        .unwrap();
                    view.read(cx).motion_samples.borrow().clone()
                })
                .unwrap();
            advance(handle, cx, 1100).await;
            let target = handle
                .update(cx, |_, _, cx| view.read(cx).motion_samples.borrow().clone())
                .unwrap();
            let distance = |a: CardRect, b: CardRect| (a.x - b.x).hypot(a.y - b.y);
            let moving = original
                .iter()
                .filter(|&(id, start)| {
                    distance(*start, midway[id]) > 1. && distance(midway[id], target[id]) > 1.
                })
                .count();
            assert!(
                moving > 0,
                "layout {mode}: missing intermediate spring positions"
            );
            handle
                .update(cx, |_, _, cx| {
                    view.update(cx, |demo, cx| demo.reorder_library(cx))
                })
                .unwrap();
            advance(handle, cx, 80).await;
            handle
                .update(cx, |_, _, cx| {
                    view.update(cx, |demo, cx| demo.reorder_library(cx))
                })
                .unwrap();
            advance(handle, cx, 1200).await;
            let settled = handle
                .update(cx, |_, _, cx| view.read(cx).motion_samples.borrow().clone())
                .unwrap();
            let error = target
                .iter()
                .map(|(id, rect)| distance(*rect, settled[id]))
                .fold(0_f32, f32::max);
            assert!(
                error < 0.2,
                "layout {mode}: interrupted reflow did not settle ({error})"
            );
            reflow.push_str(&format!("{mode},{moving},{error:.3}\n"));
            std::fs::write(out.join("reflow.csv"), &reflow).unwrap();
        }
        cx.update(|cx| cx.quit());
    })
    .detach();
}
