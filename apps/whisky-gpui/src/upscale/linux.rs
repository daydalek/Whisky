use std::ffi::OsString;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};

use super::Engine;
// Staging and output validation are shared with every engine via the cache
// module; re-exported so this file's own tests keep their existing names.
pub(super) use super::cache::{Stage, valid_output};

const HELPER_NAME: &str = "realcugan-ncnn-vulkan";
const MODEL_FILES: [&str; 2] = ["up2x-no-denoise.param", "up2x-no-denoise.bin"];
const MODEL_FAMILY: &str = "models-se";
const MODEL_DIRECTORY: &str = "share/realcugan-ncnn-vulkan/models-se";
const BUNDLE_MANIFEST: &str = "share/whisky/upscalers/manifest.json";
const INFERENCE_SCHEMA: u64 = 2;
const PASS_TIMEOUT: Duration = Duration::from_secs(120);

const STATUS_INITIAL: u8 = 0;
const STATUS_READY: u8 = 1;
const STATUS_WORKING: u8 = 2;
const STATUS_CPU: u8 = 3;
const STATUS_MISSING: u8 = 4;
const STATUS_FAILED: u8 = 5;
static STATUS: AtomicU8 = AtomicU8::new(STATUS_INITIAL);

#[derive(Clone)]
pub(super) struct Config {
    helper: PathBuf,
    models: PathBuf,
    fingerprint: String,
}

impl Config {
    pub(super) fn key(&self, engine: Engine) -> String {
        let device = match engine {
            Engine::RealCuganCpu => "cpu",
            _ => "gpu",
        };
        format!(
            "realcugan-ncnn-v{INFERENCE_SCHEMA}-{device}-{}",
            self.fingerprint
        )
    }
}

pub(super) fn status() -> &'static str {
    match STATUS.load(Ordering::Relaxed) {
        STATUS_READY => "组件已就绪",
        STATUS_WORKING => "正在处理封面",
        STATUS_CPU => "CPU 兼容模式",
        STATUS_MISSING => "组件缺失或损坏",
        STATUS_FAILED => "超分失败，保留原图",
        _ => "组件随应用提供，首次使用时校验",
    }
}

#[derive(Clone)]
struct RuntimePaths {
    helper: PathBuf,
    models: PathBuf,
    manifest: Option<PathBuf>,
    bundled: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct FileIdentity {
    path: PathBuf,
    device: u64,
    inode: u64,
    size: u64,
    modified_sec: i64,
    modified_nsec: i64,
    changed_sec: i64,
    changed_nsec: i64,
    mode: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Snapshot(Vec<FileIdentity>);

struct CachedConfig {
    snapshot: Snapshot,
    config: Config,
}

fn runtime_paths(
    helper_override: Option<OsString>,
    exe_dir: Option<PathBuf>,
    models_override: Option<OsString>,
) -> Option<RuntimePaths> {
    let bundled = helper_override.is_none() && models_override.is_none();
    let executable_dir = exe_dir.clone();
    let helper = match helper_override {
        Some(path) => {
            let path = PathBuf::from(path);
            (path.is_absolute() && path.file_name().is_some_and(|name| name == HELPER_NAME))
                .then_some(path)?
        }
        None => exe_dir?.join(HELPER_NAME),
    };
    let models = match models_override {
        Some(path) => {
            let path = PathBuf::from(path);
            (path.is_absolute() && path.file_name().is_some_and(|name| name == MODEL_FAMILY))
                .then_some(path)?
        }
        None => {
            let dir = executable_dir.as_deref().or_else(|| helper.parent())?;
            dir.parent()?.join(MODEL_DIRECTORY)
        }
    };
    let manifest = if bundled {
        let dir = executable_dir.as_deref()?;
        Some(dir.parent()?.join(BUNDLE_MANIFEST))
    } else {
        None
    };
    Some(RuntimePaths {
        helper,
        models,
        manifest,
        bundled,
    })
}

fn metadata_identity(path: &Path, allow_directory: bool) -> Option<FileIdentity> {
    use std::os::unix::fs::MetadataExt;

    let metadata = std::fs::symlink_metadata(path).ok()?;
    if metadata.file_type().is_symlink()
        || (!metadata.is_file() && !(allow_directory && metadata.is_dir()))
    {
        return None;
    }
    Some(FileIdentity {
        path: path.to_path_buf(),
        device: metadata.dev(),
        inode: metadata.ino(),
        size: metadata.len(),
        modified_sec: metadata.mtime(),
        modified_nsec: metadata.mtime_nsec(),
        changed_sec: metadata.ctime(),
        changed_nsec: metadata.ctime_nsec(),
        mode: metadata.mode(),
    })
}

fn snapshot(paths: &RuntimePaths) -> Option<Snapshot> {
    let mut entries = vec![
        metadata_identity(&paths.helper, false)?,
        metadata_identity(&paths.models, true)?,
    ];
    for name in MODEL_FILES {
        entries.push(metadata_identity(&paths.models.join(name), false)?);
    }
    if let Some(manifest) = &paths.manifest {
        entries.push(metadata_identity(manifest, false)?);
    }
    Some(Snapshot(entries))
}

pub(super) fn config() -> Option<Config> {
    let paths = runtime_paths(
        std::env::var_os("WHISKY_REALCUGAN_HELPER"),
        std::env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(Path::to_path_buf)),
        std::env::var_os("WHISKY_REALCUGAN_MODELS"),
    );
    let Some(paths) = paths else {
        STATUS.store(STATUS_MISSING, Ordering::Relaxed);
        return None;
    };
    let Some(snapshot) = snapshot(&paths) else {
        STATUS.store(STATUS_MISSING, Ordering::Relaxed);
        return None;
    };
    static CONFIG: OnceLock<Mutex<Option<CachedConfig>>> = OnceLock::new();
    let cache = CONFIG.get_or_init(|| Mutex::new(None));
    let mut cached = cache
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(current) = cached.as_ref() {
        if current.snapshot == snapshot {
            STATUS.store(STATUS_READY, Ordering::Relaxed);
            return Some(current.config.clone());
        }
    }
    let Some(config) = load_config(&paths) else {
        *cached = None;
        STATUS.store(STATUS_MISSING, Ordering::Relaxed);
        return None;
    };
    *cached = Some(CachedConfig {
        snapshot,
        config: config.clone(),
    });
    STATUS.store(STATUS_READY, Ordering::Relaxed);
    Some(config)
}

fn resolve(
    helper_override: Option<OsString>,
    exe_dir: Option<PathBuf>,
    models_override: Option<OsString>,
) -> Option<Config> {
    let paths = runtime_paths(helper_override, exe_dir, models_override)?;
    load_config(&paths)
}

fn load_config(paths: &RuntimePaths) -> Option<Config> {
    if paths.helper.file_name()?.to_str()? != HELPER_NAME
        || paths.models.file_name()?.to_str()? != MODEL_FAMILY
        || !executable(&paths.helper)
        || !valid_models(&paths.models)
    {
        return None;
    }
    let helper_hash = sha256_file(&paths.helper)?;
    let model_hashes = [
        sha256_file(&paths.models.join(MODEL_FILES[0]))?,
        sha256_file(&paths.models.join(MODEL_FILES[1]))?,
    ];
    if paths.bundled && !validate_bundle_manifest(paths, &helper_hash, &model_hashes) {
        return None;
    }
    Some(Config {
        helper: paths.helper.clone(),
        models: paths.models.clone(),
        fingerprint: cache_fingerprint(&helper_hash, &model_hashes),
    })
}

fn executable(path: &Path) -> bool {
    metadata_identity(path, false)
        .is_some_and(|identity| identity.mode & 0o111 != 0 && identity.size > 0)
}

fn valid_models(dir: &Path) -> bool {
    dir.file_name().is_some_and(|name| name == MODEL_FAMILY)
        && metadata_identity(dir, true).is_some()
        && MODEL_FILES.iter().all(|name| {
            metadata_identity(&dir.join(name), false).is_some_and(|metadata| metadata.size > 0)
        })
}

fn sha256_file(path: &Path) -> Option<String> {
    let mut file = std::fs::File::open(path).ok()?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer).ok()?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    Some(format!("{:x}", digest.finalize()))
}

fn cache_fingerprint(helper_hash: &str, model_hashes: &[String; 2]) -> String {
    let mut digest = Sha256::new();
    digest.update(helper_hash.as_bytes());
    digest.update(b"\0");
    for hash in model_hashes {
        digest.update(hash.as_bytes());
        digest.update(b"\0");
    }
    digest.update(b"schema=2;noise=0;scale=2;format=png;tile=128;jobs=1:1:1;syncgap=2");
    format!("{:x}", digest.finalize())
}

fn validate_bundle_manifest(
    paths: &RuntimePaths,
    helper_hash: &str,
    model_hashes: &[String; 2],
) -> bool {
    let Some(manifest_path) = paths.manifest.as_deref() else {
        return false;
    };
    let Some(bundle) = manifest_path
        .ancestors()
        .find(|ancestor| ancestor.join("bin").join(HELPER_NAME) == paths.helper)
    else {
        return false;
    };
    if bundle.join(MODEL_DIRECTORY) != paths.models {
        return false;
    }
    let Ok(bytes) = std::fs::read(manifest_path) else {
        return false;
    };
    let Ok(manifest) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        return false;
    };
    if manifest
        .get("schemaVersion")
        .and_then(serde_json::Value::as_u64)
        != Some(1)
        || manifest
            .get("modelFamily")
            .and_then(serde_json::Value::as_str)
            != Some(MODEL_FAMILY)
    {
        return false;
    }
    let Some(inference) = manifest.get("inference") else {
        return false;
    };
    if inference
        .get("schemaVersion")
        .and_then(serde_json::Value::as_u64)
        != Some(INFERENCE_SCHEMA)
        || inference.get("noise").and_then(serde_json::Value::as_u64) != Some(0)
        || inference.get("scale").and_then(serde_json::Value::as_u64) != Some(2)
        || inference.get("format").and_then(serde_json::Value::as_str) != Some("png")
        || inference
            .get("tileSize")
            .and_then(serde_json::Value::as_u64)
            != Some(128)
        || inference.get("jobs").and_then(serde_json::Value::as_str) != Some("1:1:1")
        || inference.get("syncgap").and_then(serde_json::Value::as_u64) != Some(2)
    {
        return false;
    }
    let Some(files) = manifest.get("files").and_then(serde_json::Value::as_object) else {
        return false;
    };
    let mut expected = vec![(
        format!("bin/{HELPER_NAME}"),
        helper_hash,
        paths.helper.clone(),
    )];
    for (index, name) in MODEL_FILES.iter().enumerate() {
        expected.push((
            format!("{MODEL_DIRECTORY}/{name}"),
            &model_hashes[index],
            paths.models.join(name),
        ));
    }
    expected.into_iter().all(|(name, hash, path)| {
        let Some(entry) = files.get(&name) else {
            return false;
        };
        entry.get("sha256").and_then(serde_json::Value::as_str) == Some(hash)
            && entry.get("size").and_then(serde_json::Value::as_u64)
                == std::fs::symlink_metadata(&path)
                    .ok()
                    .map(|metadata| metadata.len())
    })
}

fn fingerprint(helper: &Path, models: &Path) -> Option<String> {
    Some(cache_fingerprint(
        &sha256_file(helper)?,
        &[
            sha256_file(&models.join(MODEL_FILES[0]))?,
            sha256_file(&models.join(MODEL_FILES[1]))?,
        ],
    ))
}

/// Multi-pass ncnn derivation inside a `cache::publish` stage: each pass
/// writes a sibling of the publish output, the last pass writes the publish
/// output itself, and `publish` performs the validation and atomic rename.
pub(super) fn derive(
    config: &Config,
    source: &Path,
    passes: u8,
    engine: Engine,
    derived: &Path,
    expected: (u32, u32),
    cancel: &AtomicBool,
) -> Option<PathBuf> {
    if valid_output(derived, expected) {
        return Some(derived.to_path_buf());
    }
    super::cache::publish(derived, expected, cancel, |output| {
        let stage_dir = output.parent()?;
        let input = stage_dir.join("input.png");
        image::load_from_memory(&std::fs::read(source).ok()?)
            .ok()?
            .save_with_format(&input, image::ImageFormat::Png)
            .ok()?;
        let mut current = input;
        for pass in 0..passes {
            if cancel.load(Ordering::Relaxed) {
                return None;
            }
            let pass_out = if pass + 1 == passes {
                output.to_path_buf()
            } else {
                stage_dir.join(format!("pass-{pass}.png"))
            };
            run_pass(config, engine, &current, &pass_out, PASS_TIMEOUT, cancel)?;
            let want = (
                expected.0 >> (passes - 1 - pass),
                expected.1 >> (passes - 1 - pass),
            );
            if !valid_output(&pass_out, want) {
                return None;
            }
            current = pass_out;
        }
        Some(())
    })
}

fn run_pass(
    config: &Config,
    engine: Engine,
    input: &Path,
    output: &Path,
    timeout: Duration,
    cancel: &AtomicBool,
) -> Option<()> {
    let mut command = Command::new(&config.helper);
    command
        .arg("-i")
        .arg(input)
        .arg("-o")
        .arg(output)
        .arg("-n")
        .arg("0")
        .arg("-s")
        .arg("2")
        .arg("-f")
        .arg("png")
        .arg("-t")
        .arg("128")
        .arg("-j")
        .arg("1:1:1")
        .arg("-c")
        .arg("2")
        .arg("-m")
        .arg(&config.models);
    if engine == Engine::RealCuganCpu {
        command.arg("-g").arg("-1");
    }
    super::process::run_helper(command, output, timeout, cancel)
}

pub(super) fn upscaled_cover(
    source: &Path,
    passes: u8,
    engine: Engine,
    cancel: &AtomicBool,
    cache_root: &Path,
) -> Option<PathBuf> {
    if cancel.load(Ordering::Relaxed) {
        return None;
    }
    let Some(config) = config() else {
        STATUS.store(STATUS_MISSING, Ordering::Relaxed);
        return None;
    };
    let (width, height) = super::dimensions(source)?;
    let passes = super::capped_passes(passes, width, height);
    if passes == 0 {
        return None;
    }
    let expected = (
        width.checked_shl(u32::from(passes))?,
        height.checked_shl(u32::from(passes))?,
    );
    let cpu_cache =
        super::cache::location_in(cache_root, source, passes, &config.key(Engine::RealCuganCpu))?;
    let gpu_cache =
        super::cache::location_in(cache_root, source, passes, &config.key(Engine::RealCugan))?;

    if engine == Engine::RealCugan {
        return derive_auto(
            &config, source, passes, &gpu_cache, &cpu_cache, expected, cancel,
        );
    }

    let selected = if engine == Engine::RealCuganCpu {
        Engine::RealCuganCpu
    } else {
        Engine::RealCugan
    };
    let target = if selected == Engine::RealCuganCpu {
        &cpu_cache
    } else {
        &gpu_cache
    };
    if valid_output(target, expected) {
        STATUS.store(
            if selected == Engine::RealCuganCpu {
                STATUS_CPU
            } else {
                STATUS_READY
            },
            Ordering::Relaxed,
        );
        return Some(target.clone());
    }
    STATUS.store(
        if selected == Engine::RealCuganCpu {
            STATUS_CPU
        } else {
            STATUS_WORKING
        },
        Ordering::Relaxed,
    );
    let output = derive(&config, source, passes, selected, target, expected, cancel);
    STATUS.store(
        if output.is_some() {
            if selected == Engine::RealCuganCpu {
                STATUS_CPU
            } else {
                STATUS_READY
            }
        } else {
            STATUS_FAILED
        },
        Ordering::Relaxed,
    );
    output
}

fn derive_auto(
    config: &Config,
    source: &Path,
    passes: u8,
    gpu_cache: &Path,
    cpu_cache: &Path,
    expected: (u32, u32),
    cancel: &AtomicBool,
) -> Option<PathBuf> {
    if valid_output(cpu_cache, expected) {
        STATUS.store(STATUS_CPU, Ordering::Relaxed);
        return Some(cpu_cache.to_path_buf());
    }
    if valid_output(gpu_cache, expected) {
        STATUS.store(STATUS_READY, Ordering::Relaxed);
        return Some(gpu_cache.to_path_buf());
    }
    STATUS.store(STATUS_WORKING, Ordering::Relaxed);
    if let Some(output) = derive(
        config,
        source,
        passes,
        Engine::RealCugan,
        gpu_cache,
        expected,
        cancel,
    ) {
        STATUS.store(STATUS_READY, Ordering::Relaxed);
        return Some(output);
    }
    if cancel.load(Ordering::Relaxed) {
        STATUS.store(STATUS_FAILED, Ordering::Relaxed);
        return None;
    }
    STATUS.store(STATUS_CPU, Ordering::Relaxed);
    let output = derive(
        config,
        source,
        passes,
        Engine::RealCuganCpu,
        cpu_cache,
        expected,
        cancel,
    );
    if output.is_none() {
        STATUS.store(STATUS_FAILED, Ordering::Relaxed);
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::Arc;

    struct Fixture(PathBuf);

    impl Fixture {
        fn new(name: &str) -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(0);
            let dir = std::env::temp_dir().join(format!(
                "whisky test {}-{}-{name}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed),
            ));
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }

        fn helper(&self, body: &str) -> PathBuf {
            let helper = self.0.join(HELPER_NAME);
            let log = self.0.join("invocations.log");
            let script = format!(
                "#!/bin/sh\nout=\"\"\ndevice=\"\"\nwhile [ $# -gt 0 ]; do\n  printf '%s\\n' \"$1\" >> \"{0}\"\n  if [ \"$1\" = \"-o\" ]; then shift; out=\"$1\"; printf '%s\\n' \"$1\" >> \"{0}\"; fi\n  if [ \"$1\" = \"-g\" ]; then shift; device=\"$1\"; printf '%s\\n' \"$1\" >> \"{0}\"; fi\n  shift || break\ndone\n{1}\n",
                log.display(),
                body,
            );
            std::fs::write(&helper, script).unwrap();
            std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
            helper
        }

        fn log(&self) -> String {
            std::fs::read_to_string(self.0.join("invocations.log")).unwrap_or_default()
        }

        fn models(&self) -> PathBuf {
            let dir = self.0.join("models-se");
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join("up2x-no-denoise.param"), b"param").unwrap();
            std::fs::write(dir.join("up2x-no-denoise.bin"), b"bin").unwrap();
            dir
        }

        fn png(&self, name: &str, width: u32, height: u32) -> PathBuf {
            let path = self.0.join(name);
            image::RgbaImage::from_pixel(width, height, image::Rgba([7, 60, 120, 255]))
                .save_with_format(&path, image::ImageFormat::Png)
                .unwrap();
            path
        }

        fn config(&self, helper: &Path, models: &Path) -> Config {
            Config {
                helper: helper.to_path_buf(),
                models: models.to_path_buf(),
                fingerprint: fingerprint(helper, models).unwrap(),
            }
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn derive_with(
        fixture: &Fixture,
        script: &str,
        source: &Path,
        passes: u8,
        engine: Engine,
        target: &Path,
        cancel: &AtomicBool,
    ) -> Option<PathBuf> {
        let helper = fixture.helper(script);
        let models = fixture.models();
        let config = fixture.config(&helper, &models);
        let (width, height) = super::super::dimensions(source).unwrap();
        let expected = (width << passes, height << passes);
        derive(&config, source, passes, engine, target, expected, cancel)
    }

    fn stray_stages(dir: &Path) -> Vec<PathBuf> {
        std::fs::read_dir(dir)
            .map(|entries| {
                entries
                    .flatten()
                    .map(|entry| entry.path())
                    .filter(|path| {
                        path.file_name()
                            .and_then(|name| name.to_str())
                            .map(|name| name.starts_with(".stage-"))
                            .unwrap_or(false)
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    #[test]
    fn defaults_are_only_the_adjacent_bundle_layout() {
        let fixture = Fixture::new("discovery");
        let exe_dir = fixture.0.join("bin");
        std::fs::create_dir_all(&exe_dir).unwrap();
        let paths = runtime_paths(None, Some(exe_dir.clone()), None).expect("bundle paths");
        assert_eq!(paths.helper, exe_dir.join(HELPER_NAME));
        assert_eq!(paths.models, fixture.0.join(MODEL_DIRECTORY));
        assert_eq!(paths.manifest, Some(fixture.0.join(BUNDLE_MANIFEST)));
        assert!(paths.bundled);
    }

    #[test]
    fn explicit_helper_override_requires_an_absolute_executable() {
        let fixture = Fixture::new("bad-override");
        let models = fixture.models();
        for bad in [
            OsString::from("/definitely/not/here"),
            OsString::from("relative/helper"),
        ] {
            assert!(resolve(Some(bad), None, Some(models.clone().into())).is_none());
        }
        let plain = fixture.0.join("plain");
        std::fs::write(&plain, b"#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&plain, std::fs::Permissions::from_mode(0o644)).unwrap();
        let named = fixture.0.join(HELPER_NAME);
        std::fs::copy(plain, &named).unwrap();
        std::fs::set_permissions(&named, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(resolve(Some(named.into()), None, Some(models.into())).is_some());
    }

    #[test]
    fn explicit_models_override_fails_closed_and_takes_precedence() {
        let fixture = Fixture::new("models-override");
        let helper = fixture.helper("true");
        let incomplete = fixture.0.join("half");
        std::fs::create_dir_all(&incomplete).unwrap();
        std::fs::write(incomplete.join("up2x-no-denoise.param"), b"p").unwrap();
        for bad in [incomplete.clone().into(), OsString::from("rel/models-se")] {
            assert!(resolve(Some(helper.clone().into()), None, Some(bad)).is_none());
        }
        std::fs::write(incomplete.join("up2x-no-denoise.bin"), b"").unwrap();
        assert!(resolve(Some(helper.clone().into()), None, Some(incomplete.into())).is_none());
        let sibling = helper.parent().unwrap().join("models-se");
        let chosen = fixture.0.join("alternate").join(MODEL_FAMILY);
        for (dir, byte) in [(&sibling, b"x"), (&chosen, b"y")] {
            std::fs::create_dir_all(dir).unwrap();
            std::fs::write(dir.join("up2x-no-denoise.param"), byte).unwrap();
            std::fs::write(dir.join("up2x-no-denoise.bin"), byte).unwrap();
        }
        let found = resolve(Some(helper.into()), None, Some(chosen.clone().into()))
            .expect("explicit models accepted");
        assert_eq!(found.models, chosen);
        assert!(sibling.exists());
    }

    #[test]
    fn gpu_and_cpu_forward_distinct_arguments() {
        let fixture = Fixture::new("arguments");
        let source = fixture.png("cover.png", 8, 6);
        let extensionless = fixture.0.join("extensionless cover");
        std::fs::copy(&source, &extensionless).unwrap();
        let out2x = fixture.png("fixture-2x.png", 16, 12);
        let script = format!("cp \"{}\" \"$out\"\n", out2x.display());

        let target = fixture.0.join("cache").join("gpu.png");
        let derived = derive_with(
            &fixture,
            &script,
            &extensionless,
            1,
            Engine::RealCugan,
            &target,
            &AtomicBool::new(false),
        )
        .expect("gpu pass succeeds");
        let log = fixture.log();
        let args: Vec<&str> = log.trim().lines().collect();
        assert_eq!(args.first(), Some(&"-i"));
        assert!(
            !args.iter().any(|line| *line == "-g"),
            "gpu omits -g: {log}"
        );
        for (flag, value) in [
            ("-n", "0"),
            ("-s", "2"),
            ("-f", "png"),
            ("-t", "128"),
            ("-j", "1:1:1"),
            ("-c", "2"),
        ] {
            let position = args
                .iter()
                .position(|line| *line == flag)
                .unwrap_or_else(|| panic!("missing {flag}: {log}"));
            assert_eq!(args[position + 1], value, "{flag}: {log}");
        }
        let models_position = args.iter().position(|line| *line == "-m").unwrap();
        assert!(args[models_position + 1].ends_with("models-se"), "{log}");
        assert!(args[1].ends_with("input.png"), "{log}");
        assert_eq!(super::super::dimensions(&derived), Some((16, 12)));

        let cpu_target = fixture.0.join("cache").join("cpu.png");
        let derived = derive_with(
            &fixture,
            &script,
            &extensionless,
            1,
            Engine::RealCuganCpu,
            &cpu_target,
            &AtomicBool::new(false),
        )
        .expect("cpu pass succeeds");
        let log = fixture.log();
        let args: Vec<&str> = log.trim().lines().collect();
        let position = args
            .iter()
            .rposition(|line| *line == "-g")
            .expect("-g passed");
        assert_eq!(args[position + 1], "-1", "cpu selects -g -1: {log}");
        assert!(derived.exists());
    }

    #[test]
    fn x4_runs_two_distinct_passes() {
        let fixture = Fixture::new("two-passes");
        let source = fixture.png("cover", 8, 6);
        let out2x = fixture.png("fixture-2x.png", 16, 12);
        let out4x = fixture.png("fixture-4x.png", 32, 24);
        let script = format!(
            "case \"$out\" in\n  *pass-0.png) cp \"{}\" \"$out\" ;;\n  *) cp \"{}\" \"$out\" ;;\nesac\n",
            out2x.display(),
            out4x.display(),
        );
        let target = fixture.0.join("cache").join("x4.png");
        let derived = derive_with(
            &fixture,
            &script,
            &source,
            2,
            Engine::RealCugan,
            &target,
            &AtomicBool::new(false),
        )
        .expect("two passes succeed");
        assert_eq!(super::super::dimensions(&derived), Some((32, 24)));
        let log = fixture.log();
        let calls = log.lines().filter(|line| *line == "-i").count();
        assert_eq!(calls, 2, "expected two helper invocations: {log}");
        assert_eq!(log.lines().filter(|line| *line == "-s").count(), 2);
        assert_eq!(log.lines().filter(|line| *line == "1:1:1").count(), 2);
        assert!(stray_stages(target.parent().unwrap()).is_empty());
    }

    #[test]
    fn cached_derivative_skips_a_second_spawn() {
        let fixture = Fixture::new("cache-reuse");
        let source = fixture.png("cover", 8, 6);
        let out2x = fixture.png("fixture-2x.png", 16, 12);
        let script = format!("cp \"{}\" \"$out\"\n", out2x.display());
        let target = fixture.0.join("cache").join("target.png");
        let cancel = AtomicBool::new(false);
        let first = derive_with(
            &fixture,
            &script,
            &source,
            1,
            Engine::RealCugan,
            &target,
            &cancel,
        )
        .expect("first run");
        std::fs::remove_file(fixture.0.join("invocations.log")).unwrap();
        let second = derive_with(
            &fixture,
            &script,
            &source,
            1,
            Engine::RealCugan,
            &target,
            &cancel,
        )
        .expect("cached hit");
        assert_eq!(first, second);
        assert!(
            fixture.log().is_empty(),
            "no second spawn: {}",
            fixture.log()
        );
    }

    #[test]
    fn failure_and_wrong_dimensions_never_publish() {
        let fixture = Fixture::new("failures");
        let source = fixture.png("cover", 8, 6);
        let out2x = fixture.png("fixture-2x.png", 16, 12);
        let wrong = fixture.png("fixture-wrong.png", 10, 10);
        let cancel = AtomicBool::new(false);
        for (name, script) in [
            ("exit", "exit 1\n".to_owned()),
            (
                "wrong-size",
                format!("cp \"{}\" \"$out\"\n", wrong.display()),
            ),
            ("no-output", "true\n".to_owned()),
        ] {
            let target = fixture.0.join("cache").join(format!("{name}.png"));
            assert!(
                derive_with(
                    &fixture,
                    &script,
                    &source,
                    1,
                    Engine::RealCugan,
                    &target,
                    &cancel
                )
                .is_none(),
                "{name} must not publish",
            );
            assert!(!target.exists());
            assert!(stray_stages(target.parent().unwrap()).is_empty());
            let _ = out2x;
        }
    }

    #[test]
    fn a_failed_second_pass_leaves_nothing_behind() {
        let fixture = Fixture::new("partial");
        let source = fixture.png("cover", 8, 6);
        let out2x = fixture.png("fixture-2x.png", 16, 12);
        let script = format!(
            "case \"$out\" in\n  *pass-0.png) cp \"{}\" \"$out\" ;;\n  *) exit 1 ;;\nesac\n",
            out2x.display(),
        );
        let target = fixture.0.join("cache").join("x4.png");
        assert!(
            derive_with(
                &fixture,
                &script,
                &source,
                2,
                Engine::RealCugan,
                &target,
                &AtomicBool::new(false)
            )
            .is_none()
        );
        assert!(!target.exists());
        assert!(stray_stages(target.parent().unwrap()).is_empty());
        assert_eq!(
            fixture.log().lines().filter(|line| *line == "-i").count(),
            2
        );
    }

    #[test]
    fn corrupt_cached_derivative_is_replaced() {
        let fixture = Fixture::new("corrupt-cache");
        let source = fixture.png("cover", 8, 6);
        let out2x = fixture.png("fixture-2x.png", 16, 12);
        let script = format!("cp \"{}\" \"$out\"\n", out2x.display());
        let cancel = AtomicBool::new(false);
        for (name, corrupt) in [
            ("garbage.png", b"not a png".to_vec()),
            ("truncated.png", {
                let bytes = std::fs::read(&out2x).unwrap();
                bytes[..bytes.len() / 2].to_vec()
            }),
        ] {
            let target = fixture.0.join("cache").join(name);
            std::fs::create_dir_all(target.parent().unwrap()).unwrap();
            std::fs::write(&target, corrupt).unwrap();
            let derived = derive_with(
                &fixture,
                &script,
                &source,
                1,
                Engine::RealCugan,
                &target,
                &cancel,
            )
            .expect("corrupt cache rebuilt");
            assert!(valid_output(&derived, (16, 12)));
        }
    }

    #[test]
    fn cancelled_before_start_never_spawns() {
        let fixture = Fixture::new("pre-cancel");
        let source = fixture.png("cover", 8, 6);
        let out2x = fixture.png("fixture-2x.png", 16, 12);
        let script = format!("cp \"{}\" \"$out\"\n", out2x.display());
        let target = fixture.0.join("cache").join("target.png");
        let cancel = AtomicBool::new(true);
        assert!(
            derive_with(
                &fixture,
                &script,
                &source,
                1,
                Engine::RealCugan,
                &target,
                &cancel
            )
            .is_none()
        );
        assert!(fixture.log().is_empty());
        assert!(!target.exists());
        assert!(stray_stages(target.parent().unwrap()).is_empty());
    }

    #[test]
    fn symlink_derivative_is_rejected_and_untouched() {
        let fixture = Fixture::new("symlink");
        let source = fixture.png("cover", 8, 6);
        let out2x = fixture.png("fixture-2x.png", 16, 12);
        let script = format!("cp \"{}\" \"$out\"\n", out2x.display());
        let sentinel = fixture.0.join("sentinel.txt");
        std::fs::write(&sentinel, b"keep me").unwrap();
        let target = fixture.0.join("cache").join("target.png");
        std::fs::create_dir_all(target.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&sentinel, &target).unwrap();
        assert!(
            derive_with(
                &fixture,
                &script,
                &source,
                1,
                Engine::RealCugan,
                &target,
                &AtomicBool::new(false)
            )
            .is_none()
        );
        assert!(target.symlink_metadata().unwrap().is_symlink());
        assert_eq!(std::fs::read(&sentinel).unwrap(), b"keep me");
    }

    #[test]
    fn symlinked_pass_output_is_rejected() {
        let fixture = Fixture::new("symlink-output");
        let source = fixture.png("cover", 8, 6);
        let sentinel = fixture.png("sentinel.png", 16, 12);
        let script = format!("ln -sf \"{}\" \"$out\"\n", sentinel.display());
        let target = fixture.0.join("cache").join("target.png");
        assert!(
            derive_with(
                &fixture,
                &script,
                &source,
                1,
                Engine::RealCugan,
                &target,
                &AtomicBool::new(false)
            )
            .is_none()
        );
        assert!(!target.exists());
        assert!(stray_stages(target.parent().unwrap()).is_empty());
    }

    #[test]
    fn stage_creation_is_exclusive() {
        let fixture = Fixture::new("stage");
        let parent = fixture.0.join("cache");
        std::fs::create_dir_all(&parent).unwrap();
        let first = Stage::create(&parent, "job").expect("first create");
        assert!(
            Stage::create(&parent, "job").is_none(),
            "existing dir refused"
        );
        let occupied = parent.join("occupied");
        std::fs::create_dir_all(&occupied).unwrap();
        std::fs::write(occupied.join("sentinel"), b"keep me").unwrap();
        assert!(Stage::create(&parent, "occupied").is_none());
        assert_eq!(
            std::fs::read(occupied.join("sentinel")).unwrap(),
            b"keep me"
        );
        let link = parent.join("link");
        std::os::unix::fs::symlink(&occupied, &link).unwrap();
        assert!(Stage::create(&parent, "link").is_none());
        drop(first);
        assert!(stray_stages(&parent).is_empty() || !parent.join("job").exists());
    }

    #[test]
    fn timeout_kills_the_pass() {
        let fixture = Fixture::new("timeout");
        let source = fixture.png("cover", 8, 6);
        let helper = fixture.helper("exec sleep 30\n");
        let models = fixture.models();
        let config = fixture.config(&helper, &models);
        let output = fixture.0.join("cache").join("out.png");
        let start = Instant::now();
        assert!(
            run_pass(
                &config,
                Engine::RealCugan,
                &source,
                &output,
                Duration::from_millis(200),
                &AtomicBool::new(false),
            )
            .is_none()
        );
        assert!(
            start.elapsed() < Duration::from_secs(10),
            "kill + wait took too long"
        );
        assert!(!output.exists());
    }

    #[test]
    fn cancel_kills_the_running_pass() {
        let fixture = Fixture::new("cancel");
        let source = fixture.png("cover", 8, 6);
        let helper = fixture.helper("exec sleep 30\n");
        let models = fixture.models();
        let config = fixture.config(&helper, &models);
        let output = fixture.0.join("cache").join("out.png");
        let cancel = Arc::new(AtomicBool::new(false));
        let flag = cancel.clone();
        let start = Instant::now();
        let worker = std::thread::spawn(move || {
            run_pass(
                &config,
                Engine::RealCugan,
                &source,
                &output,
                Duration::from_secs(60),
                &flag,
            )
        });
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while !fixture.log().lines().any(|line| line == "-i") {
            assert!(std::time::Instant::now() < deadline, "helper did not start");
            std::thread::sleep(Duration::from_millis(10));
        }
        cancel.store(true, Ordering::Relaxed);
        assert!(worker.join().unwrap().is_none());
        assert!(
            start.elapsed() < Duration::from_secs(10),
            "cancel did not kill"
        );
    }

    #[test]
    fn model_and_device_change_the_cache_key() {
        let fixture = Fixture::new("keys");
        let helper = fixture.helper("true");
        let models = fixture.models();
        let first = fixture.config(&helper, &models);
        assert_ne!(
            first.key(Engine::RealCugan),
            first.key(Engine::RealCuganCpu),
        );
        std::fs::write(models.join("up2x-no-denoise.bin"), b"other").unwrap();
        let second = fixture.config(&helper, &models);
        assert_ne!(first.key(Engine::RealCugan), second.key(Engine::RealCugan),);
        let changed_helper = fixture.helper("true\n# changed");
        let third = fixture.config(&changed_helper, &models);
        assert_ne!(second.key(Engine::RealCugan), third.key(Engine::RealCugan));
        assert!(first.key(Engine::RealCugan).contains("v2"));
    }

    #[test]
    fn packaged_manifest_rejects_missing_and_corrupt_components() {
        let fixture = Fixture::new("bundle-validation");
        let root = fixture.0.join("bundle");
        let helper = root.join("bin").join(HELPER_NAME);
        std::fs::create_dir_all(helper.parent().unwrap()).unwrap();
        let source_helper = fixture.helper("true");
        std::fs::copy(source_helper, &helper).unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
        let models = root.join(MODEL_DIRECTORY);
        std::fs::create_dir_all(&models).unwrap();
        std::fs::write(models.join(MODEL_FILES[0]), b"param-data").unwrap();
        std::fs::write(models.join(MODEL_FILES[1]), b"model-data").unwrap();
        assert!(resolve(None, Some(root.join("bin")), None).is_none());

        let entries = serde_json::json!({
            format!("bin/{HELPER_NAME}"): {
                "sha256": sha256_file(&helper).unwrap(),
                "size": helper.metadata().unwrap().len()
            },
            format!("{MODEL_DIRECTORY}/{}", MODEL_FILES[0]): {
                "sha256": sha256_file(&models.join(MODEL_FILES[0])).unwrap(),
                "size": models.join(MODEL_FILES[0]).metadata().unwrap().len()
            },
            format!("{MODEL_DIRECTORY}/{}", MODEL_FILES[1]): {
                "sha256": sha256_file(&models.join(MODEL_FILES[1])).unwrap(),
                "size": models.join(MODEL_FILES[1]).metadata().unwrap().len()
            }
        });
        let manifest = serde_json::json!({
            "schemaVersion": 1,
            "modelFamily": MODEL_FAMILY,
            "inference": {
                "schemaVersion": INFERENCE_SCHEMA,
                "noise": 0,
                "scale": 2,
                "format": "png",
                "tileSize": 128,
                "jobs": "1:1:1",
                "syncgap": 2
            },
            "files": entries
        });
        let manifest_path = root.join(BUNDLE_MANIFEST);
        std::fs::create_dir_all(manifest_path.parent().unwrap()).unwrap();
        std::fs::write(&manifest_path, serde_json::to_vec(&manifest).unwrap()).unwrap();
        assert!(resolve(None, Some(root.join("bin")), None).is_some());
        std::fs::write(models.join(MODEL_FILES[1]), b"tampered").unwrap();
        assert!(resolve(None, Some(root.join("bin")), None).is_none());
    }

    #[test]
    fn automatic_mode_retries_cpu_once_after_gpu_failure() {
        let fixture = Fixture::new("auto-fallback");
        let source = fixture.png("cover", 8, 6);
        let out2x = fixture.png("fixture-2x.png", 16, 12);
        let script = format!(
            "if [ \"$device\" = -1 ]; then cp \"{}\" \"$out\"; else exit 1; fi\n",
            out2x.display()
        );
        let helper = fixture.helper(&script);
        let models = fixture.models();
        let config = fixture.config(&helper, &models);
        let gpu = fixture.0.join("cache/gpu.png");
        let cpu = fixture.0.join("cache/cpu.png");
        let result = derive_auto(
            &config,
            &source,
            1,
            &gpu,
            &cpu,
            (16, 12),
            &AtomicBool::new(false),
        )
        .expect("CPU retry succeeds");
        assert_eq!(result, cpu);
        let log = fixture.log();
        assert_eq!(log.lines().filter(|line| *line == "-i").count(), 2, "{log}");
        assert_eq!(log.lines().filter(|line| *line == "-g").count(), 1, "{log}");
        assert_eq!(log.lines().filter(|line| *line == "-n").count(), 2, "{log}");
    }

    #[test]
    fn automatic_mode_does_not_retry_cpu_after_cancellation() {
        let fixture = Fixture::new("auto-cancel");
        let source = fixture.png("cover", 8, 6);
        let helper = fixture.helper("exec sleep 30\n");
        let models = fixture.models();
        let config = fixture.config(&helper, &models);
        let gpu = fixture.0.join("cache/gpu.png");
        let cpu = fixture.0.join("cache/cpu.png");
        let cancel = Arc::new(AtomicBool::new(false));
        let worker_cancel = cancel.clone();
        let worker = std::thread::spawn(move || {
            derive_auto(&config, &source, 1, &gpu, &cpu, (16, 12), &worker_cancel)
        });
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while !fixture.log().lines().any(|line| line == "-i") {
            assert!(std::time::Instant::now() < deadline, "helper did not start");
            std::thread::sleep(Duration::from_millis(10));
        }
        cancel.store(true, Ordering::Relaxed);
        assert!(worker.join().unwrap().is_none());
        let log = fixture.log();
        assert_eq!(log.lines().filter(|line| *line == "-i").count(), 1, "{log}");
        assert!(!log.lines().any(|line| line == "-g"), "{log}");
    }

    #[test]
    #[ignore = "requires an explicitly built RealCUGAN helper and bundled models"]
    fn bundled_real_helper_upscales_extensionless_odd_rgba_image() {
        config().expect("built helper and bundled models must be available");
        let fixture = Fixture::new("real-helper");
        let source = fixture.0.join("odd rgba cover");
        image::RgbaImage::from_pixel(7, 5, image::Rgba([7, 60, 120, 255]))
            .save_with_format(&source, image::ImageFormat::Png)
            .unwrap();
        let cancel = AtomicBool::new(false);
        let x2 =
            super::super::upscaled_cover_with_cancel(&source, 1, Engine::RealCuganCpu, &cancel)
                .expect("CPU x2 real inference should succeed");
        assert_eq!(super::super::dimensions(&x2), Some((14, 10)));
        let x4 =
            super::super::upscaled_cover_with_cancel(&source, 2, Engine::RealCuganCpu, &cancel)
                .expect("CPU x4 real inference should succeed");
        assert_eq!(super::super::dimensions(&x4), Some((28, 20)));
    }
}
