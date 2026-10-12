import 'dart:convert';
import 'dart:io';

/// B站客户端的一条离线缓存记录（从 entry.json 解析）。
class BiliEntry {
  /// entry.json 所在目录（清晰度目录的上一级）
  final String entryDir;

  /// 该条目所属的 download 下第一层目录（删除时用）
  final String topLevelDir;

  final String title;
  final String? cover; // 远程封面（hdslb.com，可直接加载）
  final int bytes;
  final String? videoPath; // video.m4s 路径（fMP4，可直接播）

  BiliEntry({
    required this.entryDir,
    required this.topLevelDir,
    required this.title,
    this.cover,
    required this.bytes,
    this.videoPath,
  });
}

/// 扫描 B站 App 的离线缓存目录：
/// /storage/emulated/0/Android/data/tv.danmaku.bili/download/
/// 结构（各版本略有差异，递归找 entry.json 兜底）：
///   download/<av号|s_剧集>[/<分P或c_cid>]/<清晰度>/{video.m4s, audio.m4s, entry.json}
class BiliCache {
  static const String rootPath =
      '/storage/emulated/0/Android/data/tv.danmaku.bili/download';

  /// 目录是否存在（未安装B站/未缓存过/无权限都会为 false）
  static Future<bool> exists() async {
    try {
      return await Directory(rootPath).exists();
    } catch (_) {
      return false;
    }
  }

  /// 最近一次 scan() 失败/为空的原因（用于界面诊断显示）
  static String? lastError;

  /// 扫描全部缓存条目。失败原因记录在 [lastError] 供界面展示。
  static Future<List<BiliEntry>> scan() async {
    final out = <BiliEntry>[];
    lastError = null;
    final root = Directory(rootPath);
    try {
      bool exists;
      try {
        exists = await root.exists();
      } catch (e) {
        lastError = '访问目录失败: $e';
        return out;
      }
      if (!exists) {
        lastError = '缓存目录不存在（B站可能从未缓存过视频，或B站版本改了路径）';
        return out;
      }
      List<FileSystemEntity> top;
      try {
        top = root.listSync(followLinks: false);
      } catch (e) {
        lastError = '列目录失败（权限可能未真正生效）: $e';
        return out;
      }
      for (final av in top) {
        if (av is! Directory) continue;
        final topLevel = av.path;
        // 在该顶层目录下递归找 entry.json（深度限制 3，防卡死）
        final entryFiles = <File>[];
        _walk(av, 0, entryFiles);
        for (final ej in entryFiles) {
          final e = _parseEntry(ej, topLevel);
          if (e != null) out.add(e);
        }
      }
      if (out.isEmpty && lastError == null) {
        lastError = '目录存在但没扫到任何 entry.json（共 ${top.length} 项，B站缓存结构可能变动）';
      }
    } catch (e) {
      lastError = '扫描失败: $e';
    }
    out.sort((a, b) => b.bytes.compareTo(a.bytes));
    return out;
  }

  static void _walk(Directory dir, int depth, List<File> out) {
    if (depth > 3) return;
    List<FileSystemEntity> items;
    try {
      items = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final e in items) {
      if (e is File && e.path.endsWith('entry.json')) {
        out.add(e);
      } else if (e is Directory) {
        _walk(e, depth + 1, out);
      }
    }
  }

  static BiliEntry? _parseEntry(File entryJson, String topLevel) {
    try {
      final text = entryJson.readAsStringSync();
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
      // 在 entry.json 同级目录里找 video.m4s（可能按清晰度分子目录）
      String? video;
      final parent = entryJson.parent;
      try {
        for (final sub in parent.listSync(followLinks: false)) {
          if (sub is Directory) {
            final v = File('${sub.path}/video.m4s');
            if (v.existsSync()) {
              video = v.path;
              break;
            }
          } else if (sub is File && sub.path.endsWith('video.m4s')) {
            video = sub.path;
            break;
          }
        }
      } catch (_) {}
      return BiliEntry(
        entryDir: parent.path,
        topLevelDir: topLevel,
        title: title,
        cover: j['cover']?.toString(),
        bytes: bytes,
        videoPath: video,
      );
    } catch (_) {
      return null;
    }
  }

  /// 删除一条缓存（连同其顶层目录一起删，B站客户端里也会同步消失）
  static Future<bool> remove(BiliEntry e) async {
    try {
      final d = Directory(e.topLevelDir);
      if (await d.exists()) {
        await d.delete(recursive: true);
        return true;
      }
    } catch (_) {}
    return false;
  }
}
