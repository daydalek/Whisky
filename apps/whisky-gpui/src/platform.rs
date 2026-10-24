//! Desktop conventions shared by the root view and menus.

#[cfg(target_os = "macos")]
pub(crate) const UI_FONT: &str = ".AppleSystemUIFont";
#[cfg(not(target_os = "macos"))]
pub(crate) const UI_FONT: &str = "Noto Sans CJK SC";

#[cfg(target_os = "macos")]
pub(crate) const SHORTCUTS: [&str; 6] = [
    "cmd-q",
    "cmd-r",
    "cmd-shift-m",
    "cmd-,",
    "cmd-ctrl-s",
    "cmd-m",
];
#[cfg(not(target_os = "macos"))]
pub(crate) const SHORTCUTS: [&str; 6] = [
    "ctrl-q",
    "ctrl-r",
    "ctrl-shift-m",
    "ctrl-,",
    "ctrl-alt-s",
    "ctrl-m",
];

#[cfg(target_os = "macos")]
pub(crate) const MOTION_MENU: &str = "界面动画 · ⌘⇧M";
#[cfg(not(target_os = "macos"))]
pub(crate) const MOTION_MENU: &str = "界面动画 · Ctrl+Shift+M";

#[cfg(target_os = "macos")]
pub(crate) const REVEAL_LABEL: &str = "在访达中显示";
#[cfg(not(target_os = "macos"))]
pub(crate) const REVEAL_LABEL: &str = "在文件管理器中显示";

/// Desktop entries need the persistent AppImage path across mount generations.
pub(crate) fn desktop_launcher() -> std::io::Result<std::path::PathBuf> {
    let current = std::env::current_exe()?;
    #[cfg(target_os = "linux")]
    if let (Some(image), Some(directory)) =
        (std::env::var_os("APPIMAGE"), std::env::var_os("APPDIR"))
    {
        return Ok(persistent_launcher(
            &current,
            std::path::Path::new(&image),
            std::path::Path::new(&directory),
        ));
    }
    Ok(current)
}

#[cfg(any(target_os = "linux", test))]
fn persistent_launcher(
    current: &std::path::Path,
    image: &std::path::Path,
    directory: &std::path::Path,
) -> std::path::PathBuf {
    if image.is_absolute()
        && image.is_file()
        && let (Ok(root), Ok(executable)) = (directory.canonicalize(), current.canonicalize())
        && executable.starts_with(root)
    {
        return image.to_path_buf();
    }
    current.to_path_buf()
}

#[cfg(test)]
mod launcher_tests {
    use super::persistent_launcher;

    #[test]
    fn appimage_uses_persistent_path_and_ignores_another_apps_environment() {
        let directory =
            std::env::temp_dir().join(format!("whisky-appimage-launcher-{}", std::process::id()));
        let mount = directory.join("mount/usr/bin");
        std::fs::create_dir_all(&mount).unwrap();
        let image = directory.join("Whisky 包.AppImage");
        let binary = mount.join("whisky-gpui");
        let unrelated = directory.join("native");
        for file in [&image, &binary, &unrelated] {
            std::fs::write(file, b"fixture").unwrap();
        }
        assert_eq!(
            persistent_launcher(&binary, &image, &directory.join("mount")),
            image
        );
        assert_eq!(
            persistent_launcher(&unrelated, &image, &directory.join("mount")),
            unrelated
        );
        std::fs::remove_file(&image).unwrap();
        assert_eq!(
            persistent_launcher(&binary, &image, &directory.join("mount")),
            binary
        );
        std::fs::remove_dir_all(directory).unwrap();
    }
}
