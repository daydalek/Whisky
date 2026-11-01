//! Where a derived cover lives, and how it is written.
//!
//! The key covers the source path, its length, its modification time, the pass
//! count and the engine, so replacing a cover — or importing a custom one over
//! it — invalidates the derivative instead of showing the old artwork enlarged,
//! and the two factors and engines keep their own files.

use std::path::{Path, PathBuf};

/// Bumped when the network or the encoding changes; older derivatives then miss
/// the key instead of being reused.
const FORMAT: u32 = 1;

/// `None` when the platform has no cache directory to write into.
pub(super) fn location(source: &Path, passes: u8, engine: &str) -> Option<PathBuf> {
    let directory = directory()?;
    let metadata = std::fs::metadata(source).ok()?;
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in source.to_string_lossy().as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    for byte in engine.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    for part in [
        metadata.len(),
        metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|age| age.as_nanos() as u64)
            .unwrap_or(0),
        u64::from(passes),
        u64::from(FORMAT),
    ] {
        hash ^= part;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    Some(directory.join(format!("{hash:016x}.png")))
}

fn directory() -> Option<PathBuf> {
    let base = if cfg!(target_os = "macos") {
        std::env::var_os("HOME").map(|home| PathBuf::from(home).join("Library").join("Caches"))
    } else {
        std::env::var_os("XDG_CACHE_HOME").map(PathBuf::from).or_else(|| {
            std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache"))
        })
    }?;
    Some(base.join("whisky-gpui").join("cover-upscale"))
}

/// Encodes and moves into place, so a half-written file is never served.
pub(super) fn store(path: &Path, rgba: &[u8], width: u32, height: u32) -> bool {
    let Some(parent) = path.parent() else {
        return false;
    };
    if std::fs::create_dir_all(parent).is_err() {
        return false;
    }
    let temporary = path.with_extension("png.part");
    let encoded = image::RgbaImage::from_raw(width, height, rgba.to_vec())
        .map(|image| image.save_with_format(&temporary, image::ImageFormat::Png));
    if !matches!(encoded, Some(Ok(()))) {
        let _ = std::fs::remove_file(&temporary);
        return false;
    }
    if std::fs::rename(&temporary, path).is_err() {
        let _ = std::fs::remove_file(&temporary);
        return false;
    }
    true
}
