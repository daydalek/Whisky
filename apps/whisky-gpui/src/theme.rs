//! Visual tokens shared by every surface.
//!
//! Values are moved verbatim from the M0 demo. Do not round or retune them:
//! the committed baseline in `docs/gpui-port/baseline/` compares pixel by pixel.

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
