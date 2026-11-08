//! Per-program run settings, overrides, run history and shortcut state.
//!
//! `programs.settings.*` reads and patches the identity-keyed plist the
//! SwiftUI app uses, preserving unknown keys. The sheet keeps a draft in this
//! frontend and sends one patch when the user saves.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProgramSettingsDto {
    pub(crate) container: String,
    pub(crate) executable: String,
    pub(crate) program_name: String,
    pub(crate) locale: String,
    pub(crate) arguments: String,
    #[serde(default)]
    pub(crate) environment: BTreeMap<String, String>,
    /// `null` means the program inherits every override.
    #[serde(default)]
    pub(crate) overrides: Option<OverridesDto>,
    #[serde(default)]
    pub(crate) defaults: OverridesDto,
    #[serde(default)]
    pub(crate) available: bool,
    /// The user permanently dismissed the legacy fullscreen suggestion.
    #[serde(default)]
    pub(crate) legacy_fullscreen_dismissed: bool,
    /// The latest finished run logged a failed `ChangeDisplaySettings` call.
    #[serde(default)]
    pub(crate) display_mode_change_failed: bool,
}

impl ProgramSettingsDto {
    pub(crate) fn graphics_enabled(&self) -> bool {
        let Some(overrides) = &self.overrides else {
            return false;
        };
        overrides.graphics_backend.is_some()
            || overrides.dxvk.is_some()
            || overrides.dxvk_async.is_some()
            || overrides.dxvk_hud.is_some()
            || overrides.metal4_enabled.is_some()
    }

    pub(crate) fn upscale_enabled(&self) -> bool {
        self.overrides.as_ref().is_some_and(|overrides| {
            overrides.gdi_upscaler.is_some() || overrides.gdi_upscaler_cache.is_some()
        })
    }

    pub(crate) fn sync_enabled(&self) -> bool {
        self.overrides
            .as_ref()
            .is_some_and(|overrides| overrides.enhanced_sync.is_some())
    }

    pub(crate) fn performance_enabled(&self) -> bool {
        self.overrides
            .as_ref()
            .is_some_and(|overrides| overrides.shader_cache_enabled.is_some())
    }

    pub(crate) fn input_enabled(&self) -> bool {
        self.overrides
            .as_ref()
            .is_some_and(|overrides| overrides.controller_compatibility_mode.is_some())
    }

    pub(crate) fn display_enabled(&self) -> bool {
        self.overrides.as_ref().is_some_and(|overrides| {
            overrides.virtual_desktop_enabled.is_some() || overrides.emulate_modeset.is_some()
        })
    }

    /// Whether the legacy fullscreen prompt should pop for this program: the
    /// latest run failed a display-mode change, the fix is not already forced
    /// on, and the user has not permanently dismissed the suggestion.
    pub(crate) fn legacy_fullscreen_suggested(&self) -> bool {
        self.display_mode_change_failed
            && !self.legacy_fullscreen_dismissed
            && self.overrides.as_ref().and_then(|o| o.emulate_modeset) != Some(true)
    }

    pub(crate) fn dll_enabled(&self) -> bool {
        self.overrides
            .as_ref()
            .is_some_and(|overrides| overrides.dll_overrides.is_some())
    }

    /// Ensure an overrides object exists before a group toggle writes into it.
    pub(crate) fn overrides_mut(&mut self) -> &mut OverridesDto {
        self.overrides.get_or_insert_with(OverridesDto::default)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OverridesDto {
    #[serde(default)]
    pub(crate) graphics_backend: Option<String>,
    #[serde(default)]
    pub(crate) dxvk: Option<bool>,
    #[serde(default)]
    pub(crate) dxvk_async: Option<bool>,
    #[serde(default)]
    pub(crate) dxvk_hud: Option<String>,
    #[serde(default)]
    pub(crate) enhanced_sync: Option<String>,
    #[serde(default)]
    pub(crate) metal4_enabled: Option<bool>,
    #[serde(default)]
    pub(crate) gdi_upscaler: Option<String>,
    #[serde(default)]
    pub(crate) gdi_upscaler_cache: Option<String>,
    #[serde(default)]
    pub(crate) shader_cache_enabled: Option<bool>,
    #[serde(default)]
    pub(crate) controller_compatibility_mode: Option<bool>,
    #[serde(default)]
    pub(crate) disable_hidapi: Option<bool>,
    #[serde(default)]
    pub(crate) allow_background_events: Option<bool>,
    #[serde(default)]
    pub(crate) disable_controller_mapping: Option<bool>,
    #[serde(default)]
    pub(crate) use_button_labels: Option<bool>,
    #[serde(default)]
    pub(crate) emulate_modeset: Option<bool>,
    #[serde(default)]
    pub(crate) virtual_desktop_enabled: Option<bool>,
    #[serde(default)]
    pub(crate) resolution_preset: Option<String>,
    #[serde(default)]
    pub(crate) custom_resolution_width: Option<i64>,
    #[serde(default)]
    pub(crate) custom_resolution_height: Option<i64>,
    #[serde(default)]
    pub(crate) dll_overrides: Option<Vec<DllOverrideDto>>,
    #[serde(default)]
    pub(crate) tagged_verbs: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DllOverrideDto {
    pub(crate) dll_name: String,
    #[serde(default)]
    pub(crate) mode: String,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct HistoryDto {
    #[serde(default)]
    pub(crate) entries: Vec<RunEntryDto>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct RunEntryDto {
    pub(crate) id: String,
    #[serde(default)]
    pub(crate) program_name: String,
    #[serde(default)]
    pub(crate) log_path: String,
    #[serde(default)]
    pub(crate) start_time: f64,
    #[serde(default)]
    pub(crate) end_time: Option<f64>,
    #[serde(default)]
    pub(crate) exit_code: Option<i32>,
    #[serde(default)]
    pub(crate) duration: Option<f64>,
    #[serde(default)]
    pub(crate) has_wine_debug_output: bool,
    #[serde(default)]
    pub(crate) display_mode_change_failed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct EnvRow {
    pub(crate) id: u64,
    pub(crate) key: String,
    pub(crate) value: String,
}

/// One open run-settings sheet. The draft is replaced only by a successful
/// bridge read or save reply.
#[derive(Default)]
pub(crate) struct ProgramSettingsPage {
    pub(crate) container: Option<String>,
    pub(crate) executable: Option<String>,
    pub(crate) title: String,
    pub(crate) settings: Option<ProgramSettingsDto>,
    pub(crate) loading: bool,
    pub(crate) saving: bool,
    pub(crate) error: Option<String>,
    pub(crate) env_rows: Vec<EnvRow>,
    pub(crate) next_env_id: u64,
    pub(crate) history: Vec<RunEntryDto>,
    pub(crate) history_error: Option<String>,
    pub(crate) history_loading: bool,
    pub(crate) dll_new_mode: String,
    pub(crate) shortcut_destination: String,
    pub(crate) close_after_save: bool,
    pub(crate) shortcut_path: Option<String>,
    pub(crate) shortcut_error: Option<String>,
    /// Last measured size of the GDI upscaler disk cache for this program.
    pub(crate) cache_bytes: Option<u64>,
    /// A background walk of the cache directory is in flight.
    pub(crate) cache_pending: bool,
    /// A background clear of the cache directory is in flight.
    pub(crate) cache_clearing: bool,
    /// Bumped whenever the target or a measurement starts; stale workers drop
    /// their result when it no longer matches.
    pub(crate) cache_generation: u64,
}

impl ProgramSettingsPage {
    pub(crate) fn start(
        &mut self,
        container: &str,
        executable: &str,
        title: &str,
    ) {
        self.container = Some(container.to_owned());
        self.executable = Some(executable.to_owned());
        self.title = title.to_owned();
        self.settings = None;
        self.loading = true;
        self.saving = false;
        self.error = None;
        self.env_rows.clear();
        self.next_env_id = 0;
        self.history.clear();
        self.history_error = None;
        self.history_loading = true;
        self.shortcut_destination = default_shortcut_destination();
        self.close_after_save = false;
        self.shortcut_path = None;
        self.shortcut_error = None;
        self.cache_bytes = None;
        self.cache_pending = false;
        self.cache_clearing = false;
        self.cache_generation += 1;
    }

    pub(crate) fn apply_settings(&mut self, settings: ProgramSettingsDto) {
        #[cfg(target_os = "linux")]
        let mut settings = settings;
        #[cfg(target_os = "linux")]
        for values in std::iter::once(&mut settings.defaults).chain(settings.overrides.iter_mut()) {
            if matches!(values.graphics_backend.as_deref(), Some("d3dMetal" | "dxmt")) {
                values.graphics_backend = Some("recommended".into());
            }
            if values.enhanced_sync.as_deref() == Some("msync") {
                values.enhanced_sync = Some("esync".into());
            }
            if values.resolution_preset.as_deref() == Some("matchDisplay") {
                values.resolution_preset = Some("r1920x1080".into());
            }
        }
        self.env_rows = settings
            .environment
            .iter()
            .map(|(key, value)| {
                let id = self.next_env_id;
                self.next_env_id += 1;
                EnvRow {
                    id,
                    key: key.clone(),
                    value: value.clone(),
                }
            })
            .collect();
        self.settings = Some(settings);
        self.loading = false;
        self.saving = false;
        self.error = None;
    }

    pub(crate) fn set_region_picker_mode(&mut self, value: String) {
        const KEY: &str = "WINE_GDI_UPSCALER_PICK";
        if let Some(row) = self.env_rows.iter_mut().find(|row| row.key == KEY) {
            row.value = value;
        } else {
            let id = self.next_env_id;
            self.next_env_id += 1;
            self.env_rows.push(EnvRow { id, key: KEY.into(), value });
        }
    }

    pub(crate) fn region_picker_mode(&self) -> &str {
        self.env_rows.iter().find(|row| row.key == "WINE_GDI_UPSCALER_PICK")
            .map(|row| row.value.as_str()).unwrap_or("auto")
    }

    fn env_value(&self, key: &str) -> Option<&str> {
        self.env_rows
            .iter()
            .find(|row| row.key == key)
            .map(|row| row.value.trim())
            .filter(|value| !value.is_empty())
    }

    /// The directory this program's disk cache lives in, mirroring
    /// `content_cache_from_environment` in the Wine library: an absolute
    /// `WINE_GDI_CACHE_DIRECTORY` overrides the default Caches root, and the
    /// leaf is a hash of `WINEPREFIX` + `WINE_GDI_CACHE_GAME` (the resolved
    /// executable path, unless the env draft overrides it).
    pub(crate) fn gdi_cache_dir(&self) -> Option<PathBuf> {
        let prefix = self.container.as_deref().filter(|value| !value.is_empty())?;
        let root = self
            .env_value("WINE_GDI_CACHE_DIRECTORY")
            .filter(|dir| dir.starts_with('/'))
            .map(PathBuf::from)
            .unwrap_or_else(default_gdi_cache_root);
        let game = match self.env_value("WINE_GDI_CACHE_GAME") {
            Some(game) => game.to_owned(),
            None => {
                let exe = self.executable.as_deref()?;
                std::fs::canonicalize(exe)
                    .map(|path| path.to_string_lossy().into_owned())
                    .unwrap_or_else(|_| exe.to_owned())
            }
        };
        Some(root.join(cache_namespace(prefix, &game)))
    }

    /// Cache written by older Wine launches without HOME. The namespace is
    /// identical even when the program uses a custom root for future launches.
    pub(crate) fn legacy_gdi_cache_dir(&self) -> Option<PathBuf> {
        let leaf = self.gdi_cache_dir()?.file_name()?.to_owned();
        let legacy = PathBuf::from("/tmp/Library/Caches/com.isaacmarovitz.Whisky/GDIUpscaler").join(leaf);
        (self.gdi_cache_dir()? != legacy).then_some(legacy)
    }

    pub(crate) fn gdi_cache_dirs(&self) -> Vec<PathBuf> {
        self.gdi_cache_dir().into_iter().chain(self.legacy_gdi_cache_dir()).collect()
    }

    pub(crate) fn fail(&mut self, reason: String) {
        if self.saving {
            self.saving = false;
        } else {
            self.loading = false;
        }
        self.error = Some(reason);
    }

    pub(crate) fn apply_history(&mut self, history: HistoryDto) {
        self.history = history.entries;
        self.history_loading = false;
        self.history_error = None;
    }

    pub(crate) fn history_entries_newest_first(&self) -> Vec<&RunEntryDto> {
        self.history.iter().rev().collect()
    }
}

fn default_gdi_cache_root() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("Library/Caches/com.isaacmarovitz.Whisky/GDIUpscaler")
}

/// Must match `wgdi::cache_namespace` in content-cache.h: SHA-256 over a tagged
/// (prefix, game) pair with u64 separators; the tag is hashed with an explicit
/// 15-byte length, so the "1" of "v1" is intentionally absent. The leaf name is
/// the first 12 digest bytes hex-encoded.
fn cache_namespace(prefix: &str, game: &str) -> String {
    use sha2::Digest;
    let mut hasher = sha2::Sha256::new();
    hasher.update(b"wgdi-cache-ns-v");
    hasher.update(0u64.to_le_bytes());
    hasher.update(prefix.as_bytes());
    hasher.update(0u64.to_le_bytes());
    hasher.update(game.as_bytes());
    let digest = hasher.finalize();
    digest[..12].iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Recursive size of `path`, following directories only (symlinks count as
/// their own link entry and are never traversed).
pub(crate) fn dir_size(path: &Path) -> u64 {
    fn walk(path: &Path, total: &mut u64) {
        let Ok(entries) = std::fs::read_dir(path) else {
            return;
        };
        for entry in entries.flatten() {
            if entry.file_name() == ".lock" { continue; }
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            if kind.is_dir() {
                walk(&entry.path(), total);
            } else if kind.is_file() {
                *total = total
                    .saturating_add(entry.metadata().map(|meta| meta.len()).unwrap_or(0));
            }
        }
    }
    let mut total = 0;
    walk(path, &mut total);
    total
}

/// Coordinate with Wine's lock and generation counter while clearing records.
pub(crate) fn clear_dir(path: &Path) -> std::io::Result<()> {
    if !path.exists() {
        return Ok(());
    }
    use std::io::{Read, Seek, SeekFrom, Write};
    if std::fs::symlink_metadata(path.join(".lock"))
        .is_ok_and(|metadata| !metadata.file_type().is_file()) {
        return Err(std::io::Error::other("invalid cache lock file"));
    }
    let mut lock = std::fs::OpenOptions::new().read(true).write(true).create(true)
        .truncate(false).open(path.join(".lock"))?;
    lock.lock()?;
    let mut generation = [0u8; 8];
    let _ = lock.read(&mut generation)?;
    lock.seek(SeekFrom::Start(0))?;
    lock.write_all(&u64::from_le_bytes(generation).wrapping_add(1).to_le_bytes())?;
    for entry in std::fs::read_dir(path)? {
        let entry = entry?;
        if entry.file_name() == ".lock" { continue; }
        if entry.file_type()?.is_dir() {
            std::fs::remove_dir_all(entry.path())?;
        } else {
            std::fs::remove_file(entry.path())?;
        }
    }
    Ok(())
}

pub(crate) fn format_size(bytes: u64) -> String {
    const UNITS: [&str; 4] = ["B", "KB", "MB", "GB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024. && unit < UNITS.len() - 1 {
        value /= 1024.;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

pub(crate) fn default_shortcut_destination() -> String {
    #[cfg(target_os = "linux")]
    {
        let home = std::env::var_os("HOME")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| std::path::PathBuf::from("/"));
        let data = std::env::var_os("XDG_DATA_HOME")
            .map(std::path::PathBuf::from)
            .filter(|path| path.is_absolute())
            .unwrap_or_else(|| home.join(".local/share"));
        return data.join("applications").to_string_lossy().into_owned();
    }
    #[cfg(not(target_os = "linux"))]
    {
        let home = std::env::var_os("HOME")
            .map(|home| home.to_string_lossy().into_owned())
            .unwrap_or_default();
        if home.is_empty() {
            "/Applications".to_owned()
        } else {
            format!("{home}/Applications")
        }
    }
}

pub(crate) fn expand_home(path: &str) -> String {
    let Some(home) = std::env::var_os("HOME").map(|home| home.to_string_lossy().into_owned()) else {
        return path.to_owned();
    };
    if path == "~" {
        return home;
    }
    if let Some(rest) = path.strip_prefix("~/") {
        return format!("{home}/{rest}");
    }
    path.to_owned()
}

/// Build the one patch the bridge applies atomically. Every override field is
/// sent, with `null` clearing inheritance, so a value removed in the sheet is
/// removed from storage instead of surviving as a stale key.
pub(crate) fn settings_patch(
    settings: &ProgramSettingsDto,
    arguments: &str,
    environment: &BTreeMap<String, String>,
) -> Value {
    let mut patch = json!({
        "locale": settings.locale,
        "arguments": arguments,
        "environment": environment,
    });
    patch["overrides"] = match &settings.overrides {
        None => Value::Null,
        Some(overrides) => json!({
            "graphicsBackend": overrides.graphics_backend,
            "dxvk": overrides.dxvk,
            "dxvkAsync": overrides.dxvk_async,
            "dxvkHud": overrides.dxvk_hud,
            "enhancedSync": overrides.enhanced_sync,
            "metal4Enabled": overrides.metal4_enabled,
            "gdiUpscaler": overrides.gdi_upscaler,
            "gdiUpscalerCache": overrides.gdi_upscaler_cache,
            "shaderCacheEnabled": overrides.shader_cache_enabled,
            "controllerCompatibilityMode": overrides.controller_compatibility_mode,
            "disableHIDAPI": overrides.disable_hidapi,
            "allowBackgroundEvents": overrides.allow_background_events,
            "disableControllerMapping": overrides.disable_controller_mapping,
            "useButtonLabels": overrides.use_button_labels,
            "emulateModeset": overrides.emulate_modeset,
            "virtualDesktopEnabled": overrides.virtual_desktop_enabled,
            "resolutionPreset": overrides.resolution_preset,
            "customResolutionWidth": overrides.custom_resolution_width,
            "customResolutionHeight": overrides.custom_resolution_height,
            "dllOverrides": overrides.dll_overrides.as_ref().map(|entries| {
                entries
                    .iter()
                    .map(|entry| json!({"dllName": entry.dll_name, "mode": entry.mode}))
                    .collect::<Vec<_>>()
            }),
            "taggedVerbs": overrides.tagged_verbs,
        }),
    };
    #[cfg(target_os = "linux")]
    if let Some(overrides) = patch["overrides"].as_object_mut() {
        for key in ["metal4Enabled", "gdiUpscaler", "gdiUpscalerCache"] {
            overrides.remove(key);
        }
    }
    patch
}

pub(crate) fn locale_label(raw: &str) -> &str {
    match raw {
        "" => "自动",
        "ja_JP.UTF-8" => "日本語",
        "zh_CN.UTF-8" => "简体中文",
        "zh_TW.UTF-8" => "繁體中文",
        "en_US.UTF-8" => "English",
        "de_DE.UTF-8" => "Deutsch",
        "es_ES.UTF-8" => "Español",
        "fr_FR.UTF-8" => "Français",
        "it_IT.UTF-8" => "Italiano",
        "ko_KR.UTF-8" => "한국어",
        "ru_RU.UTF-8" => "Русский",
        "uk_UA.UTF-8" => "Українська",
        "th_TH.UTF-8" => "ไทย",
        other => other,
    }
}

pub(crate) fn graphics_label(raw: &str) -> &str {
    match raw {
        "recommended" => "自动推荐",
        "d3dMetal" => "D3DMetal",
        "dxvk" => "DXVK",
        "dxmt" => "DXMT",
        "wined3d" => "WineD3D",
        other => other,
    }
}

pub(crate) fn upscaler_label(raw: &str) -> &str {
    match raw {
        "off" => "关闭",
        "metalfx" => "MetalFX Spatial",
        "anime4k" => "Anime4K (CNN x2 S)",
        "realcugan" => "Real-CUGAN (models-se x2)",
        "adaptive" => "动态 MetalFX／静态 Real-CUGAN",
        "realesrgan" => "Real-ESRGAN AnimeVideo-v3 (x2)",
        "adaptive-realesrgan" => "动态 MetalFX／静态 AnimeVideo-v3",
        "adaptive-anime4k" => "动态 Anime4K／静态 Real-CUGAN",
        "adaptive-anime4k-realesrgan" => "动态 Anime4K／静态 AnimeVideo-v3",
        other => other,
    }
}

pub(crate) fn cache_label(raw: &str) -> &str {
    match raw {
        "off" => "关闭跨场景缓存",
        "memory" => "本次游戏缓存",
        "persistent" => "缓存并保存到磁盘",
        other => other,
    }
}

pub(crate) fn hud_label(raw: &str) -> &str {
    match raw {
        "full" => "完整",
        "partial" => "部分",
        "fps" => "仅 FPS",
        "off" => "关闭",
        other => other,
    }
}

pub(crate) fn sync_label(raw: &str) -> &str {
    match raw {
        "none" => "关闭",
        "esync" => "ESync",
        "fsync" => "FSync",
        "msync" => "MSync",
        other => other,
    }
}

pub(crate) fn resolution_label(raw: &str) -> &str {
    match raw {
        "r1280x720" => "1280 × 720",
        "r1600x900" => "1600 × 900",
        "r1920x1080" => "1920 × 1080",
        "r2560x1440" => "2560 × 1440",
        "r3840x2160" => "3840 × 2160",
        "matchDisplay" => "匹配显示器",
        "custom" => "自定义",
        other => other,
    }
}

pub(crate) fn dll_mode_label(raw: &str) -> &str {
    match raw {
        "b" => "仅内建",
        "n" => "仅原生",
        "n,b" => "原生优先",
        "b,n" => "内建优先",
        "" => "禁用",
        other => other,
    }
}

pub(crate) fn relative_time(unix_seconds: f64) -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or(0.0);
    let delta = (now - unix_seconds).max(0.0) as u64;
    match delta {
        0..=59 => "刚刚".to_owned(),
        60..=3_599 => format!("{} 分钟前", delta / 60),
        3_600..=86_399 => format!("{} 小时前", delta / 3_600),
        _ => format!("{} 天前", delta / 86_400),
    }
}

pub(crate) fn duration_label(seconds: Option<f64>) -> String {
    let Some(seconds) = seconds.filter(|seconds| *seconds >= 0.0) else {
        return "运行中".to_owned();
    };
    let total = seconds.round() as u64;
    if total >= 3_600 {
        format!("{}:{:02}:{:02}", total / 3_600, (total % 3_600) / 60, total % 60)
    } else {
        format!("{}:{:02}", total / 60, total % 60)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SETTINGS_FIXTURE: &str = r#"{
        "container": "/bottle",
        "executable": "/bottle/drive_c/Game/game.exe",
        "programName": "game.exe",
        "locale": "ja_JP.UTF-8",
        "arguments": "-windowed",
        "environment": {"GAME": "中文"},
        "overrides": {"graphicsBackend": "dxvk", "dxvkAsync": false,
            "dllOverrides": [{"dllName": "dxgi", "mode": "n,b"}]},
        "defaults": {"graphicsBackend": "recommended", "dxvkAsync": true, "dxvkHud": "off",
            "metal4Enabled": false, "enhancedSync": "msync", "shaderCacheEnabled": true,
            "controllerCompatibilityMode": false, "disableHIDAPI": false,
            "allowBackgroundEvents": false, "disableControllerMapping": false,
            "useButtonLabels": false, "virtualDesktopEnabled": false,
            "resolutionPreset": "r1920x1080", "customResolutionWidth": 1920,
            "customResolutionHeight": 1080, "dllOverrides": []},
        "available": true,
        "futureField": 1
    }"#;

    fn settings() -> ProgramSettingsDto {
        serde_json::from_str(SETTINGS_FIXTURE).expect("settings")
    }

    #[test]
    fn game_region_mode_preserves_environment_and_updates_one_entry() {
        let mut page = ProgramSettingsPage::default();
        page.apply_settings(settings());
        assert_eq!(page.region_picker_mode(), "auto");
        page.set_region_picker_mode("request123".into());
        page.set_region_picker_mode("off".into());
        assert_eq!(page.region_picker_mode(), "off");
        assert_eq!(page.env_rows.iter().filter(|row| row.key == "WINE_GDI_UPSCALER_PICK").count(), 1);
        let environment = page.env_rows.iter().map(|row| (row.key.clone(), row.value.clone())).collect();
        let patch = settings_patch(page.settings.as_ref().unwrap(), "", &environment);
        assert_eq!(patch["environment"]["WINE_GDI_UPSCALER_PICK"], "off");
        assert_eq!(patch["environment"]["GAME"], "中文");
    }

    #[test]
    fn cache_namespace_matches_wine_layout() {
        // SHA-256("wgdi-cache-ns-v" || 0u64 || "/bottle" || 0u64 || exe)[..12]
        // as produced by wgdi::cache_namespace in content-cache.h.
        assert_eq!(
            cache_namespace("/bottle", "/bottle/drive_c/Game/game.exe"),
            "29a56daf9987e9a5d0372612"
        );
    }

    #[test]
    fn clear_cache_preserves_lock_and_advances_generation() {
        use std::io::Write;
        let dir = std::env::temp_dir().join(format!("whisky-cache-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(".lock"), 7u64.to_le_bytes()).unwrap();
        std::fs::File::create(dir.join("entry.bin")).unwrap().write_all(b"cached").unwrap();
        clear_dir(&dir).unwrap();
        assert_eq!(std::fs::read(dir.join(".lock")).unwrap(), 8u64.to_le_bytes());
        assert!(!dir.join("entry.bin").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn settings_decode_overrides_defaults_and_unknown_fields() {
        let settings = settings();
        assert_eq!(settings.program_name, "game.exe");
        assert_eq!(settings.environment["GAME"], "中文");
        assert!(settings.graphics_enabled());
        assert!(!settings.sync_enabled());
        assert_eq!(
            settings.overrides.as_ref().unwrap().dll_overrides.as_ref().unwrap()[0].dll_name,
            "dxgi"
        );
        assert_eq!(settings.defaults.graphics_backend.as_deref(), Some("recommended"));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn imported_macos_preferences_render_and_save_supported_linux_values() {
        let mut source = settings();
        source.overrides_mut().graphics_backend = Some("d3dMetal".into());
        source.overrides_mut().enhanced_sync = Some("msync".into());
        source.overrides_mut().resolution_preset = Some("matchDisplay".into());
        source.overrides_mut().metal4_enabled = Some(true);
        let mut page = ProgramSettingsPage::default();
        page.apply_settings(source);
        let patch = settings_patch(page.settings.as_ref().unwrap(), "--test", &BTreeMap::new());
        assert_eq!(patch["overrides"]["graphicsBackend"], "recommended");
        assert_eq!(patch["overrides"]["enhancedSync"], "esync");
        assert_eq!(patch["overrides"]["resolutionPreset"], "r1920x1080");
        assert!(patch["overrides"].get("metal4Enabled").is_none());
    }

    #[test]
    fn patch_clears_removed_overrides_with_nulls() {
        let mut settings = settings();
        let overrides = settings.overrides_mut();
        overrides.graphics_backend = None;
        overrides.dll_overrides = None;
        let patch = settings_patch(&settings, "-windowed", &BTreeMap::new());
        assert_eq!(patch["arguments"], "-windowed");
        assert_eq!(patch["overrides"]["graphicsBackend"], Value::Null);
        assert_eq!(patch["overrides"]["dllOverrides"], Value::Null);
        assert_eq!(patch["overrides"]["dxvkAsync"], json!(false));
    }

    #[test]
    fn cleared_overrides_encode_as_a_null_group() {
        let mut settings = settings();
        settings.overrides = None;
        let patch = settings_patch(&settings, "", &BTreeMap::new());
        assert_eq!(patch["overrides"], Value::Null);
    }

    #[test]
    fn history_decodes_nested_run_fields() {
        let history: HistoryDto = serde_json::from_str(
            r#"{"entries": [{"id": "A", "programName": "game.exe",
                "logPath": "/tmp/log", "startTime": 1700000000, "endTime": 1700000065,
                "exitCode": 0, "duration": 65.0, "hasWineDebugOutput": true}],
                "futureField": true}"#,
        )
        .expect("history");
        assert_eq!(history.entries.len(), 1);
        assert_eq!(history.entries[0].exit_code, Some(0));
        assert_eq!(duration_label(history.entries[0].duration), "1:05");
        assert_eq!(duration_label(None), "运行中");
    }

    #[test]
    fn labels_cover_the_wire_values_the_bridge_emits() {
        assert_eq!(locale_label("ja_JP.UTF-8"), "日本語");
        assert_eq!(graphics_label("d3dMetal"), "D3DMetal");
        assert_eq!(hud_label("fps"), "仅 FPS");
        assert_eq!(sync_label("msync"), "MSync");
        assert_eq!(resolution_label("r1920x1080"), "1920 × 1080");
        assert_eq!(dll_mode_label("n,b"), "原生优先");
    }

    #[test]
    fn environment_rows_keep_stable_ids_across_add_and_remove() {
        let mut page = ProgramSettingsPage::default();
        page.apply_settings(settings());
        let first = page.env_rows[0].id;
        let next = page.next_env_id;
        page.env_rows.push(EnvRow {
            id: next,
            key: "NEW".into(),
            value: "1".into(),
        });
        page.next_env_id += 1;
        page.env_rows.retain(|row| row.id != first);
        assert_eq!(page.env_rows[0].key, "NEW");
        assert_ne!(page.env_rows[0].id, first);
    }
}
