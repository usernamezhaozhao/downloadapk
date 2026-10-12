import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'api_client.dart';
import 'douyin_page.dart';
import 'home_page.dart';
import 'notif_service.dart';
import 'permission_test_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // v11：先初始化主↔服务通信端口
  FlutterForegroundTask.initCommunicationPort();
  // 前台服务引擎初始化（常驻监听剪贴板用；状态栏会有一条低优先级常驻通知）
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'clipboard_channel',
      channelName: '剪贴板监听',
      channelDescription: '后台监听抖音分享链接，复制后自动弹下载横幅',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(2000),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
    ),
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '抖音下载器',
      debugShowCheckedModeBanner: false,
      // 纯白主题：白底 + 白 AppBar + 白卡片，仿 B 站离线缓存页的干净风格
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey)
            .copyWith(surface: Colors.white),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black87,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.white,
          centerTitle: true,
        ),
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 0.4,
          surfaceTintColor: Colors.white,
          shadowColor: Colors.black12,
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          indicatorColor: Color(0xFFEFEFEF),
        ),
        dividerColor: const Color(0xFFEEEEEE),
      ),
      home: const HomeTabs(),
    );
  }
}

class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key});

  @override
  State<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<HomeTabs> {
  int _idx = 0;
  DateTime? _lastBack;
  // 每次切 Tab 递增，首页监听它在返回时刷新缓存列表
  final ValueNotifier<int> _tabSignal = ValueNotifier<int>(0);
  // 通知被点击（携带作品 id）时，首页据此自动打开预览
  final ValueNotifier<String?> _pendingPreview = ValueNotifier<String?>(null);
  // 剪贴板横幅被点击（携带抖音链接）时，抖音页据此自动填入并下载
  final ValueNotifier<String?> _pendingLink = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    initAppNotif().then((_) async {
      // 冷启动：App 被杀后从通知直接拉起，也要分发 payload
      try {
        final d = await appNotif.getNotificationAppLaunchDetails();
        _handlePayload(d?.notificationResponse?.payload);
      } catch (_) {}
    });
    onNotifTap = _handlePayload;
    // 前台服务检测到抖音链接 → 主 Isolate 弹系统 heads-up（点了才下载）
    FlutterForegroundTask.addTaskDataCallback(_onClipboardLink);
  }

  /// 前台服务把检测到的抖音链接发回来，这里弹系统横幅（与通知点击同款体验）。
  /// 先立即显示链接，再异步解析出标题覆盖更新，让用户点击「立即下载」前
  /// 就知道即将下的是什么（点了才真正开始下载，不会自动下）。
  void _onClipboardLink(dynamic data) {
    if (data is! String || data.isEmpty || !mounted) return;
    showLinkHeadsUp(data);
    fetchDouyinTitle(data).then((t) {
      if (t != null && mounted) showLinkHeadsUp(data, title: t);
    });
  }

  /// 统一分发通知点击：'clip:<链接>' → 抖音页自动下载；其余 → 首页预览
  void _handlePayload(String? p) {
    if (p == null || !mounted) return;
    if (p.startsWith('clip:')) {
      _pendingLink.value = p.substring(5);
      setState(() => _idx = 1);
    } else {
      _pendingPreview.value = p;
      setState(() => _idx = 0);
    }
  }

  @override
  void dispose() {
    _tabSignal.dispose();
    _pendingPreview.dispose();
    _pendingLink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        // 双击退出：第一次提示，2 秒内再按一次才真正关闭
        final now = DateTime.now();
        if (_lastBack != null &&
            now.difference(_lastBack!).inMilliseconds < 2000) {
          SystemNavigator.pop();
          return;
        }
        _lastBack = now;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('再按一次退出程序'),
            duration: Duration(seconds: 2),
          ),
        );
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('抖音下载器')),
        // IndexedStack：保活三个页面（切 Tab 不丢输入/下载进度），首页返回时经 _tabSignal 刷新
        body: IndexedStack(
          index: _idx,
          children: [
            HomePage(
              refreshSignal: _tabSignal,
              pendingPreview: _pendingPreview,
            ),
            DouyinPage(pendingLink: _pendingLink),
            const PermissionTestPage(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _idx,
          onDestinationSelected: (i) {
            setState(() => _idx = i);
            _tabSignal.value++;
          },
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), label: '首页'),
            NavigationDestination(
                icon: Icon(Icons.download_for_offline), label: '抖音'),
            NavigationDestination(
                icon: Icon(Icons.verified_user), label: '测试'),
          ],
        ),
      ),
    );
  }
}
