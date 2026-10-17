import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hello_world_app/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Mock shared_preferences so Store.init() works without a platform.
    SharedPreferences.setMockInitialValues({});

    // Mock flutter_local_notifications platform channel so DouyinPage's
    // async init (initialize + createNotificationChannel) doesn't throw
    // inside widget tests. NOTE: `initialize` expects FutureOr<bool>, so we
    // must return a real bool (false) for it, not null — returning null
    // crashes with "type 'Null' is not a subtype of type 'FutureOr<bool>'".
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      (call) async {
        if (call.method == 'initialize') return false;
        return null;
      },
    );
  });

  testWidgets('home shows three tabs: 首页 / 抖音 / 测试', (tester) async {
    await tester.pumpWidget(const MyApp());
    // Give the async init (fully mocked above, and degradable inside the
    // app itself) a chance to run its microtasks.
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('抖音'), findsOneWidget);
    expect(find.text('测试'), findsOneWidget);
    // B站 / Shizuku 相关功能已整体移除，界面不应再出现
    expect(find.text('B站'), findsNothing);
    expect(find.textContaining('Shizuku'), findsNothing);
  });

  testWidgets('home page shows empty cache state', (tester) async {
    await tester.pumpWidget(const MyApp());
    // 等待首页异步加载（读下载记录 -> 渲染空态），进度圈消失后稳定
    await tester.pumpAndSettle();

    // 首页（默认 Tab）：无下载记录时展示空态引导
    expect(find.textContaining('还没有下载记录'), findsOneWidget);
  });
}
