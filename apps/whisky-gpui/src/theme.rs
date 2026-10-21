//! Visual tokens shared by every surface.
//!
//! Values are moved verbatim from the M0 demo. Do not round or retune them:
//! the committed baseline in `docs/gpui-port/baseline/` compares pixel by pixel.

pub(crate) const BG: u32 = 0x202021;
pub(crate) const MUTED: u32 = 0x97979b;
pub(crate) const TEXT: u32 = 0xededee;
pub(crate) const ACCENT: u32 = 0xff891b;

// Animation durations. Values match the inline literals they replaced.
pub(crate) const HOVER_MS: u64 = 180;
pub(crate) const BACKDROP_MS: u64 = 420;
pub(crate) const DETAIL_MS: u64 = 240;
pub(crate) const NOTICE_MS: u64 = 180;
pub(crate) const SIDEBAR_MS: u64 = 320;
pub(crate) const SPRING_MS: u64 = 350;
pub(crate) const LIVELY_SPRING_MS: u64 = 460;
