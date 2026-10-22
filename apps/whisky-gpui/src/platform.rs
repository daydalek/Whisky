//! Desktop conventions shared by the root view and menus.

#[cfg(target_os = "macos")]
pub(crate) const UI_FONT: &str = ".AppleSystemUIFont";
#[cfg(not(target_os = "macos"))]
pub(crate) const UI_FONT: &str = "Noto Sans CJK SC";

#[cfg(target_os = "macos")]
pub(crate) const SHORTCUTS: [&str; 6] = [
    "cmd-q", "cmd-r", "cmd-shift-m", "cmd-,", "cmd-ctrl-s", "cmd-m",
];
#[cfg(not(target_os = "macos"))]
pub(crate) const SHORTCUTS: [&str; 6] = [
    "ctrl-q", "ctrl-r", "ctrl-shift-m", "ctrl-,", "ctrl-alt-s", "ctrl-m",
];

#[cfg(target_os = "macos")]
pub(crate) const MOTION_MENU: &str = "界面动画 · ⌘⇧M";
#[cfg(not(target_os = "macos"))]
pub(crate) const MOTION_MENU: &str = "界面动画 · Ctrl+Shift+M";

#[cfg(target_os = "macos")]
pub(crate) const REVEAL_LABEL: &str = "在访达中显示";
#[cfg(not(target_os = "macos"))]
pub(crate) const REVEAL_LABEL: &str = "在文件管理器中显示";
