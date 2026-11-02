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
use std::sync::atomic::{AtomicBool, Ordering};

mod cache;

pub(crate) const SUPPORTED: bool = cfg!(any(target_os = "macos", target_os = "linux"));

#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "linux")]
pub(crate) fn status() -> &'static str {
    linux::status()
}

#[cfg(target_os = "macos")]
mod anime4k;

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
    #[cfg(target_os = "linux")]
    RealCuganCpu,
}

impl Engine {
    pub(crate) fn from_raw(raw: &str) -> Self {
        match raw {
            "realcugan" => Self::RealCugan,
            #[cfg(target_os = "linux")]
            "realcugan-cpu" => Self::RealCuganCpu,
            #[cfg(target_os = "linux")]
            _ => Self::RealCugan,
            #[cfg(not(target_os = "linux"))]
            _ => Self::Anime4K,
        }
    }

    pub(crate) fn raw(self) -> &'static str {
        match self {
            Self::Anime4K => "anime4k",
            Self::RealCugan => "realcugan",
            #[cfg(target_os = "linux")]
            Self::RealCuganCpu => "realcugan-cpu",
        }
    }
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
    if !SUPPORTED || !source.is_absolute() || passes == 0 || cancel.load(Ordering::Relaxed) {
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
    {
        let _worker = WORKER.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if cancel.load(Ordering::Relaxed) {
            return None;
        }
        linux::upscaled_cover(source, passes, engine, cancel)
    }
    #[cfg(not(target_os = "linux"))]
    {
    let derived = cache::location(source, passes, engine.raw())?;
    if derived.exists() {
        return Some(derived);
    }
    // One cover at a time: a four-times derivation holds hundreds of megabytes
    // of float buffers, and the worker pool would otherwise run several.
    let _worker = WORKER.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if derived.exists() {
        return Some(derived);
    }
    match engine {
        Engine::Anime4K => anime4k_cover(source, passes, &derived),
        Engine::RealCugan => realcugan_cover(source, passes, &derived)
            .or_else(|| upscaled_cover_fallback(source, passes)),
    }
    }
}

#[cfg(not(target_os = "linux"))]
fn upscaled_cover_fallback(source: &Path, passes: u8) -> Option<PathBuf> {
    let derived = cache::location(source, passes, Engine::Anime4K.raw())?;
    if derived.exists() { return Some(derived); }
    anime4k_cover(source, passes, &derived)
}

/// Runs the in-process Metal network for each pass.
#[cfg(not(target_os = "linux"))]
fn anime4k_cover(source: &Path, passes: u8, derived: &Path) -> Option<PathBuf> {
    let mut image = image::load_from_memory(&std::fs::read(source).ok()?)
        .ok()?
        .to_rgba8();
    for _ in 0 .. passes {
        let (width, height) = image.dimensions();
        image = image::RgbaImage::from_raw(
            width * 2,
            height * 2,
            wide(image.as_raw(), width, height)?,
        )?;
    }
    let (width, height) = image.dimensions();
    cache::store(derived, image.as_raw(), width, height).then(|| derived.to_path_buf())
}

/// Hands the cover to the Core ML helper, which writes the PNG itself.
#[cfg(not(target_os = "linux"))]
fn realcugan_cover(source: &Path, passes: u8, derived: &Path) -> Option<PathBuf> {
    let helper = resource("realcugan-helper")?;
    let model = resource("coreml/realcugan-384x384.mlmodelc")?;
    let parent = derived.parent()?;
    std::fs::create_dir_all(parent).ok()?;
    // Write beside the target and move it in, so an interrupted helper cannot
    // leave a half-written PNG that `exists` would then serve forever.
    let staging = derived.with_extension("part");
    let output = std::process::Command::new(helper)
        .arg("--model").arg(model)
        .arg("--in").arg(source)
        .arg("--out").arg(&staging)
        .arg("--passes").arg(passes.to_string())
        .output()
        .ok()?;
    if !output.status.success() || !staging.exists() {
        let _ = std::fs::remove_file(&staging);
        return None;
    }
    std::fs::rename(&staging, derived).ok()?;
    Some(derived.to_path_buf())
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
        assert!(!SUPPORTED);
        for engine in [Engine::Anime4K, Engine::RealCugan] {
            assert!(upscaled_cover(Path::new("/unused-cover.png"), 1, engine).is_none());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_factor_alone_decides_the_passes() {
        assert_eq!(Factor::Off.passes(), 0);
        assert_eq!(Factor::X2.passes(), 1);
        assert_eq!(Factor::X4.passes(), 2);
        // A thumbnail and a full poster both get the factor's passes; nothing
        // here looks at how large the card is.
        assert_eq!(capped_passes(Factor::X4.passes(), 250, 300), 2);
        assert_eq!(capped_passes(Factor::X4.passes(), 1_000, 1_500), 2);
        assert_eq!(capped_passes(Factor::X2.passes(), 1_000, 1_500), 1);
    }

    #[test]
    fn the_ceiling_drops_passes_instead_of_skipping_the_cover() {
        // 1200x1800 (2.2 MP) at 4x would be 34 MP, over the ceiling, so the
        // single 2x pass is kept rather than leaving the cover untreated.
        assert_eq!(capped_passes(2, 1_200, 1_800), 1);
        // 2400x3600 cannot fit even one pass at 2x, so it is left alone.
        assert_eq!(capped_passes(2, 2_400, 3_600), 0);
    }

    /// Drives the real pipeline against a library cover; skipped unless
    /// `WHISKY_COVER_TEST` points at one. Kept because the engines depend on
    /// files beside the executable that a plain unit test cannot fabricate.
    #[test]
    #[cfg(target_os = "macos")]
    fn a_real_cover_goes_through_both_engines() {
        let Ok(path) = std::env::var("WHISKY_COVER_TEST") else { return };
        let cover = PathBuf::from(path);
        let (width, height) = dimensions(&cover).expect("cover readable");
        let passes = capped_passes(2, width, height);
        for engine in [Engine::Anime4K, Engine::RealCugan] {
            let derived = upscaled_cover(&cover, passes, engine);
            let size = derived.as_ref().and_then(|path| dimensions(path));
            println!("{engine:?}: {derived:?} -> {size:?}");
            assert!(derived.is_some(), "{engine:?} produced nothing");
        }
    }

    #[test]
    fn every_engine_round_trips_its_raw_value() {
        #[cfg(not(target_os = "linux"))]
        for engine in [Engine::Anime4K, Engine::RealCugan] {
            assert_eq!(Engine::from_raw(engine.raw()), engine);
        }
        #[cfg(not(target_os = "linux"))]
        assert_eq!(Engine::from_raw("nonsense"), Engine::Anime4K);
        #[cfg(target_os = "linux")]
        {
            for engine in [Engine::RealCugan, Engine::RealCuganCpu] {
                assert_eq!(Engine::from_raw(engine.raw()), engine);
            }
            assert_eq!(Engine::from_raw("anime4k"), Engine::RealCugan);
            assert_eq!(Engine::from_raw("nonsense"), Engine::RealCugan);
        }
    }
}
