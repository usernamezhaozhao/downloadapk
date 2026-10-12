import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gal/gal.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';

import 'api_client.dart';
import 'download_service.dart';
import 'models.dart';
import 'parser.dart';
import 'store.dart';

const String kAlbum = '抖音下载';

class DouyinPage extends StatefulWidget {
  const DouyinPage({super.key});

  @override
  State<DouyinPage> createState() => _DouyinPageState();
}

/// App 内嵌视频播放器：用于预览弹窗里直接播放，无需跳出系统播放器。
class _VideoPreview extends StatefulWidget {
  final String path;
  const _VideoPreview(this.path);

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  late final VideoPlayerController _c;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _c = VideoPlayerController.file(File(widget.path))
      ..initialize().then((_) {
        if (mounted) setState(() => _ready = true);
      }).catchError((e) {
        if (mounted) setState(() => _ready = false);
      });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return AspectRatio(
      aspectRatio: _c.value.aspectRatio,
      child: Stack(
        alignment: Alignment.center,
        children: [
          VideoPlayer(_c),
          IconButton(
            iconSize: 56,
            color: Colors.white,
            icon: Icon(_c.value.isPlaying
                ? Icons.pause_circle_filled
                : Icons.play_circle_fill),
            onPressed: () => setState(() {
              _c.value.isPlaying ? _c.pause() : _c.play();
            }),
          ),
        ],
      ),
    );
  }
}

class _DouyinPageState extends State<DouyinPage> {
  final _cookieCtl = TextEditingController();
  final _testIdCtl = TextEditingController();
  final _linkCtl = TextEditingController();

  final FlutterLocalNotificationsPlugin _notif =
      FlutterLocalNotificationsPlugin();
  late final DownloadService _dl;

  String _status = '就绪';
  String _cookieTest = '未测试';
  double _progress = 0;
  bool _working = false;
  bool _withCover = true; // 同时下载封面
  String? _coverUrl; // 解析出的远程封面（预览用）
  List<DownloadItem> _items = [];
  List<String> _debugLogs = [];

  void _addDebug(String s) =>
      setState(() => _debugLogs.insert(0, '${DateTime.now().toLocal().toIso8601String().substring(11, 19)}  $s'));

  @override
  void initState() {
    super.initState();
    _dl = DownloadService(_notif);
    _init();
  }

  Future<void> _init() async {
    try {
      await Store.instance.init();
      await _notif.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ));
      await _dl.init();
      _cookieCtl.text = Store.instance.cookie;
      // 测试链接优先用已保存的；为空则填你指定的固定测试链接（懒人一键测）
      _testIdCtl.text = Store.instance.testId.isNotEmpty
          ? Store.instance.testId
          : kFixedTestLink;
      _refreshList();
    } catch (e) {
      // 平台层不可用（如测试环境）或插件初始化失败时降级：
      // App 仍可浏览/输入，只是通知与持久化可能受限。
      debugPrint('DouyinPage init degraded: $e');
      if (mounted) setState(() => _status = '初始化降级（通知/存储可能受限）');
    }
  }

  void _refreshList() => setState(() => _items = Store.instance.items.toList());

  /// 申请通知权限（幂等：已授权则跳过）
  Future<void> _ensureNotifPerm() async {
    final s = await Permission.notification.status;
    if (s.isDenied || s.isRestricted) {
      await Permission.notification.request();
    }
  }

  /// 发一条普通通知（失败/成功/测试结论都走这里，用户无需盯着 App）
  Future<void> _notify(String title, String body) async {
    try {
      await _notif.show(
        DateTime.now().millisecondsSinceEpoch % 100000,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'download_channel',
            '下载进度',
            importance: Importance.high,
          ),
        ),
      );
    } catch (_) {
      // 通知权限未授予时静默失败，不影响主流程
    }
  }

  Future<void> _saveCookie() async {
    await Store.instance.setCookie(_cookieCtl.text.trim());
    await Store.instance.setTestId(_testIdCtl.text.trim());
    setState(() => _cookieTest = '已保存');
  }

  Future<void> _testCookie() async {
    await _ensureNotifPerm();
    // 为空时回退到固定测试链接
    final input = _testIdCtl.text.trim().isEmpty
        ? kFixedTestLink
        : _testIdCtl.text.trim();
    setState(() => _cookieTest = '测试中…');
    try {
      await testCookie(_cookieCtl.text.trim(), input);
      setState(() => _cookieTest = '✅ cookie 有效（能正常取到数据）');
      await _notify('Cookie 测试', '✅ cookie 有效，能正常取到数据');
    } on ApiException catch (e) {
      final reason = e.kind == 'link_expired'
          ? '（链接失效/作品不存在，但 cookie 可能仍有效，建议换一个有效作品ID再测）'
          : '';
      setState(() => _cookieTest = '❌ 无效: ${e.message} $reason');
      await _notify('Cookie 测试失败', '❌ ${e.message} $reason');
    } catch (e) {
      setState(() => _cookieTest = '❌ 请求失败: $e');
      await _notify('Cookie 测试失败', '❌ 请求失败: $e');
    }
  }

  Future<void> _ensurePerms() async {
    await [
      Permission.notification,
      Permission.photos,
      Permission.videos,
    ].request();
  }

  Future<void> _download() async {
    // 为空时回退到固定测试链接（懒人一键下）
    final link = _linkCtl.text.trim().isEmpty
        ? kFixedTestLink
        : _linkCtl.text.trim();
    await _ensurePerms();
    setState(() {
      _working = true;
      _progress = 0;
      _status = '① 解析分享链接中…';
      _debugLogs.clear();
      _coverUrl = null;
    });
    try {
      // 1) 解析分享短链 -> 完整链接
      final url = await resolveShare(link);
      // 2) 取作品 ID
      final id = extractDetailId(url);
      if (id == null) {
        throw ApiException('parse_failed', '无法从链接中提取作品ID: $url');
      }
      setState(() => _status = '② 获取作品数据中…');
      // 3) 取数据
      final data = await fetchDetail(id, _cookieCtl.text.trim());
      // 4) 解析媒体
      final parsed = parseDetail(data, id);
      setState(() {
        _coverUrl = parsed.cover;
        _status = '③ 下载中…（${parsed.type == 'image' ? '图文' : '视频'}）';
      });
      _addDebug('解析结果: type=${parsed.type}, 任务数=${parsed.tasks.length}');
      _addDebug('封面: ${parsed.cover ?? '(无)'}');
      if (parsed.type == 'image') {
        _addDebug('⚠️ 这是图文，图片字段名若解析不出请把后端 JSON 贴我');
      }
      // 5) 下载（前端 + 通知双进度 + 调试日志；Cookie 透传给抖音 CDN）
      final paths = await _dl.download(
        tasks: parsed.tasks,
        onProgress: (p, label) => setState(() {
          _progress = p;
          _status = label;
        }),
        album: kAlbum,
        onLog: _addDebug,
        cookie: _cookieCtl.text.trim(),
      );
      // 5.5) 下载封面（可选）
      String? coverPath;
      if (_withCover && parsed.cover != null) {
        coverPath = await _dl.downloadCover(
          parsed.cover!,
          _cookieCtl.text.trim(),
          _addDebug,
        );
        if (coverPath != null) {
          // 封面也存一份到相册
          try {
            await Gal.putImage(coverPath, album: kAlbum);
          } catch (_) {
            _addDebug('封面写入相册失败（不影响本机副本）');
          }
        }
      }
      // 6) 记入本地列表
      final item = DownloadItem(
        id: id,
        title: parsed.title,
        type: parsed.type,
        paths: paths,
        time: DateTime.now().millisecondsSinceEpoch,
        coverPath: coverPath,
        cover: parsed.cover,
      );
      await Store.instance.addItem(item);
      _refreshList();
      setState(() {
        _progress = 1;
        _status = '✅ 下载完成，已存入相册「$kAlbum」';
      });
      await _notify('抖音下载完成',
          '已保存${parsed.type == 'image' ? '图文' : '视频'}到相册「$kAlbum」');
      _linkCtl.clear();
    } on ApiException catch (e) {
      final hint = e.kind == 'link_expired'
          ? '（链接失效或作品已删除，换一个有效链接试试）'
          : e.kind == 'parse_failed'
              ? '（解析失败，可能是链接格式不对或 cookie 需要更新）'
              : '';
      setState(() => _status = '❌ 失败[${e.kind}]: ${e.message} $hint');
      await _notify('抖音下载失败', '❌ [${e.kind}] ${e.message} $hint');
    } catch (e) {
      setState(() => _status = '❌ 失败: $e');
      await _notify('抖音下载失败', '❌ $e');
    } finally {
      setState(() => _working = false);
    }
  }

  Future<void> _open(DownloadItem item) async {
    if (item.paths.isEmpty) return;
    try {
      await OpenFilex.open(item.paths.first);
    } catch (e) {
      setState(() => _status = '打开失败: $e');
    }
  }

  void _preview(DownloadItem item) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(item.title),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.coverPath != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Image.file(File(item.coverPath!), height: 120, fit: BoxFit.cover),
                )
              else if (item.cover != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Image.network(item.cover!, height: 120, fit: BoxFit.cover),
                ),
              if (item.type == 'image')
                ...item.paths.map((p) => Image.file(File(p))).toList()
              else
                _VideoPreview(item.paths.first),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _open(item);
            },
            child: const Text('用系统播放器打开'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _itemCard(DownloadItem it) {
    final cover = it.coverPath ?? it.cover;
    final coverIsLocal = it.coverPath != null;
    return Card(
      child: ListTile(
        leading: cover != null
            ? (coverIsLocal
                ? Image.file(File(cover), width: 48, height: 48, fit: BoxFit.cover)
                : Image.network(cover, width: 48, height: 48, fit: BoxFit.cover))
            : const Icon(Icons.file_present),
        title: Text(it.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${it.type == 'image' ? '图文' : '视频'} · ${it.paths.length} 个文件'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.visibility),
              onPressed: () => _preview(it),
            ),
            IconButton(
              icon: const Icon(Icons.play_arrow),
              onPressed: () => _open(it),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // —— Cookie 设置 ——
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Cookie 设置（给后端 DouK-Downloader 用，也会透传给抖音 CDN 拉直链）',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                TextField(
                  controller: _cookieCtl,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Cookie',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _testIdCtl,
                  decoration: const InputDecoration(
                    labelText: '测试链接或作品ID（可直接粘贴抖音分享链接）',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    ElevatedButton(
                        onPressed: _saveCookie, child: const Text('保存')),
                    const SizedBox(width: 8),
                    ElevatedButton(
                        onPressed: _testCookie, child: const Text('测试 Cookie')),
                  ],
                ),
                Text(_cookieTest, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
        // —— 下载 ——
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('粘贴抖音分享链接',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                TextField(
                  controller: _linkCtl,
                  decoration: const InputDecoration(
                    labelText: '例如 https://v.douyin.com/xxxx/',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: _working ? null : _download,
                  icon: const Icon(Icons.download),
                  label: Text(_working ? '下载中…' : '下载'),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Checkbox(
                      value: _withCover,
                      onChanged: _working
                          ? null
                          : (v) => setState(() => _withCover = v ?? true),
                    ),
                    const Text('同时下载封面'),
                  ],
                ),
                if (_coverUrl != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('封面预览：',
                            style: TextStyle(fontSize: 12, color: Colors.grey)),
                        const SizedBox(height: 4),
                        Image.network(_coverUrl!, height: 120, fit: BoxFit.cover),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Text(_status),
                if (_progress > 0 && _progress < 1)
                  LinearProgressIndicator(value: _progress),
              ],
            ),
          ),
        ),
        // —— 下载调试日志（播放异常时把这里的内容贴给我）——
        Card(
          color: Colors.grey[50],
          child: ExpansionTile(
            title: const Text('下载调试日志',
                style: TextStyle(fontWeight: FontWeight.bold)),
            subtitle: const Text('若视频下载完却播不了，展开复制日志发我'),
            children: [
              if (_debugLogs.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('暂无日志', style: TextStyle(color: Colors.grey)),
                )
              else
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    _debugLogs.join('\n'),
                    style: const TextStyle(
                        fontSize: 11, fontFamily: 'monospace'),
                  ),
                ),
            ],
          ),
        ),
        // —— 本地列表 ——
        const Text('本地列表（点预览 / 播放）',
            style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        if (_items.isEmpty)
          const Text('还没有下载记录', style: TextStyle(color: Colors.grey)),
        ..._items.map(_itemCard),
      ],
    );
  }
}
