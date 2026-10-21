//! Pure model for the bottle configuration surface.
//!
//! `configuration.schema` is a flat array of fields. The four control kinds are
//! the ones `ConfigurationField.Input` declares in
//! `WhiskyCore/Sources/WhiskyCore/ConfigurationFile.swift`:
//! `toggle`, `text`, `number(min…max)` and `choice(options)`. SwiftUI renders
//! them through `ConfigurationControl` in
//! `experimental/SwiftCrossUI/Sources/WhiskyCrossUI/ConfigurationEditor.swift`.
//! Nothing here invents a kind: an unknown wire kind fails the decode.
//!
//! Sections live only in `ContainerConfiguration.sections`; the bridge's
//! payload carries no section id, so the table below mirrors that Swift order.

use std::collections::BTreeMap;

use serde_json::{Value, json};

/// `library.page` accepts 1…100; 100 keeps the round-trip count low.
pub(crate) const PAGE_LIMIT: u64 = 100;
/// `ApplicationService.scanLibrary` refuses catalogues above this size.
pub(crate) const MAX_ENTRIES: usize = 50_000;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ConfigOption {
    pub(crate) id: String,
    pub(crate) title: String,
}

impl ConfigOption {
    pub(crate) fn title_for(options: &[ConfigOption], id: &str) -> String {
        options
            .iter()
            .find(|option| option.id == id)
            .map(|option| option.title.clone())
            .unwrap_or_else(|| id.to_owned())
    }
}

/// The four kinds `ConfigurationField.Input` can carry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum FieldKind {
    Toggle,
    Text,
    Number { min: i64, max: i64 },
    Choice { options: Vec<ConfigOption> },
}

impl FieldKind {
    /// Wire name, also used as the histogram key in `--print-config`.
    pub(crate) fn name(&self) -> &'static str {
        match self {
            Self::Toggle => "toggle",
            Self::Text => "text",
            Self::Number { .. } => "number",
            Self::Choice { .. } => "choice",
        }
    }

    pub(crate) fn is_textual(&self) -> bool {
        matches!(self, Self::Text | Self::Number { .. })
    }

    #[cfg(test)]
    pub(crate) fn options(&self) -> &[ConfigOption] {
        match self {
            Self::Choice { options } => options,
            _ => &[],
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ConfigField {
    pub(crate) id: String,
    pub(crate) title: String,
    /// Localization key from the bridge; the GPUI app has no string table yet.
    pub(crate) title_key: String,
    pub(crate) kind: FieldKind,
    pub(crate) default: Value,
    /// Capability names the host must advertise, e.g. `wine.configuration`.
    pub(crate) requires: Vec<String>,
    /// Platforms the host filtered for; empty means unrestricted.
    pub(crate) platforms: Vec<String>,
}

impl ConfigField {
    /// Whether the connected helper advertises everything this field needs.
    pub(crate) fn enabled(&self, capabilities: &[String]) -> bool {
        self.requires
            .iter()
            .all(|required| capabilities.iter().any(|held| held == required))
    }
}

/// Decode `configuration.schema`. Fields and choices are filtered against the
/// platform the helper reported, so a macOS-only option never renders on Linux.
pub(crate) fn decode_schema(raw: &Value, platform: &str) -> Result<Vec<ConfigField>, String> {
    let fields = raw
        .as_array()
        .ok_or_else(|| "configuration.schema did not return an array".to_owned())?;
    let mut decoded = Vec::with_capacity(fields.len());
    for (index, field) in fields.iter().enumerate() {
        if let Some(field) = decode_field(field, platform)
            .map_err(|reason| format!("schema field {index}: {reason}"))?
        {
            decoded.push(field);
        }
    }
    Ok(decoded)
}

fn decode_field(raw: &Value, platform: &str) -> Result<Option<ConfigField>, String> {
    let field = raw
        .as_object()
        .ok_or_else(|| "a field is not an object".to_owned())?;
    let id = text(field.get("id"))?.to_owned();
    let title = text(field.get("title"))?.to_owned();
    let title_key = field
        .get("titleKey")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    let platforms = strings(field.get("platforms"));
    if !platforms.is_empty() && !platforms.iter().any(|candidate| candidate == platform) {
        return Ok(None);
    }
    let requires = strings(field.get("requires"));
    let default = field
        .get("default")
        .cloned()
        .ok_or_else(|| format!("{id} has no default"))?;
    let input = text(field.get("input"))?;
    let kind = match input {
        "toggle" => {
            required_kind(&default, Value::is_boolean, &id, "boolean")?;
            FieldKind::Toggle
        }
        "text" => {
            required_kind(&default, Value::is_string, &id, "string")?;
            FieldKind::Text
        }
        "number" => {
            required_kind(&default, Value::is_i64, &id, "integer")?;
            let min = integer(field.get("min"), &id)?;
            let max = integer(field.get("max"), &id)?;
            if min > max {
                return Err(format!("{id} has an inverted range"));
            }
            FieldKind::Number { min, max }
        }
        "choice" => {
            required_kind(&default, Value::is_string, &id, "string")?;
            let raw_options = field
                .get("options")
                .and_then(Value::as_array)
                .ok_or_else(|| format!("{id} has no options"))?;
            let mut options = Vec::with_capacity(raw_options.len());
            for option in raw_options {
                let option = option
                    .as_object()
                    .ok_or_else(|| format!("{id} has a non-object option"))?;
                let option_platforms = strings(option.get("platforms"));
                if !option_platforms.is_empty()
                    && !option_platforms
                        .iter()
                        .any(|candidate| candidate == platform)
                {
                    continue;
                }
                options.push(ConfigOption {
                    id: text(option.get("id"))?.to_owned(),
                    title: text(option.get("title"))?.to_owned(),
                });
            }
            if options.is_empty() {
                return Ok(None);
            }
            FieldKind::Choice { options }
        }
        other => return Err(format!("{id} has an unsupported input kind: {other}")),
    };
    Ok(Some(ConfigField {
        id,
        title,
        title_key,
        kind,
        default,
        requires,
        platforms,
    }))
}

fn text(raw: Option<&Value>) -> Result<&str, String> {
    raw.and_then(Value::as_str)
        .ok_or_else(|| "expected a string".to_owned())
}

fn strings(raw: Option<&Value>) -> Vec<String> {
    raw.and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

fn integer(raw: Option<&Value>, id: &str) -> Result<i64, String> {
    raw.and_then(Value::as_i64)
        .ok_or_else(|| format!("{id} has no integer bound"))
}

fn required_kind(
    value: &Value,
    matches: impl Fn(&Value) -> bool,
    id: &str,
    expected: &str,
) -> Result<(), String> {
    if matches(value) {
        Ok(())
    } else {
        Err(format!("{id} has a default that is not a {expected}"))
    }
}

/// The stored values, with the schema default filling any key the file omits.
pub(crate) fn resolved_values(
    fields: &[ConfigField],
    read: &Value,
) -> BTreeMap<String, Value> {
    fields
        .iter()
        .map(|field| {
            let value = read
                .get(&field.id)
                .filter(|value| !value.is_null())
                .cloned()
                .unwrap_or_else(|| field.default.clone());
            (field.id.clone(), value)
        })
        .collect()
}

/// A field's value as the row shows it. Toggles have no text form.
pub(crate) fn display_value(field: &ConfigField, value: &Value) -> Option<String> {
    match (&field.kind, value) {
        (FieldKind::Toggle, _) => None,
        (FieldKind::Choice { options }, Value::String(id)) => {
            Some(ConfigOption::title_for(options, id))
        }
        (_, Value::String(text)) => Some(text.clone()),
        (_, Value::Number(number)) => Some(number.to_string()),
        (_, Value::Bool(flag)) => Some(flag.to_string()),
        _ => Some(String::new()),
    }
}

/// Text and number rows commit what the user typed. Numbers must parse and fit
/// the schema range; the helper rejects the same values, so this is a local
/// pre-check that keeps a bad edit off the wire.
pub(crate) fn encode_edit(field: &ConfigField, raw: &str) -> Result<Value, String> {
    match &field.kind {
        FieldKind::Text => Ok(json!(raw)),
        FieldKind::Number { min, max } => {
            let trimmed = raw.trim();
            if trimmed.is_empty() {
                return Err(format!("请为“{}”输入一个整数", field.title));
            }
            let number: i64 = trimmed
                .parse()
                .map_err(|_| format!("“{}”需要一个整数", field.title))?;
            if number < *min || number > *max {
                return Err(format!(
                    "“{}”必须在 {min} 到 {max} 之间",
                    field.title
                ));
            }
            Ok(json!(number))
        }
        FieldKind::Toggle | FieldKind::Choice { .. } => {
            Err(format!("“{}”不是文本字段", field.title))
        }
    }
}

/// One `configuration.set` request for exactly one field.
pub(crate) fn set_payload(container: &str, field: &str, value: &Value) -> Value {
    json!({
        "container": container,
        "field": field,
        "value": value,
    })
}

/// `environment.set`; `None` removes the key.
pub(crate) fn environment_payload(container: &str, key: &str, value: Option<&str>) -> Value {
    json!({
        "container": container,
        "key": key,
        "value": value.map_or(Value::Null, Value::from),
    })
}

/// Environment variable names: non-empty, no `=`, no NUL. The helper enforces
/// the same rule in `ConfigurationFile.setEnvironmentVariable`.
pub(crate) fn validate_environment_name(raw: &str) -> Result<&str, &'static str> {
    let key = raw.trim();
    if key.is_empty() {
        return Err("变量名不能为空");
    }
    if key.contains('=') {
        return Err("变量名不能包含 =");
    }
    if key.contains('\0') {
        return Err("变量名不能包含空字符");
    }
    Ok(key)
}

/// Sorted key/value pairs, the order the rows render in.
pub(crate) fn environment_rows(values: &BTreeMap<String, String>) -> Vec<(&str, &str)> {
    values
        .iter()
        .map(|(key, value)| (key.as_str(), value.as_str()))
        .collect()
}

// MARK: - Sections

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SectionSpec {
    pub(crate) id: &'static str,
    pub(crate) title: &'static str,
}

/// `ContainerConfiguration.sections` order and titles, plus the program section
/// (`ContainerConfiguration.programSections`). `other` only appears when the
/// helper reports a field this table has not learned yet.
pub(crate) const SECTIONS: &[SectionSpec] = &[
    SectionSpec { id: "wine", title: "Wine" },
    SectionSpec { id: "launcher", title: "启动器兼容性" },
    SectionSpec { id: "input", title: "输入与控制器" },
    SectionSpec { id: "graphics", title: "图形" },
    SectionSpec { id: "audio", title: "音频" },
    SectionSpec { id: "discord", title: "Discord" },
    SectionSpec { id: "display", title: "显示" },
    SectionSpec { id: "performance", title: "性能" },
    SectionSpec { id: "cleanup", title: "退出与清理" },
    SectionSpec { id: "program", title: "程序配置" },
    SectionSpec { id: "other", title: "其他" },
];

const OTHER: &SectionSpec = &SECTIONS[SECTIONS.len() - 1];

/// The section a field id belongs to, as `ContainerConfiguration` groups it.
pub(crate) fn section_for(field_id: &str) -> &'static SectionSpec {
    let id = match field_id {
        "windowsVersion" | "enhancedSync" | "avxEnabled" => "wine",
        "launcherCompatibilityMode" | "launcherMode" | "detectedLauncher" | "launcherLocale"
        | "gpuSpoofing" | "gpuVendor" | "autoEnableDXVK" => "launcher",
        "controllerCompatibilityMode" | "disableHIDAPI" | "allowBackgroundEvents"
        | "disableControllerMapping" | "useButtonLabels" | "commandActsAsControl" => "input",
        "graphicsBackend" | "metalFX" | "frameGeneration" | "metal4Enabled" | "metalHud"
        | "metalTrace" | "dxrEnabled" | "metalValidation" | "dxvkAsync" | "dxvkHud" => "graphics",
        "audioDriver" | "audioLatencyPreset" | "outputDeviceMode" | "pinnedDeviceName" => "audio",
        "discordPresence" | "discordBridge" => "discord",
        "virtualDesktopEnabled" | "resolutionPreset" | "customResolutionWidth"
        | "customResolutionHeight" => "display",
        "shaderCacheEnabled" | "disableAppNap" => "performance",
        "clipboardPolicy" | "clipboardThreshold" | "killOnQuit" | "closeWithProcessesPolicy" => {
            "cleanup"
        }
        "programLocale" | "arguments" => "program",
        _ => return OTHER,
    };
    SECTIONS
        .iter()
        .find(|section| section.id == id)
        .unwrap_or(OTHER)
}

/// One rendered section: its header plus the fields in schema order.
pub(crate) struct Section<'a> {
    pub(crate) spec: &'static SectionSpec,
    pub(crate) fields: Vec<&'a ConfigField>,
}

/// Group decoded fields into sections, preserving the helper's field order.
pub(crate) fn group_sections(fields: &[ConfigField]) -> Vec<Section<'_>> {
    let mut sections: Vec<Section<'_>> = Vec::new();
    for field in fields {
        let spec = section_for(&field.id);
        match sections.iter_mut().find(|section| section.spec.id == spec.id) {
            Some(section) => section.fields.push(field),
            None => sections.push(Section {
                spec,
                fields: vec![field],
            }),
        }
    }
    sections
}

/// Kinds histogram for `--print-config`, in a stable order.
pub(crate) fn kind_histogram(fields: &[ConfigField]) -> BTreeMap<&'static str, usize> {
    let mut histogram = BTreeMap::new();
    for field in fields {
        *histogram.entry(field.kind.name()).or_insert(0) += 1;
    }
    histogram
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Recorded from `WhiskyBridge/.build/release/whisky-bridge`, macOS, the
    /// `galgame` bottle. 42 fields: 23 toggles, 15 choices, 3 numbers, 1 text.
    const RECORDED: &str = include_str!("../tests/fixtures/configuration-schema.json");

    fn recorded() -> Vec<ConfigField> {
        decode_schema(&serde_json::from_str(RECORDED).unwrap(), "macos").unwrap()
    }

    fn field<'a>(fields: &'a [ConfigField], id: &str) -> &'a ConfigField {
        fields.iter().find(|field| field.id == id).unwrap_or_else(|| panic!("{id}"))
    }

    #[test]
    fn recorded_schema_decodes_into_the_four_swift_kinds_only() {
        let fields = recorded();
        assert_eq!(fields.len(), 42);
        let kinds = kind_histogram(&fields);
        assert_eq!(kinds.get("toggle"), Some(&23));
        assert_eq!(kinds.get("choice"), Some(&15));
        assert_eq!(kinds.get("number"), Some(&3));
        assert_eq!(kinds.get("text"), Some(&1));
    }

    #[test]
    fn every_kind_keeps_its_default_and_enum_labels() {
        let fields = recorded();

        let windows = field(&fields, "windowsVersion");
        assert_eq!(windows.kind.name(), "choice");
        assert_eq!(windows.default, json!("win10"));
        assert_eq!(
            ConfigOption::title_for(windows.kind.options(), "win11"),
            "Windows 11"
        );
        assert_eq!(
            ConfigOption::title_for(windows.kind.options(), "winxp64"),
            "Windows XP"
        );
        // The auto option has an empty id but a readable label.
        let launcher = field(&fields, "detectedLauncher");
        assert_eq!(
            ConfigOption::title_for(launcher.kind.options(), ""),
            "自动检测"
        );

        let avx = field(&fields, "avxEnabled");
        assert_eq!(avx.kind, FieldKind::Toggle);
        assert_eq!(avx.default, json!(false));

        let pinned = field(&fields, "pinnedDeviceName");
        assert_eq!(pinned.kind, FieldKind::Text);
        assert_eq!(pinned.default, json!(""));

        let width = field(&fields, "customResolutionWidth");
        assert_eq!(width.kind, FieldKind::Number { min: 640, max: 7_680 });
        assert_eq!(width.default, json!(1_920));
    }

    #[test]
    fn every_recorded_field_maps_to_a_swiftui_section_in_order() {
        let fields = recorded();
        for field in &fields {
            assert_ne!(
                section_for(&field.id).id,
                "other",
                "{} has no section mapping",
                field.id
            );
        }
        let flat: Vec<&str> = group_sections(&fields)
            .into_iter()
            .flat_map(|section| section.fields)
            .map(|field| field.id.as_str())
            .collect();
        assert_eq!(
            flat,
            fields.iter().map(|field| field.id.as_str()).collect::<Vec<_>>()
        );
        let sections = group_sections(&fields);
        assert_eq!(sections.first().unwrap().spec.title, "Wine");
        assert_eq!(sections.last().unwrap().spec.title, "退出与清理");
    }

    #[test]
    fn platform_filtering_drops_macos_only_fields_and_options() {
        let raw: Value = serde_json::from_str(RECORDED).unwrap();
        let linux = decode_schema(&raw, "linux").unwrap();
        assert!(linux.iter().all(|field| field.id != "commandActsAsControl"));
        assert!(linux.iter().all(|field| field.id != "metalFX"));
        assert!(linux.len() < 42);
        // `d3dMetal` and `dxmt` are macOS-only options of a shared field.
        let backend = field(&linux, "graphicsBackend");
        let ids: Vec<&str> = backend
            .kind
            .options()
            .iter()
            .map(|option| option.id.as_str())
            .collect();
        assert!(!ids.contains(&"d3dMetal"));
        assert!(!ids.contains(&"dxmt"));
        assert!(ids.contains(&"dxvk"));
    }

    #[test]
    fn unknown_kinds_are_rejected_instead_of_invented() {
        let raw = json!([{
            "id": "future",
            "title": "Future",
            "default": 1,
            "input": "slider"
        }]);
        let error = decode_schema(&raw, "macos").unwrap_err();
        assert!(error.contains("unsupported input kind: slider"), "{error}");
    }

    #[test]
    fn set_payload_targets_one_field_with_the_typed_value() {
        let fields = recorded();
        assert_eq!(
            set_payload("/bottles/galgame", "windowsVersion", &json!("win11")),
            json!({
                "container": "/bottles/galgame",
                "field": "windowsVersion",
                "value": "win11"
            })
        );
        assert_eq!(
            set_payload("/bottles/galgame", "avxEnabled", &json!(true)),
            json!({
                "container": "/bottles/galgame",
                "field": "avxEnabled",
                "value": true
            })
        );
        assert_eq!(
            set_payload("/bottles/galgame", "clipboardThreshold", &json!(2048)),
            json!({
                "container": "/bottles/galgame",
                "field": "clipboardThreshold",
                "value": 2048
            })
        );
        let pinned = field(&fields, "pinnedDeviceName");
        assert_eq!(
            set_payload("/bottles/galgame", &pinned.id, &encode_edit(pinned, "MacBook Pro").unwrap()),
            json!({
                "container": "/bottles/galgame",
                "field": "pinnedDeviceName",
                "value": "MacBook Pro"
            })
        );
        // Toggles and choices never go through the text encoder.
        assert!(encode_edit(field(&fields, "avxEnabled"), "true").is_err());
        assert!(encode_edit(field(&fields, "windowsVersion"), "win11").is_err());
    }

    #[test]
    fn number_edits_are_trimmed_and_range_checked_locally() {
        let fields = recorded();
        let width = field(&fields, "customResolutionWidth");
        assert_eq!(encode_edit(width, " 2560 ").unwrap(), json!(2560));
        assert_eq!(encode_edit(width, "640").unwrap(), json!(640));
        assert_eq!(encode_edit(width, "7680").unwrap(), json!(7680));
        assert!(encode_edit(width, "639").is_err());
        assert!(encode_edit(width, "7681").is_err());
        assert!(encode_edit(width, "").is_err());
        assert!(encode_edit(width, "1920.5").is_err());
    }

    #[test]
    fn requires_flags_disable_a_field_without_the_host_capability() {
        let fields = recorded();
        let windows = field(&fields, "windowsVersion");
        assert!(!windows.enabled(&[]));
        assert!(!windows.enabled(&["configuration.file".into()]));
        assert!(windows.enabled(&["wine.configuration".into()]));
        let avx = field(&fields, "avxEnabled");
        assert!(avx.enabled(&[]));
    }

    #[test]
    fn missing_values_fall_back_to_the_schema_default() {
        let fields = recorded();
        let read = json!({"windowsVersion": "win11", "metalHud": true});
        let values = resolved_values(&fields, &read);
        assert_eq!(values["windowsVersion"], json!("win11"));
        assert_eq!(values["metalHud"], json!(true));
        assert_eq!(values["graphicsBackend"], json!("recommended"));
        assert_eq!(values["customResolutionWidth"], json!(1920));
        assert_eq!(values.len(), fields.len());
    }

    #[test]
    fn display_values_use_enum_labels_for_choices() {
        let fields = recorded();
        let windows = field(&fields, "windowsVersion");
        assert_eq!(display_value(windows, &json!("win7")).as_deref(), Some("Windows 7"));
        assert_eq!(display_value(field(&fields, "avxEnabled"), &json!(true)), None);
        let width = field(&fields, "customResolutionWidth");
        assert_eq!(display_value(width, &json!(1920)).as_deref(), Some("1920"));
        let pinned = field(&fields, "pinnedDeviceName");
        assert_eq!(
            display_value(pinned, &json!("Speakers")).as_deref(),
            Some("Speakers")
        );
    }

    /// The rejection rollback the `ConfigurationFailed` handler runs: the
    /// committed value is remembered before the optimistic write and restored
    /// when the helper refuses it, exactly once.
    #[test]
    fn a_rejected_write_restores_the_committed_value() {
        use crate::runtime::PendingEdits;

        let fields = recorded();
        let mut values = resolved_values(&fields, &json!({"avxEnabled": false}));
        let mut writes: PendingEdits<serde_json::Value> = PendingEdits::default();

        // Optimistic toggle: the row flips immediately, before the wire answer.
        writes.begin("avxEnabled", values["avxEnabled"].clone());
        values.insert("avxEnabled".to_owned(), json!(true));
        assert_eq!(values["avxEnabled"], json!(true));

        // The helper rejected the write: restore what was committed.
        let previous = writes.fail("avxEnabled").expect("rollback value");
        values.insert("avxEnabled".to_owned(), previous);
        assert_eq!(values["avxEnabled"], json!(false));
        assert_eq!(writes.fail("avxEnabled"), None, "rollback runs once");

        // A burst of edits still rolls back to the value committed before the
        // first of them, not to an intermediate draft.
        writes.begin("customResolutionWidth", json!(1920));
        writes.begin("customResolutionWidth", json!(2560));
        let previous = writes.fail("customResolutionWidth").expect("rollback value");
        assert_eq!(previous, json!(1920));

        // A confirmed write leaves nothing to roll back.
        writes.begin("pinnedDeviceName", json!(""));
        values.insert("pinnedDeviceName".to_owned(), json!("Speakers"));
        writes.succeed("pinnedDeviceName");
        assert_eq!(writes.fail("pinnedDeviceName"), None);
        assert_eq!(values["pinnedDeviceName"], json!("Speakers"));
    }

    #[test]
    fn environment_names_follow_the_helper_rule() {
        assert_eq!(validate_environment_name("LANG"), Ok("LANG"));
        assert_eq!(validate_environment_name("  WINEDLLOVERRIDES "), Ok("WINEDLLOVERRIDES"));
        assert!(validate_environment_name("").is_err());
        assert!(validate_environment_name("   ").is_err());
        assert!(validate_environment_name("A=B").is_err());
        assert!(validate_environment_name("A\0B").is_err());
    }

    #[test]
    fn environment_payload_round_trips_a_map_per_key() {
        let map: BTreeMap<String, String> = serde_json::from_value(json!({
            "LANG": "ja_JP.UTF-8",
            "WINEDLLOVERRIDES": "d3dcompiler_47=n"
        }))
        .unwrap();
        let rows = environment_rows(&map);
        assert_eq!(
            rows,
            vec![
                ("LANG", "ja_JP.UTF-8"),
                ("WINEDLLOVERRIDES", "d3dcompiler_47=n")
            ]
        );
        assert_eq!(
            environment_payload("/b", "LANG", Some("ja_JP.UTF-8")),
            json!({"container": "/b", "key": "LANG", "value": "ja_JP.UTF-8"})
        );
        assert_eq!(
            environment_payload("/b", "LANG", None),
            json!({"container": "/b", "key": "LANG", "value": null})
        );
        // Decoding the reply of a set/remove is the same shape as the read.
        let reply: BTreeMap<String, String> = serde_json::from_value(json!({
            "LANG": "ja_JP.UTF-8"
        }))
        .unwrap();
        assert_eq!(environment_rows(&reply), vec![("LANG", "ja_JP.UTF-8")]);
    }
}
