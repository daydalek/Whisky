//! Where a derived cover lives, and how it is written.
//!
//! The key covers the source path, its length, its modification time, the pass
//! count and the engine, so replacing a cover — or importing a custom one over
//! it — invalidates the derivative instead of showing the old artwork enlarged,
//! and the two factors and engines keep their own files.
//!
//! `publish` is the only path by which an inference result becomes a cache
//! entry: the engine writes `stage/output.png` inside an exclusive working
//! directory, the result is fully decoded and dimension-checked, then renamed
//! over the target. Cancellation, engine failure, invalid output and I/O
//! errors all leave the previous entry — or nothing — and the `Stage` drop
//! removes the working directory.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// Bumped when the network or the encoding changes; older derivatives then miss
/// the key instead of being reused.
const FORMAT: u32 = 1;
/// How many unique names `Stage::new` tries before giving up.
const STAGE_ATTEMPTS: u32 = 64;

/// `None` when the platform has no cache directory to write into.
pub(super) fn location(source: &Path, passes: u8, engine: &str) -> Option<PathBuf> {
    location_in(&default_root()?, source, passes, engine)
}

/// The cache file `source`/`passes`/`engine` maps to under an explicit root,
/// so tests and the Linux fallback lookup share the production key without
/// touching process-wide HOME state.
pub(super) fn location_in(
    root: &Path,
    source: &Path,
    passes: u8,
    engine: &str,
) -> Option<PathBuf> {
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
    Some(root.join(format!("{hash:016x}.png")))
}

/// The platform cache root, or `None` when there is nowhere to write.
pub(super) fn default_root() -> Option<PathBuf> {
    directory()
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

/// Output validation shared by every engine: a real file, never a symlink,
/// that fully decodes to exactly `expected` pixels.
pub(super) fn valid_output(path: &Path, expected: (u32, u32)) -> bool {
    let Ok(metadata) = std::fs::symlink_metadata(path) else {
        return false;
    };
    if metadata.is_symlink() || !metadata.is_file() {
        return false;
    }
    if super::dimensions(path) != Some(expected) {
        return false;
    }
    let Ok(bytes) = std::fs::read(path) else {
        return false;
    };
    image::load_from_memory(&bytes)
        .map(|image| (image.width(), image.height()) == expected)
        .unwrap_or(false)
}

/// An exclusive 0700 working directory beside the publish target; `Drop`
/// removes only the directory it created, so a failed or cancelled
/// derivation leaves no partial output and never disturbs other work.
pub(super) struct Stage(pub(super) PathBuf);

impl Stage {
    /// Creates a uniquely named `.stage-*` directory inside `parent`.
    pub(super) fn new(parent: &Path) -> Option<Self> {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        for _ in 0..STAGE_ATTEMPTS {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|age| age.as_nanos())
                .unwrap_or(0);
            let name = format!(
                ".stage-{}-{nanos}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed),
            );
            if let Some(stage) = Self::create(parent, &name) {
                return Some(stage);
            }
        }
        None
    }

    /// Creates exactly `parent/name`, refusing to open anything that already
    /// exists — including another task's directory or a symlink.
    pub(super) fn create(parent: &Path, name: &str) -> Option<Self> {
        let dir = parent.join(name);
        let mut builder = std::fs::DirBuilder::new();
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(&dir).ok()?;
        Some(Self(dir))
    }
}

impl Drop for Stage {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The one place an inference result becomes a cache entry.
///
/// `infer` receives `stage/output.png` inside an exclusive working directory
/// beside `derived` and must write the finished image there — never the
/// final path. On success the output is fully decoded and dimension-checked
/// against `expected`, then atomically renamed over `derived`. Cancellation
/// (checked before inference, after inference and before the rename), a
/// failed callback, an invalid or wrong-sized output, and any I/O or rename
/// failure all return `None` with the `Stage` drop removing the working
/// directory: a previously valid cache entry survives a failed replacement.
/// A symlinked target is never written through, and another task's stage or
/// partial file is never removed.
pub(super) fn publish(
    derived: &Path,
    expected: (u32, u32),
    cancel: &AtomicBool,
    infer: impl FnOnce(&Path) -> Option<()>,
) -> Option<PathBuf> {
    if cancel.load(Ordering::Relaxed) {
        return None;
    }
    if derived
        .symlink_metadata()
        .map(|metadata| metadata.is_symlink())
        .unwrap_or(false)
    {
        return None;
    }
    let parent = derived.parent()?;
    std::fs::create_dir_all(parent).ok()?;
    let stage = Stage::new(parent)?;
    let output = stage.0.join("output.png");
    if cancel.load(Ordering::Relaxed) {
        return None;
    }
    infer(&output)?;
    if cancel.load(Ordering::Relaxed) {
        return None;
    }
    if !valid_output(&output, expected) {
        return None;
    }
    if cancel.load(Ordering::Relaxed) {
        return None;
    }
    std::fs::rename(&output, derived).ok()?;
    Some(derived.to_path_buf())
}

/// Publishes already-encoded RGBA through `publish`, so the Metal path gets
/// the same staging, validation and atomic rename as every other engine.
pub(super) fn store(
    path: &Path,
    rgba: &[u8],
    width: u32,
    height: u32,
    cancel: &AtomicBool,
) -> bool {
    publish(path, (width, height), cancel, |output| {
        image::RgbaImage::from_raw(width, height, rgba.to_vec())?
            .save_with_format(output, image::ImageFormat::Png)
            .ok()
    })
    .is_some()
}
