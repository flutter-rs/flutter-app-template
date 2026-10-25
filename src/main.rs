//! Host side of `flutter-app-template`.
//!
//! Besides opening a GLFW window and starting the engine in it, this binary
//! registers the verification harness the embedder's reply path is checked
//! with: three channels that let the Dart UI ask the host to call *into* Dart
//! and then show exactly what the host decoded. See the "Verifying the
//! embedder" section of `README.md` for what a reviewer should see.
//!
//! Everything in the harness runs on the platform thread: the trigger handler
//! is called from the engine's message dispatch, and the reply callbacks are
//! delivered there too, which is the only thread the embedder API accepts
//! messages from.

use flutter_engine::{
    channel::{
        Message, MessageChannel, MessageHandler, MethodCall, MethodCallHandler, MethodChannel,
        MethodError,
    },
    codec::{STANDARD_CODEC, Value},
};
use flutter_glfw::window::{WindowArgs, WindowMode};
use log::{error, info};
use serde::{Deserialize, de::DeserializeOwned};
use std::{
    fmt::Debug,
    path::{Path, PathBuf},
    sync::Weak,
};

/// Dart -> host: one method per verification case, invoked by a button.
const TRIGGER_CHANNEL: &str = "flutter-rs/verify";

/// Host -> Dart: the calls whose replies this harness checks.
const HOST_CHANNEL: &str = "flutter-rs/verify/host";

/// Host -> Dart: the basic messages whose replies this harness checks.
const MESSAGE_CHANNEL: &str = "flutter-rs/verify/messages";

fn main() {
    env_logger::init();

    // A packaged build keeps its resources next to the executable, so that is
    // what both paths default to; the environment variables stay as overrides
    // for running straight out of the build tree.
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| PathBuf::from("."));

    // Directory produced by `flutter build bundle` (contains kernel_blob.bin,
    // the asset manifest, fonts, ...).
    let assets_dir = path_from_env("FLUTTER_ASSET_DIR", exe_dir.join("flutter_assets"));

    // Official engine builds ship `icudtl.dat` separately instead of linking it
    // into libflutter_engine, so the embedder has to be told where it lives.
    let icu_data = path_from_env("FLUTTER_ICU_DATA", exe_dir.join("icudtl.dat"));

    for (what, path) in [("asset directory", &assets_dir), ("icu data", &icu_data)] {
        assert!(path.exists(), "{what} `{}` does not exist", path.display());
    }

    let mut args = Vec::new();
    if let Ok(snapshot) = std::env::var("FLUTTER_AOT_SNAPSHOT")
        && std::path::Path::new(&snapshot).exists()
    {
        args.push(format!("--aot-shared-library-name={snapshot}"));
    }

    let mut desktop = flutter_glfw::init().expect("failed to initialize glfw");

    let window_args = WindowArgs {
        width: 1280,
        height: 720,
        title: "Flutter App Demo",
        mode: WindowMode::Windowed,
    };

    let window = desktop
        .create_window_with_icu(&window_args, assets_dir, icu_data, args)
        .expect("failed to create window");

    // The two host -> Dart channels are registered first, so the trigger
    // channel's handler can be handed the handles it drives them through. The
    // engine owns all three; these are weak handles.
    let host = window.register_channel(MethodChannel::new(
        HOST_CHANNEL,
        Unexpected(HOST_CHANNEL),
        &STANDARD_CODEC,
    ));
    let messages = window.register_channel(MessageChannel::new(
        MESSAGE_CHANNEL,
        Unexpected(MESSAGE_CHANNEL),
        &STANDARD_CODEC,
    ));
    window.register_channel(MethodChannel::new(
        TRIGGER_CHANNEL,
        Harness {
            host,
            messages,
            calls: 0,
        },
        &STANDARD_CODEC,
    ));

    window.run(None, None).expect("engine run failed");

    // The window-close path, which is the one `shutdown()` exists for: the
    // event loop has returned, so the engine is still live and this thread is
    // still its platform thread. Dropping the window would shut the engine
    // down too, but only this form can log that it happened.
    info!("the window closed; shutting the engine down");
    window.shutdown();
    info!("the engine is shut down; leaving main");
}

/// The host half of the verification harness.
///
/// Every case answers the Dart trigger with one line of text, which is what
/// the UI shows. The cases that wait for Dart answer the trigger *from inside*
/// the reply callback, so a line only appears once the full
/// send -> release -> Dart-replies -> decode sequence has run.
struct Harness {
    host: Weak<MethodChannel>,
    messages: Weak<MessageChannel>,
    /// Counts the calls made into Dart, so a reply can be matched to its call
    /// in the log.
    calls: i64,
}

impl Harness {
    /// Call `method` on the Dart side of [`HOST_CHANNEL`], then answer
    /// `trigger` with a line describing the reply the host decoded as `V`.
    fn relay<V>(&self, trigger: MethodCall, method: &str, nonce: i64)
    where
        V: DeserializeOwned + Debug + Send + 'static,
    {
        let Some(host) = self.host.upgrade() else {
            return trigger.error(
                "no-channel",
                format!("{HOST_CHANNEL} is no longer registered"),
                Value::Null,
            );
        };
        let label = format!("{method}#{nonce}");

        host.invoke_method_with_result(
            method.to_owned(),
            Value::I64(nonce),
            move |result: Result<V, MethodError<Value>>| {
                let line = describe(&result);
                info!("{label} came back as {line}");
                trigger.success(line);
            },
        );
    }

    /// Send a call Dart deliberately never answers.
    ///
    /// Two things must not happen: the reply callback must not run, and
    /// releasing the response handle right after the send — which is what the
    /// embedder API asks for — must not take the reply path or the process
    /// down with it. So the trigger is answered immediately, before Dart has
    /// had a chance to not reply.
    fn no_reply(&self, trigger: MethodCall, nonce: i64) {
        let Some(host) = self.host.upgrade() else {
            return trigger.error(
                "no-channel",
                format!("{HOST_CHANNEL} is no longer registered"),
                Value::Null,
            );
        };

        host.invoke_method_with_result(
            "never".to_owned(),
            Value::I64(nonce),
            move |result: Result<Value, MethodError<Value>>| {
                // Reaching this means the Dart handler replied after all, so
                // the case is not testing what it claims to.
                error!(
                    "never#{nonce} came back as {}, but the Dart handler must never reply",
                    describe(&result)
                );
            },
        );

        trigger.success(format!(
            "sent never#{nonce}; Dart will not reply, so nothing more should appear for it"
        ));
    }

    /// Round-trip a basic message, the [`MessageChannel::send_with_result`]
    /// half of the reply path.
    fn message(&self, trigger: MethodCall, nonce: i64) {
        let Some(messages) = self.messages.upgrade() else {
            return trigger.error(
                "no-channel",
                format!("{MESSAGE_CHANNEL} is no longer registered"),
                Value::Null,
            );
        };

        messages.send_with_result(Value::I64(nonce), move |value: Value| {
            let line = format!("Ok({value:?})");
            info!("message#{nonce} came back as {line}");
            trigger.success(line);
        });
    }
}

impl MethodCallHandler for Harness {
    fn on_method_call(&mut self, call: MethodCall) {
        self.calls += 1;
        let nonce = self.calls;
        info!("verification case {} requested as #{nonce}", call.method());

        match call.method() {
            // Dart replies at once: the ordinary path.
            "replyNow" => self.relay::<String>(call, "echo", nonce),
            // Dart replies seconds later, long after the send released the
            // response handle it created.
            "replyLate" => self.relay::<String>(call, "echoLate", nonce),
            // Dart replies with typed lists, `Float32List` among them.
            "typedLists" => self.relay::<TypedLists>(call, "typedLists", nonce),
            // Dart throws a `PlatformException`: the error envelope.
            "dartError" => self.relay::<Value>(call, "fail", nonce),
            // Dart has no handler for the method, which the framework answers
            // with the empty envelope that decodes as `NotImplemented`.
            "notImplemented" => self.relay::<Value>(call, "unhandled", nonce),
            "noReply" => self.no_reply(call, nonce),
            "message" => self.message(call, nonce),
            _ => call.not_implemented(),
        }
    }
}

/// The host side of a host -> Dart channel, which Dart never calls: anything
/// arriving here is a bug in the harness, not in the embedder.
struct Unexpected(&'static str);

impl MethodCallHandler for Unexpected {
    fn on_method_call(&mut self, call: MethodCall) {
        error!(
            "unexpected inbound call {} on {}, which only carries host -> Dart calls",
            call.method(),
            self.0
        );
        call.not_implemented();
    }
}

impl MessageHandler for Unexpected {
    fn on_message(&mut self, msg: Message) {
        error!(
            "unexpected inbound message {:?} on {}, which only carries host -> Dart messages",
            msg.raw_value(),
            self.0
        );
        // Answer anyway: an unanswered response handle leaks engine memory.
        if msg.can_respond() {
            msg.respond(Value::Null);
        }
    }
}

/// The typed lists the `typedLists` case asks Dart for.
///
/// Decoding into concrete vectors rather than a [`Value`] is deliberate: a
/// `Value` reply comes back through serde as a plain list of doubles, so it
/// could not show that the standard codec read the right element type. The
/// field names are the keys the Dart handler returns.
#[derive(Deserialize)]
struct TypedLists {
    bytes: Vec<u8>,
    int32s: Vec<i32>,
    int64s: Vec<i64>,
    float32s: Vec<f32>,
    float64s: Vec<f64>,
}

/// Written out by hand rather than derived, so the one line the UI shows names
/// the Dart type each list arrived as.
impl Debug for TypedLists {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Uint8List {:?}, Int32List {:?}, Int64List {:?}, Float32List {:?}, Float64List {:?}",
            self.bytes, self.int32s, self.int64s, self.float32s, self.float64s
        )
    }
}

/// The path `var` points at, or `fallback` when it is unset.
fn path_from_env(var: &str, fallback: PathBuf) -> PathBuf {
    std::env::var_os(var).map_or(fallback, PathBuf::from)
}

/// Render what a reply callback decoded as the single line the Dart UI shows.
fn describe<V>(result: &Result<V, MethodError<Value>>) -> String
where
    V: Debug,
{
    match result {
        Ok(value) => format!("Ok({value:?})"),
        Err(MethodError::Err {
            code,
            message,
            details,
        }) => format!("Err(code: {code}, message: {message}, details: {details:?})"),
        Err(MethodError::NotImplemented) => "Err(NotImplemented)".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use flutter_engine::codec::value::from_value_owned;
    use std::collections::HashMap;

    /// Every case that waits for Dart hands the trigger's [`MethodCall`] to a
    /// reply callback, which the embedder requires to be `Send`. That the call
    /// can cross that bound is the property the whole harness rests on, so it
    /// is asserted rather than assumed.
    #[test]
    fn a_method_call_can_be_carried_into_a_reply_callback() {
        fn assert_send<T: Send>() {}

        assert_send::<MethodCall>();
    }

    #[test]
    fn an_ok_reply_is_described_with_the_decoded_value() {
        let result: Result<String, MethodError<Value>> = Ok("echo of 1".to_owned());

        assert_eq!(describe(&result), r#"Ok("echo of 1")"#);
    }

    #[test]
    fn an_error_envelope_is_described_with_its_code_and_message() {
        let result: Result<Value, MethodError<Value>> = Err(MethodError::Err {
            code: "dart-error".to_owned(),
            message: "the Dart handler refused".to_owned(),
            details: Value::String("fail".to_owned()),
        });

        assert_eq!(
            describe(&result),
            r#"Err(code: dart-error, message: the Dart handler refused, details: String("fail"))"#
        );
    }

    #[test]
    fn an_empty_envelope_is_described_as_not_implemented() {
        let result: Result<Value, MethodError<Value>> = Err(MethodError::NotImplemented);

        assert_eq!(describe(&result), "Err(NotImplemented)");
    }

    /// The `typedLists` case is only worth anything if the reply decodes
    /// element by element, so this pins [`TypedLists`] against exactly the
    /// [`Value`] the standard codec produces for the Dart map in
    /// `lib/main.dart`.
    #[test]
    fn the_typed_lists_reply_decodes_element_by_element() {
        let value = Value::Map(HashMap::from([
            ("bytes".to_owned(), Value::U8List(vec![1, 2, 255])),
            ("int32s".to_owned(), Value::I32List(vec![-1, 2])),
            // 2^53 + 1: not representable as an f64, so a reply that still
            // holds it cannot have gone through a double on the way.
            (
                "int64s".to_owned(),
                Value::I64List(vec![9_007_199_254_740_993, -7]),
            ),
            ("float32s".to_owned(), Value::F32List(vec![1.5, -2.5])),
            ("float64s".to_owned(), Value::F64List(vec![0.25, 1.0e300])),
        ]));

        let decoded: TypedLists = from_value_owned(&value).expect("the harness reply decodes");

        assert_eq!(decoded.bytes, [1, 2, 255]);
        assert_eq!(decoded.int32s, [-1, 2]);
        assert_eq!(decoded.int64s, [9_007_199_254_740_993, -7]);
        assert_eq!(decoded.float32s, [1.5, -2.5]);
        assert_eq!(decoded.float64s, [0.25, 1.0e300]);
    }
}
