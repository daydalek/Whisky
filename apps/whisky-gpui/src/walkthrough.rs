//! Lossless NextMoe snapshots and graph reading helpers.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub(crate) struct Walkthrough {
    pub(crate) id: String,
    pub(crate) work_id: String,
    pub(crate) source: String,
    pub(crate) source_url: Option<String>,
    pub(crate) source_author: Option<String>,
    pub(crate) source_updated_on: Option<String>,
    pub(crate) lang: String,
    pub(crate) release: Option<Value>,
    #[serde(default)]
    pub(crate) ending_count: usize,
    #[serde(default)]
    pub(crate) save_count: usize,
    #[serde(default)]
    pub(crate) segment_count: usize,
    #[serde(default)]
    pub(crate) work_route_hints: bool,
    pub(crate) chart: Option<Value>,
    #[serde(flatten)]
    pub(crate) extra: std::collections::BTreeMap<String, Value>,
}

#[derive(Default)]
pub(crate) struct WalkthroughView {
    pub(crate) guide: Option<String>,
    pub(crate) expanded: BTreeSet<String>,
    pub(crate) camera: crate::walkthrough_tree::Camera,
    pub(crate) viewport: std::rc::Rc<std::cell::Cell<[f32; 4]>>,
    pub(crate) drag: Option<[f32; 2]>,
    pub(crate) fullscreen: bool,
    pub(crate) original: bool,
    /// Segment key of the route open in the reader.
    pub(crate) route: Option<String>,
    /// Show the node graph instead of the route reader.
    pub(crate) graph: bool,
    pub(crate) route_scroll: gpui_kit::ScrollHandle,
    pub(crate) pending: Option<(String, String)>,
    pub(crate) error: Option<String>,
}

pub(crate) fn field_text<'a>(value: &'a Value, field: &str) -> &'a str {
    value.get(field).and_then(Value::as_str).unwrap_or("")
}

pub(crate) fn items<'a>(value: &'a Value, field: &str) -> &'a [Value] {
    value
        .get(field)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

/// Keep the source wording available next to machine translations.
pub(crate) fn translated(value: &Value, field: &str, original: bool) -> String {
    let raw = field_text(value, field);
    let localized = if field == "condition" {
        "condition_localized"
    } else {
        "localized"
    };
    if !original {
        if let Some(translation) = value.get(localized).and_then(|v| v.get("zh-Hans")) {
            if let Some(label) = translation
                .get("value")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
            {
                let machine = translation
                    .get("is_machine")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                return format!("{label}{}", if machine { " · 机译" } else { "" });
            }
        }
    }
    raw.to_owned()
}

pub(crate) fn node_label(chart: &Value, node: &Value, original: bool) -> String {
    let kind = field_text(node, "node_type");
    let (collection, field, prefix) = match kind {
        "entry" => ("entries", "label", "开始"),
        "save" => ("saves", "label", "存档"),
        "ending" => ("endings", "name", "结局"),
        _ => return format!("节点 {} · {}", kind, field_text(node, "key")),
    };
    let name = items(chart, collection)
        .iter()
        .find(|n| field_text(n, "key") == field_text(node, "key"))
        .map(|n| translated(n, field, original))
        .unwrap_or_else(|| field_text(node, "key").to_owned());
    format!("{prefix} · {name}")
}

/// A save can be produced on several paths; show all source sections in provider order.
pub(crate) fn save_origins<'a>(chart: &'a Value, key: &str) -> Vec<(&'a Value, usize)> {
    items(chart, "segments")
        .iter()
        .flat_map(|segment| {
            items(segment, "steps")
                .iter()
                .enumerate()
                .filter_map(move |(index, step)| {
                    (field_text(step, "step_type") == "save" && field_text(step, "save_key") == key)
                        .then_some((segment, index + 1))
                })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn graph_preserves_shared_saves_duplicate_endings_and_future_steps() {
        let raw = json!({"id":"9", "work_id":"4", "source":"future-source", "lang":"ja",
            "chart":{"sections":[{"key":"a","title":"路线 A"},{"key":"b","title":"路线 B"}],
                "saves":[{"key":"s","label":"SAVE 1"}],
                "endings":[{"key":"e1","name":"END"},{"key":"e2","name":"END"}],
                "segments":[{"key":"g1","section_key":"a","steps":[{"step_type":"save","save_key":"s"}]},
                    {"key":"g2","section_key":"b","from_node":{"node_type":"save","key":"s"},
                    "steps":[{"step_type":"future","new_field":42}]}]}, "new_metadata":true});
        let guide: Walkthrough = serde_json::from_value(raw.clone()).unwrap();
        let chart = guide.chart.as_ref().unwrap();
        let origins = save_origins(chart, "s");
        assert_eq!(origins.len(), 1);
        assert_eq!(field_text(origins[0].0, "section_key"), "a");
        assert_eq!(origins[0].1, 1);
        assert_eq!(
            node_label(chart, &json!({"node_type":"save","key":"s"}), false),
            "存档 · SAVE 1"
        );
        let encoded = serde_json::to_value(guide).unwrap();
        assert_eq!(encoded["chart"], raw["chart"]);
        assert_eq!(encoded["new_metadata"], true);
    }

    #[test]
    fn translation_labels_machine_text_and_retains_original_fallback() {
        let value =
            json!({"text":"選択", "localized":{"zh-Hans":{"value":"选择","is_machine":true}}});
        assert_eq!(translated(&value, "text", false), "选择 · 机译");
        assert_eq!(translated(&value, "text", true), "選択");
        assert_eq!(translated(&json!({"text":"原文"}), "text", false), "原文");
    }
}
