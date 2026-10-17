import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:gal/gal.dart';
import 'package:permission_handler/permission_handler.dart';

import 'api_client.dart';
import 'clipboard_task.dart';
import 'download_service.dart';
import 'models.dart';
import 'notif_service.dart';
import 'parser.dart';
import 'store.dart';

const String kAlbum = '抖音下载';

class DouyinPage extends StatefulWidget {
  /// 横幅通知被点击（携带 'clip:<链接>' 提取出的链接）时，自动填入并下载
  final ValueNotifier<String?>? pendingLink;
  /// 检测到剪贴板里的抖音链接时回调父级（用于自动切到本页并预填链接）
  final VoidCallback? onDetected;

  const DouyinPage({super.key, this.pendingLink, this.onDetected});

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
  bool _clipboardMonitor = true; // 剪贴板自动监听开关（持久化）
  String? _coverUrl; // 解析出的远程封面（预览用）
  List<String> _debugLogs = [];

  // 剪贴板监听：上次已提示过的链接 + 时间（短时间内重复触发才忽略，
  // 隔几秒再复制同一条仍会重新提示，对标抖音「每次复制都问」的体验）
  String? _lastClipboardLink;
  DateTime? _lastClipboardAt;

  void _addDebug(String s) =>
      setState(() => _debugLogs.insert(0, '${DateTime.now().toLocal().toIso8601String().substring(11, 19)}  $s'));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dl = DownloadService(_notif);
    _init();
    _checkClipboard();
    // 用户点了剪贴板横幅 → 自动填入链接并开始下载
    widget.pendingLink?.addListener(_onPendingLink);
  }

  void _onPendingLink() {
    final link = widget.pendingLink?.value;
    if (link == null || _working || !mounted) return;
    widget.pendingLink!.value = null;
    _linkCtl.text = link;
    _download();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.pendingLink?.removeListener(_onPendingLink);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从后台回到前台时检查剪贴板（复制抖音链接 → 横幅通知提醒）
    if (state == AppLifecycleState.resumed) _checkClipboard();
  }

  /// 匹配抖音链接（含 v.douyin.com 短链）
  static final RegExp _douyinLink = RegExp(
      r'https?://[^\s]*douyin\.com/[^\s]+',
      caseSensitive: false);

  Future<void> _checkClipboard() async {
    // 开关关闭时完全不监听
    if (!_clipboardMonitor || _working || !mounted) return;
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text ?? '';
      final m = _douyinLink.firstMatch(text);
      if (m == null) return;
      final link = m.group(0)!;
      // 仅「同一条链接且 4 秒内重复」才跳过，避免单次返回连发；
      // 隔几秒再复制同一条（或复制新链接）都会重新提示。
      if (link == _lastClipboardLink &&
          _lastClipboardAt != null &&
          DateTime.now().difference(_lastClipboardAt!).inSeconds < 4) {
        return;
      }
      _lastClipboardLink = link;
      _lastClipboardAt = DateTime.now();
      if (!mounted) return;
      // 把识别到的链接预填进输入框，并让父级自动切到本页，
      // 用户一眼就能看到“即将下载的是哪条”，而不是只说“检测到链接”。
      if (_linkCtl.text != link) _linkCtl.text = link;
      widget.onDetected?.call();
      // 系统级 heads-up 横幅：返回前台时尝试从屏幕顶部悬浮弹出。
      // 注意：App 在前台时部分厂商（小米/华为）会把 heads-up 收进状态栏不弹，
      // 所以下面再用 App 内顶部横幅兜底，保证一定能看见、点了就下载。
      final granted = await _ensureNotifPerm();
      if (granted) {
        // 先立即显示链接；解析出视频标题后再覆盖更新，点击前就知道要下的是什么
        await showLinkHeadsUp(link);
        fetchDouyinTitle(link).then((t) {
          if (t != null && mounted) showLinkHeadsUp(link, title: t);
        });
      }
      // App 内顶部横幅（兜底，始终可见可点），直接把链接展示出来
      final short = link.length > 60 ? '${link.substring(0, 60)}…' : link;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('检测到抖音链接：$short\n是否立即下载？'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: '立即下载',
            onPressed: () {
              if (_working || !mounted) return;
              _linkCtl.text = link;
              _download();
            },
          ),
        ),
      );
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
      _clipboardMonitor = Store.instance.clipboardMonitor;
      // 开关默认开 → 启动前台服务常驻监听（关则停止）
      if (_clipboardMonitor) await _applyMonitorService(true);
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

  /// 开关联动：开 → 启动前台服务（状态栏常驻低优先级通知）；关 → 停止服务
  Future<void> _applyMonitorService(bool on) async {
    try {
      if (on) {
        // 安卓 13+ 启动前台服务必须先有通知权限
        await _ensureNotifPerm();
        final running = await FlutterForegroundTask.isRunningService;
        if (running != true) {
          await FlutterForegroundTask.startService(
            callback: clipboardTaskStartCallback,
            serviceId: 256,
            notificationTitle: '抖音下载器 · 剪贴板监听中',
            notificationText: '复制抖音链接后，点通知上的「读取剪贴板」即可自动弹下载横幅',
            notificationButtons: const [
              NotificationButton(id: 'read_clipboard', text: '读取剪贴板'),
            ],
          );
        }
      } else {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {
      // 服务启动失败（如权限/厂商限制）静默降级，仍可用「回到前台」检测
    }
  }

  /// 申请通知权限，返回最终是否已授权
  Future<bool> _ensureNotifPerm() async {
    final s = await Permission.notification.status;
    if (s.isDenied || s.isRestricted) {
      final r = await Permission.notification.request();
      return r.isGranted;
    }
    return s.isGranted;
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
            kChannelResult,
            '下载结果',
            channelDescription: '下载成功/失败与 Cookie 测试结果',
            importance: Importance.high,
            priority: Priority.high,
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
                const Divider(height: 1),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('剪贴板自动监听'),
                  subtitle: const Text(
                      '复制链接后，下拉通知栏点「抖音下载」磁贴即可（安卓10+后台读不到剪贴板）'),
                  value: _clipboardMonitor,
                  onChanged: _working
                      ? null
                      : (v) async {
                          final val = v ?? true;
                          setState(() => _clipboardMonitor = val);
                          await Store.instance.setClipboardMonitor(val);
                          await _applyMonitorService(val);
                        },
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
      ],
    );
  }
}
