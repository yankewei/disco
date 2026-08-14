//! Native Disco application composition root.

mod assets;

use assets::DiscoAssets;
use directories::ProjectDirs;
use disco_codex_engine::CodexRuntime;
use disco_opencode_engine::discover_opencode;
use disco_storage::SqliteJournal;
use disco_ui::{ComposerInput, DiscoWorkspace, init_composer_input};
use gpui::{App, AppContext, Application, Bounds, WindowBounds, WindowOptions, px, size};
use std::fs;
use std::path::{Path, PathBuf};
use tracing_subscriber::EnvFilter;

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .with_target(false)
        .compact()
        .init();

    let project_dirs = ProjectDirs::from("com", "yankewei", "disco")
        .expect("the operating system should expose an application data directory");
    fs::create_dir_all(project_dirs.data_dir())
        .expect("the Disco application data directory should be writable");
    let journal = SqliteJournal::open(project_dirs.data_dir().join("runs.sqlite3"))
        .expect("the run journal should open");
    let config_path = project_dirs.data_dir().join("config.toml");
    let workspace_path = resolve_workspace_path();
    let codex_connection = CodexRuntime::connect(&workspace_path)
        .and_then(|runtime| runtime.list_models().map(|models| (runtime, models)))
        .map_err(|error| error.to_string());
    let opencode_version = discover_opencode()
        .ok()
        .map(|installation| installation.version);
    Application::new()
        .with_assets(DiscoAssets::discover())
        .run(move |cx: &mut App| {
            init_composer_input(cx);
            let bounds = Bounds::centered(None, size(px(1_280.), px(800.)), cx);
            cx.open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(bounds)),
                    titlebar: Some(gpui::TitlebarOptions {
                        title: Some("Disco".into()),
                        appears_transparent: true,
                        traffic_light_position: Some(gpui::point(px(14.), px(14.))),
                    }),
                    ..Default::default()
                },
                |window, cx| {
                    let composer = cx.new(ComposerInput::new);
                    cx.new(|cx| {
                        cx.observe_window_appearance(window, |_, window, cx| {
                            window.refresh();
                            cx.notify();
                        })
                        .detach();
                        DiscoWorkspace::new(
                            journal,
                            composer,
                            config_path,
                            workspace_path,
                            codex_connection,
                            opencode_version,
                            cx,
                        )
                    })
                },
            )
            .expect("the main Disco window should open");
            cx.activate(true);
        });
}

fn resolve_workspace_path() -> PathBuf {
    if let Some(configured) = std::env::var_os("DISCO_WORKSPACE")
        .map(PathBuf::from)
        .filter(|path| path.is_dir())
    {
        return configured.canonicalize().unwrap_or(configured);
    }

    let current = std::env::current_dir().expect("the current directory should be available");
    if let Some(project_root) = current.ancestors().find(|path| is_project_root(path)) {
        return project_root.to_owned();
    }

    let development_root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    if development_root.is_dir() {
        return development_root.canonicalize().unwrap_or(development_root);
    }

    current
}

fn is_project_root(path: &Path) -> bool {
    [".git", "Cargo.toml", "package.json", "pyproject.toml"]
        .iter()
        .any(|marker| path.join(marker).exists())
}
