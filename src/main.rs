use flutter_glfw::window::{WindowArgs, WindowMode};
use std::path::PathBuf;

fn main() {
    env_logger::init();

    // Directory produced by `flutter build bundle` (contains kernel_blob.bin,
    // the asset manifest, fonts, ...).
    let assets_dir = std::env::var("FLUTTER_ASSET_DIR").expect("FLUTTER_ASSET_DIR is not set");

    // Official engine builds ship `icudtl.dat` separately instead of linking it
    // into libflutter_engine, so the embedder has to be told where it lives.
    let icu_data = std::env::var("FLUTTER_ICU_DATA").expect("FLUTTER_ICU_DATA is not set");

    let mut args = Vec::new();
    if let Ok(snapshot) = std::env::var("FLUTTER_AOT_SNAPSHOT") {
        if std::path::Path::new(&snapshot).exists() {
            args.push(format!("--aot-shared-library-name={}", snapshot));
        }
    }

    let mut desktop = flutter_glfw::init().expect("failed to initialize glfw");

    let window_args = WindowArgs {
        width: 1280,
        height: 720,
        title: "Flutter App Demo",
        mode: WindowMode::Windowed,
    };

    let window = desktop
        .create_window_with_icu(
            &window_args,
            PathBuf::from(assets_dir),
            PathBuf::from(icu_data),
            args,
        )
        .expect("failed to create window");

    window.run(None, None).expect("engine run failed");
}
