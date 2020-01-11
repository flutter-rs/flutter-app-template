use flutter_winit::FlutterWindow;
use glutin::window::WindowBuilder;
use std::path::Path;

fn main() {
    env_logger::init();

    let assets_dir = std::env::var("FLUTTER_ASSET_DIR").expect("FLUTTER_ASSET_DIR");

    let mut args = Vec::with_capacity(1);

    if let Ok(snapshot) = std::env::var("FLUTTER_AOT_SNAPSHOT") {
        if Path::new(&snapshot).exists() {
            args.push(format!("--aot-shared-library-name={}", snapshot));
        }
    }

    let window = WindowBuilder::new().with_title("Flutter App Demo");
    let flutter = FlutterWindow::new(window).unwrap();
    let flutter = flutter.with_resource_context().unwrap();

    flutter.start_engine(Path::new(&assets_dir), &args).unwrap();

    flutter.run();
}
