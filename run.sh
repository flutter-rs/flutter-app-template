#!/usr/bin/env bash
# Build and run the flutter-app-template against the modernized flutter-rs
# (flutter-glfw embedder) and a fresh Flutter SDK.
set -euo pipefail

cd "$(dirname "$0")"

# 1. The official Flutter engine embedder library. It must match the engine
#    version of your Flutter SDK (bin/internal/engine.version). Download once:
#
#    EV=$(cat "$(dirname "$(dirname "$(readlink -f "$(which flutter)")")")"/bin/internal/engine.version)
#    mkdir -p .engine && cd .engine
#    curl -fSL -o emb.zip \
#      "https://storage.googleapis.com/flutter_infra_release/flutter/$EV/linux-x64/linux-x64-embedder.zip"
#    unzip -o emb.zip libflutter_engine.so && cd ..
ENGINE_DIR="$PWD/.engine"
if [[ ! -f "$ENGINE_DIR/libflutter_engine.so" ]]; then
  echo "Missing $ENGINE_DIR/libflutter_engine.so — see the comment in this script." >&2
  exit 1
fi

# 2. icudtl.dat ships separately in the SDK's host engine cache.
FLUTTER_ROOT="$(dirname "$(dirname "$(readlink -f "$(which flutter)")")")"
ICU_DATA="$(find "$FLUTTER_ROOT/bin/cache/artifacts/engine" -name icudtl.dat | head -1)"

# 3. Compile the Dart code into an asset bundle (kernel_blob.bin + assets).
flutter build bundle

# 4. Build and launch the Rust host. The engine library is needed both at link
#    time (-L) and at run time (LD_LIBRARY_PATH).
RUSTFLAGS="-L $ENGINE_DIR" cargo build

# 5. JIT (debug) by default. For AOT (release) set MODE=aot, which requires:
#      - a RELEASE-mode libflutter_engine.so in .engine-release/ (the public
#        embedder zip is JIT-only; build one with:
#        engine/src && flutter/tools/gn --runtime-mode=release --no-rbe --no-lto \
#          --prebuilt-dart-sdk && ninja -C out/host_release flutter_engine_library)
#      - an AOT snapshot: flutter assemble -o build/aot -dTargetPlatform=linux-x64 \
#          -dBuildMode=release -dTargetFile=$PWD/lib/main.dart aot_elf_release
#        then copy the produced app.so to build/app.so
#      - an asset bundle WITHOUT kernel_blob.bin
if [[ "${MODE:-jit}" == "aot" ]]; then
  ENGINE_DIR="$PWD/.engine-release"
  rm -rf build/aot_assets && cp -r build/flutter_assets build/aot_assets
  rm -f build/aot_assets/kernel_blob.bin
  RUST_LOG="${RUST_LOG:-info}" \
  LD_LIBRARY_PATH="$ENGINE_DIR" \
  FLUTTER_ASSET_DIR="$PWD/build/aot_assets" \
  FLUTTER_ICU_DATA="$ICU_DATA" \
  FLUTTER_AOT_SNAPSHOT="$PWD/build/app.so" \
    ./target/debug/flutter-app-template
else
  RUST_LOG="${RUST_LOG:-info}" \
  LD_LIBRARY_PATH="$ENGINE_DIR" \
  FLUTTER_ASSET_DIR="$PWD/build/flutter_assets" \
  FLUTTER_ICU_DATA="$ICU_DATA" \
    ./target/debug/flutter-app-template
fi
