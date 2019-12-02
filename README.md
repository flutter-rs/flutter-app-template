# flutter-app-template [![Join Gitter Chat Channel](https://badges.gitter.im/flutter-rs/community.svg)](https://gitter.im/flutter-rs/community?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)

Example app built using flutter-rs.
 <img src="https://raw.githubusercontent.com/gliheng/flutter-rs/master/www/images/logo.png" width="50" height="50" align="center" />

![screenshot](https://raw.githubusercontent.com/gliheng/flutter-rs/master/www/images/screenshot_mac.png)

# Get Started

## Install requirements

- [Rust](https://www.rust-lang.org/tools/install)

- [flutter sdk](https://flutter.io)

## Config flutter engine version
`flutter-rs` needs to know your flutter engine version.

You can set this using any of the following methods.
- If you have flutter cli in your PATH, you're set.
- Set FLUTTER_ROOT environment variable to your flutter sdk path
- Set FLUTTER_ENGINE_VERSION environment variable to your engine version

## Develop
- To create a new project

    `git clone https://github.com/flutter-rs/flutter-app-template`

- To develop with cli hot-reloading:

    `cargo flutter run`

## Distribute
- To build distribution, use:
    `cargo flutter --format appimage build --release`
