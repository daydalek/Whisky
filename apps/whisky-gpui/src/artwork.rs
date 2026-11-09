use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use gpui_kit::{prelude::*, *};
use image::ImageDecoder;

const CACHE_BYTES: usize = 96 * 1024 * 1024;
const CACHE_ENTRIES: usize = 192;
const MAX_DECODES: usize = 2;
const MAX_QUEUED: usize = 64;
const MAX_SOURCE_BYTES: u64 = 128 * 1024 * 1024;
const EDGES: [u32; 7] = [128, 256, 512, 768, 1024, 1536, 2048];
/// Blur levels the backdrop control can pick; level 0 is the sharp image.
pub(crate) const BLUR_LEVELS: u8 = 5;
/// Blur erases high-frequency detail, so variants decode at a small fixed
/// edge instead of the display edge — cheap to compute and ~25× less memory.
const BLUR_EDGE: u32 = 384;
/// `fast_blur` sigma per level at `BLUR_EDGE` resolution.
const BLUR_SIGMAS: [f32; BLUR_LEVELS as usize - 1] = [1.4, 2.8, 5.0, 8.0];

/// The level a stored number selects, clamped to the supported range.
pub(crate) fn blur_level(value: f64) -> u8 {
    if value.is_finite() {
        value.round().clamp(0., f64::from(BLUR_LEVELS - 1)) as u8
    } else {
        0
    }
}

/// Sigma applied at decode resolution; level 0 draws the sharp image.
fn blur_sigma(level: u8) -> Option<f32> {
    level
        .checked_sub(1)
        .and_then(|index| BLUR_SIGMAS.get(usize::from(index)))
        .copied()
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct Key {
    original: PathBuf,
    upscale_variant: bool,
    resolved: PathBuf,
    edge: u32,
    blur: u8,
    length: u64,
    modified_ns: u128,
}

struct Entry {
    image: Option<Arc<RenderImage>>,
    finished: bool,
    bytes: usize,
    touched: u64,
    seen_frame: u64,
    waiters: HashSet<EntityId>,
}

pub(crate) struct ArtworkCache {
    entries: HashMap<Key, Entry>,
    queue: VecDeque<Key>,
    jobs: HashMap<Key, Task<()>>,
    bytes: usize,
    clock: u64,
    frame: u64,
}

fn visible(bounds: Bounds<Pixels>, clip: Bounds<Pixels>) -> bool {
    let overlap = bounds.intersect(&clip);
    overlap.size.width > px(0.) && overlap.size.height > px(0.)
}

fn target_edge(width: f32, height: f32, scale: f32) -> u32 {
    let needed = (width.max(height) * scale).ceil();
    if !needed.is_finite() || needed <= 0. {
        return EDGES[0];
    }
    EDGES
        .iter()
        .copied()
        .find(|edge| *edge as f32 >= needed)
        .unwrap_or(2048)
}

fn fingerprint(path: &Path) -> (u64, u128) {
    std::fs::metadata(path)
        .map(|meta| {
            (
                meta.len(),
                meta.modified()
                    .ok()
                    .and_then(|modified| modified.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|duration| duration.as_nanos())
                    .unwrap_or(0),
            )
        })
        .unwrap_or((0, 0))
}

fn size_allowed(total_bytes: u64, width: u32, height: u32) -> bool {
    width != 0 && height != 0 && total_bytes <= MAX_SOURCE_BYTES
}

fn decode(path: &Path, edge: u32, blur: u8) -> Option<Arc<RenderImage>> {
    let mut reader = image::ImageReader::open(path)
        .ok()?
        .with_guessed_format()
        .ok()?;
    let mut limits = image::Limits::default();
    limits.max_image_width = Some(16_384);
    limits.max_image_height = Some(16_384);
    limits.max_alloc = Some(256 * 1024 * 1024);
    reader.limits(limits);
    let mut decoder = reader.into_decoder().ok()?;
    let (width, height) = decoder.dimensions();
    if !size_allowed(decoder.total_bytes(), width, height) {
        return None;
    }
    let orientation = decoder
        .orientation()
        .unwrap_or(image::metadata::Orientation::NoTransforms);
    let mut decoded = image::DynamicImage::from_decoder(decoder).ok()?;
    decoded.apply_orientation(orientation);
    if decoded.width().max(decoded.height()) > edge {
        decoded = decoded.resize(edge, edge, image::imageops::FilterType::Triangle);
    }
    let mut rgba = decoded.to_rgba8();
    if let Some(sigma) = blur_sigma(blur) {
        rgba = image::imageops::fast_blur(&rgba, sigma);
    }
    for pixel in rgba.pixels_mut() {
        pixel.0.swap(0, 2);
    }
    Some(Arc::new(RenderImage::new(vec![image::Frame::new(rgba)])))
}

fn render_image_bytes(image: &RenderImage) -> usize {
    let size = image.size(0);
    size.width.0.max(0) as usize * size.height.0.max(0) as usize * 4
}

#[cfg(target_os = "macos")]
fn release_decode_scratch() {
    use std::sync::Mutex;
    use std::time::{Duration, Instant};
    static LAST: Mutex<Option<Instant>> = Mutex::new(None);
    let Ok(mut last) = LAST.try_lock() else {
        return;
    };
    if last.is_some_and(|at| at.elapsed() < Duration::from_secs(1)) {
        return;
    }
    *last = Some(Instant::now());
    drop(last);
    unsafe extern "C" {
        fn malloc_zone_pressure_relief(zone: *mut std::ffi::c_void, goal: usize) -> usize;
    }
    unsafe {
        malloc_zone_pressure_relief(std::ptr::null_mut(), 0);
    }
}

fn eviction_keys(entries: &HashMap<Key, Entry>, mut bytes: usize) -> Vec<Key> {
    let mut keys = Vec::new();
    if entries.len() <= CACHE_ENTRIES && bytes <= CACHE_BYTES {
        return keys;
    }
    let mut sorted: Vec<_> = entries.iter().collect();
    sorted.sort_by_key(|(_, entry)| entry.touched);
    let mut remaining = entries.len();
    for (key, entry) in sorted {
        if remaining <= CACHE_ENTRIES && bytes <= CACHE_BYTES {
            break;
        }
        keys.push(key.clone());
        remaining -= 1;
        bytes = bytes.saturating_sub(entry.bytes);
    }
    keys
}

impl ArtworkCache {
    pub(crate) fn new(cx: &mut App) -> Entity<Self> {
        let cache = cx.new(|_| Self {
            entries: HashMap::new(),
            queue: VecDeque::new(),
            jobs: HashMap::new(),
            bytes: 0,
            clock: 0,
            frame: 0,
        });
        cx.observe_release(&cache, |cache, cx| {
            for entry in cache.entries.values_mut() {
                if let Some(image) = entry.image.take() {
                    cx.drop_image(image, None);
                }
            }
        })
        .detach();
        cache
    }

    pub(crate) fn begin_frame(&mut self, _cx: &mut Context<Self>) {
        self.frame = self.frame.wrapping_add(1);
    }

    fn request(
        &mut self,
        original: &Path,
        upscale_variant: bool,
        resolved: PathBuf,
        edge: u32,
        blur: u8,
        view: EntityId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<Arc<RenderImage>> {
        let (length, modified_ns) = fingerprint(&resolved);
        let key = Key {
            original: original.to_path_buf(),
            upscale_variant,
            resolved,
            edge,
            blur,
            length,
            modified_ns,
        };
        for image in self.supersede(&key) {
            cx.drop_image(image, Some(&mut *window));
        }
        if !self.enqueue(key.clone(), view) {
            return None;
        }
        self.start_jobs(cx);
        for image in self.evict_to_budget() {
            cx.drop_image(image, Some(&mut *window));
        }
        self.entries.get(&key).and_then(|entry| entry.image.clone())
    }

    fn enqueue(&mut self, key: Key, view: EntityId) -> bool {
        self.clock = self.clock.wrapping_add(1);
        let touched = self.clock;
        if let Some(entry) = self.entries.get_mut(&key) {
            entry.touched = touched;
            entry.seen_frame = self.frame;
            if !entry.finished {
                entry.waiters.insert(view);
            }
            return true;
        }
        if self.queue.len() >= MAX_QUEUED {
            return false;
        }
        let mut waiters = HashSet::new();
        waiters.insert(view);
        self.entries.insert(
            key.clone(),
            Entry {
                image: None,
                finished: false,
                bytes: 0,
                touched,
                seen_frame: self.frame,
                waiters,
            },
        );
        self.queue.push_back(key);
        true
    }

    fn can_start_job(&self) -> bool {
        self.jobs.len() < MAX_DECODES
    }

    fn supersede(&mut self, key: &Key) -> Vec<Arc<RenderImage>> {
        let stale: Vec<Key> = self
            .entries
            .keys()
            .filter(|candidate| {
                **candidate != *key
                    && candidate.original == key.original
                    && candidate.upscale_variant == key.upscale_variant
                    && candidate.edge == key.edge
                    && candidate.blur == key.blur
            })
            .cloned()
            .collect();
        self.remove_entries(stale)
    }

    fn remove_entries(&mut self, keys: Vec<Key>) -> Vec<Arc<RenderImage>> {
        let mut released = Vec::new();
        for key in keys {
            self.queue.retain(|queued| *queued != key);
            if let Some(entry) = self.entries.remove(&key) {
                self.bytes = self.bytes.saturating_sub(entry.bytes);
                if let Some(image) = entry.image {
                    released.push(image);
                }
            }
        }
        released
    }

    fn evict_to_budget(&mut self) -> Vec<Arc<RenderImage>> {
        let keys = eviction_keys(&self.entries, self.bytes);
        self.remove_entries(keys)
    }

    fn next_job(&mut self) -> Option<Key> {
        while let Some(key) = self.queue.pop_front() {
            match self.entries.get(&key) {
                Some(entry)
                    if !entry.finished && entry.seen_frame >= self.frame.saturating_sub(1) =>
                {
                    return Some(key);
                }
                Some(entry) => {
                    self.bytes = self.bytes.saturating_sub(entry.bytes);
                    self.entries.remove(&key);
                }
                None => {}
            }
        }
        None
    }

    fn start_jobs(&mut self, cx: &mut Context<Self>) {
        while self.can_start_job() {
            let Some(key) = self.next_job() else {
                break;
            };
            if self.jobs.contains_key(&key) {
                continue;
            }
            let job_key = key.clone();
            let resolved = key.resolved.clone();
            let edge = key.edge;
            let blur = key.blur;
            let task = cx.spawn(async move |this, cx| {
                let decoded = cx
                    .background_spawn(async move { decode(&resolved, edge, blur) })
                    .await;
                let _ = this.update(cx, |cache, cx| cache.complete(&job_key, decoded, cx));
            });
            self.jobs.insert(key, task);
        }
    }

    fn finish(
        &mut self,
        key: &Key,
        decoded: Option<Arc<RenderImage>>,
    ) -> (Vec<EntityId>, Vec<Arc<RenderImage>>) {
        self.jobs.remove(key);
        self.queue.retain(|queued| *queued != *key);
        let mut waiters = Vec::new();
        let mut released = Vec::new();
        if let Some(entry) = self.entries.get_mut(key) {
            entry.finished = true;
            waiters.extend(entry.waiters.drain());
            if let Some(image) = decoded {
                let bytes = render_image_bytes(&image);
                entry.bytes = bytes;
                self.bytes = self.bytes.saturating_add(bytes);
                entry.image = Some(image);
            }
        } else if let Some(image) = decoded {
            released.push(image);
        }
        released.extend(self.evict_to_budget());
        (waiters, released)
    }

    fn complete(&mut self, key: &Key, decoded: Option<Arc<RenderImage>>, cx: &mut Context<Self>) {
        let (waiters, released) = self.finish(key, decoded);
        for image in released {
            cx.drop_image(image, None);
        }
        for waiter in waiters {
            App::notify(cx, waiter);
        }
        self.start_jobs(cx);
        #[cfg(target_os = "macos")]
        if self.jobs.is_empty() && self.queue.is_empty() {
            cx.background_spawn(async {
                release_decode_scratch();
            })
            .detach();
        }
    }
}

pub(crate) struct Artwork {
    cache: Entity<ArtworkCache>,
    source: PathBuf,
    resolver: Option<Box<dyn Fn(&Path, &mut App) -> PathBuf>>,
    fit: ObjectFit,
    blur: u8,
    style: StyleRefinement,
}
impl Artwork {
    pub(crate) fn new(cache: Entity<ArtworkCache>, source: PathBuf) -> Self {
        Self {
            cache,
            source,
            resolver: None,
            fit: ObjectFit::Contain,
            blur: 0,
            style: StyleRefinement::default(),
        }
    }
    pub(crate) fn with_resolver(
        mut self,
        resolver: impl Fn(&Path, &mut App) -> PathBuf + 'static,
    ) -> Self {
        self.resolver = Some(Box::new(resolver));
        self
    }
    pub(crate) fn object_fit(mut self, fit: ObjectFit) -> Self {
        self.fit = fit;
        self
    }
    /// A blurred variant: a separate cache entry decoded at `BLUR_EDGE` with
    /// the level's sigma applied once, off the render thread.
    pub(crate) fn blur(mut self, level: u8) -> Self {
        self.blur = level;
        self
    }
}
impl Styled for Artwork {
    fn style(&mut self) -> &mut StyleRefinement {
        &mut self.style
    }
}
impl IntoElement for Artwork {
    type Element = Div;
    fn into_element(self) -> Self::Element {
        let mut computed = Style::default();
        computed.refine(&self.style);
        let corners = computed.corner_radii;
        let own_opacity = computed.opacity.unwrap_or(1.);
        let fit = self.fit;
        let blur = self.blur;
        let cache = self.cache;
        let original = self.source;
        let upscale_variant = self.resolver.is_some();
        let resolver = self.resolver;
        let mut outer = div();
        *outer.style() = self.style;
        outer.child(
            canvas(
                move |bounds, window, cx| {
                    if own_opacity <= 0.001 || !visible(bounds, window.content_mask().bounds) {
                        return None;
                    }
                    let path = resolver
                        .as_ref()
                        .map_or_else(|| original.clone(), |resolve| resolve(&original, cx));
                    let mut edge = target_edge(
                        f32::from(bounds.size.width),
                        f32::from(bounds.size.height),
                        window.scale_factor(),
                    );
                    if blur > 0 {
                        edge = edge.min(BLUR_EDGE);
                    }
                    let view = window.current_view();
                    cache.update(cx, |cache, cx| {
                        cache.request(
                            &original,
                            upscale_variant,
                            path,
                            edge,
                            blur,
                            view,
                            window,
                            cx,
                        )
                    })
                },
                move |bounds, image: Option<Arc<RenderImage>>, window, _| {
                    if let Some(image) = image {
                        let image_bounds = fit.get_bounds(bounds, image.size(0));
                        let _ = window.paint_image(
                            bounds,
                            image_bounds,
                            corners.to_pixels(window.rem_size()),
                            image,
                            0,
                            false,
                        );
                    }
                },
            )
            .size_full(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ArtworkCache, BLUR_LEVELS, CACHE_BYTES, CACHE_ENTRIES, Entry, Key, MAX_QUEUED,
        MAX_SOURCE_BYTES, blur_level, decode, eviction_keys, render_image_bytes, size_allowed,
        target_edge, visible,
    };
    use gpui_kit::{Bounds, EntityId, RenderImage, Task, point, px, size};
    use std::collections::{HashMap, HashSet, VecDeque};
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn key(
        original: &str,
        upscale_variant: bool,
        resolved: &str,
        edge: u32,
        length: u64,
        modified_ns: u128,
    ) -> Key {
        blurred_key(original, upscale_variant, resolved, edge, 0, length, modified_ns)
    }

    fn blurred_key(
        original: &str,
        upscale_variant: bool,
        resolved: &str,
        edge: u32,
        blur: u8,
        length: u64,
        modified_ns: u128,
    ) -> Key {
        Key {
            original: PathBuf::from(original),
            upscale_variant,
            resolved: PathBuf::from(resolved),
            edge,
            blur,
            length,
            modified_ns,
        }
    }

    fn entry(bytes: usize, touched: u64, finished: bool) -> Entry {
        let image = if bytes > 0 {
            Some(Arc::new(RenderImage::new(vec![image::Frame::new(
                image::RgbaImage::from_pixel(8, 8, image::Rgba([0, 0, 0, 0])),
            )])))
        } else {
            None
        };
        Entry {
            image,
            finished,
            bytes,
            touched,
            seen_frame: 0,
            waiters: HashSet::new(),
        }
    }

    fn cache() -> ArtworkCache {
        ArtworkCache {
            entries: HashMap::new(),
            queue: VecDeque::new(),
            jobs: HashMap::new(),
            bytes: 0,
            clock: 0,
            frame: 0,
        }
    }

    fn temp_dir(name: &str) -> PathBuf {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let dir = std::env::temp_dir().join(format!(
            "whisky-artwork-{}-{}-{name}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst),
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write_png(path: &Path, width: u32, height: u32, pixel: image::Rgba<u8>) {
        let buffer = image::RgbaImage::from_pixel(width, height, pixel);
        let mut bytes = std::io::Cursor::new(Vec::new());
        buffer
            .write_to(&mut bytes, image::ImageFormat::Png)
            .unwrap();
        std::fs::write(path, bytes.into_inner()).unwrap();
    }

    #[test]
    fn target_edge_quantizes_up_to_fixed_buckets() {
        assert_eq!(target_edge(140., 210., 2.), 512);
        assert_eq!(target_edge(320., 480., 2.), 1024);
        assert_eq!(target_edge(960., 540., 2.), 2048);
        assert_eq!(target_edge(0., 0., 2.), 128);
        assert_eq!(target_edge(-5., 3., 2.), 128);
        assert_eq!(target_edge(f32::NAN, 3., 2.), 128);
        assert_eq!(target_edge(64., 64., 1.), 128);
        assert_eq!(target_edge(900., 900., 4.), 2048);
    }

    #[test]
    fn visible_requires_positive_overlap_with_clip() {
        let clip = Bounds {
            origin: point(px(0.), px(0.)),
            size: size(px(100.), px(100.)),
        };
        let outside = [
            Bounds {
                origin: point(px(-120.), px(10.)),
                size: size(px(100.), px(50.)),
            },
            Bounds {
                origin: point(px(150.), px(10.)),
                size: size(px(100.), px(50.)),
            },
            Bounds {
                origin: point(px(10.), px(-120.)),
                size: size(px(50.), px(100.)),
            },
            Bounds {
                origin: point(px(10.), px(150.)),
                size: size(px(50.), px(100.)),
            },
            Bounds {
                origin: point(px(10.), px(10.)),
                size: size(px(0.), px(50.)),
            },
            Bounds {
                origin: point(px(10.), px(10.)),
                size: size(px(50.), px(0.)),
            },
        ];
        for bounds in outside {
            assert!(!visible(bounds, clip), "unexpected visible {bounds:?}");
        }
        let inside = [
            Bounds {
                origin: point(px(-50.), px(10.)),
                size: size(px(100.), px(50.)),
            },
            Bounds {
                origin: point(px(90.), px(-40.)),
                size: size(px(50.), px(100.)),
            },
            Bounds {
                origin: point(px(10.), px(90.)),
                size: size(px(50.), px(50.)),
            },
            Bounds {
                origin: point(px(0.), px(0.)),
                size: size(px(100.), px(100.)),
            },
        ];
        for bounds in inside {
            assert!(visible(bounds, clip), "expected visible {bounds:?}");
        }
        let zero_clip = Bounds {
            origin: point(px(0.), px(0.)),
            size: size(px(0.), px(0.)),
        };
        assert!(!visible(
            Bounds {
                origin: point(px(0.), px(0.)),
                size: size(px(10.), px(10.)),
            },
            zero_clip
        ));
    }

    #[test]
    fn decode_resizes_to_display_edge_and_preserves_aspect() {
        let dir = temp_dir("resize");
        let path = dir.join("cover.png");
        write_png(&path, 3600, 4800, image::Rgba([9, 30, 60, 255]));
        let image = decode(&path, 512, 0).unwrap();
        let size = image.size(0);
        assert_eq!(size.width.0, 384);
        assert_eq!(size.height.0, 512);
        assert_eq!(render_image_bytes(&image), 384 * 512 * 4);
        let small = dir.join("small.png");
        write_png(&small, 16, 12, image::Rgba([9, 30, 60, 255]));
        let image = decode(&small, 512, 0).unwrap();
        let size = image.size(0);
        assert_eq!(size.width.0, 16);
        assert_eq!(size.height.0, 12);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn decode_uses_content_not_extension() {
        let dir = temp_dir("extensionless");
        let path = dir.join("a1b2c3");
        write_png(&path, 32, 32, image::Rgba([1, 2, 3, 255]));
        let image = decode(&path, 128, 0).unwrap();
        assert_eq!(image.size(0).width.0, 32);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn blur_level_rounds_and_clamps_to_the_supported_range() {
        assert_eq!(blur_level(0.), 0);
        assert_eq!(blur_level(1.6), 2);
        assert_eq!(blur_level(2.), 2);
        assert_eq!(blur_level(99.), BLUR_LEVELS - 1);
        assert_eq!(blur_level(-3.), 0);
        assert_eq!(blur_level(f64::NAN), 0);
    }

    #[test]
    fn blurred_decode_keeps_size_and_softens_edges() {
        let dir = temp_dir("blur");
        let path = dir.join("step.png");
        let mut buffer = image::RgbaImage::from_pixel(64, 32, image::Rgba([0, 0, 0, 255]));
        for y in 0..32 {
            for x in 32..64 {
                buffer.put_pixel(x, y, image::Rgba([255, 255, 255, 255]));
            }
        }
        buffer.save(&path).unwrap();
        // The level-0 variant keeps the hard edge at x=32.
        let sharp = decode(&path, 128, 0).unwrap();
        let sharp_bytes = sharp.as_bytes(0).unwrap();
        let edge_at = |bytes: &[u8]| bytes[(16 * 64 + 32) * 4];
        assert_eq!(edge_at(sharp_bytes), 255);
        // The blurred variant lands between the two halves (BGRA symmetric).
        let blurred = decode(&path, 128, 2).unwrap();
        assert_eq!(blurred.size(0).width.0, 64);
        let blurred_bytes = blurred.as_bytes(0).unwrap();
        assert!(edge_at(blurred_bytes) > 20 && edge_at(blurred_bytes) < 235);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn decode_swaps_rgba_to_bgra_and_keeps_alpha() {
        let dir = temp_dir("bgra");
        let path = dir.join("red.png");
        write_png(&path, 4, 2, image::Rgba([255, 0, 0, 128]));
        let image = decode(&path, 128, 0).unwrap();
        let bytes = image.as_bytes(0).unwrap();
        assert_eq!(&bytes[..4], &[0, 0, 255, 128]);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn decode_rejects_missing_corrupt_and_oversized_sources() {
        let dir = temp_dir("reject");
        assert_eq!(decode(&dir.join("missing.png"), 128, 0), None);
        let corrupt = dir.join("corrupt.png");
        std::fs::write(&corrupt, b"not an image").unwrap();
        assert_eq!(decode(&corrupt, 128, 0), None);
        assert!(!size_allowed(MAX_SOURCE_BYTES + 1, 10, 10));
        assert!(!size_allowed(4, 0, 10));
        assert!(!size_allowed(4, 10, 0));
        assert!(size_allowed(16, 2, 2));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn key_identity_distinguishes_resolved_path_edge_and_fingerprint() {
        let base = key("/bottle/cover.png", true, "/cache/x4.png", 512, 10, 20);
        assert_ne!(
            base,
            key("/bottle/cover.png", true, "/cache/x2.png", 512, 10, 20)
        );
        assert_ne!(
            base,
            key("/bottle/cover.png", true, "/cache/x4.png", 1024, 10, 20)
        );
        assert_ne!(
            base,
            key("/bottle/cover.png", true, "/cache/x4.png", 512, 11, 20)
        );
        assert_ne!(
            base,
            key("/bottle/cover.png", true, "/cache/x4.png", 512, 10, 21)
        );
        assert_ne!(
            base,
            key("/bottle/cover.png", false, "/cache/x4.png", 512, 10, 20)
        );
        assert_eq!(base, base.clone());
    }

    #[test]
    fn eviction_removes_least_touched_until_within_budget() {
        let mut entries = HashMap::new();
        let old = key("/a.png", false, "/a.png", 512, 1, 1);
        let fresh = key("/b.png", false, "/b.png", 512, 1, 1);
        let newest = key("/c.png", false, "/c.png", 512, 1, 1);
        entries.insert(old.clone(), entry(CACHE_BYTES + 1024, 1, true));
        entries.insert(fresh.clone(), entry(1024, 2, true));
        entries.insert(newest.clone(), entry(1024, 3, true));
        let bytes = entries.values().map(|entry| entry.bytes).sum();
        let evicted = eviction_keys(&entries, bytes);
        assert_eq!(evicted, vec![old]);
    }

    #[test]
    fn entry_limit_evicts_zero_byte_failures() {
        let mut entries = HashMap::new();
        for index in 0..CACHE_ENTRIES + 1 {
            entries.insert(
                key("/a.png", false, "/a.png", 512, index as u64, index as u128),
                entry(0, index as u64, true),
            );
        }
        let evicted = eviction_keys(&entries, 0);
        assert_eq!(evicted.len(), 1);
        assert_eq!(evicted[0].modified_ns, 0);
    }

    #[test]
    fn supersede_replaces_same_variant_edge_exactly_once() {
        let mut cache = cache();
        let old = key("/a.png", true, "/a-x4.png", 512, 1, 1);
        let new = key("/a.png", true, "/a-x4.png", 512, 2, 2);
        let other_edge = key("/a.png", true, "/a-x4.png", 1024, 1, 1);
        let other_variant = key("/a.png", false, "/a.png", 512, 1, 1);
        cache.bytes = 40 * 1024 * 1024 * 2 + 8;
        cache
            .entries
            .insert(old.clone(), entry(40 * 1024 * 1024, 1, true));
        cache
            .entries
            .insert(other_edge.clone(), entry(40 * 1024 * 1024, 2, true));
        cache
            .entries
            .insert(other_variant.clone(), entry(8, 3, true));
        let released = cache.supersede(&new);
        assert_eq!(released.len(), 1);
        assert!(!cache.entries.contains_key(&old));
        assert!(cache.entries.contains_key(&other_edge));
        assert!(cache.entries.contains_key(&other_variant));
        assert_eq!(cache.bytes, 40 * 1024 * 1024 + 8);
        assert!(cache.supersede(&new).is_empty());
    }

    #[test]
    fn supersede_keeps_sibling_blur_levels_cached() {
        let mut cache = cache();
        let old = blurred_key("/a.png", false, "/a.png", 384, 2, 1, 1);
        let sibling = blurred_key("/a.png", false, "/a.png", 384, 3, 1, 1);
        cache.entries.insert(old.clone(), entry(1024, 1, true));
        cache
            .entries
            .insert(sibling.clone(), entry(1024, 2, true));
        let released = cache.supersede(&blurred_key("/a.png", false, "/a.png", 384, 2, 2, 2));
        assert_eq!(released.len(), 1);
        assert!(!cache.entries.contains_key(&old));
        assert!(cache.entries.contains_key(&sibling));
    }

    #[test]
    fn resolved_change_supersedes_previous_derivative() {
        let mut cache = cache();
        let original_hit = key("/a.png", true, "/cache/v1.png", 512, 1, 1);
        let regenerated = key("/a.png", true, "/cache/v2.png", 512, 1, 1);
        cache
            .entries
            .insert(original_hit.clone(), entry(1024, 1, true));
        let released = cache.supersede(&regenerated);
        assert_eq!(released.len(), 1);
        assert!(cache.entries.is_empty());
    }

    #[test]
    fn next_job_skips_stale_and_missing_entries_once_each() {
        let mut cache = cache();
        cache.frame = 5;
        let stale = key("/stale.png", false, "/stale.png", 512, 1, 1);
        let missing = key("/gone.png", false, "/gone.png", 512, 1, 1);
        let fresh = key("/fresh.png", false, "/fresh.png", 512, 1, 1);
        cache.entries.insert(stale.clone(), entry(0, 1, false));
        let mut fresh_entry = entry(0, 2, false);
        fresh_entry.seen_frame = 5;
        cache.entries.insert(fresh.clone(), fresh_entry);
        cache.queue.push_back(stale.clone());
        cache.queue.push_back(missing.clone());
        cache.queue.push_back(fresh.clone());
        assert_eq!(cache.next_job(), Some(fresh));
        assert_eq!(cache.next_job(), None);
        assert!(!cache.entries.contains_key(&stale));
        assert!(cache.queue.is_empty());
    }

    #[test]
    fn finish_releases_decoded_image_for_removed_entry() {
        let mut cache = cache();
        let key = key("/a.png", false, "/a.png", 512, 1, 1);
        let decoded = Arc::new(RenderImage::new(vec![image::Frame::new(
            image::RgbaImage::from_pixel(8, 8, image::Rgba([0, 0, 0, 0])),
        )]));
        let weak = Arc::downgrade(&decoded);
        let (waiters, released) = cache.finish(&key, Some(decoded));
        assert!(waiters.is_empty());
        assert_eq!(released.len(), 1);
        drop(released);
        assert!(weak.upgrade().is_none());
    }

    #[test]
    fn finish_records_failure_within_entry_cap() {
        let mut cache = cache();
        let key = key("/a.png", false, "/a.png", 512, 1, 1);
        cache.entries.insert(key.clone(), entry(0, 1, false));
        let (waiters, released) = cache.finish(&key, None);
        assert!(waiters.is_empty());
        assert!(released.is_empty());
        let entry = cache.entries.get(&key).unwrap();
        assert!(entry.finished);
        assert!(entry.image.is_none());
    }

    #[test]
    fn enqueue_admits_once_and_reuses_pending_entry() {
        let mut cache = cache();
        let view = EntityId::from(7);
        let key = key("/a.png", false, "/a.png", 512, 1, 1);
        assert!(cache.enqueue(key.clone(), view));
        assert!(cache.enqueue(key.clone(), view));
        assert_eq!(cache.entries.len(), 1);
        assert_eq!(cache.queue.len(), 1);
        assert_eq!(cache.next_job(), Some(key.clone()));
        cache.jobs.insert(key.clone(), Task::ready(()));
        assert!(cache.enqueue(key.clone(), view));
        assert!(cache.queue.is_empty());
        assert_eq!(cache.jobs.len(), 1);
        assert!(!cache.entries.get(&key).unwrap().finished);
        let (_, released) = cache.finish(&key, None);
        assert!(released.is_empty());
        assert!(cache.entries.get(&key).unwrap().finished);
        assert!(cache.enqueue(key, view));
    }

    #[test]
    fn queue_cap_rejects_beyond_max_queued() {
        let mut cache = cache();
        let view = EntityId::from(7);
        for index in 0..MAX_QUEUED {
            let key = key("/a.png", false, "/a.png", 512, index as u64, index as u128);
            assert!(cache.enqueue(key, view));
        }
        assert_eq!(cache.queue.len(), MAX_QUEUED);
        let extra = key("/a.png", false, "/a.png", 512, 999, 999);
        assert!(!cache.enqueue(extra.clone(), view));
        assert!(!cache.entries.contains_key(&extra));
        let started = cache.next_job().unwrap();
        cache.jobs.insert(started, Task::ready(()));
        assert!(cache.enqueue(extra, view));
        assert_eq!(cache.queue.len(), MAX_QUEUED);
    }

    #[test]
    fn can_start_job_tracks_active_decode_count() {
        let mut cache = cache();
        let key_a = key("/a.png", false, "/a.png", 512, 1, 1);
        let key_b = key("/b.png", false, "/b.png", 512, 1, 1);
        assert!(cache.can_start_job());
        cache.jobs.insert(key_a.clone(), Task::ready(()));
        cache.jobs.insert(key_b, Task::ready(()));
        assert!(!cache.can_start_job());
        cache.entries.insert(key_a.clone(), entry(0, 1, false));
        let _ = cache.finish(&key_a, None);
        assert!(cache.can_start_job());
    }

    #[test]
    fn pending_job_survives_entry_replacement() {
        let mut cache = cache();
        cache.frame = 5;
        let view = EntityId::from(7);
        let key = key("/a.png", false, "/a.png", 512, 1, 1);
        assert!(cache.enqueue(key.clone(), view));
        assert_eq!(cache.next_job(), Some(key.clone()));
        cache.jobs.insert(key.clone(), Task::ready(()));
        cache.entries.remove(&key);
        assert_eq!(cache.jobs.len(), 1);
        assert!(cache.enqueue(key.clone(), view));
        assert_eq!(cache.jobs.len(), 1);
        let image = Arc::new(RenderImage::new(vec![image::Frame::new(
            image::RgbaImage::from_pixel(8, 8, image::Rgba([0, 0, 0, 0])),
        )]));
        let (waiters, released) = cache.finish(&key, Some(image));
        assert_eq!(waiters, vec![view]);
        assert!(released.is_empty());
        let entry = cache.entries.get(&key).unwrap();
        assert!(entry.finished);
        assert!(entry.image.is_some());
        assert!(cache.jobs.is_empty());
        assert!(cache.queue.is_empty());
    }

    #[test]
    fn finish_eviction_releases_cpu_arc() {
        let mut cache = cache();
        let big = key("/big.png", false, "/big.png", 512, 1, 1);
        let image = Arc::new(RenderImage::new(vec![image::Frame::new(
            image::RgbaImage::from_pixel(1, 1, image::Rgba([0, 0, 0, 0])),
        )]));
        let weak = Arc::downgrade(&image);
        cache.entries.insert(
            big.clone(),
            Entry {
                image: Some(image),
                finished: true,
                bytes: CACHE_BYTES + 1,
                touched: 1,
                seen_frame: 0,
                waiters: HashSet::new(),
            },
        );
        cache.bytes = CACHE_BYTES + 1;
        let released = cache.evict_to_budget();
        assert_eq!(released.len(), 1);
        drop(released);
        assert!(weak.upgrade().is_none());
        assert_eq!(cache.bytes, 0);
    }
}
