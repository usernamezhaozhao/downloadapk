import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'models.dart';

/// 下载服务：流式下载（带进度） -> 存入系统相册（gal）-> 同时在本机私有目录留一份副本供列表/播放
///
/// 关键修复（播放 bug）：抖音 `downloads` 直链是 `aweme/v1/play/` 接口，
/// 必须带 `Referer` + 浏览器 `User-Agent`（通常还要 `Cookie`），否则：
///   - 无 Referer -> 403（HTML 错误页）
///   - 无 Cookie  -> 404
/// 之前用裸 GET 把 403 的 HTML 当 .mp4 存了，所以「下载完成却播不了」。
/// 现在：① 补请求头；② 落盘前校验 HTTP 200 且非 HTML/JSON；③ 文件头魔数二次校验。
class DownloadService {
  static const String channelId = 'download_channel';
  static const String channelName = '下载进度';
  static const int notifId = 100;

  static const String _ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  final FlutterLocalNotificationsPlugin notif;
  DownloadService(this.notif);

  Future<void> init() async {
    await notif
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          channelId,
          channelName,
          description: '抖音下载进度与结果通知',
          importance: Importance.low,
        ));
  }

  /// 下载一批媒体。onProgress 回调整体进度 0..1，onLog 回传调试信息。
  /// cookie 透传给抖音 CDN（部分视频需要登录态 Cookie 才放流）。
  /// 返回本机私有目录下的文件路径列表（供「本地列表页」直接打开/播放）。
  Future<List<String>> download({
    required List<MediaTask> tasks,
    required void Function(double p, String label) onProgress,
    required String album,
    required void Function(String) onLog,
    String cookie = '',
  }) async {
    final extDir = await getExternalStorageDirectory();
    final saveDir = Directory('${extDir!.path}/抖音');
    await saveDir.create(recursive: true);

    // 相册写入权限（安卓 13+ 会弹系统授权框）
    try {
      await Gal.requestAccess(toAlbum: true);
    } catch (_) {
      onLog('相册授权失败（不影响本地下载）');
    }

    final results = <String>[];
    int done = 0;
    for (final t in tasks) {
      final localPath = '${saveDir.path}/${t.fileName}';
      onLog('开始下载: ${t.kind} -> $localPath');
      final r = await _downloadOne(t.url, localPath, cookie, (p) {
        final overall = (done + p) / tasks.length;
        onProgress(overall, '下载中 (${done + 1}/${tasks.length})');
        _showProgress(overall, '下载中 (${done + 1}/${tasks.length})');
      }, onLog);

      onLog('落盘校验: HTTP ${r.status} · Content-Type=${r.contentType} · '
          '大小=${r.bytesWritten}B · 文件头=${r.magic}');
      if (!r.ok) {
        // 二次保险：即便前面没拦住，存下来的若不是媒体也直接报错
        final f = File(localPath);
        if (await f.exists()) await f.delete();
        throw Exception('下载到的不是有效媒体文件（${r.magic}），已删除临时文件。'
            '调试：${r.status} / ${r.contentType}');
      }

      // 存进系统相册（文件管理器/相册可见）
      try {
        if (t.kind == 'video') {
          await Gal.putVideo(localPath, album: album);
        } else {
          await Gal.putImage(localPath, album: album);
        }
      } catch (_) {
        onLog('相册写入失败（不影响本机副本）');
      }

      results.add(localPath);
      done++;
      onProgress(done / tasks.length, '已完成 $done/${tasks.length}');
    }

    // 下载完成：取消「进行中」的常驻进度通知，成功/失败通知由调用方（抖音页）统一发出并携带 payload
    try {
      await notif.cancel(notifId);
    } catch (_) {}

    return results;
  }

  /// 下载封面图（与媒体同样的请求头逻辑：Referer + UA + Cookie）。
  /// 成功返回本地路径，失败（非图片/网络错误）返回 null 并清理临时文件。
  Future<String?> downloadCover(
    String url,
    String cookie,
    void Function(String) onLog,
  ) async {
    final extDir = await getExternalStorageDirectory();
    final saveDir = Directory('${extDir!.path}/抖音');
    await saveDir.create(recursive: true);
    final name = 'cover_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final path = '${saveDir.path}/$name';
    onLog('开始下载封面: $url');
    final r = await _downloadOne(url, path, cookie, (_) {}, onLog);
    onLog('封面落盘校验: HTTP ${r.status} · ${r.contentType} · ${r.magic}');
    if (!r.ok) {
      final f = File(path);
      if (await f.exists()) await f.delete();
      onLog('封面不是有效图片，已跳过');
      return null;
    }
    return path;
  }

  /// 返回的单条下载结果（用于调试日志）
  _DlResult _result({
    required int status,
    required String contentType,
    required int bytesWritten,
    required String magic,
    required bool ok,
  }) =>
      _DlResult(status, contentType, bytesWritten, magic, ok);

  Future<_DlResult> _downloadOne(
    String url,
    String path,
    String cookie,
    void Function(double) onP,
    void Function(String) log,
  ) async {
    final headers = <String, String>{
      'User-Agent': _ua,
      'Referer': 'https://www.douyin.com/',
    };
    if (cookie.isNotEmpty) headers['Cookie'] = cookie;

    final request = http.Request('GET', Uri.parse(url))..headers.addAll(headers);
    final response = await http.Client().send(request);

    final status = response.statusCode;
    final contentType =
        response.headers['content-type'] ?? '(无 content-type)';
    log('HTTP $status · Content-Type=$contentType · '
        'Content-Length=${response.contentLength}');

    // ① 非 200 直接报错（含 403/404），不落盘
    if (status != 200) {
      final head = await _readSnippet(response.stream);
      log('非 200 响应体片段: ${head.replaceAll('\n', ' ').trim().take(160)}');
      return _result(
          status: status,
          contentType: contentType,
          bytesWritten: 0,
          magic: 'ERR',
          ok: false);
    }
    // ② Content-Type 明显是错误页/JSON 也不落盘
    if (contentType.toLowerCase().contains('text/html') ||
        contentType.toLowerCase().contains('application/json')) {
      final head = await _readSnippet(response.stream);
      log('返回疑似错误页: ${head.replaceAll('\n', ' ').trim().take(160)}');
      return _result(
          status: status,
          contentType: contentType,
          bytesWritten: 0,
          magic: 'HTML/JSON',
          ok: false);
    }

    // ③ 流式写入
    final file = File(path);
    final sink = file.openWrite();
    int received = 0;
    final total = response.contentLength ?? 0;
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      if (total > 0) {
        onP(received / total);
      } else {
        onP(0.5);
      }
    }
    await sink.close();

    // ④ 文件头魔数校验：mp4 / jpg / png / webp / mpeg-ts 才算媒体
    final magic = await _magic(path);
    final ok = _isMediaMagic(magic);
    return _result(
        status: status,
        contentType: contentType,
        bytesWritten: received,
        magic: magic,
        ok: ok);
  }

  /// 读取响应流前 ~300 字节作为错误诊断片段（不消费整个流以外的部分无影响）
  Future<String> _readSnippet(Stream<List<int>> stream) async {
    final buf = <int>[];
    await for (final c in stream) {
      buf.addAll(c);
      if (buf.length >= 300) break;
    }
    return String.fromCharCodes(buf.take(300));
  }

  /// 读取文件前若干字节，返回可读魔数描述
  Future<String> _magic(String path) async {
    try {
      final f = File(path);
      final bytes = await f.openRead(0, 16).first;
      if (bytes.isEmpty) return 'EMPTY';
      final hex = bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      // mp4: 前 4 字节是 box size，随后紧跟 'ftyp'（如 00 00 00 18 66 74 79 70）
      final head16 = String.fromCharCodes(bytes.take(16));
      if (head16.contains('ftyp')) return 'MP4($hex)';
      if (bytes.first == 0xFF && bytes.length > 1 && bytes[1] == 0xD8) {
        return 'JPG($hex)';
      }
      if (bytes.first == 0x89 &&
          bytes.length > 3 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47) {
        return 'PNG($hex)';
      }
      if (bytes.first == 0x47) return 'MPEG-TS($hex)';
      if (bytes.first == 0x3C) return 'HTML?($hex)';
      // WebP: "RIFF"...."WEBP"
      if (bytes.length >= 12 &&
          bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
          bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
        return 'WEBP($hex)';
      }
      return hex;
    } catch (_) {
      return 'READ_ERR';
    }
  }

  bool _isMediaMagic(String m) =>
      m.startsWith('MP4') ||
      m.startsWith('JPG') ||
      m.startsWith('PNG') ||
      m.startsWith('WEBP') ||
      m.startsWith('MPEG-TS');

  void _showProgress(double p, String title) {
    notif.show(
      notifId,
      title,
      '${(p * 100).toInt()}%',
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          importance: Importance.low,
          showProgress: true,
          maxProgress: 100,
          progress: (p * 100).toInt(),
          ongoing: true,
          onlyAlertOnce: true,
        ),
      ),
    );
  }
}

class _DlResult {
  final int status;
  final String contentType;
  final int bytesWritten;
  final String magic;
  final bool ok;
  _DlResult(this.status, this.contentType, this.bytesWritten, this.magic, this.ok);
}

extension _Take on String {
  String take(int n) => length <= n ? this : substring(0, n);
}
