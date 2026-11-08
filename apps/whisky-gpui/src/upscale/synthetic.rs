//! Synthetic upscale engine for test environments without physical GPUs.
//!
//! Pure software pixel scaling with synchronous row checkpoints for
//! cancellation. Publishing — staging, validation, atomic rename — is the
//! caller's job through `cache::publish`; `derive` writes exactly where it
//! is told and never touches the final cache path.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

/// Generate the scaled pixels and encode them as PNG at `output`.
///
/// `checkpoint` runs synchronously on every 32nd output row before the row's
/// pixels are produced; returning `false` — or a cancelled token — aborts
/// the derivation with `None` and nothing written. Tests use the hook to
/// cancel mid-image deterministically instead of relying on timing.
pub(crate) fn derive_with(
    source: &Path,
    passes: u8,
    output: &Path,
    expected: (u32, u32),
    cancel: &AtomicBool,
    checkpoint: impl Fn(u32) -> bool,
) -> Option<()> {
    if cancel.load(Ordering::Relaxed) {
        return None;
    }
    let (out_w, out_h) = expected;
    let img = image::ImageReader::open(source)
        .ok()?
        .with_guessed_format()
        .ok()?
        .decode()
        .ok()?;
    let src_rgba = img.to_rgba8();
    let (src_w, src_h) = src_rgba.dimensions();

    if src_w == 0 || src_h == 0 || out_w == 0 || out_h == 0 {
        return None;
    }

    let mut out_rgba = vec![0u8; (out_w as usize) * (out_h as usize) * 4];
    for y in 0..out_h {
        if y % 32 == 0 && (!checkpoint(y) || cancel.load(Ordering::Relaxed)) {
            return None;
        }
        let src_y = (y >> passes).min(src_h - 1);
        for x in 0..out_w {
            let src_x = (x >> passes).min(src_w - 1);
            let pixel = src_rgba.get_pixel(src_x, src_y);
            let idx = ((y * out_w + x) * 4) as usize;
            out_rgba[idx..idx + 4].copy_from_slice(&pixel.0);
        }
    }

    if cancel.load(Ordering::Relaxed) {
        return None;
    }

    image::RgbaImage::from_raw(out_w, out_h, out_rgba)?
        .save_with_format(output, image::ImageFormat::Png)
        .ok()
}

/// The plain derivation hook used in production: no checkpoints.
pub(crate) fn derive(
    source: &Path,
    passes: u8,
    output: &Path,
    expected: (u32, u32),
    cancel: &AtomicBool,
) -> Option<()> {
    derive_with(source, passes, output, expected, cancel, |_| true)
}
