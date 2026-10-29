//! Visual tokens shared by every surface, with dynamic Light / Dark / System
//! appearance adaptation.
//!
//! Dark-mode values match the M0 baseline verbatim so existing visual captures
//! stay pixel-identical when dark mode is active.

use std::sync::atomic::{AtomicBool, Ordering};

use gpui_kit::component::theme::{Theme, ThemeMode};
use gpui_kit::{App, Window, WindowAppearance};
use serde::{Deserialize, Serialize};

pub(crate) const BG: u32 = 0x202021;
pub(crate) const MUTED: u32 = 0x97979b;
pub(crate) const TEXT: u32 = 0xededee;
pub(crate) const ACCENT: u32 = 0xff891b;
// Connection state. Added for the M1a status pill and failure dialog.
pub(crate) const SUCCESS: u32 = 0x3ecf8e;
pub(crate) const DANGER: u32 = 0xff5f57;

// Radii used by the status pill and its dialog.
pub(crate) const RADIUS_SM: f32 = 6.;
pub(crate) const RADIUS_LG: f32 = 14.;

// Surfaces for the status pill and its dialog.
pub(crate) const HOVER: u32 = 0xffffff10;
pub(crate) const SURFACE: u32 = 0x29292c;
pub(crate) const SURFACE_BORDER: u32 = 0xffffff23;
pub(crate) const OVERLAY: u32 = 0x00000088;

// Animation durations. Values match the inline literals they replaced.
pub(crate) const HOVER_MS: u64 = 180;
pub(crate) const BACKDROP_MS: u64 = 420;
pub(crate) const DETAIL_MS: u64 = 240;
pub(crate) const NOTICE_MS: u64 = 180;
pub(crate) const SIDEBAR_MS: u64 = 320;
pub(crate) const SPRING_MS: u64 = 350;
pub(crate) const LIVELY_SPRING_MS: u64 = 460;

static DARK_MODE: AtomicBool = AtomicBool::new(true);

/// User-facing appearance preference: follow OS appearance or force Light/Dark.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum AppearanceMode {
    #[default]
    System,
    Light,
    Dark,
}

pub(crate) const APPEARANCE_OPTIONS: [(&str, &str); 3] = [
    ("跟随系统", "system"),
    ("浅色", "light"),
    ("深色", "dark"),
];

impl AppearanceMode {
    pub(crate) fn from_wire(raw: &str) -> Self {
        match raw.trim().to_ascii_lowercase().as_str() {
            "light" => Self::Light,
            "dark" => Self::Dark,
            _ => Self::System,
        }
    }

    pub(crate) fn wire(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::Light => "light",
            Self::Dark => "dark",
        }
    }

    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::System => "跟随系统",
            Self::Light => "浅色",
            Self::Dark => "深色",
        }
    }

    pub(crate) fn icon_name(self) -> &'static str {
        match self {
            Self::System => "sun-moon",
            Self::Light => "sun",
            Self::Dark => "moon",
        }
    }

    pub(crate) fn next(self) -> Self {
        match self {
            Self::System => Self::Light,
            Self::Light => Self::Dark,
            Self::Dark => Self::System,
        }
    }

    pub(crate) fn resolve(self, system: WindowAppearance) -> ThemeMode {
        match self {
            Self::Light => ThemeMode::Light,
            Self::Dark => ThemeMode::Dark,
            Self::System => match system {
                WindowAppearance::Light | WindowAppearance::VibrantLight => ThemeMode::Light,
                WindowAppearance::Dark | WindowAppearance::VibrantDark => ThemeMode::Dark,
            },
        }
    }

    pub(crate) fn window_override(self) -> Option<WindowAppearance> {
        match self {
            Self::System => None,
            Self::Light => Some(WindowAppearance::Light),
            Self::Dark => Some(WindowAppearance::Dark),
        }
    }
}

pub(crate) fn is_dark() -> bool {
    DARK_MODE.load(Ordering::Relaxed)
}

pub(crate) fn set_dark(dark: bool) {
    DARK_MODE.store(dark, Ordering::Relaxed);
}

/// Synchronize the global `gpui-kit` component theme and local surface tokens
/// with `mode` and the current OS `WindowAppearance`.
pub(crate) fn sync_theme(
    mode: AppearanceMode,
    window: Option<&Window>,
    cx: &mut App,
) -> ThemeMode {
    let system = window
        .map(Window::appearance)
        .unwrap_or_else(|| cx.window_appearance());
    let resolved = mode.resolve(system);
    set_dark(resolved.is_dark());
    if Theme::global(cx).mode != resolved {
        Theme::change(resolved, None, cx);
        if !resolved.is_dark() {
            Theme::update(cx, |theme| {
                let light_gray: gpui_kit::Hsla = gpui_kit::rgb(0xe8e8ed).into();
                let light_gray_hover: gpui_kit::Hsla = gpui_kit::rgb(0xdedee5).into();
                let light_gray_border: gpui_kit::Hsla = gpui_kit::rgb(0xd1d1d8).into();
                theme.colors.accent = light_gray;
                theme.colors.list_active = light_gray;
                theme.colors.list_active_border = light_gray_border;
                theme.colors.table_active = light_gray;
                theme.colors.table_active_border = light_gray_border;
                theme.colors.selection = light_gray_hover;
                theme.colors.ring = light_gray_border;
            });
        }
    }
    resolved
}

// MARK: - Dynamic semantic color tokens

pub(crate) fn bg() -> u32 {
    if is_dark() { BG } else { 0xf5f5f7 }
}

pub(crate) fn surface() -> u32 {
    if is_dark() { SURFACE } else { 0xfafafb }
}

pub(crate) fn surface_border() -> u32 {
    if is_dark() { SURFACE_BORDER } else { 0x00000016 }
}

pub(crate) fn divider() -> u32 {
    if is_dark() { 0xffffff0c } else { 0x00000010 }
}

pub(crate) fn text() -> u32 {
    if is_dark() { TEXT } else { 0x1c1c1e }
}

pub(crate) fn subtext() -> u32 {
    if is_dark() { 0xc3c3ca } else { 0x3a3a3c }
}

pub(crate) fn muted_color() -> u32 {
    if is_dark() { MUTED } else { 0x6e6e73 }
}

pub(crate) fn hover() -> u32 {
    if is_dark() { HOVER } else { 0x00000008 }
}

pub(crate) fn hover_strong() -> u32 {
    if is_dark() { 0xffffff18 } else { 0x00000010 }
}

pub(crate) fn selected_bg() -> u32 {
    if is_dark() { 0xffffff1a } else { 0x00000010 }
}

pub(crate) fn card_bg() -> u32 {
    if is_dark() { 0xffffff08 } else { 0x00000006 }
}

pub(crate) fn card_bg_subtle() -> u32 {
    if is_dark() { 0xffffff05 } else { 0x00000004 }
}

pub(crate) fn card_border() -> u32 {
    if is_dark() { 0xffffff0d } else { 0x00000010 }
}

pub(crate) fn section_bg() -> u32 {
    if is_dark() { 0xffffff08 } else { 0x00000006 }
}

pub(crate) fn section_border() -> u32 {
    if is_dark() { 0xffffff0a } else { 0x00000010 }
}

pub(crate) fn toolbar_bg() -> u32 {
    if is_dark() { 0x272729f5 } else { 0xf5f5f7f2 }
}

pub(crate) fn sidebar_gradient() -> (u32, u32) {
    if is_dark() {
        (0x272930ff, 0x242529ff)
    } else {
        (0xededf0ff, 0xe6e6ebff)
    }
}

pub(crate) fn placeholder_gradient() -> (u32, u32) {
    if is_dark() {
        (0xffffff12, 0xffffff04)
    } else {
        (0x0000000b, 0x00000004)
    }
}

pub(crate) fn portrait_bg() -> u32 {
    if is_dark() { 0x1b1b1eff } else { 0x00000008 }
}

pub(crate) fn badge_bg() -> u32 {
    if is_dark() { 0xffffff0b } else { 0x00000009 }
}

pub(crate) fn badge_text() -> u32 {
    if is_dark() { 0xb8b8bc } else { 0x48484c }
}

pub(crate) fn round_btn_bg() -> u32 {
    if is_dark() { 0xffffff09 } else { 0x00000008 }
}

pub(crate) fn round_btn_border() -> u32 {
    if is_dark() { 0xffffff0d } else { 0x00000012 }
}

pub(crate) fn round_btn_hover() -> u32 {
    if is_dark() { 0xffffff20 } else { 0x00000014 }
}

pub(crate) fn toast_bg() -> u32 {
    if is_dark() { 0x3b3b40 } else { 0xf2f2f5 }
}

pub(crate) fn toast_border() -> u32 {
    if is_dark() { 0xffffff20 } else { 0x00000018 }
}

pub(crate) fn overlay() -> u32 {
    if is_dark() { OVERLAY } else { 0x00000044 }
}

pub(crate) fn star_empty() -> u32 {
    if is_dark() { 0xffffff26 } else { 0x00000020 }
}

pub(crate) fn timeline_dot_idle() -> u32 {
    if is_dark() { 0x565658 } else { 0xb8b8bd }
}

pub(crate) fn code_bg() -> u32 {
    if is_dark() { 0x00000040 } else { 0x00000007 }
}

pub(crate) fn pill_selected_text() -> u32 {
    if is_dark() { 0xffffff } else { 0x1c1c1e }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appearance_mode_wire_and_cycle_round_trip() {
        for mode in [AppearanceMode::System, AppearanceMode::Light, AppearanceMode::Dark] {
            assert_eq!(AppearanceMode::from_wire(mode.wire()), mode);
        }
        assert_eq!(AppearanceMode::from_wire("unknown"), AppearanceMode::System);
        assert_eq!(AppearanceMode::System.next(), AppearanceMode::Light);
        assert_eq!(AppearanceMode::Light.next(), AppearanceMode::Dark);
        assert_eq!(AppearanceMode::Dark.next(), AppearanceMode::System);
    }

    #[test]
    fn appearance_mode_resolves_system_and_explicit_overrides() {
        assert_eq!(
            AppearanceMode::System.resolve(WindowAppearance::Light),
            ThemeMode::Light
        );
        assert_eq!(
            AppearanceMode::System.resolve(WindowAppearance::VibrantLight),
            ThemeMode::Light
        );
        assert_eq!(
            AppearanceMode::System.resolve(WindowAppearance::Dark),
            ThemeMode::Dark
        );
        assert_eq!(
            AppearanceMode::System.resolve(WindowAppearance::VibrantDark),
            ThemeMode::Dark
        );
        assert_eq!(
            AppearanceMode::Light.resolve(WindowAppearance::Dark),
            ThemeMode::Light
        );
        assert_eq!(
            AppearanceMode::Dark.resolve(WindowAppearance::Light),
            ThemeMode::Dark
        );
    }

    #[test]
    fn dynamic_tokens_switch_between_dark_and_light() {
        set_dark(true);
        assert_eq!(bg(), BG);
        assert_eq!(surface(), SURFACE);
        assert_eq!(text(), TEXT);

        set_dark(false);
        assert_ne!(bg(), BG);
        assert_ne!(surface(), SURFACE);
        assert_ne!(text(), TEXT);
        for rgba_token in [
            surface_border(),
            divider(),
            hover(),
            hover_strong(),
            selected_bg(),
            card_bg(),
            card_bg_subtle(),
            card_border(),
            section_bg(),
            section_border(),
            portrait_bg(),
            badge_bg(),
            round_btn_bg(),
            round_btn_border(),
            round_btn_hover(),
            toast_border(),
            overlay(),
            star_empty(),
            code_bg(),
        ] {
            let color = gpui_kit::rgba(rgba_token);
            assert!(
                (color.r - color.g).abs() < 0.02 && (color.g - color.b).abs() < 0.02,
                "expected neutral gray rgba token, got 0x{rgba_token:08x} -> {color:?}"
            );
        }

        set_dark(true);
    }
}
