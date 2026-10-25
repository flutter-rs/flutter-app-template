# flutter-app-template

[![Join Gitter Chat Channel][gitter-badge]][gitter-url]

Example app built using [flutter-rs][flutter-rs].

It doubles as the embedder's live-verification harness: the UI drives the
platform channels in both directions, so the parts of flutter-rs that unit
tests cannot reach — the reply path and the shutdown path — can be watched in a
real app. See [Verifying the embedder](#verifying-the-embedder).

![flutter-app-template][flutter-app-template]

# Get Started

## Requirements

- [Rust](https://www.rust-lang.org/tools/install) 1.88 or newer
- the [Flutter SDK](https://flutter.dev) 3.44 or newer (Dart 3.10 or newer)
- `.engine/libflutter_engine.so`, matching your SDK's engine version. The
  comments at the top of `run.sh` have the download command; `MODE=aot` also
  needs a release engine in `.engine-release/` and an AOT snapshot.

## Run

```sh
./run.sh                     # JIT (debug) engine from .engine/
MODE=aot ./run.sh            # AOT (release) engine from .engine-release/
RUST_LOG=debug ./run.sh      # more host logging
./run.sh 2>&1 | tee run.log  # keep the log to read afterwards
```

`run.sh` builds the Dart asset bundle, builds the Rust host and opens the GLFW
window.

## Test

```sh
flutter test                 # the Dart half of the harness
FLUTTER_ENGINE_LIB_DIR=$PWD/.engine LD_LIBRARY_PATH=$PWD/.engine cargo test
```

# Verifying the embedder

The host (`src/main.rs`) registers three channels and the Dart app
(`lib/main.dart`) answers on two of them:

| channel | direction | carries |
| --- | --- | --- |
| `flutter-rs/verify` | Dart -> host | one method per case, invoked by a button |
| `flutter-rs/verify/host` | host -> Dart | the method calls whose replies the host checks |
| `flutter-rs/verify/messages` | host -> Dart | the basic message whose reply the host checks |

Every button asks the host to call *into* Dart; the line that appears in the log
area is the line the host answered with, i.e. what the host decoded from Dart's
reply. Lines are newest-first, tagged `dart` (what the UI did), `host` (what the
host did or answered) or `problem` (what should not have happened). The host logs
the same outcomes to stderr.

## The reply path

`MethodChannel::invoke_method_with_result` and `MessageChannel::send_with_result`
used to segfault, because the reply callback's user data was boxed and reclaimed
at two different types. These buttons run the whole
create -> send -> release -> Dart-replies -> decode sequence that cannot be
reached from a unit test.

| button | the UI must show | what it proves |
| --- | --- | --- |
| **reply now** | `host decoded Ok("echo of N")` | a reply is decoded and handed to the callback at all |
| **reply after 2 s** | nothing for two seconds, then `host decoded Ok("late echo of N after 2000 ms")` | releasing the response handle right after the send does not cut the reply off |
| **never reply** | `host decoded sent never#N; Dart will not reply, ...` at once, and nothing else for that call, ever | a reply that never comes does not crash the host, block it, or hold up the next case |
| **Dart throws** | `host decoded Err(code: dart-error, message: the Dart handler refused, details: String("fail"))` | the error envelope decodes, details included |
| **no Dart handler** | `host decoded Err(NotImplemented)` | the empty envelope the framework sends for an unhandled method decodes |
| **typed lists** | `host decoded Ok(Uint8List [1, 2, 255], Int32List [-1, 2], Int64List [9007199254740993, -7], Float32List [1.5, -2.5], Float64List [0.25, 1e300])` | the standard codec reads each typed list as itself, `Float32List` (new in 0.5.0) included, and `9007199254740993` proves no double is involved |
| **basic message** | `host decoded Ok(String("pong for N"))` | the same reply path over a `BasicMessageChannel` |

Press every button at least once, and press **never reply** before closing the
window: shutting the engine down with a reply still outstanding must not crash
and must not log anything of its own. (The callback behind that reply stays
alive inside the engine until shutdown — that is the embedder API's documented
"small memory leak" for a handle that is never answered, and the log cannot show
it either way.)

## Shutdown

`FlutterEngine::shutdown` is idempotent, every entry point after it is a logged
no-op, and dropping the last engine handle without a shutdown warns. Reaching
any of that needs the normal window-close path, which `SIGTERM` skips.

- **Close the window** invokes `close` on `flutter-rs/window`, which is exactly
  what clicking the window's X does: GLFW's `should_close` flag is set, the event
  loop returns, and the host shuts the engine down explicitly. Closing the window
  by its X or with this button must behave identically.
- **SystemNavigator.pop()** is the framework's own way out. It reaches the
  embedder as `SystemNavigator.pop` on `flutter/platform`. Today the embedder
  answers that call as not implemented and the window stays open — that is the
  known gap this button exists to show, not a failure of the harness.

However the window is closed, the host log must end with these two `INFO` lines
from `flutter_app_template`, in this order and with nothing after them:

```
the window closed; shutting the engine down
the engine is shut down; leaving main
```

## What the log must not contain

A clean run has **no `WARN` and no `ERROR` lines at all**. In particular:

- `the last FlutterEngine handle was dropped without calling shutdown()` — the
  explicit `shutdown()` after the event loop did not run, or ran on the wrong
  thread.
- `FlutterEngine::shutdown called more than once` — something shut the engine
  down twice; the second call is a no-op, but nothing in this app should make it.
- `FlutterWindow dropped off the platform thread` — the window outlived its
  thread.
- `a message response handle was dropped without sending a response!` — a
  response handle was lost instead of being answered, which leaks engine memory.
- `never#N came back as ...` — the Dart handler for the never-reply case replied
  after all, so that case was not testing what it claims to.
- any `panicked at` line. The FFI boundary catches panics instead of letting them
  unwind into the engine, so a panic appears in the log rather than aborting; it
  is still a bug.

# License
Copyright 2020 flutter-rs

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

[gitter-badge]: https://badges.gitter.im/flutter-rs/community.svg
[gitter-url]: https://gitter.im/flutter-rs/community
[flutter-rs]: https://github.com/flutter-rs/flutter-rs
[flutter-app-template]: https://user-images.githubusercontent.com/741807/72478608-a8b0e500-37f2-11ea-84ee-d7bd38a6370e.png
