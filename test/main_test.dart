import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart';

class MyWidget extends StatelessWidget {
  final String title;
  final String message;

  const MyWidget({
    Key key,
    @required this.title,
    @required this.message,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Test',
      home: Scaffold(
        appBar: AppBar(
          title: Text(title),
        ),
        body: Center(
          child: Text(message),
        ),
      ),
    );
  }
}

void main() {
  group('A unit test', () {
    test('2 + 2 = 4', () {
      expect(2 + 2, 4);
    });
  });

  group('A widget test', () {
    testWidgets('MyWidget has a title and message',
        (WidgetTester tester) async {
      await tester.pumpWidget(MyWidget(title: 'T', message: 'M'));

      final titleFinder = find.text('T');
      final messageFinder = find.text('M');

      expect(titleFinder, findsOneWidget);
      expect(messageFinder, findsOneWidget);
    });
  });
}
