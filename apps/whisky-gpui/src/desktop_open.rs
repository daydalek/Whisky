//! Startup file handoff retained until the bridge supplies its first catalogue.
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ExternalOpen {
    pub(crate) path: PathBuf,
    pub(crate) container: Option<PathBuf>,
    pub(crate) container_id: Option<String>,
}

pub(crate) fn parse(arguments: &[String]) -> Result<Option<ExternalOpen>, &'static str> {
    if arguments.is_empty() {
        return Ok(None);
    }
    let (path, container, container_id) = match arguments {
        [path] if !path.starts_with('-') => (path, None, None),
        [flag, path] if flag == "--open-file" => (path, None, None),
        [flag, path, container_flag, container]
            if flag == "--open-file" && container_flag == "--container" =>
        {
            (path, Some(container), None)
        }
        [flag, path, id_flag, id] if flag == "--open-file" && id_flag == "--container-id" => {
            let valid = id.len() == 36
                && id.bytes().enumerate().all(|(index, value)| {
                    if [8, 13, 18, 23].contains(&index) {
                        value == b'-'
                    } else {
                        value.is_ascii_hexdigit()
                    }
                });
            if !valid {
                return Err("Invalid shortcut container ID");
            }
            (path, None, Some(id))
        }
        _ => {
            return Err(
                "usage: whisky-gpui [<file> | --open-file <file> [--container <path> | --container-id <id>]]",
            );
        }
    };
    if (container_id.is_none() && !std::path::Path::new(path).is_absolute())
        || container.is_some_and(|value| !std::path::Path::new(value).is_absolute())
    {
        return Err("Desktop file and container paths must be absolute");
    }
    if container_id.is_some()
        && !std::path::Path::new(path).is_absolute()
        && !std::path::Path::new(path)
            .components()
            .all(|part| matches!(part, std::path::Component::Normal(_)))
    {
        return Err("Invalid container-relative shortcut path");
    }
    Ok(Some(ExternalOpen {
        path: PathBuf::from(path),
        container: container.map(PathBuf::from),
        container_id: container_id.cloned(),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).into()).collect()
    }
    #[test]
    fn desktop_file_arguments_retain_literal_paths_and_prefix_identity() {
        let parsed = parse(&args(&[
            "--open-file",
            "/tmp/中文 %f ' $HOME.exe",
            "--container",
            "/tmp/Prefix = %u",
        ]))
        .unwrap()
        .unwrap();
        assert_eq!(parsed.path, PathBuf::from("/tmp/中文 %f ' $HOME.exe"));
        assert_eq!(parsed.container, Some(PathBuf::from("/tmp/Prefix = %u")));
        assert!(parse(&[]).unwrap().is_none());
        assert!(parse(&args(&["/tmp/game.exe"])).unwrap().is_some());
    }
    #[test]
    fn incomplete_or_ambiguous_desktop_arguments_fail_before_startup() {
        for values in [
            vec!["--open-file"],
            vec!["--open-file", "relative.exe"],
            vec!["--container", "/tmp"],
            vec!["--open-file", "/tmp/game.exe", "--container", "relative"],
        ] {
            assert!(parse(&args(&values)).is_err());
        }
    }
    #[test]
    fn stable_container_ids_allow_safe_relative_program_paths() {
        let id = "4984B9E2-E62C-4B96-B120-B8B29D663840";
        let parsed = parse(&args(&[
            "--open-file",
            "drive_c/中文 %f.exe",
            "--container-id",
            id,
        ]))
        .unwrap()
        .unwrap();
        assert_eq!(parsed.container_id.as_deref(), Some(id));
        for path in ["../foreign.exe", "./game.exe"] {
            assert!(parse(&args(&["--open-file", path, "--container-id", id])).is_err());
        }
        assert!(
            parse(&args(&[
                "--open-file",
                "game.exe",
                "--container-id",
                "invalid"
            ]))
            .is_err()
        );
    }
}
