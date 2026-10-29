//! Persisted scraping policy and the local, cancellable welcome/settings draft.
use std::collections::BTreeMap;

use serde_json::{Value, json};

pub(crate) const COMPLETED: &str = "libraryOnboardingCompleted";
pub(crate) const ENABLED: &str = "libraryMetadataEnabledSources";
pub(crate) const DEFAULT_SOURCE: &str = "libraryMetadataDefaultSource";
pub(crate) const SOURCES: [(&str, &str); 4] = [
    ("bangumi", "Bangumi"),
    ("vndb", "VNDB"),
    ("steam", "Steam"),
    ("ymgal", "月幕"),
];
pub(crate) const CATEGORIES: [(&str, &str, &str); 4] = [
    ("basic", "名称与基本信息", "libraryMetadataBasicSource"),
    ("summary", "简介", "libraryMetadataSummarySource"),
    ("cover", "封面", "libraryMetadataCoverSource"),
    ("characters", "人物", "libraryMetadataCharactersSource"),
];

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct MetadataPreferences {
    pub(crate) default_source: String,
    pub(crate) category_sources: BTreeMap<String, String>,
    pub(crate) enabled_sources: Vec<String>,
}

impl Default for MetadataPreferences {
    fn default() -> Self {
        Self {
            default_source: "bangumi".into(),
            category_sources: BTreeMap::new(),
            enabled_sources: SOURCES.iter().map(|(id, _)| (*id).into()).collect(),
        }
    }
}

fn known(source: &str) -> bool {
    SOURCES.iter().any(|(id, _)| *id == source)
}

impl MetadataPreferences {
    pub(crate) fn read(values: &Value) -> Self {
        let mut result = Self::default();
        if let Some(source) = values
            .get(DEFAULT_SOURCE)
            .and_then(Value::as_str)
            .filter(|s| known(s))
        {
            result.default_source = source.into();
        }
        for (category, _, key) in CATEGORIES {
            if let Some(source) = values.get(key).and_then(Value::as_str).filter(|s| known(s)) {
                result
                    .category_sources
                    .insert(category.into(), source.into());
            }
        }
        if let Some(enabled) = values.get(ENABLED).and_then(Value::as_str) {
            // An explicit empty list is intentional, not a request for defaults.
            result.enabled_sources = SOURCES
                .iter()
                .filter(|(id, _)| enabled.split(',').any(|part| part.trim() == *id))
                .map(|(id, _)| (*id).into())
                .collect();
        }
        result
    }

    pub(crate) fn values(&self) -> Value {
        let mut values = serde_json::Map::new();
        values.insert(DEFAULT_SOURCE.into(), json!(self.default_source));
        values.insert(ENABLED.into(), json!(self.enabled_sources.join(",")));
        for (category, _, key) in CATEGORIES {
            values.insert(
                key.into(),
                json!(
                    self.category_sources
                        .get(category)
                        .map(String::as_str)
                        .unwrap_or("inherit")
                ),
            );
        }
        Value::Object(values)
    }
}

#[derive(Clone)]
pub(crate) struct Onboarding {
    pub(crate) draft: MetadataPreferences,
    pub(crate) welcome: bool,
    pub(crate) step: usize,
    pub(crate) expanded: bool,
    pub(crate) saving: bool,
    pub(crate) error: Option<String>,
}

impl Onboarding {
    pub(crate) fn new(draft: MetadataPreferences, welcome: bool) -> Self {
        Self {
            draft,
            welcome,
            step: if welcome { 0 } else { 1 },
            expanded: false,
            saving: false,
            error: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strategy_round_trip_preserves_overrides_and_disabled_network_sources() {
        let mut policy = MetadataPreferences::default();
        policy
            .category_sources
            .insert("characters".into(), "vndb".into());
        policy.enabled_sources.clear();
        assert_eq!(MetadataPreferences::read(&policy.values()), policy);
    }

    #[test]
    fn unknown_values_do_not_enable_unknown_providers() {
        let policy = MetadataPreferences::read(&json!({
            DEFAULT_SOURCE: "unknown",
            ENABLED: "unknown,vndb,vndb",
            "libraryMetadataSummarySource": "inherit"
        }));
        assert_eq!(policy.default_source, "bangumi");
        assert_eq!(policy.enabled_sources, ["vndb"]);
        assert!(policy.category_sources.is_empty());
    }
}
