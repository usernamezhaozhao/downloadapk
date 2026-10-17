import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'store.dart';
import 'video_preview.dart';

/// 首页：本 App 的下载缓存列表（布局仿 B 站「离线缓存」页）。
/// 支持：搜索 / 删除 / 按作品归组（封面+标题+文件数+容量）/ 点卡片自动预览播放 / 底部容量统计。
class HomePage extends StatefulWidget {
  /// 主页 Tab 每次切换时递增，用于返回首页时刷新缓存列表
  final ValueNotifier<int>? refreshSignal;
  /// 通知被点击（携带作品 id）时，自动跳到首页并打开该作品预览
  final ValueNotifier<String?>? pendingPreview;

  const HomePage({super.key, this.refreshSignal, this.pendingPreview});

  @override
  State<HomePage> createState() => _HomePageState();
}

/// 按作品 ID 归组后的展示单元（同一作品多次下载会合并文件）
class _Group {
  final String id;
  final String title;
  final String type; // 'video' | 'image'
  final List<String> paths = [];
  final String? coverPath; // 本地封面
  final String? cover; // 远程封面

  _Group(this.id, this.title, this.type, this.coverPath, this.cover);
}

class _HomePageState extends State<HomePage> {
  bool _loaded = false;
  String _query = '';
  List<DownloadItem> _records = [];
  Map<String, int> _sizes = {}; // 文件路径 -> 字节数
  int? _freeBytes; // 设备剩余空间（df 取不到则为 null）
  String? _pendingId; // 通知点击后要自动打开预览的作品 id

  @override
  void initState() {
    super.initState();
    widget.refreshSignal?.addListener(_onSignal);
    widget.pendingPreview?.addListener(_onPending);
    _load();
  }

  void _onSignal() {
    if (mounted) _load();
  }

  void _onPending() {
    final id = widget.pendingPreview?.value;
    if (id == null) return;
    widget.pendingPreview!.value = null;
    _pendingId = id;
    if (_loaded) _tryOpenPending();
  }

  void _tryOpenPending() {
    final id = _pendingId;
    if (id == null || !mounted) return;
    for (final g in _allGroups()) {
      if (g.id == id) {
        _pendingId = null;
        _preview(g);
        return;
      }
    }
    // 列表里还没这个作品（极端情况）就清掉，避免反复弹
    _pendingId = null;
  }

  @override
  void dispose() {
    widget.refreshSignal?.removeListener(_onSignal);
    widget.pendingPreview?.removeListener(_onPending);
    super.dispose();
  }

  Future<void> _load() async {
    // 1) 读取下载记录（优先，确保列表/空态不依赖下面的磁盘查询）
    //    force: 通知上的「后台下载」在另一个 isolate 里写数据，
    //    回 App 时强制刷新，刚下好的作品才会立刻出现在列表里。
    try {
      await Store.instance.init(force: true);
    } catch (_) {}
    final records = Store.instance.items.toList();

    // 2) 统计每个文件大小（缺失文件计 0）
    final sizes = <String, int>{};
    for (final r in records) {
      for (final p in r.paths) {
        if (sizes.containsKey(p)) continue;
        try {
          sizes[p] = File(p).lengthSync();
        } catch (_) {
          sizes[p] = 0;
        }
      }
    }
    if (mounted) {
      setState(() {
        _records = records;
        _sizes = sizes;
        _loaded = true; // 先让列表/空态出来，不阻塞在磁盘查询上
      });
      _tryOpenPending();
    }

    // 3) 剩余空间（失败静默降级为只显示已使用，绝不阻塞列表）
    int? free;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final res = await Process.run('df', ['-k', dir.path]);
      if (res.exitCode == 0) {
        final lines = res.stdout.toString().trim().split('\n');
        if (lines.length >= 2) {
          final parts = lines.last.split(RegExp(r'\s+'));
          if (parts.length >= 4) {
            final kb = int.tryParse(parts[parts.length - 3]);
            if (kb != null) free = kb * 1024;
          }
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _freeBytes = free);
  }

  /// 所有作品归组（不做搜索过滤），供「通知点击自动预览」查找
  List<_Group> _allGroups() {
    final map = <String, _Group>{};
    for (final r in _records) {
      final g = map.putIfAbsent(r.id,
          () => _Group(r.id, r.title, r.type, r.coverPath, r.cover));
      for (final p in r.paths) {
        if (!g.paths.contains(p)) g.paths.add(p);
      }
    }
    return map.values.toList();
  }

  List<_Group> _grouped() {
    final groups = _allGroups();
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return groups;
    return groups.where((g) => g.title.toLowerCase().contains(q)).toList();
  }

  int _groupSize(_Group g) =>
      g.paths.fold(0, (s, p) => s + (_sizes[p] ?? 0));

  Future<void> _delete(_Group g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除缓存'),
        content: Text('删除「${g.title}」？\n将同时删除本机文件（相册副本不受影响）。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    final targets = [...g.paths, if (g.coverPath != null) g.coverPath!];
    for (final p in targets) {
      try {
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    await Store.instance.removeItem(g.id);
    _load();
  }

  void _preview(_Group g) {
    if (g.paths.isEmpty) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(g.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: double.maxFinite,
          child: g.type == 'image'
              ? SizedBox(
                  height: 360,
                  child: ListView(
                    children: [
                      for (final p in g.paths)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Image.file(File(p),
                              errorBuilder: (_, __, ___) => const SizedBox(
                                  height: 60,
                                  child: Center(child: Text('图片已删除')))),
                        ),
                    ],
                  ),
                )
              : VideoPreview(g.paths.first),
        ),
        actions: [
          if (g.type != 'image')
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                OpenFilex.open(g.paths.first);
              },
              child: const Text('用系统播放器打开'),
            ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _delete(g);
            },
            child: const Text('删除'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 缩略图：16:9、圆角 6；仅在多文件（图文/多P）时右下角显示数量角标，
  /// 比例与排布对齐 B站「离线缓存」列表。
  Widget _thumb(_Group g) {
    Widget img;
    if (g.coverPath != null) {
      img = Image.file(File(g.coverPath!),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _thumbPlaceholder());
    } else if (g.cover != null) {
      img = Image.network(g.cover!,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _thumbPlaceholder());
    } else {
      img = _thumbPlaceholder();
    }
    return SizedBox(
      width: 138,
      height: 78,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFFF2F2F4)),
            img,
            if (g.paths.length > 1)
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.filter_none,
                          size: 10, color: Colors.white),
                      const SizedBox(width: 2),
                      Text('${g.paths.length}',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 10)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _thumbPlaceholder() => const ColoredBox(
        color: Color(0xFFF2F2F4),
        child: Center(
          child: Icon(Icons.play_circle_outline,
              size: 26, color: Color(0x33000000)),
        ),
      );

  /// 列表行：左缩略图 + 右标题/容量。点开预览，**长按删除**（B站同款操作，
  /// 列表里不再挂删除按钮，让右侧留白更干净）。
  Widget _row(_Group g) {
    return InkWell(
      onTap: () => _preview(g),
      onLongPress: () => _delete(g),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _thumb(g),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    g.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15,
                        height: 1.3,
                        fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${_fmt(_groupSize(g))}'
                    '${g.paths.length > 1 ? ' · ${g.paths.length} 个文件' : ''}',
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF9A9AA0)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _listHeader() => const Padding(
        padding: EdgeInsets.fromLTRB(12, 14, 12, 4),
        child: Text('已缓存视频',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
      );

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 搜索：浅灰圆角胶囊，弱化存在感，把视觉重心让给列表（B站离线缓存也是这个调性）
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFF4F4F6),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                const SizedBox(width: 12),
                const Icon(Icons.search, size: 18, color: Color(0xFF9A9AA0)),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: '搜索已缓存的作品',
                      hintStyle:
                          TextStyle(fontSize: 13, color: Color(0xFF9A9AA0)),
                    ),
                    style: const TextStyle(fontSize: 13),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
        Expanded(child: _douyinBody()),
      ],
    );
  }

  // —— 抖音：本 App 的下载缓存（平铺列表，无卡片/无阴影，仿 B站「离线缓存」） ——
  Widget _douyinBody() {
    final groups = _grouped();
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    if (groups.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_outlined, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 8),
            Text(
              _query.isEmpty
                  ? '还没有下载记录\n去「抖音」页下载第一个作品吧'
                  : '没有匹配「$_query」的结果',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF9A9AA0), fontSize: 13),
            ),
          ],
        ),
      );
    }
    final used = groups.fold<int>(0, (s, g) => s + _groupSize(g));
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _listHeader(),
        for (final g in groups) _row(g),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(
            '已使用 ${_fmt(used)}'
            '${_freeBytes != null ? '  /  剩余 ${_fmt(_freeBytes!)}' : ''}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Color(0xFF9A9AA0)),
          ),
        ),
      ],
    );
  }
}
