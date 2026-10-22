//! Local UI state that is not shared with the SwiftUI app: the last window
//! frame, restored on the next launch.

use std::path::PathBuf;

use gpui_kit::{App, Bounds, Pixels, WindowBounds, point, px, size};
use serde::{Deserialize, Serialize};

const MIN_WIDTH: f32 = 800.;
const MIN_HEIGHT: f32 = 580.;

#[derive(Debug, Clone, Copy, PartialEq, Deserialize, Serialize)]
pub(crate) struct WindowFrame {
    pub(crate) x: f32,
    pub(crate) y: f32,
    pub(crate) width: f32,
    pub(crate) height: f32,
}

impl WindowFrame {
    fn is_usable(self) -> bool {
        [self.x, self.y, self.width, self.height]
            .iter()
            .all(|value| value.is_finite())
            && self.width >= MIN_WIDTH
            && self.height >= MIN_HEIGHT
    }

    fn bounds(self) -> Bounds<Pixels> {
        Bounds {
            origin: point(px(self.x), px(self.y)),
            size: size(px(self.width), px(self.height)),
        }
    }
}

/// `on_open_urls` delivers `NSURL.absoluteString`, so Finder hands us
/// `file:///Users/...` with percent escapes. Decode it back to a local path.
pub(crate) fn path_from_open_url(raw: &str) -> PathBuf {
    let Some(rest) = raw.strip_prefix("file://") else {
        return PathBuf::from(raw);
    };
    let rest = rest.strip_prefix("localhost").unwrap_or(rest);
    PathBuf::from(String::from_utf8_lossy(&percent_decode(rest)).into_owned())
}

fn percent_decode(input: &str) -> Vec<u8> {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let high = (bytes[index + 1] as char).to_digit(16);
            let low = (bytes[index + 2] as char).to_digit(16);
            if let (Some(high), Some(low)) = (high, low) {
                out.push((high * 16 + low) as u8);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    out
}

fn state_path() -> Option<PathBuf> {    if let Some(path) = std::env::var_os("WHISKY_GPUI_STATE") {
        return Some(PathBuf::from(path));
    }
    let home = PathBuf::from(std::env::var_os("HOME")?);
    #[cfg(target_os = "macos")]
    let directory = home
        .join("Library")
        .join("Application Support")
        .join("Whisky");
    #[cfg(not(target_os = "macos"))]
    let directory = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .unwrap_or_else(|| home.join(".config"))
        .join("whisky");
    Some(directory.join("gpui-window.json"))
}

fn load() -> Option<WindowFrame> {
    let path = state_path()?;
    let data = std::fs::read(path).ok()?;
    serde_json::from_slice::<WindowFrame>(&data)
        .ok()
        .filter(|frame| frame.is_usable())
}

/// Saved frame when it is usable, otherwise the centered default size.
pub(crate) fn initial_window_bounds(cx: &mut App) -> WindowBounds {
    match load() {
        Some(frame) => WindowBounds::Windowed(frame.bounds()),
        None => WindowBounds::Windowed(Bounds::centered(
            None,
            size(px(1280.), px(820.)),
            cx,
        )),
    }
}

/// Persist the last windowed frame. Maximized and fullscreen windows store
/// their restored bounds, so quitting while zoomed still restores a sane size.
pub(crate) fn save_window(window_bounds: WindowBounds) {
    let bounds = match window_bounds {
        WindowBounds::Windowed(bounds)
        | WindowBounds::Maximized(bounds)
        | WindowBounds::Fullscreen(bounds) => bounds,
    };
    let frame = WindowFrame {
        x: f32::from(bounds.origin.x),
        y: f32::from(bounds.origin.y),
        width: f32::from(bounds.size.width),
        height: f32::from(bounds.size.height),
    };
    if !frame.is_usable() {
        return;
    }
    let Some(path) = state_path() else { return };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Ok(data) = serde_json::to_vec(&frame) {
        let _ = std::fs::write(path, data);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_below_the_window_minimum_are_not_restored() {
        let frame = WindowFrame {
            x: 10.,
            y: 20.,
            width: MIN_WIDTH,
            height: MIN_HEIGHT,
        };
        assert!(frame.is_usable());
        assert!(!WindowFrame { width: 500., ..frame }.is_usable());
        assert!(!WindowFrame { height: f32::NAN, ..frame }.is_usable());
    }

    #[test]
    fn frames_round_trip_through_json() {
        let frame = WindowFrame {
            x: -120.5,
            y: 40.,
            width: 1440.,
            height: 900.,
        };
        let data = serde_json::to_vec(&frame).unwrap();
        assert_eq!(
            serde_json::from_slice::<WindowFrame>(&data).unwrap(),
            frame
        );
    }

    #[test]
    fn finder_file_urls_decode_to_local_paths() {
        assert_eq!(
            path_from_open_url("file:///Users/me/My%20Games/setup.exe"),
            PathBuf::from("/Users/me/My Games/setup.exe")
        );
        assert_eq!(
            path_from_open_url("file://localhost/Users/me/game.exe"),
            PathBuf::from("/Users/me/game.exe")
        );
        assert_eq!(
            path_from_open_url("/Users/me/game.exe"),
            PathBuf::from("/Users/me/game.exe")
        );
    }
}
