import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'douyin_page.dart';
import 'home_page.dart';
import 'notif_service.dart';
import 'permission_test_page.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '抖音下载器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.green),
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

  @override
  void initState() {
    super.initState();
    initAppNotif();
    // 通知点击：跳到首页并让首页打开对应作品预览
    onNotifTap = (payload) {
      if (payload != null) _pendingPreview.value = payload;
      setState(() => _idx = 0);
    };
  }

  @override
  void dispose() {
    _tabSignal.dispose();
    _pendingPreview.dispose();
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
            const DouyinPage(),
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
