import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Dart -> host: one method per verification case, served by `src/main.rs`.
const triggerChannel = MethodChannel('flutter-rs/verify');

/// Host -> Dart: the calls whose replies the host checks.
const hostChannel = MethodChannel('flutter-rs/verify/host');

/// Host -> Dart: the basic messages whose replies the host checks.
const hostMessageChannel = BasicMessageChannel<Object?>(
  'flutter-rs/verify/messages',
  StandardMessageCodec(),
);

/// The embedder's own window channel, served by flutter-rs' `WindowPlugin`.
const windowChannel = MethodChannel('flutter-rs/window', JSONMethodCodec());

/// How long the `echoLate` case makes the host wait for its reply — long
/// enough that the response handle the send created is released first.
const lateReplyDelay = Duration(seconds: 2);

/// Set `FLUTTER_RS_SELFTEST=1` to run every case once at startup and close
/// the window afterwards, so the whole reply path can be checked from the host
/// log on a machine where nothing can click a button.
bool get runSelfTest => Platform.environment.containsKey('FLUTTER_RS_SELFTEST');

/// The cases the UI offers, in the order the buttons show them.
const verificationCases = <VerificationCase>[
  VerificationCase(
    trigger: 'replyNow',
    label: 'reply now',
    expectation: 'the host calls echo() and shows the Ok(...) it decoded',
  ),
  VerificationCase(
    trigger: 'replyLate',
    label: 'reply after 2 s',
    expectation:
        'Dart replies two seconds after the host released the response '
        'handle; the reply must still arrive',
  ),
  VerificationCase(
    trigger: 'noReply',
    label: 'never reply',
    expectation:
        'the host answers at once and nothing more may ever appear for '
        'that call',
  ),
  VerificationCase(
    trigger: 'dartError',
    label: 'Dart throws',
    expectation:
        'the host decodes Err(code: dart-error, ...) from the error envelope',
  ),
  VerificationCase(
    trigger: 'notImplemented',
    label: 'no Dart handler',
    expectation: 'the host decodes Err(NotImplemented) from the empty envelope',
  ),
  VerificationCase(
    trigger: 'typedLists',
    label: 'typed lists',
    expectation:
        'Uint8List, Int32List, Int64List, Float32List and Float64List '
        'decode element by element',
  ),
  VerificationCase(
    trigger: 'message',
    label: 'basic message',
    expectation: 'the same reply path over a BasicMessageChannel',
  ),
];

void main() {
  runApp(const VerificationApp());
}

/// Answers the host's calls on [hostChannel].
///
/// This is the whole Dart half of the reply-path check. It is a plain function
/// rather than a method so `test/main_test.dart` can drive every case without
/// an engine.
Future<Object?> handleHostCall(MethodCall call) async {
  switch (call.method) {
    case 'echo':
      return 'echo of ${call.arguments}';

    case 'echoLate':
      await Future<void>.delayed(lateReplyDelay);

      return 'late echo of ${call.arguments} after '
          '${lateReplyDelay.inMilliseconds} ms';

    case 'never':
      // Never completes: the host has to survive a reply that never comes.
      return Completer<Object?>().future;

    case 'typedLists':
      // The keys and element types the host's `TypedLists` struct decodes.
      return <String, Object?>{
        'bytes': Uint8List.fromList(<int>[1, 2, 255]),
        'int32s': Int32List.fromList(<int>[-1, 2]),
        // 2^53 + 1 is not representable as a double, so a value that survives
        // the round trip cannot have gone through one on the way.
        'int64s': Int64List.fromList(<int>[9007199254740993, -7]),
        'float32s': Float32List.fromList(<double>[1.5, -2.5]),
        'float64s': Float64List.fromList(<double>[0.25, 1e300]),
      };

    case 'fail':
      throw PlatformException(
        code: 'dart-error',
        message: 'the Dart handler refused',
        details: 'fail',
      );

    default:
      // The framework turns this into the empty reply envelope that the host
      // decodes as `MethodError::NotImplemented`.
      throw MissingPluginException('no Dart handler for ${call.method}');
  }
}

/// One verification case: a button, and the host method it triggers.
class VerificationCase {
  const VerificationCase({
    required this.trigger,
    required this.label,
    required this.expectation,
  });

  /// The method the UI invokes on [triggerChannel].
  final String trigger;

  /// The button's text.
  final String label;

  /// What the log should show afterwards; also the button's tooltip.
  final String expectation;
}

/// Who produced a log line.
enum Source {
  /// Something the Dart side did.
  dart,

  /// Something the host side did, or the answer it gave.
  host,

  /// Something that should not have happened.
  problem,
}

class VerificationApp extends StatelessWidget {
  const VerificationApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter-rs verification',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const VerificationPage(),
    );
  }
}

class VerificationPage extends StatefulWidget {
  const VerificationPage({super.key});

  @override
  State<VerificationPage> createState() => _VerificationPageState();
}

class _VerificationPageState extends State<VerificationPage> {
  final List<_Line> _log = <_Line>[];
  final Set<String> _running = <String>{};

  @override
  void initState() {
    super.initState();

    hostChannel.setMethodCallHandler(_onHostCall);
    hostMessageChannel.setMessageHandler(_onHostMessage);

    if (runSelfTest) {
      // After the first frame: the host's channels are served from the
      // platform thread, and starting before the engine has drawn would race
      // the window metrics it is still sending.
      WidgetsBinding.instance.addPostFrameCallback((_) => _selfTest());
    }
  }

  @override
  void dispose() {
    hostChannel.setMethodCallHandler(null);
    hostMessageChannel.setMessageHandler(null);

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('flutter-rs embedder verification'),
        actions: <Widget>[
          IconButton(
            key: const ValueKey('clear-log'),
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear the log',
            onPressed: () => setState(_log.clear),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: .stretch,
        children: <Widget>[
          _Controls(
            running: _running,
            onRun: _run,
            onClose: _closeWindow,
            onPop: _pop,
          ),
          const Divider(height: 1),
          Expanded(child: _LogView(lines: _log)),
        ],
      ),
    );
  }

  Future<Object?> _onHostCall(MethodCall call) {
    _append(.host, 'called ${call.method}(${call.arguments})');

    return handleHostCall(call);
  }

  Future<Object?> _onHostMessage(Object? message) async {
    _append(.host, 'sent the message $message');

    return 'pong for $message';
  }

  /// Ask the host to run one case and show the line it answers with.
  Future<void> _run(VerificationCase verification) async {
    _append(.dart, 'invoking ${triggerChannel.name}.${verification.trigger}()');

    setState(() => _running.add(verification.trigger));

    try {
      final reply = await triggerChannel.invokeMethod<String>(
        verification.trigger,
      );

      _append(.host, 'decoded $reply');
    } on PlatformException catch (error) {
      _append(
        .problem,
        'the host answered with ${error.code}: ${error.message}',
      );
    } on MissingPluginException {
      _append(
        .problem,
        'the host has no handler for ${verification.trigger}: is the '
        'harness registered?',
      );
    } finally {
      if (mounted) {
        setState(() => _running.remove(verification.trigger));
      }
    }
  }

  /// Run every case in order, then leave through `SystemNavigator.pop()`.
  ///
  /// Each `_run` awaits the host's answer, so the cases do not overlap and the
  /// log reads in order. The wait at the end is what gives `never` a chance to
  /// break its promise: if its reply callback ever runs, the host logs an
  /// error, and that has to happen while the engine is still up.
  Future<void> _selfTest() async {
    _append(.dart, 'self-test: ${verificationCases.length} cases');

    for (final verification in verificationCases) {
      await _run(verification);
    }

    await Future<void>.delayed(lateReplyDelay * 2);
    _append(.dart, 'self-test: done, closing the window');

    await _pop();
  }

  /// Close the window the way clicking its X does, which is the path
  /// `FlutterWindow::shutdown` is meant to run on.
  Future<void> _closeWindow() async {
    _append(
      .dart,
      'invoking ${windowChannel.name}.close(): the window should close and '
      'the host should log a clean shutdown',
    );

    await windowChannel.invokeMethod<void>('close');
  }

  /// The framework's own way out, for comparison: it reaches the embedder as
  /// `SystemNavigator.pop` on `flutter/platform`.
  Future<void> _pop() async {
    _append(.dart, 'SystemNavigator.pop()');

    await SystemNavigator.pop();

    _append(
      .dart,
      'SystemNavigator.pop() returned; the embedder raises the window close '
      'flag, so the host should log a clean shutdown next',
    );
  }

  void _append(Source source, String text) {
    if (!mounted) return;

    setState(() => _log.insert(0, _Line(source: source, text: text)));
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.running,
    required this.onRun,
    required this.onClose,
    required this.onPop,
  });

  final Set<String> running;
  final ValueChanged<VerificationCase> onRun;
  final VoidCallback onClose;
  final VoidCallback onPop;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: .start,
        children: <Widget>[
          const Text(
            'The reply path: the host calls into Dart and shows what it decoded.',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: verificationCases
                .map(
                  (verification) => _CaseButton(
                    verification: verification,
                    isRunning: running.contains(verification.trigger),
                    onRun: onRun,
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 16),
          const Text('Shutdown: close the window, then read the host log.'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                key: const ValueKey('close-window'),
                onPressed: onClose,
                icon: const Icon(Icons.close),
                label: const Text('Close the window'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('system-navigator-pop'),
                onPressed: onPop,
                icon: const Icon(Icons.exit_to_app),
                label: const Text('SystemNavigator.pop()'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CaseButton extends StatelessWidget {
  const _CaseButton({
    required this.verification,
    required this.isRunning,
    required this.onRun,
  });

  final VerificationCase verification;
  final bool isRunning;
  final ValueChanged<VerificationCase> onRun;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: verification.expectation,
      child: FilledButton.tonal(
        key: ValueKey('case-${verification.trigger}'),
        onPressed: isRunning ? null : () => onRun(verification),
        child: Row(
          mainAxisSize: .min,
          children: <Widget>[
            Text(verification.label),
            const SizedBox(width: 8),
            SizedBox(
              width: 14,
              height: 14,
              child: isRunning
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _LogView extends StatelessWidget {
  const _LogView({required this.lines});

  final List<_Line> lines;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return const Center(
        child: Text('Press a button; the newest line appears at the top.'),
      );
    }

    return ListView.builder(
      key: const ValueKey('log'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: lines.length,
      itemBuilder: (context, index) => _LogLine(line: lines[index]),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({required this.line});

  final _Line line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final color = switch (line.source) {
      .dart => theme.colorScheme.primary,
      .host => theme.colorScheme.tertiary,
      .problem => theme.colorScheme.error,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        '${line.stamp}  ${line.source.name.padRight(7)}  ${line.text}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: color,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

/// One line of the on-screen log.
class _Line {
  _Line({required this.source, required this.text}) : at = DateTime.now();

  final Source source;
  final String text;
  final DateTime at;

  /// `hh:mm:ss.mmm`, to line the log up with the host's own timestamps.
  String get stamp {
    final time = at.toIso8601String().split('T').last;

    return time.substring(0, 12);
  }
}
