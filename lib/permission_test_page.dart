import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// 后端健康接口（HTTP 明文，用于验证 INTERNET + 明文流量是否可用）
const String _backendToken = 'http://8.152.206.46:5555/token';

class PermissionTestPage extends StatefulWidget {
  const PermissionTestPage({super.key});

  @override
  State<PermissionTestPage> createState() => _PermissionTestPageState();
}

class _PermissionTestPageState extends State<PermissionTestPage> {
  final FlutterLocalNotificationsPlugin _notif =
      FlutterLocalNotificationsPlugin();

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'test_channel',
    '权限测试通知',
    description: '权限自检测试用',
    importance: Importance.high,
  );

  String _netResult = '未测试';
  String _playResult = '未测试';
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
    _initNotif();
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

  Future<void> _initNotif() async {
    await _notif
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);
    await _notif.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
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

      await _notif.show(
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
        const Text('三、操作日志', style: TextStyle(fontWeight: FontWeight.bold)),
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
