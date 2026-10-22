//! Startup file handoff retained until the bridge supplies its first catalogue.
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ExternalOpen {
    pub(crate) path: PathBuf,
    pub(crate) container: Option<PathBuf>,
}

pub(crate) fn parse(arguments: &[String]) -> Result<Option<ExternalOpen>, &'static str> {
    if arguments.is_empty() {
        return Ok(None);
    }
    let (path, container) = match arguments {
        [path] if !path.starts_with('-') => (path, None),
        [flag, path] if flag == "--open-file" => (path, None),
        [flag, path, container_flag, container]
            if flag == "--open-file" && container_flag == "--container" =>
        {
            (path, Some(container))
        }
        _ => return Err("usage: whisky-gpui [<file> | --open-file <file> [--container <path>]]"),
    };
    if !std::path::Path::new(path).is_absolute()
        || container.is_some_and(|value| !std::path::Path::new(value).is_absolute())
    {
        return Err("Desktop file and container paths must be absolute");
    }
    Ok(Some(ExternalOpen {
        path: PathBuf::from(path),
        container: container.map(PathBuf::from),
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
}
