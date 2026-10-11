import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'models.dart';

/// 下载服务：流式下载（带进度） -> 存入系统相册（gal）-> 同时在本机私有目录留一份副本供列表/播放
class DownloadService {
  static const String channelId = 'download_channel';
  static const String channelName = '下载进度';
  static const int notifId = 100;

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

  /// 下载一批媒体。onProgress 回调整体进度 0..1。
  /// 返回本机私有目录下的文件路径列表（供「本地列表页」直接打开/播放）。
  Future<List<String>> download({
    required List<MediaTask> tasks,
    required void Function(double p, String label) onProgress,
    required String album,
  }) async {
    final extDir = await getExternalStorageDirectory();
    final saveDir = Directory('${extDir!.path}/抖音');
    await saveDir.create(recursive: true);

    // 相册写入权限（安卓 13+ 会弹系统授权框）
    try {
      await Gal.requestAccess(toAlbum: true);
    } catch (_) {
      // 相册授权失败不阻断本地下载
    }

    final results = <String>[];
    int done = 0;
    for (final t in tasks) {
      final localPath = '${saveDir.path}/${t.fileName}';
      await _downloadOne(t.url, localPath, (p) {
        final overall = (done + p) / tasks.length;
        onProgress(overall, '下载中 (${done + 1}/${tasks.length})');
        _showProgress(overall, '下载中 (${done + 1}/${tasks.length})');
      });

      // 存进系统相册（文件管理器/相册可见）
      try {
        if (t.kind == 'video') {
          await Gal.putVideo(localPath, album: album);
        } else {
          await Gal.putImage(localPath, album: album);
        }
      } catch (_) {
        // 相册写入失败不影响本机副本
      }

      results.add(localPath);
      done++;
      onProgress(done / tasks.length, '已完成 $done/${tasks.length}');
    }

    await notif.show(
      notifId,
      '下载完成',
      '已保存 ${results.length} 个文件',
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          importance: Importance.high,
          progress: 100,
          maxProgress: 100,
          showProgress: false,
        ),
      ),
    );
    return results;
  }

  Future<void> _downloadOne(
      String url, String path, void Function(double) onP) async {
    final request = http.Request('GET', Uri.parse(url));
    final response = await http.Client().send(request);
    final total = response.contentLength ?? 0;
    final file = File(path);
    final sink = file.openWrite();
    int received = 0;
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
  }

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
