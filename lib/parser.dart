import 'models.dart';

/// 把后端 /douyin/detail 返回的 data 解析成「标题 + 类型 + 媒体任务列表」。
///
/// 注意：DouK-Downloader 不同版本返回字段名可能不同，这里做防御式解析——
/// 同时尝试多个常见字段名，并对嵌套结构做深度搜索，尽量不漏。
/// 拿到真实响应后如需微调字段名，改这里即可。
class ParsedDetail {
  final String title;
  final String type; // 'video' | 'image'
  final List<MediaTask> tasks;
  final String? cover; // 封面图远程地址（static_cover 优先，其次 dynamic_cover）

  ParsedDetail(this.title, this.type, this.tasks, [this.cover]);
}

/// 取一个 http 字符串（用于封面字段）
String? _asStr(dynamic v) =>
    v is String && v.startsWith('http') ? v : null;

String sanitize(String s) {
  final cleaned = s
      .replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]+'), '_')
      .trim()
      .replaceAll(RegExp(r'\s+'), '_');
  return cleaned.isEmpty ? 'douyin' : cleaned;
}

List<String> _collectUrls(dynamic v) {
  final out = <String>[];
  if (v is String && v.startsWith('http')) out.add(v);
  if (v is List) {
    for (final e in v) {
      if (e is String && e.startsWith('http')) {
        out.add(e);
      } else if (e is Map) {
        final u = _urlFromMap(e);
        if (u != null) out.add(u);
      }
    }
  } else if (v is Map) {
    final u = _urlFromMap(v);
    if (u != null) out.add(u);
  }
  return out;
}

String? _urlFromMap(Map m) {
  for (final k in ['url', 'src', 'play_addr', 'play_url', 'video_url']) {
    final v = m[k];
    if (v is String && v.startsWith('http')) return v;
    if (v is Map) {
      final inner = _urlFromMap(v);
      if (inner != null) return inner;
    }
  }
  return null;
}

/// 深度搜索：在任意嵌套 map/list 中找出所有 http(s) 字符串 URL
List<String> _deepUrls(dynamic node, {List<String>? acc}) {
  final out = acc ?? <String>[];
  if (node is String && node.startsWith('http')) {
    out.add(node);
  } else if (node is List) {
    for (final e in node) _deepUrls(e, acc: out);
  } else if (node is Map) {
    for (final e in node.values) _deepUrls(e, acc: out);
  }
  return out;
}

/// 深度搜索：返回第一个「键名含 [keys] 之一」且值为 http 字符串的 URL
/// 用动态 Map 以兼容后端返回中嵌套的 Map<dynamic, dynamic>
String? _deepFirstUrlByKey(Map node, List<String> keys) {
  for (final entry in node.entries) {
    if (entry.key is String &&
        keys.any((k) => (entry.key as String).toLowerCase().contains(k))) {
      final v = entry.value;
      if (v is String && v.startsWith('http')) return v;
      if (v is Map) {
        final u = _urlFromMap(v);
        if (u != null) return u;
      }
    }
  }
  // 递归
  for (final entry in node.entries) {
    final v = entry.value;
    if (v is Map) {
      final found = _deepFirstUrlByKey(v, keys);
      if (found != null) return found;
    } else if (v is List) {
      for (final e in v) {
        if (e is Map) {
          final found = _deepFirstUrlByKey(e, keys);
          if (found != null) return found;
        }
      }
    }
  }
  return null;
}

/// 深度搜索：返回所有「键名含 [keys] 之一」的 list 内 URL
List<String> _deepUrlsByKey(Map node, List<String> keys) {
  final out = <String>[];
  for (final entry in node.entries) {
    if (entry.key is String &&
        keys.any((k) => (entry.key as String).toLowerCase().contains(k))) {
      out.addAll(_collectUrls(entry.value));
    }
  }
  for (final entry in node.entries) {
    final v = entry.value;
    if (v is Map) {
      out.addAll(_deepUrlsByKey(v, keys));
    } else if (v is List) {
      for (final e in v) {
        if (e is Map) out.addAll(_deepUrlsByKey(e, keys));
      }
    }
  }
  return out;
}

/// 取一个 http 字符串 URL；兼容「字符串 / 列表 / 嵌套 map」三种形态
String? _asUrl(dynamic v) {
  if (v is String && v.startsWith('http')) return v;
  if (v is List) {
    for (final e in v) {
      if (e is String && e.startsWith('http')) return e;
      if (e is Map) {
        final u = _urlFromMap(e);
        if (u != null) return u;
      }
    }
  }
  if (v is Map) return _urlFromMap(v);
  return null;
}

/// 深度搜索图片 CDN 链接（douyinpic / douyinstatic / 图片扩展名）
List<String> _deepImageUrls(dynamic node) {
  final out = <String>[];
  void walk(dynamic n) {
    if (n is String) {
      final s = n.toLowerCase();
      if (s.startsWith('http') &&
          (n.contains('douyinpic') ||
              n.contains('douyinstatic') ||
              s.endsWith('.jpg') ||
              s.endsWith('.png') ||
              s.endsWith('.webp'))) {
        out.add(n);
      }
    } else if (n is List) {
      for (final e in n) walk(e);
    } else if (n is Map) {
      for (final e in n.values) walk(e);
    }
  }

  walk(node);
  return out;
}

ParsedDetail parseDetail(Map<String, dynamic> data, String detailId) {
  // 标题
  final rawTitle =
      data['desc'] ?? data['title'] ?? data['aweme_title'] ?? data['aweme_desc'];
  final title = sanitize((rawTitle ?? '抖音_$detailId').toString());

  // 视频直链：DouK-Downloader 真实字段是 downloads（也可能是列表/嵌套）
  String? videoUrl = _asUrl(data['downloads']);
  if (videoUrl == null) {
    for (final key in [
      'video_url',
      'video_play_url',
      'video_play_addr',
      'play_addr',
      'play_url',
      'videoUrl',
      'url'
    ]) {
      final u = _asUrl(data[key]);
      if (u != null) {
        videoUrl = u;
        break;
      }
    }
  }
  if (videoUrl == null) {
    videoUrl = _deepFirstUrlByKey(data, ['video', 'play', 'download']);
  }

  // 图文（图片列表）
  final imgUrls = <String>[];
  for (final key in [
    'images',
    'img_list',
    'image_list',
    'imgUrls',
    'img_urls',
    'image_urls'
  ]) {
    imgUrls.addAll(_collectUrls(data[key]));
  }
  if (imgUrls.isEmpty) imgUrls.addAll(_deepImageUrls(data));

  // 封面：DouK-Downloader 直接返回 static_cover / dynamic_cover 字段
  final cover = _asStr(data['static_cover']) ?? _asStr(data['dynamic_cover']);

  // 后端用中文标注类型：视频 / 图文
  final typeRaw = (data['type'] ?? '').toString();
  final isImage = typeRaw.contains('图');

  if (isImage && imgUrls.isNotEmpty) {
    final tasks = imgUrls.asMap().entries.map((e) {
      final idx = e.key + 1;
      return MediaTask(e.value, '${title}_$idx.jpg', 'image');
    }).toList();
    return ParsedDetail(title, 'image', tasks, cover);
  }
  if (videoUrl != null) {
    return ParsedDetail(
        title, 'video', [MediaTask(videoUrl, '$title.mp4', 'video')], cover);
  }
  if (imgUrls.isNotEmpty) {
    final tasks = imgUrls.asMap().entries.map((e) {
      final idx = e.key + 1;
      return MediaTask(e.value, '${title}_$idx.jpg', 'image');
    }).toList();
    return ParsedDetail(title, 'image', tasks, cover);
  }
  throw Exception('未能从返回数据中解析出视频或图片链接');
}
