//! A per-entry draft. Search results never write storage: only explicit Save
//! commits the selected platform IDs, category policy and manual text.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};

use gpui_kit::component::input::InputState;
use gpui_kit::{prelude::*, *};
use serde_json::{Value, json};

use crate::state::WhiskyApp;

static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

pub(crate) const PROVIDERS: &[(&str, &str)] = &[
    ("steam", "Steam"),
    ("bangumi", "Bangumi"),
    ("vndb", "VNDB"),
    ("ymgal", "月幕"),
];
pub(crate) const CATEGORIES: &[(&str, &str)] = &[
    ("basic", "基本信息"),
    ("summary", "简介"),
    ("cover", "封面"),
    ("characters", "角色"),
];

/// Accept only a provider's known work URL or stable ID, never search text or
/// a URL whose host merely contains the provider's name.
pub(crate) fn platform_id(source: &str, input: &str) -> Option<String> {
    let input = input.trim();
    let id = if let Some(url) = input.strip_prefix("https://").or_else(|| input.strip_prefix("http://")) {
        let (host, path) = url.split_once('/')?;
        let path = path.split(['?', '#']).next()?.trim_end_matches('/');
        match source {
            "steam" if matches!(host, "store.steampowered.com" | "steamcommunity.com") =>
                path.strip_prefix("app/")?.split('/').next()?,
            "bangumi" if matches!(host, "bgm.tv" | "bangumi.tv" | "chii.in") =>
                path.strip_prefix("subject/")?,
            "vndb" if matches!(host, "vndb.org" | "www.vndb.org") => path,
            "ymgal" if matches!(host, "ymgal.games" | "www.ymgal.games") =>
                path.strip_prefix("ga")?,
            _ => return None,
        }
    } else { input };
    let digits = match source {
        "vndb" => id.strip_prefix('v').unwrap_or(id),
        "ymgal" => id.strip_prefix("ga").unwrap_or(id),
        "steam" | "bangumi" => id,
        _ => return None,
    };
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit())
        || digits.bytes().all(|byte| byte == b'0') {
        return None;
    }
    let digits = digits.trim_start_matches('0');
    Some(if source == "vndb" { format!("v{digits}") } else { digits.into() })
}

pub(crate) struct MetadataEditor {
    pub(crate) generation: u64,
    /// Monotonic within this editor generation; allocated before dispatch.
    pub(crate) search_request: u64,
    pub(crate) record: Value,
    pub(crate) saved: Value,
    pub(crate) capabilities: Value,
    pub(crate) loaded: bool,
    pub(crate) busy: bool,
    pub(crate) search_source: String,
    pub(crate) search_queries: BTreeMap<String, String>,
    pub(crate) inputs: BTreeMap<&'static str, Entity<InputState>>,
    pub(crate) message: Option<String>,
    pub(crate) characters_expanded: bool,
}

impl Default for MetadataEditor {
    fn default() -> Self {
        Self {
            generation: NEXT_GENERATION.fetch_add(1, Ordering::Relaxed),
            search_request: 0,
            record: json!({}),
            saved: json!({}),
            capabilities: json!({}),
            loaded: false,
            busy: false,
            search_source: "steam".into(),
            search_queries: BTreeMap::new(),
            inputs: BTreeMap::new(),
            message: None,
            characters_expanded: false,
        }
    }
}

impl MetadataEditor {
    /// The network allow-list does not forbid using already local metadata.
    pub(crate) fn policy_sources(&self, mut allowed: Vec<String>) -> Vec<String> {
        for &(source, _) in PROVIDERS {
            if self.record["bindings"][source].is_string()
                || self.record["snapshots"][source].is_object() {
                if !allowed.iter().any(|enabled| enabled == source) {
                    allowed.push(source.into());
                }
            }
        }
        allowed
    }

    pub(crate) fn switch_search_source(&mut self, source: &str, current_query: Option<String>) {
        if let Some(query) = current_query {
            self.search_queries.insert(self.search_source.clone(), query);
        }
        self.search_source = source.into();
    }

    pub(crate) fn manual_enabled(&self, field: &str) -> bool {
        self.record[field].is_string()
    }

    /// Empty is an intentional local override, not "inherit".
    pub(crate) fn set_manual(&mut self, field: &str, value: Option<&str>) {
        match value {
            Some(value) => self.record[field] = json!(value),
            None => {
                if let Some(record) = self.record.as_object_mut() {
                    record.remove(field);
                }
            }
        }
    }

    pub(crate) fn effective_source(&self, category: &str) -> &str {
        let source = self.source(category);
        if source.is_empty() { self.source("default") } else { source }
    }

    pub(crate) fn accept_reply(&mut self, reply: &Value) -> Result<(), String> {
        let record = &reply["record"];
        if !record.is_object() || !record["defaultSource"].is_string() {
            return Err("桥接服务返回了无效的资料配置；未覆盖草稿".into());
        }
        self.capabilities = reply["capabilities"].clone();
        self.record = record.clone();
        self.saved = self.record.clone();
        self.loaded = true;
        self.inputs.clear();
        Ok(())
    }

    pub(crate) fn source(&self, category: &str) -> &str {
        if category == "default" {
            self.record["defaultSource"].as_str().unwrap_or("steam")
        } else {
            self.record["categorySources"][category].as_str().unwrap_or("")
        }
    }

    pub(crate) fn set_source(&mut self, category: &str, source: &str) {
        if category == "default" {
            self.record["defaultSource"] = json!(source);
        } else if source.is_empty() {
            if let Some(overrides) = self.record["categorySources"].as_object_mut() {
                overrides.remove(category);
            }
        } else {
            self.record["categorySources"][category] = json!(source);
        }
    }

    /// IDs, not translated/display titles, define the remote work.
    pub(crate) fn bind(&mut self, source: &str, snapshot: Value) -> Result<(), String> {
        let id = snapshot["sourceID"].as_str().filter(|id| !id.trim().is_empty())
            .ok_or("此结果缺少平台 ID，无法安全关联")?.to_owned();
        if snapshot["source"].as_str() != Some(source) {
            return Err("结果的平台与搜索来源不一致".into());
        }
        // Search hits are summaries. Re-selecting the same work must not
        // replace hydrated details (especially characters) with that summary.
        if self.record["bindings"][source].as_str() == Some(&id)
            && self.record["snapshots"][source]["sourceID"].as_str() == Some(&id) {
            return Ok(());
        }
        self.record["bindings"][source] = json!(id);
        self.record["snapshots"][source] = snapshot;
        Ok(())
    }
}

impl WhiskyApp {
    pub(crate) fn metadata_search_input(
        &mut self, window: &mut Window, cx: &mut Context<Self>,
    ) -> Entity<InputState> {
        let page = self.game_info.as_mut().expect("game info is open");
        if let Some(input) = &page.input { return input.clone(); }
        let value = page.editor.search_queries.get(&page.editor.search_source)
            .cloned().unwrap_or_else(|| page.title.clone());
        let input = cx.new(|cx| InputState::new(window, cx)
            .placeholder("搜索名称，或粘贴作品 ID / 网址")
            .default_value(value));
        page.input = Some(input.clone());
        input
    }

    pub(crate) fn toggle_metadata_manual(
        &mut self, field: &'static str, enabled: bool, cx: &mut Context<Self>,
    ) {
        let Some(page) = self.game_info.as_mut() else { return; };
        if !page.editor.loaded || page.editor.busy { return; }
        let value = page.editor.inputs.get(field)
            .map(|input| input.read(cx).value().to_string())
            .unwrap_or_default();
        page.editor.set_manual(field, enabled.then_some(value.as_str()));
        cx.notify();
    }

    pub(crate) fn bind_metadata_id(&mut self, cx: &mut Context<Self>) {
        let Some(page) = self.game_info.as_mut() else { return; };
        if !page.editor.loaded || page.editor.busy || page.searching { return; }
        let input = page.input.as_ref().map(|input| input.read(cx).value().to_string()).unwrap_or_default();
        let source = page.editor.search_source.clone();
        let Some(id) = platform_id(&source, &input) else {
            page.error = Some("请输入所选平台的作品 ID 或作品页面网址；关联不会按标题猜测。".into());
            cx.notify();
            return;
        };
        if page.editor.record["bindings"][&source].as_str() != Some(&id) {
            if let Some(snapshots) = page.editor.record["snapshots"].as_object_mut() {
                snapshots.remove(&source);
            }
        }
        page.editor.record["bindings"][&source] = json!(id);
        page.error = None;
        page.editor.message = Some("平台 ID 已加入草稿；保存后刷新以获取资料。".into());
        cx.notify();
    }

    pub(crate) fn metadata_editor_input(
        &mut self, field: &'static str, window: &mut Window, cx: &mut Context<Self>,
    ) -> Entity<InputState> {
        let page = self.game_info.as_mut().expect("game info is open");
        if let Some(input) = page.editor.inputs.get(field) {
            return input.clone();
        }
        let value = page.editor.record[field].as_str().unwrap_or("").to_owned();
        let input = cx.new(|cx| InputState::new(window, cx)
            .placeholder("可留空；关闭手动编辑以恢复来源")
            .default_value(value));
        cx.observe(&input, |_, _, cx| cx.notify()).detach();
        page.editor.inputs.insert(field, input.clone());
        input
    }

    pub(crate) fn set_metadata_source(&mut self, category: &str, source: &str, cx: &mut Context<Self>) {
        if let Some(page) = self.game_info.as_mut() {
            if page.editor.loaded && !page.editor.busy {
                page.editor.set_source(category, source);
            }
        }
        cx.notify();
    }

    pub(crate) fn set_metadata_search_source(&mut self, source: &str, cx: &mut Context<Self>) {
        if let Some(page) = self.game_info.as_mut() {
            if !page.searching && !page.editor.busy {
                let query = page.input.take().map(|input| input.read(cx).value().to_string());
                page.editor.switch_search_source(source, query);
                page.groups.clear();
            }
        }
        cx.notify();
    }

    pub(crate) fn unbind_metadata_source(&mut self, source: &str, cx: &mut Context<Self>) {
        if let Some(page) = self.game_info.as_mut() {
            if page.editor.loaded && !page.editor.busy {
                if let Some(bindings) = page.editor.record["bindings"].as_object_mut() {
                    bindings.remove(source);
                }
                if let Some(snapshots) = page.editor.record["snapshots"].as_object_mut() {
                    snapshots.remove(source);
                }
            }
        }
        cx.notify();
    }

    pub(crate) fn save_metadata_editor(&mut self, cx: &mut Context<Self>) {
        if !self.service_available("metadata.configuration.save") { return; }
        let sources = if self.flag("offline") { Vec::new() } else { self.metadata_sources() };
        let Some(page) = self.game_info.as_mut() else { return; };
        if !page.editor.loaded || page.editor.busy { return; }
        for (&field, input) in &page.editor.inputs {
            if page.editor.manual_enabled(field) {
                page.editor.record[field] = json!(input.read(cx).value().to_string());
            }
        }
        page.editor.busy = true;
        page.error = None;
        self.bridge.metadata_record(&page.container, &page.entry_id,
            page.editor.generation, "save", Some(page.editor.record.clone()), Some(sources));
        cx.notify();
    }

    pub(crate) fn load_metadata_editor(&mut self, cx: &mut Context<Self>) {
        let available = self.service_available("metadata.configuration.get");
        let Some(page) = self.game_info.as_mut() else { return; };
        if !available {
            page.error = Some("当前服务不支持分来源资料编辑，请更新桥接服务。未修改现有资料。".into());
        } else {
            page.editor.busy = true;
            self.bridge.metadata_record(&page.container, &page.entry_id,
                page.editor.generation, "get", None, None);
        }
        cx.notify();
    }

    pub(crate) fn metadata_editor_dirty(&self, cx: &Context<Self>) -> bool {
        self.game_info.as_ref().is_some_and(|page| {
            page.editor.record != page.editor.saved || page.editor.inputs.iter().any(|(field, input)| {
                page.editor.manual_enabled(field) && input.read(cx).value().as_ref()
                    != page.editor.saved[*field].as_str().unwrap_or("")
            })
        })
    }

    pub(crate) fn refresh_metadata_editor(&mut self, cx: &mut Context<Self>) {
        if !self.service_available("metadata.refresh") || self.metadata_editor_dirty(cx) || self.flag("offline") {
            return;
        }
        let sources = self.metadata_sources();
        if sources.is_empty() { return; }
        let Some(page) = self.game_info.as_mut() else { return; };
        if !page.editor.loaded || page.editor.busy { return; }
        let sources = sources.into_iter().filter(|source|
            page.editor.record["bindings"][source].is_string()
                && page.editor.capabilities[source]["refresh"].as_bool() == Some(true))
            .collect::<Vec<_>>();
        if sources.is_empty() { return; }
        page.editor.busy = true;
        page.error = None;
        self.bridge.metadata_record(&page.container, &page.entry_id,
            page.editor.generation, "refresh", None, Some(sources));
        cx.notify();
    }

    pub(crate) fn metadata_record_result(
        &mut self, container: String, entry_id: String, generation: u64,
        operation: String, result: Result<Value, String>, cx: &mut Context<Self>,
    ) {
        // A save still updates the library if its editor was dismissed.
        if operation != "get" && result.is_ok() {
            self.bridge.load_entries(&container);
        }
        let allowed = self.metadata_sources();
        let Some(page) = self.game_info.as_mut().filter(|page|
            page.container == container && page.entry_id == entry_id
                && page.editor.generation == generation) else { return; };
        page.editor.busy = false;
        match result {
            Ok(reply) => {
                if let Err(reason) = page.editor.accept_reply(&reply) {
                    page.error = Some(reason);
                    cx.notify();
                    return;
                }
                if operation == "get" {
                    let preferred = page.editor.source("default");
                    page.editor.search_source = allowed.iter().find(|source| *source == preferred)
                        .or_else(|| allowed.first()).cloned().unwrap_or_else(|| preferred.into());
                }
                page.error = reply["errors"].as_object().filter(|errors| !errors.is_empty())
                    .map(|errors| errors.iter().map(|(source, error)| format!("{source}: {}", error.as_str().unwrap_or("刷新失败")))
                        .collect::<Vec<_>>().join("\n"));
                page.editor.message = (operation != "get").then(|| if operation == "refresh" {
                    "已按保存的平台 ID 刷新".into()
                } else { "资料已保存".into() });
            }
            Err(reason) => page.error = Some(reason),
        }
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::{MetadataEditor, platform_id};
    use serde_json::json;

    #[test]
    fn translated_titles_do_not_change_binding_identity() {
        let mut draft = MetadataEditor::default();
        for title in ["Original title", "中文标题"] {
            draft.bind("vndb", json!({"source":"vndb","sourceID":"v17","title":title})).unwrap();
            assert_eq!(draft.record["bindings"]["vndb"], "v17");
        }
        assert_eq!(draft.record["bindings"].as_object().unwrap().len(), 1);
    }

    #[test]
    fn rebinding_same_id_preserves_hydrated_details_but_changed_id_replaces_them() {
        let mut draft = MetadataEditor::default();
        let hydrated = json!({"source":"vndb","sourceID":"v17","title":"Full title",
            "characters":[{"id":"c1","name":"Character"}],"summary":"Full summary"});
        draft.bind("vndb", hydrated.clone()).unwrap();
        draft.bind("vndb", json!({"source":"vndb","sourceID":"v17","title":"Search variant"})).unwrap();
        assert_eq!(draft.record["snapshots"]["vndb"], hydrated);
        draft.bind("vndb", json!({"source":"vndb","sourceID":"v18","title":"Different work"})).unwrap();
        assert_eq!(draft.record["bindings"]["vndb"], "v18");
        assert!(draft.record["snapshots"]["vndb"]["characters"].is_null());
    }

    #[test]
    fn missing_or_mismatched_identity_never_binds() {
        let mut draft = MetadataEditor::default();
        assert!(draft.bind("steam", json!({"source":"steam","title":"Ambiguous"})).is_err());
        assert!(draft.bind("steam", json!({"source":"vndb","sourceID":"1"})).is_err());
        assert!(draft.record["bindings"].is_null());
    }

    #[test]
    fn category_inheritance_preserves_other_fields() {
        let mut draft = MetadataEditor::default();
        draft.record = json!({"futureField":42});
        draft.set_source("default", "bangumi");
        draft.set_source("cover", "steam");
        draft.set_source("cover", "");
        assert_eq!(draft.source("default"), "bangumi");
        assert_eq!(draft.source("cover"), "");
        assert_eq!(draft.record["futureField"], 42);
    }

    #[test]
    fn editing_and_cancel_do_not_change_the_saved_record() {
        let reply = json!({"record":{"version":1,"defaultSource":"bangumi","bindings":{},"snapshots":{}}});
        let mut draft = MetadataEditor::default();
        draft.accept_reply(&reply).unwrap();
        draft.bind("steam", json!({"source":"steam","sourceID":"42","title":"Game"})).unwrap();
        draft.set_source("cover", "steam");
        assert_eq!(draft.saved, reply["record"]);
        // Closing drops this editor; reopening consumes only the saved reply.
        let mut reopened = MetadataEditor::default();
        reopened.accept_reply(&reply).unwrap();
        assert_eq!(reopened.record, draft.saved);
        assert_ne!(reopened.generation, draft.generation);
    }

    #[test]
    fn invalid_reply_preserves_draft_and_category_follows_default() {
        let mut draft = MetadataEditor::default();
        draft.set_source("default", "bangumi");
        assert_eq!(draft.effective_source("basic"), "bangumi");
        let before = draft.record.clone();
        assert!(draft.accept_reply(&json!({"record":null})).is_err());
        assert_eq!(draft.record, before);
        assert!(!draft.loaded);
    }

    #[test]
    fn provider_urls_and_ids_are_explicit_and_host_checked() {
        for (source, input, id) in [
            ("steam", "https://store.steampowered.com/app/42/A_Title/?l=zh", "42"),
            ("bangumi", "https://bgm.tv/subject/123", "123"),
            ("vndb", "https://vndb.org/v17", "v17"),
            ("ymgal", "https://www.ymgal.games/ga123", "123"),
            ("vndb", "17", "v17"),
            ("steam", "0042", "42"),
        ] {
            assert_eq!(platform_id(source, input).as_deref(), Some(id));
        }
        for input in ["Game title", "0", "https://bgm.tv/subject/123",
            "https://store.steampowered.com.evil.test/app/42", "https://store.steampowered.com@evil.test/app/42"] {
            assert_eq!(platform_id("steam", input), None);
        }
    }

    #[test]
    fn empty_manual_value_is_distinct_from_inherited_value() {
        let mut draft = MetadataEditor::default();
        draft.set_manual("manualTitle", Some(""));
        assert!(draft.manual_enabled("manualTitle"));
        assert_eq!(draft.record["manualTitle"], "");
        draft.set_manual("manualSummary", Some("  "));
        assert_eq!(draft.record["manualSummary"], "  ");
        draft.set_manual("manualTitle", None);
        assert!(!draft.manual_enabled("manualTitle"));
        assert!(draft.record.get("manualTitle").is_none());
        assert_eq!(draft.record["manualSummary"], "  ");
    }

    #[test]
    fn opening_preserves_existing_empty_and_nonempty_overrides() {
        let mut draft = MetadataEditor::default();
        let record = json!({"defaultSource":"vndb","manualTitle":"","manualSummary":"Existing summary"});
        draft.accept_reply(&json!({"record":record})).unwrap();
        assert_eq!(draft.record, record);
        assert_eq!(draft.saved, record);
        assert!(draft.manual_enabled("manualTitle"));
        assert!(draft.manual_enabled("manualSummary"));
    }

    #[test]
    fn search_keywords_are_independent_including_explicit_empty_query() {
        let mut draft = MetadataEditor::default();
        draft.switch_search_source("vndb", Some("English name".into()));
        draft.switch_search_source("bangumi", Some("日本語名".into()));
        draft.switch_search_source("steam", Some("".into()));
        assert_eq!(draft.search_queries["steam"], "English name");
        assert_eq!(draft.search_queries["vndb"], "日本語名");
        assert_eq!(draft.search_queries["bangumi"], "");
        // Switching before an input is mounted never overwrites its keyword.
        draft.switch_search_source("vndb", None);
        assert_eq!(draft.search_queries["steam"], "English name");
    }

    #[test]
    fn cached_provider_remains_a_policy_choice_without_network_permission() {
        let mut draft = MetadataEditor::default();
        draft.bind("vndb", json!({"source":"vndb","sourceID":"v17","title":"Cached"})).unwrap();
        assert_eq!(draft.policy_sources(vec!["steam".into()]), vec!["steam", "vndb"]);
        assert_eq!(draft.policy_sources(vec![]), vec!["vndb"]);
    }
}
