import 'dart:convert';

import 'package:shizuku_api/shizuku_api.dart';

import 'bili_cache.dart';

/// 通过 Shizuku（shell 权限）读取 /Android/data 下 B站缓存。
///
/// 普通 App 即使在 Android 11+ 上拿到 MANAGE_EXTERNAL_STORAGE，部分 ROM
/// （小米等）仍会拒绝访问 /sdcard/Android/data，报 errno 13。Shizuku 以
/// adb shell(uid 2000) 身份执行命令，能读该目录，是更稳的方案。
///
/// 使用前需 Shizuku App 已安装并运行，且本 App 已被 Shizuku 授权
/// （[requestAuth] 触发系统对话框）。
class ShizukuBili {
  static final ShizukuApi _api = ShizukuApi();

  static const String root =
      '/storage/emulated/0/Android/data/tv.danmaku.bili/download';

  /// Shizuku 服务是否在线（App 已安装并启动、且本 App 已配对）
  static Future<bool> get available async {
    try {
      return await _api.pingBinder() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 本 App 是否已被 Shizuku 授权
  static Future<bool> get authorized async {
    try {
      return await _api.checkPermission() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 请求 Shizuku 授权（弹出系统对话框），返回是否授予
  static Future<bool> requestAuth() async {
    try {
      return await _api.requestPermission() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 执行一条 shell 命令，返回 stdout 文本；任何失败返回 null
  static Future<String?> _shell(String cmd) async {
    try {
      // runCommand 的返回类型在不同版本里可能是 String? 或 void，
      // 用 dynamic 兜底，确保编译期安全。
      final dynamic out = await _api.runCommand(cmd);
      return out?.toString();
    } catch (_) {
      return null;
    }
  }

  /// 扫描全部 B站缓存条目（经 Shizuku shell 读取 entry.json）。
  /// 失败/为空时返回空列表。
  static Future<List<BiliEntry>> scan() async {
    final out = <BiliEntry>[];
    final ls = await _shell('ls -1 "$root"');
    if (ls == null) return out;
    final tops = ls
        .split('\n')
        .where((e) => e.trim().isNotEmpty)
        .map((e) => e.trim())
        .toList();
    for (final top in tops) {
      // 在该顶层目录下找 entry.json（最多 3 层）
      final find = await _shell(
          'find "$root/$top" -maxdepth 3 -name entry.json');
      if (find == null) continue;
      final ejPaths = find
          .split('\n')
          .where((e) => e.trim().isNotEmpty)
          .toList();
      for (final ej in ejPaths) {
        final cat = await _shell('cat "$ej"');
        if (cat == null) continue;
        final entry = _parseEntryJson(cat, ej, '$root/$top');
        if (entry != null) out.add(entry);
      }
    }
    out.sort((a, b) => b.bytes.compareTo(a.bytes));
    return out;
  }

  /// 删除一条缓存（shell rm -rf 其顶层目录）
  static Future<bool> remove(BiliEntry e) async {
    final r = await _shell('rm -rf "${e.topLevelDir}"');
    return r != null;
  }

  /// 复用 bili_cache 的解析逻辑（从 JSON 文本提取 title/cover/total_bytes）。
  /// videoPath 在 Shizuku 路径下暂不可直接读（在 /Android/data 内），
  /// 留空，预览时展示提示；后续可经 Shizuku cp 到 App 私有目录再播。
  static BiliEntry? _parseEntryJson(
      String text, String entryJsonPath, String topLevel) {
    try {
      final j = jsonDecode(text);
      if (j is! Map) return null;
      final page = j['page_data'];
      final title = (j['title'] ??
              (page is Map ? page['part'] : null) ??
              '未知标题')
          .toString();
      final bytes = (j['total_bytes'] is int)
          ? j['total_bytes'] as int
          : int.tryParse('${j['total_bytes']}') ?? 0;
      final dir = entryJsonPath.substring(
          0, entryJsonPath.length - 'entry.json'.length);
      return BiliEntry(
        entryDir: dir,
        topLevelDir: topLevel,
        title: title,
        cover: j['cover']?.toString(),
        bytes: bytes,
        videoPath: null,
      );
    } catch (_) {
      return null;
    }
  }
}
