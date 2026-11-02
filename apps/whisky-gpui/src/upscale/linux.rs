use std::ffi::OsString;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use super::Engine;

const HELPER_NAME: &str = "realcugan-ncnn-vulkan";
const MODEL_FILES: [&str; 2] = ["up2x-no-denoise.param", "up2x-no-denoise.bin"];
const PASS_TIMEOUT: Duration = Duration::from_secs(120);
const POLL: Duration = Duration::from_millis(40);
const STAGE_ATTEMPTS: u32 = 64;

pub(super) struct Config {
    helper: PathBuf,
    models: PathBuf,
    fingerprint: u64,
}

impl Config {
    pub(super) fn key(&self, engine: Engine) -> String {
        let device = match engine {
            Engine::RealCuganCpu => "cpu",
            _ => "gpu",
        };
        format!("realcugan-ncnn-{device}-{:016x}", self.fingerprint)
    }
}

pub(super) fn config() -> Option<&'static Config> {
    static CONFIG: OnceLock<Option<Config>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            resolve(
                std::env::var_os("WHISKY_REALCUGAN_HELPER"),
                std::env::var_os("PATH"),
                std::env::current_exe()
                    .ok()
                    .and_then(|exe| exe.parent().map(Path::to_path_buf)),
                std::env::var_os("WHISKY_REALCUGAN_MODELS"),
            )
        })
        .as_ref()
}

fn resolve(
    helper_override: Option<OsString>,
    search_path: Option<OsString>,
    exe_dir: Option<PathBuf>,
    models_override: Option<OsString>,
) -> Option<Config> {
    let helper = match helper_override {
        Some(path) => {
            let path = PathBuf::from(path);
            (path.is_absolute() && executable(&path)).then_some(path)?
        }
        None => helper_candidates(search_path.as_ref(), exe_dir.as_deref())
            .into_iter()
            .find(|candidate| executable(candidate))?,
    };
    let models = match models_override {
        Some(dir) => {
            let dir = PathBuf::from(dir);
            (dir.is_absolute() && valid_models(&dir)).then_some(dir)?
        }
        None => model_candidates(&helper)
            .into_iter()
            .find(|candidate| valid_models(candidate))?,
    };
    Some(Config {
        fingerprint: fingerprint(&helper, &models)?,
        helper,
        models,
    })
}

fn helper_candidates(search_path: Option<&OsString>, exe_dir: Option<&Path>) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(dir) = exe_dir {
        candidates.push(dir.join(HELPER_NAME));
    }
    if let Some(path) = search_path {
        candidates.extend(
            std::env::split_paths(path)
                .filter(|entry| entry.is_absolute())
                .map(|entry| entry.join(HELPER_NAME)),
        );
    }
    candidates
}

fn model_candidates(helper: &Path) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(parent) = helper.parent() {
        candidates.push(parent.join("models-se"));
        candidates.push(
            parent
                .join("..")
                .join("share")
                .join("realcugan-ncnn-vulkan")
                .join("models-se"),
        );
    }
    candidates.push(PathBuf::from("/usr/share/realcugan-ncnn-vulkan/models-se"));
    candidates.push(PathBuf::from("/usr/share/realcugan/models-se"));
    candidates.push(PathBuf::from("/usr/local/share/realcugan-ncnn-vulkan/models-se"));
    candidates
}

fn executable(path: &Path) -> bool {
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn valid_models(dir: &Path) -> bool {
    dir.is_dir()
        && MODEL_FILES.iter().all(|name| {
            std::fs::metadata(dir.join(name))
                .map(|metadata| metadata.is_file() && metadata.len() > 0)
                .unwrap_or(false)
        })
}

fn fingerprint(helper: &Path, models: &Path) -> Option<u64> {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    let metadata = std::fs::metadata(helper).ok()?;
    for part in [
        metadata.len(),
        metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .map(|age| age.as_nanos() as u64)
            .unwrap_or(0),
    ] {
        hash ^= part;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    let mut bytes = Vec::new();
    for name in MODEL_FILES {
        bytes.clear();
        std::fs::File::open(models.join(name))
            .ok()?
            .read_to_end(&mut bytes)
            .ok()?;
        for byte in &bytes {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    Some(hash)
}

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
    if derived
        .symlink_metadata()
        .map(|metadata| metadata.is_symlink())
        .unwrap_or(false)
    {
        return None;
    }
    std::fs::create_dir_all(derived.parent()?).ok()?;
    let stage = Stage::new(derived.parent()?)?;
    let input = stage.0.join("input.png");
    image::load_from_memory(&std::fs::read(source).ok()?)
        .ok()?
        .save_with_format(&input, image::ImageFormat::Png)
        .ok()?;
    let mut current = input;
    for pass in 0 .. passes {
        if cancel.load(Ordering::Relaxed) {
            return None;
        }
        let output = stage.0.join(if pass + 1 == passes {
            "output.png".to_owned()
        } else {
            format!("pass-{pass}.png")
        });
        run_pass(config, engine, &current, &output, PASS_TIMEOUT, cancel)?;
        let want = (
            expected.0 >> (passes - 1 - pass),
            expected.1 >> (passes - 1 - pass),
        );
        if !valid_output(&output, want) {
            return None;
        }
        current = output;
    }
    if cancel.load(Ordering::Relaxed) {
        return None;
    }
    std::fs::rename(&current, derived).ok()?;
    Some(derived.to_path_buf())
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
        .arg("-1")
        .arg("-s")
        .arg("2")
        .arg("-f")
        .arg("png")
        .arg("-t")
        .arg("128")
        .arg("-j")
        .arg("1:1:1")
        .arg("-m")
        .arg(&config.models);
    if engine == Engine::RealCuganCpu {
        command.arg("-g").arg("-1");
    }
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                return (status.success() && output.is_file()).then_some(());
            }
            Ok(None) => {
                if cancel.load(Ordering::Relaxed) || Instant::now() >= deadline {
                    kill_wait(&mut child);
                    return None;
                }
                std::thread::sleep(POLL);
            }
            Err(_) => {
                kill_wait(&mut child);
                return None;
            }
        }
    }
}

fn kill_wait(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

struct Stage(PathBuf);

impl Stage {
    fn new(parent: &Path) -> Option<Self> {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        for _ in 0 .. STAGE_ATTEMPTS {
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

    fn create(parent: &Path, name: &str) -> Option<Self> {
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
                "#!/bin/sh\nout=\"\"\nwhile [ $# -gt 0 ]; do\n  echo \"$1\" >> \"{0}\"\n  if [ \"$1\" = \"-o\" ]; then shift; out=\"$1\"; echo \"$1\" >> \"{0}\"; fi\n  shift || break\ndone\n{1}\n",
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
    fn discovery_finds_helper_next_to_exe_and_in_path() {
        let fixture = Fixture::new("discovery");
        let exe_dir = fixture.0.join("bin");
        std::fs::create_dir_all(&exe_dir).unwrap();
        let helper = fixture.helper("true");
        let helper_in_bin = exe_dir.join(HELPER_NAME);
        std::fs::copy(&helper, &helper_in_bin).unwrap();
        let models = fixture.models();
        let found = resolve(None, None, Some(exe_dir.clone()), Some(models.clone().into()))
            .expect("helper beside the executable");
        assert_eq!(found.helper, helper_in_bin);
        std::fs::remove_file(&helper_in_bin).unwrap();
        let search = std::env::join_paths([fixture.0.clone()]).unwrap();
        let found = resolve(None, Some(search), Some(exe_dir), Some(models.into()))
            .expect("helper on PATH");
        assert_eq!(found.helper, helper);
    }

    #[test]
    fn discovery_ignores_relative_and_empty_path_entries() {
        let fixture = Fixture::new("relative-path");
        fixture.helper("true");
        let search = std::env::join_paths([
            PathBuf::from("relative"),
            PathBuf::new(),
            fixture.0.clone(),
        ])
        .unwrap();
        let found = resolve(None, Some(search), None, Some(fixture.models().into()))
            .expect("absolute entry still matches");
        assert_eq!(found.helper, fixture.0.join(HELPER_NAME));
    }

    #[test]
    fn explicit_helper_override_fails_closed_when_invalid() {
        let fixture = Fixture::new("bad-override");
        fixture.helper("true");
        let search = std::env::join_paths([fixture.0.clone()]).unwrap();
        for bad in [
            OsString::from("/definitely/not/here"),
            OsString::from("relative/helper"),
        ] {
            assert!(resolve(Some(bad), Some(search.clone()), None, None).is_none());
        }
        let plain = fixture.0.join("plain");
        std::fs::write(&plain, b"#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&plain, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(resolve(Some(plain.into()), Some(search), None, None).is_none());
    }

    #[test]
    fn explicit_models_override_fails_closed_and_takes_precedence() {
        let fixture = Fixture::new("models-override");
        let helper = fixture.helper("true");
        let incomplete = fixture.0.join("half");
        std::fs::create_dir_all(&incomplete).unwrap();
        std::fs::write(incomplete.join("up2x-no-denoise.param"), b"p").unwrap();
        for bad in [incomplete.clone().into(), OsString::from("rel/models")] {
            assert!(resolve(Some(helper.clone().into()), None, None, Some(bad)).is_none());
        }
        std::fs::write(incomplete.join("up2x-no-denoise.bin"), b"").unwrap();
        assert!(
            resolve(Some(helper.clone().into()), None, None, Some(incomplete.into())).is_none()
        );
        let sibling = helper.parent().unwrap().join("models-se");
        let chosen = fixture.0.join("chosen");
        for (dir, byte) in [(&sibling, b"x"), (&chosen, b"y")] {
            std::fs::create_dir_all(dir).unwrap();
            std::fs::write(dir.join("up2x-no-denoise.param"), byte).unwrap();
            std::fs::write(dir.join("up2x-no-denoise.bin"), byte).unwrap();
        }
        let found = resolve(Some(helper.into()), None, None, Some(chosen.clone().into()))
            .expect("explicit models accepted");
        assert_eq!(found.models, chosen);
        let found = resolve(
            Some(fixture.0.join(HELPER_NAME).into()),
            None,
            None,
            None,
        )
        .expect("sibling models-se discovered");
        assert_eq!(found.models, sibling);
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
        assert!(!args.iter().any(|line| *line == "-g"), "gpu omits -g: {log}");
        for (flag, value) in [
            ("-n", "-1"),
            ("-s", "2"),
            ("-f", "png"),
            ("-t", "128"),
            ("-j", "1:1:1"),
        ] {
            let position = args.iter().position(|line| *line == flag).unwrap_or_else(|| {
                panic!("missing {flag}: {log}")
            });
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
        let position = args.iter().rposition(|line| *line == "-g").expect("-g passed");
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
        let first = derive_with(&fixture, &script, &source, 1, Engine::RealCugan, &target, &cancel)
            .expect("first run");
        std::fs::remove_file(fixture.0.join("invocations.log")).unwrap();
        let second = derive_with(&fixture, &script, &source, 1, Engine::RealCugan, &target, &cancel)
            .expect("cached hit");
        assert_eq!(first, second);
        assert!(fixture.log().is_empty(), "no second spawn: {}", fixture.log());
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
            ("wrong-size", format!("cp \"{}\" \"$out\"\n", wrong.display())),
            ("no-output", "true\n".to_owned()),
        ] {
            let target = fixture.0.join("cache").join(format!("{name}.png"));
            assert!(
                derive_with(&fixture, &script, &source, 1, Engine::RealCugan, &target, &cancel)
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
            derive_with(&fixture, &script, &source, 2, Engine::RealCugan, &target, &AtomicBool::new(false))
                .is_none()
        );
        assert!(!target.exists());
        assert!(stray_stages(target.parent().unwrap()).is_empty());
        assert_eq!(fixture.log().lines().filter(|line| *line == "-i").count(), 2);
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
                bytes[.. bytes.len() / 2].to_vec()
            }),
        ] {
            let target = fixture.0.join("cache").join(name);
            std::fs::create_dir_all(target.parent().unwrap()).unwrap();
            std::fs::write(&target, corrupt).unwrap();
            let derived = derive_with(&fixture, &script, &source, 1, Engine::RealCugan, &target, &cancel)
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
            derive_with(&fixture, &script, &source, 1, Engine::RealCugan, &target, &cancel).is_none()
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
            derive_with(&fixture, &script, &source, 1, Engine::RealCugan, &target, &AtomicBool::new(false))
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
            derive_with(&fixture, &script, &source, 1, Engine::RealCugan, &target, &AtomicBool::new(false))
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
        assert!(Stage::create(&parent, "job").is_none(), "existing dir refused");
        let occupied = parent.join("occupied");
        std::fs::create_dir_all(&occupied).unwrap();
        std::fs::write(occupied.join("sentinel"), b"keep me").unwrap();
        assert!(Stage::create(&parent, "occupied").is_none());
        assert_eq!(std::fs::read(occupied.join("sentinel")).unwrap(), b"keep me");
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
        assert!(run_pass(
            &config,
            Engine::RealCugan,
            &source,
            &output,
            Duration::from_millis(200),
            &AtomicBool::new(false),
        )
        .is_none());
        assert!(start.elapsed() < Duration::from_secs(10), "kill + wait took too long");
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
        std::thread::sleep(Duration::from_millis(150));
        cancel.store(true, Ordering::Relaxed);
        assert!(worker.join().unwrap().is_none());
        assert!(start.elapsed() < Duration::from_secs(10), "cancel did not kill");
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
        assert_ne!(
            first.key(Engine::RealCugan),
            second.key(Engine::RealCugan),
        );
    }
}
