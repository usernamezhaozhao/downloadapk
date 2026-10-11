import 'package:flutter/material.dart';
import 'bilibili_page.dart';
import 'douyin_page.dart';
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
  final List<Widget> _pages = const [
    DouyinPage(),
    BilibiliPage(),
    PermissionTestPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('抖音下载器')),
      body: _pages[_idx],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _idx,
        onDestinationSelected: (i) => setState(() => _idx = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.download_for_offline), label: '抖音'),
          NavigationDestination(icon: Icon(Icons.tv), label: 'B站'),
          NavigationDestination(
              icon: Icon(Icons.verified_user), label: '测试'),
        ],
      ),
    );
  }
}
