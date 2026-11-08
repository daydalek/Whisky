//! Cover upscaling for the shelf.
//!
//! Covers arrive smaller than the card draws them — Bangumi thumbnails sit
//! around 250 points, a Steam header is 460 — so the option enlarges them once
//! and caches the result. Two engines share the pipeline:
//!
//! * **Anime4K** runs the same x2 network the Wine GDI presenter uses, on Metal
//!   compute, straight from this process.
//! * **Real-CUGAN** shells out to `realcugan-helper`, which tiles the cover into
//!   the Core ML model's fixed window. Slower to start, better line work.
//!
//! Neither engine is limited by the cover's size: the factor alone decides how
//! many x2 passes run, and only a memory ceiling can reduce that for covers far
//! larger than any card.

use std::path::{Path, PathBuf};
use std::sync::atomic::AtomicBool;

mod cache;
mod process;

pub(crate) mod synthetic;

#[cfg(target_os = "macos")]
mod anime4k;

#[cfg(any(target_os = "linux", test))]
mod linux;

/// Two passes are 4x. A third would be 8x, which no card asks for.
const MAX_PASSES: u8 = 2;
/// Ceiling on the whole derivation, not on the source: 24 megapixels is a
/// 6000x4000 cover at 4x, and the float buffers behind it are already hundreds
/// of megabytes. Above this a pass is dropped rather than the cover skipped.
const MAX_OUTPUT_PIXELS: f64 = 24.0 * 1_048_576.0;
/// Serialises derivations so the GPU memory of one cover is the ceiling.
static WORKER: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Which network does the work.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum Engine {
    Anime4K,
    RealCugan,
    RealCuganCpu,
    Synthetic,
}

impl Engine {
    pub(crate) fn from_raw(raw: &str) -> Self {
        match raw {
            "realcugan" => Self::RealCugan,
            "realcugan-cpu" => Self::RealCuganCpu,
            "anime4k" => Self::Anime4K,
            "synthetic" => Self::Synthetic,
            _ => Self::Anime4K,
        }
        .platform_default()
    }

    fn platform_default(self) -> Self {
        #[cfg(target_os = "macos")]
        {
            match self {
                Self::RealCuganCpu => Self::RealCugan,
                engine => engine,
            }
        }
        #[cfg(target_os = "linux")]
        {
            match self {
                Self::RealCuganCpu => Self::RealCuganCpu,
                Self::Synthetic => Self::Synthetic,
                _ => Self::RealCugan,
            }
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        {
            self
        }
    }

    pub(crate) fn raw(self) -> &'static str {
        match self {
            Self::Anime4K => "anime4k",
            Self::RealCugan => "realcugan",
            Self::RealCuganCpu => "realcugan-cpu",
            Self::Synthetic => "synthetic",
        }
    }

    fn available(self) -> bool {
        match self {
            Self::Anime4K => cfg!(target_os = "macos"),
            Self::RealCugan => {
                cfg!(target_os = "macos") || cfg!(any(target_os = "linux", test))
            }
            Self::RealCuganCpu => cfg!(any(target_os = "linux", test)),
            Self::Synthetic => true,
        }
    }

    fn ncnn(self) -> bool {
        match self {
            Self::RealCugan => cfg!(target_os = "linux"),
            Self::RealCuganCpu => cfg!(any(target_os = "linux", test)),
            Self::Anime4K | Self::Synthetic => false,
        }
    }
}

pub(crate) fn engines() -> &'static [Engine] {
    #[cfg(target_os = "macos")]
    {
        &[Engine::RealCugan, Engine::Anime4K]
    }
    #[cfg(target_os = "linux")]
    {
        &[Engine::RealCugan, Engine::RealCuganCpu]
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        &[]
    }
}

pub(crate) fn supported() -> bool {
    !engines().is_empty()
}

pub(crate) fn ready() -> bool {
    #[cfg(target_os = "macos")]
    {
        true
    }
    #[cfg(target_os = "linux")]
    {
        linux::config().is_some()
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        false
    }
}

fn cache_key(engine: Engine) -> Option<String> {
    #[cfg(any(target_os = "linux", test))]
    if engine.ncnn() {
        return linux::config().map(|config| config.key(engine));
    }
    Some(engine.raw().to_owned())
}

/// How hard the option works on a cover.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Factor {
    Off,
    /// One x2 pass.
    X2,
    /// Two x2 passes: 4x, one more than the card strictly needs.
    X4,
}

impl Factor {
    pub(crate) fn from_raw(raw: &str) -> Self {
        match raw {
            "x2" => Self::X2,
            "x4" => Self::X4,
            _ => Self::Off,
        }
    }

    pub(crate) fn raw(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::X2 => "x2",
            Self::X4 => "x4",
        }
    }

    /// Passes the factor asks for, before the memory ceiling has a say.
    pub(crate) fn passes(self) -> u8 {
        match self {
            Self::Off => 0,
            Self::X2 => 1,
            Self::X4 => 2,
        }
    }
}

/// How many passes fit in the ceiling for a cover of this size.
pub(crate) fn capped_passes(passes: u8, width: u32, height: u32) -> u8 {
    let mut passes = passes.min(MAX_PASSES);
    while passes > 0 {
        let scale = 4_f64.powi(i32::from(passes));
        let pixels = f64::from(width) * f64::from(height) * scale;
        if pixels <= MAX_OUTPUT_PIXELS {
            break;
        }
        passes -= 1;
    }
    passes
}

/// Header-only size read. Metadata providers store covers under a hash with no
/// file extension, so the format has to come from the bytes: asking `image` to
/// guess from the path fails on every one of them.
fn dimensions(source: &Path) -> Option<(u32, u32)> {
    image::ImageReader::open(source)
        .ok()?
        .with_guessed_format()
        .ok()?
        .into_dimensions()
        .ok()
}

/// The worker gate, shared by production and tests: `work` runs holding the
/// single derivation slot, after a fresh cancellation check. Queue
/// cancellation after acquiring the worker is expected behaviour.
fn with_worker<R>(cancel: &AtomicBool, work: impl FnOnce() -> Option<R>) -> Option<R> {
    let _worker = WORKER.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if cancel.load(std::sync::atomic::Ordering::Relaxed) {
        return None;
    }
    work()
}

/// The derived cover for `source`, or `None` when it cannot be produced — the
/// caller then keeps drawing the original.
pub(crate) fn upscaled_cover(source: &Path, passes: u8, engine: Engine) -> Option<PathBuf> {
    upscaled_cover_with_cancel(source, passes, engine, &AtomicBool::new(false))
}

pub(crate) fn upscaled_cover_with_cancel(
    source: &Path,
    passes: u8,
    engine: Engine,
    cancel: &AtomicBool,
) -> Option<PathBuf> {
    upscaled_cover_in(source, passes, engine, cancel, &cache::default_root()?)
}

/// The shared implementation with an explicit cache root: tests pass a
/// per-test directory so no global HOME/cache state is involved, while
/// `upscaled_cover_with_cancel` resolves the platform root and forwards.
pub(crate) fn upscaled_cover_in(
    source: &Path,
    passes: u8,
    engine: Engine,
    cancel: &AtomicBool,
    cache_root: &Path,
) -> Option<PathBuf> {
    if !engine.available() || !source.is_absolute() || passes == 0 {
        return None;
    }
    if cancel.load(std::sync::atomic::Ordering::Relaxed) {
        return None;
    }
    let (width, height) = dimensions(source)?;
    if width == 0 || height == 0 {
        return None;
    }
    let passes = capped_passes(passes, width, height);
    if passes == 0 {
        return None;
    }
    #[cfg(target_os = "linux")]
    if engine != Engine::Synthetic {
        return with_worker(cancel, || {
            linux::upscaled_cover(source, passes, engine, cancel, cache_root)
        });
    }
    let derived = cache::location_in(cache_root, source, passes, &cache_key(engine)?)?;
    let expected = (
        width.checked_shl(u32::from(passes))?,
        height.checked_shl(u32::from(passes))?,
    );
    // One cover at a time: a four-times derivation holds hundreds of megabytes
    // of float buffers, and the worker pool would otherwise run several. The
    // hit check shares the gate too: full-PNG validation decodes the file, so
    // parallel cache hits outside the gate could still multiply decode memory.
    with_worker(cancel, || {
        if cached(&derived, expected) {
            return Some(derived.clone());
        }
        match engine {
            #[cfg(any(target_os = "linux", test))]
            Engine::RealCugan | Engine::RealCuganCpu if engine.ncnn() => {
                ncnn_cover(source, passes, engine, &derived, expected, cancel)
            }
            #[cfg(not(target_os = "linux"))]
            Engine::Anime4K => anime4k_cover(source, passes, &derived, cancel),
            #[cfg(not(target_os = "linux"))]
            Engine::RealCugan => realcugan_cover(source, passes, &derived, expected, cancel),
            Engine::Synthetic => cache::publish(&derived, expected, cancel, |output| {
                synthetic::derive(source, passes, output, expected, cancel)
            }),
            _ => None,
        }
    })
}

/// Cache hits share publish's validation for every engine: a real file that
/// fully decodes to exactly `expected`, never a symlink or a truncated PNG.
fn cached(derived: &Path, expected: (u32, u32)) -> bool {
    cache::valid_output(derived, expected)
}

#[cfg(any(target_os = "linux", test))]
fn ncnn_cover(
    source: &Path,
    passes: u8,
    engine: Engine,
    derived: &Path,
    expected: (u32, u32),
    cancel: &AtomicBool,
) -> Option<PathBuf> {
    linux::derive(&linux::config()?, source, passes, engine, derived, expected, cancel)
}

#[cfg(not(any(target_os = "linux", test)))]
fn ncnn_cover(
    _source: &Path,
    _passes: u8,
    _engine: Engine,
    _derived: &Path,
    _expected: (u32, u32),
    _cancel: &AtomicBool,
) -> Option<PathBuf> {
    None
}

/// Runs the in-process Metal network for each pass, checking the token
/// before and after every GPU dispatch. A cancelled token lands mid-pass —
/// an executing GPU command is not preempted.
#[cfg(not(target_os = "linux"))]
fn anime4k_cover(
    source: &Path,
    passes: u8,
    derived: &Path,
    cancel: &AtomicBool,
) -> Option<PathBuf> {
    let mut image = image::load_from_memory(&std::fs::read(source).ok()?)
        .ok()?
        .to_rgba8();
    for _ in 0 .. passes {
        if cancel.load(std::sync::atomic::Ordering::Relaxed) {
            return None;
        }
        let (width, height) = image.dimensions();
        image = image::RgbaImage::from_raw(
            width * 2,
            height * 2,
            wide(image.as_raw(), width, height)?,
        )?;
        if cancel.load(std::sync::atomic::Ordering::Relaxed) {
            return None;
        }
    }
    let (width, height) = image.dimensions();
    cache::store(derived, image.as_raw(), width, height, cancel).then(|| derived.to_path_buf())
}

/// Hands the cover to the Core ML helper through the shared bounded process
/// runner; staging, validation and the atomic rename are `publish`'s job.
#[cfg(not(target_os = "linux"))]
fn realcugan_cover(
    source: &Path,
    passes: u8,
    derived: &Path,
    expected: (u32, u32),
    cancel: &AtomicBool,
) -> Option<PathBuf> {
    let helper = resource("realcugan-helper")?;
    let model = resource("coreml/realcugan-384x384.mlmodelc")?;
    cache::publish(derived, expected, cancel, |output| {
        let mut command = std::process::Command::new(&helper);
        command
            .arg("--model").arg(&model)
            .arg("--in").arg(source)
            .arg("--out").arg(output)
            .arg("--passes").arg(passes.to_string());
        process::run_helper(command, output, process::HELPER_TIMEOUT, cancel)
    })
}

/// A file shipped in the bundle's `Resources`, next to the executable.
#[cfg(not(target_os = "linux"))]
fn resource(name: &str) -> Option<PathBuf> {
    let resources = std::env::current_exe()
        .ok()?
        .parent()?
        .parent()?
        .join("Resources");
    let path = resources.join(name);
    path.exists().then_some(path)
}

/// Runs the x2 network once. Separated so the platform gate lives in one place.
#[cfg(target_os = "macos")]
fn wide(rgba: &[u8], width: u32, height: u32) -> Option<Vec<u8>> {
    anime4k::upscale_x2(rgba, width, height)
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn wide(_rgba: &[u8], _width: u32, _height: u32) -> Option<Vec<u8>> {
    None
}

#[cfg(all(test, not(any(target_os = "macos", target_os = "linux"))))]
mod platform_tests {
    use super::*;

    #[test]
    fn unsupported_platform_never_starts_an_upscaler() {
        assert!(!supported());
        assert!(engines().is_empty());
        for engine in [Engine::Anime4K, Engine::RealCugan, Engine::RealCuganCpu] {
            assert!(upscaled_cover(Path::new("/unused-cover.png"), 1, engine).is_none());
        }
    }
}

#[cfg(test)]
mod tests;
