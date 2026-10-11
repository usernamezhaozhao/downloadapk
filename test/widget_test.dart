import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hello_world_app/bilibili_page.dart';
import 'package:hello_world_app/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Mock shared_preferences so Store.init() works without a platform.
    SharedPreferences.setMockInitialValues({});

    // Mock flutter_local_notifications platform channel so DouyinPage's
    // async init (initialize + createNotificationChannel) doesn't throw
    // MissingPluginException inside widget tests.
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async => null,
    );
  });

  testWidgets('home shows three tabs: 抖音 / B站 / 测试', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump(); // let async init run

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('抖音'), findsOneWidget);
    expect(find.text('B站'), findsOneWidget);
    expect(find.text('测试'), findsOneWidget);
  });

  testWidgets('tapping B站 tab shows Hello Bilibili', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    await tester.tap(find.text('B站'));
    await tester.pumpAndSettle();

    expect(find.text('Hello Bilibili'), findsOneWidget);
  });
}
