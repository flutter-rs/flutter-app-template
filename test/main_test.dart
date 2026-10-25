import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_app_template/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('handleHostCall', () {
    test('echo replies at once with the argument the host sent', () async {
      expect(await handleHostCall(const MethodCall('echo', 7)), 'echo of 7');
    });

    testWidgets('echoLate replies only after the delay', (tester) async {
      Object? reply;

      handleHostCall(
        const MethodCall('echoLate', 3),
      ).then((value) => reply = value);

      await tester.pump(lateReplyDelay - const Duration(milliseconds: 1));

      expect(reply, isNull, reason: 'the reply came early');

      await tester.pump(const Duration(milliseconds: 1));

      expect(reply, 'late echo of 3 after 2000 ms');
    });

    testWidgets('never leaves the host waiting for ever', (tester) async {
      expect(handleHostCall(const MethodCall('never', 4)), doesNotComplete);

      await tester.pump(const Duration(minutes: 5));
    });

    test('typedLists returns the keys and types the host decodes', () async {
      // Keep this in step with the `TypedLists` struct and its unit test in
      // `src/main.rs`: the host decodes the reply field by field.
      final reply =
          await handleHostCall(const MethodCall('typedLists', 5))
              as Map<String, Object?>;

      expect(
        reply.keys,
        unorderedEquals(<String>[
          'bytes',
          'int32s',
          'int64s',
          'float32s',
          'float64s',
        ]),
      );
      expect(reply['bytes'], isA<Uint8List>());
      expect(reply['int32s'], isA<Int32List>());
      expect(reply['int64s'], isA<Int64List>());
      expect(reply['float32s'], isA<Float32List>());
      expect(reply['float64s'], isA<Float64List>());
      expect(
        reply['int64s'],
        <int>[9007199254740993, -7],
        reason: 'an int that no double can hold must survive the round trip',
      );
      expect(reply['float32s'], <double>[1.5, -2.5]);
    });

    test('fail throws the error envelope the host decodes', () {
      expect(
        handleHostCall(const MethodCall('fail', 6)),
        throwsA(
          isA<PlatformException>()
              .having((error) => error.code, 'code', 'dart-error')
              .having((error) => error.details, 'details', 'fail'),
        ),
      );
    });

    test('an unknown method throws, which becomes the empty envelope', () {
      expect(
        handleHostCall(const MethodCall('unhandled', 7)),
        throwsA(isA<MissingPluginException>()),
      );
    });
  });

  group('the UI', () {
    test('gives every case its own trigger', () {
      final triggers = verificationCases
          .map((verification) => verification.trigger)
          .toSet();

      expect(
        triggers,
        hasLength(verificationCases.length),
        reason: 'two cases sharing a trigger would also share a widget key',
      );
    });

    testWidgets('shows a button per case and logs what the host calls', (
      tester,
    ) async {
      await tester.pumpWidget(const VerificationApp());

      for (final verification in verificationCases) {
        expect(
          find.byKey(ValueKey('case-${verification.trigger}')),
          findsOneWidget,
        );
      }

      final messenger = tester.binding.defaultBinaryMessenger;

      await messenger.handlePlatformMessage(
        hostChannel.name,
        hostChannel.codec.encodeMethodCall(const MethodCall('echo', 8)),
        null,
      );
      await tester.pump();

      expect(find.textContaining('called echo(8)'), findsOneWidget);
    });
  });
}
