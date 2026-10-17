import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'bg_log.dart';
import 'notif_service.dart';

/// 后端健康接口（HTTP 明文，用于验证 INTERNET + 明文流量是否可用）
const String _backendToken = 'http://8.152.206.46:5555/token';

/// 主引擎上的原生控制通道（与 [main.dart] 里同一个通道名）。
/// 用它可以让原生代码启动透明 Activity，等同于点磁贴。
const MethodChannel _nativeControl = MethodChannel('native_control');

class PermissionTestPage extends StatefulWidget {
  const PermissionTestPage({super.key});

  @override
  State<PermissionTestPage> createState() => _PermissionTestPageState();
}

class _PermissionTestPageState extends State<PermissionTestPage> {
  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'test_channel',
    '权限测试通知',
    description: '权限自检测试用',
    importance: Importance.high,
  );

  String _netResult = '未测试';
  String _playResult = '未测试';
  String _bannerResult = '未测试';
  String _proxyResult = '未测试';
  double _progress = 0;
  final List<String> _log = [];

  // 敏感权限及其当前授权状态
  final Map<Permission, PermissionStatus> _status = {};
  final List<_Perm> _perms = [
    _Perm('互联网 INTERNET', '访问后端 / 下载直链', null),
    _Perm('网络状态 ACCESS_NETWORK_STATE', '判断有无网络', null),
    _Perm('读取图片 READ_MEDIA_IMAGES', '读取相册图片', Permission.photos),
    _Perm('读取视频 READ_MEDIA_VIDEO', '读取视频文件', Permission.videos),
    _Perm('读取音乐 READ_MEDIA_AUDIO', '读取音乐文件', Permission.audio),
    _Perm('通知 POST_NOTIFICATIONS', '弹下载进度/结果通知', Permission.notification),
    _Perm('前台服务 FOREGROUND_SERVICE', '下载时后台保活(防杀)', null),
    _Perm('跳过电池优化', '防省电策略杀进程', Permission.ignoreBatteryOptimizations),
  ];

  @override
  void initState() {
    super.initState();
    // 通知插件已由 notif_service.initAppNotif() 统一初始化，这里只建测试通道
    appNotif
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);
    for (final p in _perms) {
      if (p.permission != null) {
        p.permission!.status.then((s) {
          if (mounted) setState(() => _status[p.permission!] = s);
        }).catchError((_) {
          // 平台插件不可用（如测试环境）时静默降级，状态保持「…」
        });
      }
    }
  }

  void _addLog(String s) => setState(() => _log.insert(0, s));

  String _statusText(Permission? p) {
    if (p == null) return '普通权限(自动授予)';
    final s = _status[p];
    if (s == null) return '…';
    if (s.isGranted) return '已授权';
    if (s.isDenied) return '未授权';
    if (s.isPermanentlyDenied) return '已永久拒绝';
    return s.name;
  }

  Future<void> _request(Permission p, String label) async {
    final s = await p.request();
    setState(() => _status[p] = s);
    _addLog('$label → ${s.name}');
  }

  Future<void> _checkNet() async {
    setState(() => _netResult = '测试中…');
    try {
      final r = await http
          .get(Uri.parse(_backendToken))
          .timeout(const Duration(seconds: 15));
      setState(() => _netResult = '成功 (HTTP ${r.statusCode}) — INTERNET+明文可用');
      _addLog('网络自检: HTTP ${r.statusCode}');
    } catch (e) {
      setState(() => _netResult = '失败: $e');
      _addLog('网络自检失败: $e');
    }
  }

  Future<void> _downloadAndPlay() async {
    setState(() => _playResult = '下载中…');
    try {
      final ByteData data = await rootBundle.load('song.mp4');
      final bytes = data.buffer.asUint8List();
      final dir = await getExternalStorageDirectory();
      final file = File('${dir!.path}/song.mp4');

      // 分块写入，顺便驱动进度条（模拟下载过程）
      const chunk = 256 * 1024;
      final sink = file.openWrite();
      for (int i = 0; i < bytes.length; i += chunk) {
        final end = (i + chunk < bytes.length) ? i + chunk : bytes.length;
        sink.add(bytes.sublist(i, end));
        setState(() => _progress = end / bytes.length);
      }
      await sink.close();

      await appNotif.show(
        1,
        '下载成功',
        'song.mp4 已保存，准备调用播放器',
        NotificationDetails(
          android: AndroidNotificationDetails(_channel.id, _channel.name),
        ),
      );
      setState(() => _playResult = '已保存，正在调用系统播放器…');
      _addLog('已写入: ${file.path}');

      final res = await OpenFilex.open(file.path);
      _addLog('调用播放器: ${res.message}');
      setState(() => _playResult = '已调用播放器 (${res.message})');
    } catch (e) {
      setState(() => _playResult = '失败: $e');
      _addLog('下载播放失败: $e');
    }
  }

  /// 通知横幅自检：走与「检测到抖音链接」完全相同的通道发一条横幅，
  /// 并把「是否发送成功 / 系统里有没有落库 / 失败原因」全部显示出来。
  /// 这是排查「横幅从来不弹」最快的一步：能区分「没发出去」和「发出去了但被系统藏了」。
  Future<void> _testBanner() async {
    setState(() => _bannerResult = '发送中…');
    final status = await Permission.notification.status;
    final ok = await showLinkHeadsUp(
      'https://v.douyin.com/selfcheck-demo/',
      title: '横幅自检（示例）',
    );
    // 给系统一点时间落库
    await Future.delayed(const Duration(milliseconds: 400));
    final active = await debugActiveNotifications();
    final err = lastNotifError == null ? '' : '\n失败原因：$lastNotifError';
    setState(() => _bannerResult =
        'show() 返回值：${ok ? '成功' : '失败'}\n通知权限：$status\n$active$err');
    _addLog('横幅自检: ok=$ok · $active${err.isEmpty ? '' : ' · $err'}');
  }

  /// 与磁贴等价的触发：让原生 handler 启动透明 Activity，由它在获得焦点后
  /// 读剪贴板。链路：native_control → ClipboardProxyActivity → clipboard_proxy
  /// → main._onClipboardLink → 弹横幅。用来区分「磁贴没启起来」还是「后面断了」。
  Future<void> _testProxy() async {
    setState(() => _proxyResult = '已请求…（看顶部有没有弹横幅，或有没有 Toast）');
    try {
      await _nativeControl.invokeMethod<void>('startClipboardProxy');
      _addLog('手动触发透明窗口: 已发出请求');
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      setState(() => _proxyResult =
          '已请求（2 秒内既没弹横幅也没 Toast → 透明窗口大概被 ROM 拦了）');
    } catch (e) {
      setState(() => _proxyResult = '调用失败：$e');
      _addLog('手动触发透明窗口失败: $e');
    }
  }

  /// 后台下载日志（写在 App 缓存目录，主/后台 isolate 共用）
  String _bgLogText = '';

  Future<void> _loadBgLog() async {
    final text = await readBgLog();
    if (mounted) setState(() => _bgLogText = text);
  }

  Future<void> _clearBgLog() async {
    await clearBgLog();
    if (mounted) setState(() => _bgLogText = '（已清空）');
  }

  Widget _permRow(_Perm p) {
    final isNormal = p.permission == null;
    return ListTile(
      title: Text(p.label),
      subtitle: Text(p.note),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Chip(label: Text(_statusText(p.permission))),
          if (!isNormal)
            TextButton(
              onPressed: () => _request(p.permission!, p.label),
              child: const Text('申请'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text('一、权限状态（普通权限自动授予；敏感权限点“申请”会弹系统授权框）',
            style: TextStyle(fontWeight: FontWeight.bold)),
        ..._perms.map(_permRow),
        const Divider(),
        const Text('二、自动自检', style: TextStyle(fontWeight: FontWeight.bold)),
        ElevatedButton(
          onPressed: _checkNet,
          child: const Text('① 网络自检（ping 后端 /token）'),
        ),
        Text('结果: $_netResult'),
        const SizedBox(height: 8),
        ElevatedButton(
          onPressed: _downloadAndPlay,
          child: const Text('② 下载并播放自检（song.mp4）'),
        ),
        Text('结果: $_playResult'),
        if (_progress > 0 && _progress < 1)
          LinearProgressIndicator(value: _progress),
        const Divider(),
        const Text('三、通知链路自检（横幅不弹时先点这个）',
            style: TextStyle(fontWeight: FontWeight.bold)),
        ElevatedButton(
          onPressed: _testBanner,
          child: const Text('③ 发一条测试横幅（含错误回显）'),
        ),
        Text('结果: $_bannerResult'),
        if (_bannerResult != '未测试')
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              '怎么读这个结果：\n'
              '· show() 失败 → 看「失败原因」，那就是真正的 bug\n'
              '· show() 成功但系统里 0 条 → 通知被系统拦下了（权限/厂商限制）\n'
              '· 系统里有 N 条但你看不到 → 去通知设置把「剪贴板提醒」通道设为重要、允许横幅\n'
              '（小米：设置 → 应用设置 → 本应用 → 通知管理 → 剪贴板提醒）',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ),
        TextButton(
          onPressed: () => openAppSettings(),
          child: const Text('打开本 App 的系统设置（改通知权限）'),
        ),
        const SizedBox(height: 8),
        const Text('四、剪贴板链路自检（磁贴点了没反应时点这个）',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const Padding(
          padding: EdgeInsets.only(bottom: 6),
          child: Text(
            '它和磁贴走的是同一条链路（原生 → 透明窗口 → 读剪贴板 → 弹横幅），'
            '只是省掉了「磁贴」这一步。用来区分是磁贴没启动起来，还是后面的环节断了。',
            style: TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ),
        ElevatedButton(
          onPressed: _testProxy,
          child: const Text('④ 手动触发读剪贴板（等同磁贴）'),
        ),
        Text('结果: $_proxyResult'),
        const Divider(),
        const Text('五、后台下载日志（点横幅上「后台下载」没反应时看这里）',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const Padding(
          padding: EdgeInsets.only(bottom: 6),
          child: Text(
            '「后台下载」跑在一个全新的后台 isolate 里，看不到界面。它每一步都会写进 '
            'App 缓存目录的 bg_download.log，这里直接读出来——'
            '如果日志是空的，说明通知动作根本没到 App（插件那边没起来）。',
            style: TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ),
        Row(
          children: [
            ElevatedButton(
              onPressed: _loadBgLog,
              child: const Text('刷新后台日志'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _clearBgLog,
              child: const Text('清空'),
            ),
          ],
        ),
        if (_bgLogText.isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.all(8),
            color: const Color(0xFFF6F6F8),
            child: SelectableText(
              _bgLogText,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
        const Divider(),
        const Text('六、操作日志', style: TextStyle(fontWeight: FontWeight.bold)),
        ..._log.map((e) => Text('• $e', style: const TextStyle(fontSize: 12))),
      ],
    );
  }
}

class _Perm {
  final String label;
  final String note;
  final Permission? permission;
  _Perm(this.label, this.note, this.permission);
}
