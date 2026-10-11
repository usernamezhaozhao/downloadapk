import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hello_world_app/main.dart';

void main() {
  testWidgets('shows Hello World on screen', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    // The text appears in both the AppBar title and the body, so we
    // assert "at least one" rather than exactly one.
    expect(find.text('Hello World'), findsWidgets);
  });
}
