//! Existing-prefix selection uses the same surface and controls as the bottle dialogs.
use crate::container_import::ImportState;
use crate::{controls::*, state::WhiskyApp, theme::*};
use gpui_kit::component::Disableable;
use gpui_kit::component::{
    button::{Button, ButtonVariants},
    switch::Switch,
};
use gpui_kit::{prelude::*, *};

impl WhiskyApp {
    pub(crate) fn begin_import_scan(&mut self, root: Option<String>, cx: &mut Context<Self>) {
        self.import_generation = self.import_generation.wrapping_add(1);
        self.import_bottles = Some(ImportState::scanning(self.import_generation, root.clone()));
        if matches!(
            self.bridge_status,
            crate::bridge::BridgeStatus::Connected { .. }
        ) {
            self.bridge
                .discover_containers(self.import_generation, root);
        } else {
            if let Some(state) = self.import_bottles.as_mut() {
                state.failed(
                    self.import_generation,
                    "桥接尚未连接，请恢复连接后重新扫描".into(),
                );
            }
            self.bridge.retry();
        }
        cx.notify();
    }

    pub(crate) fn import_bottles_view(
        &mut self,
        width: f32,
        height: f32,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(state) = self.import_bottles.as_ref() else {
            return div().into_any_element();
        };
        let busy = state.importing;
        let loading = state.loading;
        let connected = matches!(
            self.bridge_status,
            crate::bridge::BridgeStatus::Connected { .. }
        );
        let request = state.request;
        let selected = state.selection();
        let root = state.root.clone();
        let mut rows: Vec<AnyElement> = Vec::new();
        if loading {
            rows.push(muted("正在扫描已有容器…").into_any_element());
        } else if state.candidates.is_empty() && state.error.is_none() {
            rows.push(muted("当前扫描位置没有待导入的容器").into_any_element());
        }
        for candidate in &state.candidates {
            let path = candidate.path.clone();
            rows.push(
                row()
                    .gap(px(12.))
                    .py(px(12.))
                    .border_b_1()
                    .border_color(rgba(surface_border()))
                    .child(
                        col()
                            .flex_1()
                            .min_w_0()
                            .gap(px(5.))
                            .child(div().truncate().child(candidate.name.clone()))
                            .child(muted(candidate.path.clone()).truncate()),
                    )
                    .child(
                        Switch::new(format!("candidate:{}", candidate.path))
                            .checked(state.selected.contains(&candidate.path))
                            .disabled(busy || loading)
                            .on_change(cx.listener(move |this, checked, _, cx| {
                                if let Some(state) = this.import_bottles.as_mut() {
                                    state.toggle(&path, *checked);
                                }
                                cx.notify();
                            })),
                    )
                    .into_any_element(),
            );
        }
        if let Some(error) = state.error.as_ref() {
            rows.insert(0, muted(error.clone()).into_any_element());
        }
        if let Some(count) = state.completed {
            rows.insert(
                0,
                muted(format!("本次新增 {count} 个容器")).into_any_element(),
            );
        }
        let select_label = if state.candidates.len() > 128 {
            "选中前 128 项"
        } else {
            "全选"
        };
        let count = selected.len();
        let no_candidates = state.candidates.is_empty();
        let pw = 740_f32.min(width - 48.);
        let ph = 620_f32.min(height - 48.);
        div()
            .absolute()
            .inset_0()
            .occlude()
            .bg(rgba(overlay()))
            .on_scroll_wheel(|_, _, cx| cx.stop_propagation())
            .child(
                col()
                    .absolute()
                    .left(px((width - pw) / 2.))
                    .top(px((height - ph) / 2.))
                    .w(px(pw))
                    .h(px(ph))
                    .rounded(px(RADIUS_LG))
                    .overflow_hidden()
                    .bg(rgb(crate::theme::surface()))
                    .border_1()
                    .border_color(rgba(surface_border()))
                    .shadow_xl()
                    .child(
                        row()
                            .h(px(48.))
                            .px(px(18.))
                            .border_b_1()
                            .border_color(rgba(surface_border()))
                            .child(
                                div()
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .child("导入已有容器"),
                            ),
                    )
                    .child(
                        col()
                            .px(px(18.))
                            .py(px(12.))
                            .gap(px(9.))
                            .child(
                                muted(
                                    root.clone()
                                        .unwrap_or_else(|| "扫描默认容器位置及已知容器目录".into()),
                                )
                                .truncate(),
                            )
                            .child(
                                row()
                                    .gap(px(8.))
                                    .child(
                                        Button::new("rescan-candidates")
                                            .label("重新扫描")
                                            .disabled(busy || loading)
                                            .on_click(cx.listener(move |this, _, _, cx| {
                                                this.begin_import_scan(root.clone(), cx);
                                            })),
                                    )
                                    .child(
                                        Button::new("choose-scan-root")
                                            .label("选择扫描目录…")
                                            .disabled(busy || loading)
                                            .on_click(cx.listener(|this, _, _, _| {
                                                this.bridge.choose_path(
                                                    "discover-bottles",
                                                    "folder",
                                                    None,
                                                    None,
                                                    &[],
                                                );
                                            })),
                                    )
                                    .child(
                                        Button::new("choose-one-prefix")
                                            .label("选择容器目录…")
                                            .disabled(busy || loading)
                                            .on_click(cx.listener(|this, _, window, cx| {
                                                this.import_bottles = None;
                                                this.focus_handle.focus(window, cx);
                                                this.bridge.choose_path(
                                                    "import-bottle",
                                                    "folder",
                                                    None,
                                                    None,
                                                    &[],
                                                );
                                                cx.notify();
                                            })),
                                    )
                                    .child(
                                        Button::new("select-candidates")
                                            .label(select_label)
                                            .disabled(busy || loading || no_candidates)
                                            .on_click(cx.listener(|this, _, _, cx| {
                                                if let Some(state) = this.import_bottles.as_mut() {
                                                    let paths = state
                                                        .candidates
                                                        .iter()
                                                        .take(128)
                                                        .map(|candidate| candidate.path.clone())
                                                        .collect::<Vec<_>>();
                                                    state.selected.clear();
                                                    for path in paths {
                                                        state.toggle(&path, true);
                                                    }
                                                }
                                                cx.notify();
                                            })),
                                    ),
                            ),
                    )
                    .child(
                        col()
                            .id("candidate-import-list")
                            .flex_1()
                            .min_h_0()
                            .overflow_y_scroll()
                            .px(px(18.))
                            .children(rows),
                    )
                    .child(
                        row()
                            .justify_end()
                            .gap(px(8.))
                            .px(px(18.))
                            .py(px(13.))
                            .border_t_1()
                            .border_color(rgba(surface_border()))
                            .child(
                                Button::new("close-candidates")
                                    .label("关闭")
                                    .disabled(busy)
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.import_bottles = None;
                                        this.focus_handle.focus(window, cx);
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new("import-candidates")
                                    .label(if busy {
                                        "正在导入…".to_owned()
                                    } else {
                                        format!("导入选中项（{count}）")
                                    })
                                    .primary()
                                    .disabled(busy || loading || count == 0 || !connected)
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        if !matches!(
                                            this.bridge_status,
                                            crate::bridge::BridgeStatus::Connected { .. }
                                        ) {
                                            if let Some(state) = this.import_bottles.as_mut() {
                                                state.failed(
                                                    request,
                                                    "桥接尚未连接，请恢复连接后重新扫描".into(),
                                                );
                                            }
                                            this.bridge.retry();
                                            cx.notify();
                                            return;
                                        }
                                        if let Some(state) = this.import_bottles.as_mut() {
                                            state.importing = true;
                                            state.error = None;
                                        }
                                        this.bridge.import_candidates(request, selected.clone());
                                        cx.notify();
                                    })),
                            ),
                    ),
            )
            .into_any_element()
    }
}
