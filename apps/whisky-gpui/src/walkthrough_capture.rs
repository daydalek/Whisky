//! Deterministic route-reader screenshots, enabled only by visual-test.
use super::*;

pub(super) fn run(handle: AnyWindowHandle, view: Entity<WhiskyApp>, cx: &mut App) {
    cx.spawn(async move |cx| {
        let out = std::path::PathBuf::from(std::env::var_os("WHISKY_WALKTHROUGH_CAPTURE").unwrap());
        std::fs::create_dir_all(&out).unwrap();
        for (name, width, section) in [
            ("guide-collapsed", 1280., None),
            ("guide-common", 1280., Some("common")),
            ("guide-save-branch", 900., Some("heroine")),
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
                        let guide: serde_json::Value = serde_json::from_str(include_str!(
                            "../tests/fixtures/nextmoe-walkthrough.json"
                        ))
                        .unwrap();
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
                        this.walkthrough_view.fullscreen = true;
                        this.walkthrough_view.camera = Default::default();
                        this.walkthrough_view.expanded.clear();
                        if section.is_some() {
                            let chart = this.entries[0]
                                .metadata
                                .as_ref()
                                .unwrap()
                                .walkthroughs
                                .as_ref()
                                .unwrap()[0]
                                .chart
                                .as_ref()
                                .unwrap();
                            let tree = crate::walkthrough_tree::Tree::build(
                                chart,
                                scope,
                                false,
                                &Default::default(),
                            );
                            this.walkthrough_view.expanded.extend(
                                tree.nodes
                                    .into_iter()
                                    .filter(|n| n.expandable)
                                    .map(|n| n.key),
                            );
                        }
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
            handle
                .update(cx, |_, _, cx| {
                    view.update(cx, |this, cx| {
                        this.detail_scroll
                            .set_offset(point(px(0.), -this.detail_scroll.max_offset().y));
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
