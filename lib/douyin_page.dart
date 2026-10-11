import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';

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
  List<DownloadItem> _items = [];

  @override
  void initState() {
    super.initState();
    _dl = DownloadService(_notif);
    _init();
  }

  Future<void> _init() async {
    await Store.instance.init();
    await _notif.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
    await _dl.init();
    _cookieCtl.text = Store.instance.cookie;
    _testIdCtl.text = Store.instance.testId;
    _refreshList();
  }

  void _refreshList() => setState(() => _items = Store.instance.items.toList());

  Future<void> _saveCookie() async {
    await Store.instance.setCookie(_cookieCtl.text.trim());
    await Store.instance.setTestId(_testIdCtl.text.trim());
    setState(() => _cookieTest = '已保存');
  }

  Future<void> _testCookie() async {
    setState(() => _cookieTest = '测试中…');
    try {
      await testCookie(_cookieCtl.text.trim(), _testIdCtl.text.trim());
      setState(() => _cookieTest = '✅ cookie 有效（能正常取到数据）');
    } on ApiException catch (e) {
      final reason = e.kind == 'link_expired'
          ? '（链接失效/作品不存在，但 cookie 可能仍有效，建议换一个有效作品ID再测）'
          : '';
      setState(() => _cookieTest = '❌ 无效: ${e.message} $reason');
    } catch (e) {
      setState(() => _cookieTest = '❌ 请求失败: $e');
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
    final link = _linkCtl.text.trim();
    if (link.isEmpty) {
      setState(() => _status = '请先粘贴抖音分享链接');
      return;
    }
    await _ensurePerms();
    setState(() {
      _working = true;
      _progress = 0;
      _status = '① 解析分享链接中…';
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
      setState(() => _status = '③ 下载中…（${parsed.type == 'image' ? '图文' : '视频'}）');
      // 5) 下载（前端 + 通知双进度）
      final paths = await _dl.download(
        tasks: parsed.tasks,
        onProgress: (p, label) => setState(() {
          _progress = p;
          _status = label;
        }),
        album: kAlbum,
      );
      // 6) 记入本地列表
      final item = DownloadItem(
        id: id,
        title: parsed.title,
        type: parsed.type,
        paths: paths,
        time: DateTime.now().millisecondsSinceEpoch,
      );
      await Store.instance.addItem(item);
      _refreshList();
      setState(() {
        _progress = 1;
        _status = '✅ 下载完成，已存入相册「$kAlbum」';
      });
      _linkCtl.clear();
    } on ApiException catch (e) {
      final hint = e.kind == 'link_expired'
          ? '（链接失效或作品已删除，换一个有效链接试试）'
          : e.kind == 'parse_failed'
              ? '（解析失败，可能是链接格式不对或 cookie 需要更新）'
              : '';
      setState(() => _status = '❌ 失败[${e.kind}]: ${e.message} $hint');
    } catch (e) {
      setState(() => _status = '❌ 失败: $e');
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
          child: item.type == 'image'
              ? ListView(
                  shrinkWrap: true,
                  children: item.paths
                      .map((p) => Image.file(File(p)))
                      .toList(),
                )
              : const Center(child: Icon(Icons.play_circle_fill, size: 64)),
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
    final cover = it.coverPath;
    return Card(
      child: ListTile(
        leading: cover != null
            ? (it.type == 'image'
                ? Image.file(File(cover),
                    width: 48, height: 48, fit: BoxFit.cover)
                : const Icon(Icons.video_file, size: 40))
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
                const Text('Cookie 设置（给后端 TikTokDownloader 用）',
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
                    labelText: '测试作品ID（用于验证 cookie）',
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
                const SizedBox(height: 8),
                Text(_status),
                if (_progress > 0 && _progress < 1)
                  LinearProgressIndicator(value: _progress),
              ],
            ),
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
