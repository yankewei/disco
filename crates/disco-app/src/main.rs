//! Native Disco application composition root.

mod assets;

use assets::DiscoAssets;
use directories::ProjectDirs;
use disco_storage::SqliteJournal;
use disco_ui::DiscoWorkspace;
use gpui::{App, AppContext, Application, Bounds, WindowBounds, WindowOptions, px, size};
use std::fs;
use tracing_subscriber::EnvFilter;

fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .with_target(false)
        .compact()
        .init();

    let project_dirs = ProjectDirs::from("dev", "Disco", "disco")
        .expect("the operating system should expose an application data directory");
    fs::create_dir_all(project_dirs.data_dir())
        .expect("the Disco application data directory should be writable");
    let journal = SqliteJournal::open(project_dirs.data_dir().join("runs.sqlite3"))
        .expect("the run journal should open");
    let workspace = DiscoWorkspace::new(journal).expect("the initial run projection should build");

    Application::new()
        .with_assets(DiscoAssets::discover())
        .run(move |cx: &mut App| {
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
                |_, cx| cx.new(|_| workspace),
            )
            .expect("the main Disco window should open");
            cx.activate(true);
        });
}
