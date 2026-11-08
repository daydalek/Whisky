use super::*;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::time::Duration;

struct TestDir(PathBuf);

impl TestDir {
    fn new(name: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let dir = std::env::temp_dir().join(format!(
            "whisky-upscale-test-{}-{}-{name}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed),
        ));
        std::fs::create_dir_all(&dir).expect("create test dir");
        Self(dir)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn crc32(tag: &[u8], data: &[u8]) -> u32 {
    let mut crc = 0xffff_ffff_u32;
    for &b in tag.iter().chain(data.iter()) {
        crc ^= u32::from(b);
        for _ in 0..8 {
            if crc & 1 != 0 {
                crc = (crc >> 1) ^ 0xedb8_8320;
            } else {
                crc >>= 1;
            }
        }
    }
    !crc
}

/// Generates a minimal, valid PNG file containing the given IHDR dimensions
/// without needing multi-megabyte heap pixel allocations.
fn write_png_header_dimensions(path: &Path, width: u32, height: u32) {
    let mut bytes = Vec::with_capacity(66);
    bytes.extend_from_slice(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);
    let mut ihdr_body = Vec::with_capacity(13);
    ihdr_body.extend_from_slice(&width.to_be_bytes());
    ihdr_body.extend_from_slice(&height.to_be_bytes());
    ihdr_body.extend_from_slice(&[8, 6, 0, 0, 0]); // 8-bit RGBA
    let ihdr_crc = crc32(b"IHDR", &ihdr_body);
    bytes.extend_from_slice(&13u32.to_be_bytes());
    bytes.extend_from_slice(b"IHDR");
    bytes.extend_from_slice(&ihdr_body);
    bytes.extend_from_slice(&ihdr_crc.to_be_bytes());
    let comp = [0x78, 0x9c, 0x63, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01];
    let idat_crc = crc32(b"IDAT", &comp);
    bytes.extend_from_slice(&(comp.len() as u32).to_be_bytes());
    bytes.extend_from_slice(b"IDAT");
    bytes.extend_from_slice(&comp);
    bytes.extend_from_slice(&idat_crc.to_be_bytes());
    let iend_crc = crc32(b"IEND", &[]);
    bytes.extend_from_slice(&0u32.to_be_bytes());
    bytes.extend_from_slice(b"IEND");
    bytes.extend_from_slice(&iend_crc.to_be_bytes());
    std::fs::write(path, bytes).expect("write minimal png");
}

fn create_test_image(path: &Path, width: u32, height: u32, color: [u8; 4]) {
    let mut img = image::RgbaImage::new(width, height);
    for p in img.pixels_mut() {
        *p = image::Rgba(color);
    }
    img.save_with_format(path, image::ImageFormat::Png)
        .expect("save test png");
}

/// `.stage-*` working dirs and `.part` leftovers under `dir` — a failed or
/// cancelled derivation must own-clean every one of them.
fn stray_working_files(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .map(|entries| {
            entries
                .flatten()
                .map(|entry| entry.path())
                .filter(|path| {
                    path.file_name()
                        .and_then(|name| name.to_str())
                        .map(|name| name.starts_with(".stage-") || name.ends_with(".part"))
                        .unwrap_or(false)
                })
                .collect()
        })
        .unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Pure factor/ceiling logic
// ---------------------------------------------------------------------------

#[test]
fn the_factor_alone_decides_the_passes() {
    assert_eq!(Factor::Off.passes(), 0);
    assert_eq!(Factor::X2.passes(), 1);
    assert_eq!(Factor::X4.passes(), 2);
    assert_eq!(capped_passes(Factor::X4.passes(), 250, 300), 2);
    assert_eq!(capped_passes(Factor::X4.passes(), 1_000, 1_500), 2);
    assert_eq!(capped_passes(Factor::X2.passes(), 1_000, 1_500), 1);
}

#[test]
fn the_ceiling_drops_passes_instead_of_skipping_the_cover() {
    assert_eq!(capped_passes(2, 1_200, 1_800), 1);
    assert_eq!(capped_passes(2, 2_400, 3_600), 0);
}

#[test]
fn test_capped_passes_boundary_thresholds() {
    assert_eq!(capped_passes(2, 6000, 4000), 0);
    assert_eq!(capped_passes(1, 6000, 4000), 0);
    assert_eq!(capped_passes(2, 1000, 1500), 2);
    assert_eq!(capped_passes(2, 1030, 1530), 1);
    assert_eq!(capped_passes(2, 1200, 1800), 1);
    assert_eq!(capped_passes(0, 100, 100), 0);
}

#[test]
fn test_extreme_dimensions_and_ceiling_truncation() {
    assert_eq!(capped_passes(2, 6000, 4000), 0);
    assert_eq!(capped_passes(1, 6000, 4000), 0);
    assert_eq!(capped_passes(2, 10000, 10000), 0);
    assert_eq!(capped_passes(1, 10000, 10000), 0);
    assert_eq!(capped_passes(2, u32::MAX, u32::MAX), 0);
    assert_eq!(capped_passes(1, u32::MAX, u32::MAX), 0);
    assert_eq!(capped_passes(2, 1, u32::MAX), 0);
    assert_eq!(capped_passes(2, u32::MAX, 1), 0);
    assert_eq!(capped_passes(2, 1, 1), 2);
    assert_eq!(capped_passes(1, 1, 1), 1);
    assert_eq!(capped_passes(0, 1, 1), 0);
}

#[test]
fn every_engine_round_trips_its_raw_value() {
    for engine in engines() {
        assert_eq!(Engine::from_raw(engine.raw()), *engine);
    }
    assert_eq!(Engine::from_raw(Engine::Synthetic.raw()), Engine::Synthetic);
}

#[test]
#[cfg(target_os = "macos")]
fn macos_mapping_keeps_both_bundled_engines() {
    assert_eq!(Engine::from_raw("anime4k"), Engine::Anime4K);
    assert_eq!(Engine::from_raw("realcugan"), Engine::RealCugan);
    assert_eq!(Engine::from_raw("nonsense"), Engine::Anime4K);
    assert_eq!(Engine::from_raw("realcugan-cpu"), Engine::RealCugan);
    assert_eq!(Engine::from_raw("synthetic"), Engine::Synthetic);
}

#[test]
#[cfg(target_os = "linux")]
fn linux_mapping_folds_apple_engines_into_realcugan() {
    assert_eq!(Engine::from_raw("anime4k"), Engine::RealCugan);
    assert_eq!(Engine::from_raw("nonsense"), Engine::RealCugan);
    assert_eq!(Engine::from_raw("realcugan"), Engine::RealCugan);
    assert_eq!(Engine::from_raw("realcugan-cpu"), Engine::RealCuganCpu);
    assert_eq!(Engine::from_raw("synthetic"), Engine::Synthetic);
}

// ---------------------------------------------------------------------------
// Public entry point with an explicit cache root (no global HOME state)
// ---------------------------------------------------------------------------

#[test]
fn test_synthetic_upscale_preserves_dimensions_2x_and_4x_and_cache_hit() {
    let dir = TestDir::new("scale-dimensions");
    let file = dir.path().join("scale_test.png");
    create_test_image(&file, 20, 30, [10, 20, 30, 255]);
    let cancel = AtomicBool::new(false);

    let derived_x2 = upscaled_cover_in(&file, 1, Engine::Synthetic, &cancel, dir.path())
        .expect("1 pass upscale should succeed");
    assert_eq!(dimensions(&derived_x2), Some((40, 60)));
    // The derived file lives under the explicit root, not any global cache.
    assert!(derived_x2.starts_with(dir.path()));

    // Cache hit: a repeat call returns the same path without re-deriving.
    let mtime = std::fs::metadata(&derived_x2).unwrap().modified().unwrap();
    let hit = upscaled_cover_in(&file, 1, Engine::Synthetic, &cancel, dir.path());
    assert_eq!(hit, Some(derived_x2.clone()));
    assert_eq!(
        std::fs::metadata(&derived_x2).unwrap().modified().unwrap(),
        mtime,
        "cache hit must not rewrite the file"
    );

    let derived_x4 = upscaled_cover_in(&file, 2, Engine::Synthetic, &cancel, dir.path())
        .expect("2 passes upscale should succeed");
    assert_eq!(dimensions(&derived_x4), Some((80, 120)));
    assert!(stray_working_files(dir.path()).is_empty());
}

#[test]
fn test_memory_ceiling_drops_passes_on_oversized_cover() {
    let dir = TestDir::new("oversized");
    let oversized_file = dir.path().join("oversized_6000x4000.png");
    write_png_header_dimensions(&oversized_file, 6000, 4000);
    assert_eq!(dimensions(&oversized_file), Some((6000, 4000)));

    let cancel = AtomicBool::new(false);
    for passes in [1, 2] {
        assert!(
            upscaled_cover_in(&oversized_file, passes, Engine::Synthetic, &cancel, dir.path())
                .is_none(),
            "6000x4000 cover with {passes} passes must drop to 0 and return None"
        );
    }
    assert!(stray_working_files(dir.path()).is_empty());
}

#[test]
fn test_zero_passes_and_zero_dimensions_return_none() {
    let dir = TestDir::new("zero-cases");
    let file_1x1 = dir.path().join("dim_1x1.png");
    create_test_image(&file_1x1, 1, 1, [123, 234, 56, 255]);
    let cancel = AtomicBool::new(false);

    assert!(
        upscaled_cover_in(&file_1x1, 0, Engine::Synthetic, &cancel, dir.path()).is_none(),
        "1x1 cover with 0 passes must return None"
    );
    let p1 = upscaled_cover_in(&file_1x1, 1, Engine::Synthetic, &cancel, dir.path())
        .expect("1x1 with 1 pass must upscale to 2x2");
    assert_eq!(dimensions(&p1), Some((2, 2)));
    let p2 = upscaled_cover_in(&file_1x1, 2, Engine::Synthetic, &cancel, dir.path())
        .expect("1x1 with 2 passes must upscale to 4x4");
    assert_eq!(dimensions(&p2), Some((4, 4)));

    let file_0x0 = dir.path().join("dim_0x0.png");
    write_png_header_dimensions(&file_0x0, 0, 0);
    for passes in [1, 2] {
        assert!(
            upscaled_cover_in(&file_0x0, passes, Engine::Synthetic, &cancel, dir.path()).is_none(),
            "0x0 cover must return None without panic"
        );
    }
    assert!(stray_working_files(dir.path()).is_empty());
}

#[test]
fn test_pre_cancelled_token_returns_none_immediately() {
    let dir = TestDir::new("pre-cancel");
    let file = dir.path().join("pre_cancelled.png");
    create_test_image(&file, 20, 20, [1, 2, 3, 255]);
    let cancel = AtomicBool::new(true);
    assert!(
        upscaled_cover_in(&file, 1, Engine::Synthetic, &cancel, dir.path()).is_none(),
        "pre-cancelled token must return None immediately"
    );
    assert!(stray_working_files(dir.path()).is_empty());
}

#[test]
fn test_double_checked_caching_concurrency() {
    let dir = TestDir::new("double-checked-caching");
    let file = dir.path().join("shared_cover.png");
    create_test_image(&file, 32, 32, [45, 120, 210, 255]);
    let root = dir.path().to_path_buf();

    let num_threads = 10;
    let barrier = Arc::new(std::sync::Barrier::new(num_threads));
    let mut handles = Vec::new();
    for _ in 0..num_threads {
        let file = file.clone();
        let root = root.clone();
        let barrier = barrier.clone();
        handles.push(std::thread::spawn(move || {
            barrier.wait();
            let cancel = AtomicBool::new(false);
            upscaled_cover_in(&file, 1, Engine::Synthetic, &cancel, &root)
        }));
    }
    let mut results = Vec::new();
    for h in handles {
        results.push(h.join().expect("thread join"));
    }
    assert_eq!(results.len(), num_threads);
    let first = results[0].as_ref().expect("first result exists");
    for (i, r) in results.iter().enumerate() {
        assert_eq!(r.as_ref(), Some(first), "thread {i} should receive identical cached path");
    }
    assert_eq!(dimensions(first), Some((64, 64)));
    assert!(stray_working_files(dir.path()).is_empty());
}

// ---------------------------------------------------------------------------
// Worker gate: mutual exclusion proven with channels, not timing
// ---------------------------------------------------------------------------

#[test]
fn test_worker_gate_is_exclusive_and_queue_cancellation() {
    let (entered_tx, entered_rx) = std::sync::mpsc::channel::<()>();
    let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
    let active = Arc::new(AtomicUsize::new(0));

    // First worker enters the gate, reports, then waits for release.
    let a1 = active.clone();
    let h1 = std::thread::spawn(move || {
        with_worker(&AtomicBool::new(false), || {
            a1.fetch_add(1, Ordering::SeqCst);
            entered_tx.send(()).expect("entered signal");
            release_rx.recv().expect("release signal");
            a1.fetch_sub(1, Ordering::SeqCst);
            Some(())
        })
    });
    entered_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("first worker must enter the gate");

    // Second worker queues on the gate and cannot enter while it is held.
    let (entered2_tx, entered2_rx) = std::sync::mpsc::channel::<()>();
    let a2 = active.clone();
    let h2 = std::thread::spawn(move || {
        with_worker(&AtomicBool::new(false), || {
            a2.fetch_add(1, Ordering::SeqCst);
            entered2_tx.send(()).expect("second entered");
            a2.fetch_sub(1, Ordering::SeqCst);
            Some(())
        })
    });
    assert!(
        entered2_rx.recv_timeout(Duration::from_millis(200)).is_err(),
        "second worker must not enter while the gate is held"
    );
    assert_eq!(active.load(Ordering::SeqCst), 1, "max active workers is 1");

    release_tx.send(()).expect("release first worker");
    entered2_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("second worker enters only after the first releases");
    h1.join().expect("h1 join");
    h2.join().expect("h2 join");
    assert_eq!(active.load(Ordering::SeqCst), 0);

    // A token cancelled while queued returns None as soon as the gate opens.
    let (hold_tx, hold_rx) = std::sync::mpsc::channel::<()>();
    let (holding_tx, holding_rx) = std::sync::mpsc::channel::<()>();
    let h3 = std::thread::spawn(move || {
        with_worker(&AtomicBool::new(false), || {
            holding_tx.send(()).unwrap();
            hold_rx.recv().unwrap();
            Some(())
        })
    });
    holding_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let queued_cancel = Arc::new(AtomicBool::new(true));
    let qc = queued_cancel.clone();
    let h4 = std::thread::spawn(move || with_worker(&qc, || Some(())));
    hold_tx.send(()).unwrap();
    assert!(h4.join().unwrap().is_none(), "queued-cancellation returns None");
    h3.join().expect("h3 join");
}

// ---------------------------------------------------------------------------
// publish(): staged atomicity, validation and cleanup on every failure path
// ---------------------------------------------------------------------------

#[test]
fn test_cancel_mid_pixels_leaves_no_stage_or_target() {
    let dir = TestDir::new("mid-pixels");
    let src = dir.path().join("src.png");
    create_test_image(&src, 128, 128, [1, 2, 3, 255]);
    let derived = dir.path().join("derived.png");
    let cancel = Arc::new(AtomicBool::new(false));
    let (staged_tx, staged_rx) = std::sync::mpsc::channel::<(u32, PathBuf)>();
    let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();

    let c = cancel.clone();
    let (src_c, derived_c) = (src.clone(), derived.clone());
    let h = std::thread::spawn(move || {
        cache::publish(&derived_c, (256, 256), &c, |output| {
            let stage_dir = output.parent().expect("stage dir").to_path_buf();
            synthetic::derive_with(&src_c, 1, output, (256, 256), &c, move |row| {
                if row == 32 {
                    // Readiness is signalled only once pixels are actually
                    // being produced inside a real stage dir — the main
                    // thread then cancels and releases.
                    staged_tx
                        .send((row, stage_dir.clone()))
                        .expect("checkpoint signal");
                    release_rx.recv_timeout(Duration::from_secs(10)).is_ok()
                } else {
                    true
                }
            })
        })
    });

    let (reached_row, stage_dir) = staged_rx
        .recv_timeout(Duration::from_secs(5))
        .expect("the row-32 checkpoint must be reached");
    assert_eq!(reached_row, 32, "inference reached the expected checkpoint");
    assert!(stage_dir.exists(), "a real staged directory exists during inference");
    cancel.store(true, Ordering::SeqCst);
    release_tx.send(()).expect("release the checkpoint");

    assert!(h.join().expect("worker join").is_none(), "cancelled publish returns None");
    assert!(!derived.exists(), "target must not exist after cancellation");
    assert!(!stage_dir.exists(), "owned stage dir must be removed on cancellation");
    assert!(stray_working_files(dir.path()).is_empty());

    // A clean retry on the same file succeeds.
    let retry = AtomicBool::new(false);
    let retry_res = cache::publish(&derived, (256, 256), &retry, |output| {
        synthetic::derive(&src, 1, output, (256, 256), &retry)
    });
    assert_eq!(retry_res, Some(derived.clone()));
    assert_eq!(dimensions(&derived), Some((256, 256)));
}

#[test]
fn test_publish_failures_leave_nothing_and_preserve_valid_cache() {
    let dir = TestDir::new("publish-failures");
    let src = dir.path().join("src.png");
    create_test_image(&src, 16, 16, [9, 9, 9, 255]);
    let derived = dir.path().join("derived.png");
    let cancel = AtomicBool::new(false);

    // Callback failure: nothing is published and no stage remains.
    assert!(
        cache::publish(&derived, (32, 32), &cancel, |_| None).is_none(),
        "failing callback must return None"
    );
    assert!(!derived.exists());
    assert!(stray_working_files(dir.path()).is_empty());

    // Invalid (truncated) output: same cleanup.
    assert!(
        cache::publish(&derived, (32, 32), &cancel, |output| {
            std::fs::write(output, b"not a png").ok()
        })
        .is_none(),
        "undecodable output must return None"
    );
    assert!(!derived.exists());
    assert!(stray_working_files(dir.path()).is_empty());

    // Wrong dimensions: same cleanup.
    let wrong = dir.path().join("wrong.png");
    create_test_image(&wrong, 8, 8, [1, 1, 1, 255]);
    assert!(
        cache::publish(&derived, (32, 32), &cancel, |output| {
            std::fs::copy(&wrong, output).ok().map(|_| ())
        })
        .is_none(),
        "wrong-dimension output must return None"
    );
    assert!(!derived.exists());
    assert!(stray_working_files(dir.path()).is_empty());

    // A previously valid cache entry survives a failed replacement.
    let ok = cache::publish(&derived, (32, 32), &cancel, |output| {
        synthetic::derive(&src, 1, output, (32, 32), &cancel)
    });
    assert!(ok.is_some(), "baseline derivation succeeds");
    let bytes = std::fs::read(&derived).unwrap();
    assert!(
        cache::publish(&derived, (32, 32), &cancel, |_| None).is_none(),
        "failing replacement returns None"
    );
    assert_eq!(
        std::fs::read(&derived).unwrap(),
        bytes,
        "existing valid cache must be preserved after a failed replacement"
    );
}

#[test]
fn test_publish_partial_write_rename_failure_and_post_stage_cancel() {
    let dir = TestDir::new("publish-edges");
    let src = dir.path().join("src.png");
    create_test_image(&src, 16, 16, [9, 9, 9, 255]);
    let derived = dir.path().join("derived.png");
    let cancel = AtomicBool::new(false);

    // Callback writes partial data then fails: nothing is published.
    assert!(
        cache::publish(&derived, (32, 32), &cancel, |output| {
            std::fs::write(output, b"\x89PNGpartial").ok()?;
            None
        })
        .is_none(),
        "partial write then callback failure must return None"
    );
    assert!(!derived.exists());
    assert!(stray_working_files(dir.path()).is_empty());

    // Cancellation after the staged output is already valid: no publish.
    let late_cancel = AtomicBool::new(false);
    assert!(
        cache::publish(&derived, (32, 32), &late_cancel, |output| {
            let result = synthetic::derive(&src, 1, output, (32, 32), &late_cancel);
            if result.is_some() {
                // The stage finished but the caller cancelled meanwhile.
                late_cancel.store(true, Ordering::SeqCst);
            }
            result
        })
        .is_none(),
        "cancel between inference and rename must not publish"
    );
    assert!(!derived.exists());
    assert!(stray_working_files(dir.path()).is_empty());

    // Rename failure: the target path is an existing directory.
    let dir_target = dir.path().join("target-dir.png");
    std::fs::create_dir_all(&dir_target).unwrap();
    assert!(
        cache::publish(&dir_target, (32, 32), &cancel, |output| {
            synthetic::derive(&src, 1, output, (32, 32), &cancel)
        })
        .is_none(),
        "rename onto a directory must fail cleanly"
    );
    assert!(dir_target.is_dir(), "the target directory survives");

    // Foreign working files are never touched by our cleanup.
    let foreign_part = dir.path().join("foreign.png.part");
    std::fs::write(&foreign_part, b"other task's partial").unwrap();
    let foreign_stage = dir.path().join(".stage-foreign");
    std::fs::create_dir_all(&foreign_stage).unwrap();
    std::fs::write(foreign_stage.join("keep"), b"sentinel").unwrap();
    assert!(
        cache::publish(&derived, (32, 32), &cancel, |_| None).is_none(),
        "failing publish cleans only its own stage"
    );
    assert_eq!(
        std::fs::read(&foreign_part).unwrap(),
        b"other task's partial",
        "a foreign .part file is left alone"
    );
    assert_eq!(
        std::fs::read(foreign_stage.join("keep")).unwrap(),
        b"sentinel",
        "a foreign stage dir is left alone"
    );
}

#[test]
fn test_cached_never_serves_truncated_wrong_dim_or_symlink_files() {
    let dir = TestDir::new("cache-validation");
    let src = dir.path().join("src.png");
    create_test_image(&src, 16, 16, [9, 9, 9, 255]);
    let cancel = AtomicBool::new(false);
    let target =
        cache::location_in(dir.path(), &src, 1, "synthetic").expect("computed cache target");

    // IHDR-intact but truncated pixel data must never be a cache hit: the
    // entry is replaced by a real derivation.
    write_png_header_dimensions(&target, 32, 32);
    assert_eq!(dimensions(&target), Some((32, 32)), "header still reads 32x32");
    let result =
        upscaled_cover_in(&src, 1, Engine::Synthetic, &cancel, dir.path());
    assert_eq!(result, Some(target.clone()));
    assert!(
        cache::valid_output(&target, (32, 32)),
        "the truncated entry was replaced by a decodable image"
    );

    // A wrong-dimension valid PNG at the target is replaced too.
    create_test_image(&target, 8, 8, [1, 1, 1, 255]);
    let result =
        upscaled_cover_in(&src, 1, Engine::Synthetic, &cancel, dir.path());
    assert_eq!(result, Some(target.clone()));
    assert_eq!(dimensions(&target), Some((32, 32)));

    // A symlink at the computed target: publish refuses to write through it
    // and the referent is untouched.
    std::fs::remove_file(&target).unwrap();
    let referent = dir.path().join("referent.png");
    create_test_image(&referent, 4, 4, [7, 7, 7, 255]);
    let referent_bytes = std::fs::read(&referent).unwrap();
    std::os::unix::fs::symlink(&referent, &target).unwrap();
    let result =
        upscaled_cover_in(&src, 1, Engine::Synthetic, &cancel, dir.path());
    assert!(result.is_none(), "a symlinked cache target is not served or written");
    assert!(target.symlink_metadata().unwrap().is_symlink());
    assert_eq!(
        std::fs::read(&referent).unwrap(),
        referent_bytes,
        "the symlink referent is untouched"
    );
}

#[test]
fn test_symlink_target_is_rejected_and_untouched() {
    let dir = TestDir::new("symlink-target");
    let real = dir.path().join("real.png");
    create_test_image(&real, 4, 4, [5, 5, 5, 255]);
    let link = dir.path().join("link.png");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    let cancel = AtomicBool::new(false);
    assert!(
        cache::publish(&link, (8, 8), &cancel, |output| {
            std::fs::write(output, b"x").ok()
        })
        .is_none(),
        "a symlinked target must never be written through"
    );
    assert!(link.symlink_metadata().unwrap().is_symlink(), "symlink must survive");
    assert!(stray_working_files(dir.path()).is_empty());
}

// ---------------------------------------------------------------------------
// Optional real-engine smoke: ignored by default, requires explicit env
// ---------------------------------------------------------------------------

#[test]
#[ignore = "requires WHISKY_COVER_TEST=<cover> and a real Metal/CoreML runtime"]
#[cfg(target_os = "macos")]
fn a_real_cover_goes_through_both_engines() {
    let path = std::env::var("WHISKY_COVER_TEST")
        .expect("set WHISKY_COVER_TEST to the cover path when running this test explicitly");
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
