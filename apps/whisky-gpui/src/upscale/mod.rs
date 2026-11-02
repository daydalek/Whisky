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
}

impl Engine {
    pub(crate) fn from_raw(raw: &str) -> Self {
        match raw {
            "realcugan" => Self::RealCugan,
            "realcugan-cpu" => Self::RealCuganCpu,
            "anime4k" => Self::Anime4K,
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
        }
    }

    fn available(self) -> bool {
        match self {
            Self::Anime4K => cfg!(target_os = "macos"),
            Self::RealCugan => {
                cfg!(target_os = "macos") || cfg!(any(target_os = "linux", test))
            }
            Self::RealCuganCpu => cfg!(any(target_os = "linux", test)),
        }
    }

    fn ncnn(self) -> bool {
        match self {
            Self::RealCugan => cfg!(target_os = "linux"),
            Self::RealCuganCpu => cfg!(any(target_os = "linux", test)),
            Self::Anime4K => false,
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
    let derived = cache::location(source, passes, &cache_key(engine)?)?;
    let expected = (width << passes, height << passes);
    if cached(&derived, engine, expected) {
        return Some(derived);
    }
    // One cover at a time: a four-times derivation holds hundreds of megabytes
    // of float buffers, and the worker pool would otherwise run several.
    let _worker = WORKER.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if cancel.load(std::sync::atomic::Ordering::Relaxed) {
        return None;
    }
    if cached(&derived, engine, expected) {
        return Some(derived);
    }
    match engine {
        Engine::RealCugan | Engine::RealCuganCpu if engine.ncnn() => {
            ncnn_cover(source, passes, engine, &derived, expected, cancel)
        }
        Engine::Anime4K => anime4k_cover(source, passes, &derived),
        Engine::RealCugan => realcugan_cover(source, passes, &derived),
        Engine::RealCuganCpu => None,
    }
}

fn cached(derived: &Path, engine: Engine, expected: (u32, u32)) -> bool {
    if !derived.exists() {
        return false;
    }
    !engine.ncnn() || valid_ncnn(derived, expected)
}

#[cfg(any(target_os = "linux", test))]
fn valid_ncnn(path: &Path, expected: (u32, u32)) -> bool {
    linux::valid_output(path, expected)
}

#[cfg(not(any(target_os = "linux", test)))]
fn valid_ncnn(_path: &Path, _expected: (u32, u32)) -> bool {
    false
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
    linux::derive(linux::config()?, source, passes, engine, derived, expected, cancel)
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

/// Runs the in-process Metal network for each pass.
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

#[cfg(not(target_os = "macos"))]
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
    fn a_real_cover_goes_through_both_engines() {
        let Ok(path) = std::env::var("WHISKY_COVER_TEST") else { return };
        let cover = PathBuf::from(path);
        let (width, height) = dimensions(&cover).expect("cover readable");
        let passes = capped_passes(2, width, height);
        for engine in engines() {
            let derived = upscaled_cover(&cover, passes, *engine);
            let size = derived.as_ref().and_then(|path| dimensions(path));
            println!("{engine:?}: {derived:?} -> {size:?}");
            assert!(derived.is_some(), "{engine:?} produced nothing");
        }
    }

    #[test]
    fn every_engine_round_trips_its_raw_value() {
        for engine in engines() {
            assert_eq!(Engine::from_raw(engine.raw()), *engine);
        }
    }

    #[test]
    #[cfg(target_os = "macos")]
    fn macos_mapping_keeps_both_bundled_engines() {
        assert_eq!(Engine::from_raw("anime4k"), Engine::Anime4K);
        assert_eq!(Engine::from_raw("realcugan"), Engine::RealCugan);
        assert_eq!(Engine::from_raw("nonsense"), Engine::Anime4K);
        assert_eq!(Engine::from_raw("realcugan-cpu"), Engine::RealCugan);
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn linux_mapping_folds_apple_engines_into_realcugan() {
        assert_eq!(Engine::from_raw("anime4k"), Engine::RealCugan);
        assert_eq!(Engine::from_raw("nonsense"), Engine::RealCugan);
        assert_eq!(Engine::from_raw("realcugan"), Engine::RealCugan);
        assert_eq!(Engine::from_raw("realcugan-cpu"), Engine::RealCuganCpu);
    }
}
