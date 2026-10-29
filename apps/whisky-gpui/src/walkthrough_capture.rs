//! Deterministic route-reader screenshots, enabled only by visual-test.
use super::*;

pub(super) fn run(handle: AnyWindowHandle, view: Entity<WhiskyApp>, cx: &mut App) {
    cx.spawn(async move |cx| {
        let out = std::path::PathBuf::from(std::env::var_os("WHISKY_WALKTHROUGH_CAPTURE").unwrap());
        std::fs::create_dir_all(&out).unwrap();
        for (name, width, route, graph, fullscreen) in [
            ("guide-warmup", 1280., None, false, true),
            ("guide-routes", 1280., None, false, true),
            ("guide-save-branch", 900., Some("g2"), false, true),
            ("guide-graph", 1280., None, true, true),
            ("guide-inline", 1100., None, false, false),
        ] {
            handle
                .update(cx, |_, window, cx| {
                    window.resize(size(px(width), px(900.)));
                    view.update(cx, |this, cx| {
                        let mut game = crate::model::demo_data()[0].clone();
                        game.id = "route-fixture".into();
                        game.container = "/tmp/route-fixture".into();
                        game.title = "攻略路线 · 视图验收".into();
                        game.description = None;
                        let mut guide: serde_json::Value = serde_json::from_str(include_str!(
                            "../tests/fixtures/nextmoe-walkthrough.json"
                        ))
                        .unwrap();
                        for i in 1..=20 {
                            guide["chart"]["segments"][0]["steps"].as_array_mut().unwrap().push(serde_json::json!({
                                "step_type": "choice",
                                "text": format!("额外测试选项 {i}"),
                                "alternatives": [],
                                "achievement": false
                            }));
                        }
                        game.metadata = Some(
                            serde_json::from_value(serde_json::json!({
                                "source": "nextmoe", "sourceID": "4", "walkthroughs": [guide]
                            }))
                            .unwrap(),
                        );
                        this.demo = false;
                        this.entries = vec![game];
                        this.settings = false;
                        this.loading = false;
                        this.open_detail(0, cx);
                        let scope = "/tmp/route-fixture:route-fixture:4:1";
                        this.walkthrough_view.guide = Some(scope.into());
                        this.walkthrough_view.fullscreen = fullscreen;
                        this.walkthrough_view.camera = Default::default();
                        this.walkthrough_view.expanded.clear();
                        this.walkthrough_view.route = route.map(str::to_owned);
                        this.walkthrough_view.graph = graph;
                        cx.notify();
                    });
                })
                .unwrap();
            for _ in 0..40 {
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
            if !fullscreen {
                handle.update(cx, |_, _, cx| {
                    view.update(cx, |this, cx| {
                        this.detail_scroll.set_offset(point(px(0.), -this.detail_scroll.max_offset().y));
                        cx.notify();
                    });
                }).unwrap();
                for _ in 0..15 {
                    cx.background_executor().timer(Duration::from_millis(16)).await;
                    handle.update(cx, |_, window, cx| {
                        window.refresh();
                        window.draw(cx).clear(cx);
                    }).unwrap();
                }
            }
            let position = handle.update(cx, |_, _, cx| {
                let bounds = view.read(cx).walkthrough_view.route_scroll.bounds();
                point(bounds.origin.x + px(80.), bounds.origin.y + px(80.))
            }).unwrap();
            handle.update(cx, |_, window, cx| {
                window.dispatch_event(PlatformInput::MouseMove(MouseMoveEvent {
                    position,
                    ..Default::default()
                }), cx);
                window.refresh();
                window.draw(cx).clear(cx);
            }).unwrap();
            handle
                .update(cx, |_, window, cx| {
                    window.dispatch_event(
                        gpui_kit::PlatformInput::ScrollWheel(gpui_kit::ScrollWheelEvent {
                            position,
                            delta: gpui_kit::ScrollDelta::Pixels(point(px(0.), px(-200.))),
                            modifiers: Default::default(),
                            touch_phase: gpui_kit::TouchPhase::Moved,
                        }),
                        cx,
                    );
                    view.update(cx, |this, cx| {
                        if name != "guide-warmup" && !graph && route.is_none() {
                            assert!(this.walkthrough_view.route_scroll.max_offset().y > px(0.), "{name}: fixture must overflow");
                            assert!(this.walkthrough_view.route_scroll.offset().y < px(0.), "{name}: route page did not scroll");
                        }
                        cx.notify();
                    });
                })
                .unwrap();
            for _ in 0..15 {
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
            handle
                .update(cx, |_, window, _| {
                    window
                        .render_to_image()
                        .unwrap()
                        .save(out.join(format!("{name}.png")))
                        .unwrap();
                })
                .unwrap();
        }
        cx.update(|cx| cx.quit());
    })
    .detach();
}
