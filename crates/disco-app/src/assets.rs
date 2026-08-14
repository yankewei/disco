use gpui::{AssetSource, Result, SharedString};
use std::{
    borrow::Cow,
    fs,
    io::ErrorKind,
    path::{Path, PathBuf},
};

/// 为开发运行和 macOS App Bundle 提供同一套 GPUI 资源路径。
pub(crate) struct DiscoAssets {
    root: PathBuf,
}

impl DiscoAssets {
    pub(crate) fn discover() -> Self {
        let bundle_resources = std::env::current_exe().ok().and_then(|executable| {
            let contents = executable.parent()?.parent()?;
            (contents.file_name()? == "Contents")
                .then(|| contents.join("Resources"))
                .filter(|resources| resources.is_dir())
        });

        Self {
            root: bundle_resources
                .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("../../assets")),
        }
    }
}

impl AssetSource for DiscoAssets {
    fn load(&self, path: &str) -> Result<Option<Cow<'static, [u8]>>> {
        match fs::read(self.root.join(path)) {
            Ok(data) => Ok(Some(Cow::Owned(data))),
            Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    fn list(&self, path: &str) -> Result<Vec<SharedString>> {
        let mut entries = match fs::read_dir(self.root.join(path)) {
            Ok(entries) => entries
                .filter_map(|entry| entry.ok())
                .filter_map(|entry| entry.file_name().into_string().ok())
                .map(SharedString::from)
                .collect::<Vec<_>>(),
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => return Err(error.into()),
        };
        entries.sort_unstable();
        Ok(entries)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_repository_assets_by_logical_path() {
        let assets = DiscoAssets::discover();

        assert!(
            assets
                .load("images/app-logo.png")
                .expect("the app logo should be readable")
                .is_some()
        );
        assert_eq!(
            assets
                .list("icons/providers")
                .expect("the provider icon directory should be readable"),
            ["codex.png", "deepseek.svg", "kimi-code.png", "opencode.svg"]
                .map(SharedString::from)
                .to_vec()
        );
        assert!(
            assets
                .load("icons/ui/chevron-down.svg")
                .expect("the chevron icon should be readable")
                .is_some()
        );
        assert!(
            assets
                .load("icons/ui/chevron-up.svg")
                .expect("the upward chevron icon should be readable")
                .is_some()
        );
        assert!(
            assets
                .load("icons/ui/settings.svg")
                .expect("the settings icon should be readable")
                .is_some()
        );
        assert!(
            assets
                .load("icons/ui/back.svg")
                .expect("the back icon should be readable")
                .is_some()
        );
        assert!(
            assets
                .load("icons/ui/providers.svg")
                .expect("the providers icon should be readable")
                .is_some()
        );
        assert!(
            assets
                .load("icons/ui/send.svg")
                .expect("the send icon should be readable")
                .is_some()
        );
        assert!(
            assets
                .load("icons/ui/stop.svg")
                .expect("the stop icon should be readable")
                .is_some()
        );
        assert!(
            assets
                .load("icons/ui/folder.svg")
                .expect("the folder icon should be readable")
                .is_some()
        );
        assert!(
            assets
                .load("icons/ui/chevron-right.svg")
                .expect("the right chevron icon should be readable")
                .is_some()
        );
    }
}
