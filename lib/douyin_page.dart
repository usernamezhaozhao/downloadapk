import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gal/gal.dart';
import 'package:permission_handler/permission_handler.dart';

import 'api_client.dart';
import 'download_service.dart';
import 'models.dart';
import 'notif_service.dart';
import 'parser.dart';
import 'store.dart';

const String kAlbum = '抖音下载';

class DouyinPage extends StatefulWidget {
  const DouyinPage({super.key});

  @override
  State<DouyinPage> createState() => _DouyinPageState();
}

class _DouyinPageState extends State<DouyinPage> with WidgetsBindingObserver {
  final _cookieCtl = TextEditingController();
  final _testIdCtl = TextEditingController();
  final _linkCtl = TextEditingController();

  final FlutterLocalNotificationsPlugin _notif = appNotif;
  late final DownloadService _dl;

  String _status = '就绪';
  String _cookieTest = '未测试';
  double _progress = 0;
  bool _working = false;
  bool _withCover = true; // 同时下载封面
  String? _coverUrl; // 解析出的远程封面（预览用）
  List<String> _debugLogs = [];

  // 剪贴板监听：上次已提示过的链接（避免重复打扰）+ 弹窗防重入
  String? _lastClipboardLink;
  bool _clipboardDialogOpen = false;

  void _addDebug(String s) =>
      setState(() => _debugLogs.insert(0, '${DateTime.now().toLocal().toIso8601String().substring(11, 19)}  $s'));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dl = DownloadService(_notif);
    _init();
    _checkClipboard();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从后台回到前台时检查剪贴板（复制抖音链接 → 自动询问是否下载）
    if (state == AppLifecycleState.resumed) _checkClipboard();
  }

  /// 匹配抖音链接（含 v.douyin.com 短链）
  static final RegExp _douyinLink = RegExp(
      r'https?://[^\s]*douyin\.com/[^\s]+',
      caseSensitive: false);

  Future<void> _checkClipboard() async {
    if (_working || _clipboardDialogOpen || !mounted) return;
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text ?? '';
      final m = _douyinLink.firstMatch(text);
      if (m == null) return;
      final link = m.group(0)!;
      if (link == _lastClipboardLink) return;
      _lastClipboardLink = link;
      if (!mounted) return;
      _clipboardDialogOpen = true;
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('检测到抖音链接'),
          content: Text(link,
              maxLines: 3, overflow: TextOverflow.ellipsis),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('忽略')),
            ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('立即下载')),
          ],
        ),
      );
      _clipboardDialogOpen = false;
      if (ok == true && mounted) {
        _linkCtl.text = link;
        _download();
      }
    } catch (_) {
      // 剪贴板不可用时静默降级
    }
  }

  Future<void> _init() async {
    try {
      await Store.instance.init();
      // 通知插件由 notif_service.initAppNotif() 统一初始化（含点击回调）。
      await _dl.init();
      _cookieCtl.text = Store.instance.cookie;
      // 测试链接优先用已保存的；为空则填你指定的固定测试链接（懒人一键测）
      _testIdCtl.text = Store.instance.testId.isNotEmpty
          ? Store.instance.testId
          : kFixedTestLink;
    } catch (e) {
      // 平台层不可用（如测试环境）或插件初始化失败时降级：
      // App 仍可浏览/输入，只是通知与持久化可能受限。
      debugPrint('DouyinPage init degraded: $e');
      if (mounted) setState(() => _status = '初始化降级（通知/存储可能受限）');
    }
  }

  /// 申请通知权限（幂等：已授权则跳过）
  Future<void> _ensureNotifPerm() async {
    final s = await Permission.notification.status;
    if (s.isDenied || s.isRestricted) {
      await Permission.notification.request();
    }
  }

  /// 发一条通知（失败/成功/测试结论都走这里，用户无需盯着 App）。
  /// [payload] 携带作品 id，点击通知即可跳转 App 内部观看。
  Future<void> _notify(String title, String body, [String? payload]) async {
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
        payload: payload,
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
      setState(() {
        _progress = 1;
        _status = '✅ 下载完成，已存入相册「$kAlbum」';
      });
      await _notify(
          '下载成功',
          '✅ ${parsed.type == 'image' ? '图文' : '视频'}已下载完成，点击进入 App 观看',
          id);
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
        // —— B 站说明（规划中）——
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('B 站（规划中）',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                SizedBox(height: 6),
                Text(
                  '后续将直接读取 B 站 App 的缓存路径：B 站负责下载，'
                  '本应用读取其缓存目录，实现播放与管理，'
                  '届时 B 站不再单独开 Tab。',
                  style: TextStyle(fontSize: 13, color: Colors.black54),
                ),
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
      ],
    );
  }
}
