import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'api_client.dart';
import 'bg_log.dart';
import 'download_service.dart';
import 'models.dart';
import 'notif_service.dart';
import 'parser.dart';
import 'store.dart';

/// 通知上的「后台下载」按钮走这里：**不把 App 拉到前台**，直接在后台
/// isolate 里把「解析 → 取数据 → 下载 → 存相册 → 写入本地列表」跑完。
///
/// 为什么能这么干：这条路径用的是通知动作的「后台广播」通道（
/// `showsUserInterface: false`），系统只启动一个后台 isolate，不会显示界面。
/// 入口见 [notif_service.backgroundActionEntry]（它负责 binding + 插件注册）。
///
/// 每一步都通过 [bgLog] 落盘，失败时「测试」页能看到具体卡在哪一步。
Future<void> runBackgroundDownload(String link) async {
  const album = '抖音下载';
  try {
    await bgLog('开始后台下载: $link');
    await _notify('正在后台下载…', _short(link), id: 200, alert: false);

    await Store.instance.init(force: true);
    final cookie = Store.instance.cookie;
    await bgLog('本地记录已加载，cookie ${cookie.isEmpty ? '为空' : '已就绪(长度 ${cookie.length})'}');

    final url = await resolveShare(link);
    await bgLog('短链解析完成: $url');
    final id = extractDetailId(url);
    if (id == null) throw Exception('无法从链接提取作品ID：$url');

    final data = await fetchDetail(id, cookie);
    final parsed = parseDetail(data, id);
    await bgLog('取到数据: type=${parsed.type} 任务数=${parsed.tasks.length} '
        '标题=${parsed.title}');

    // quiet: 后台不维护进度条，避免后台 isolate 里的通知调用异常打断下载
    final svc = DownloadService(appNotif, quiet: true);
    final paths = await svc.download(
      tasks: parsed.tasks,
      onProgress: (_, __) {},
      album: album,
      onLog: (msg) => bgLog('  · $msg'),
      cookie: cookie,
    );
    await bgLog('下载完成，文件 ${paths.length} 个: $paths');

    String? coverPath;
    if (parsed.cover != null) {
      coverPath = await svc.downloadCover(parsed.cover!, cookie, (_) {});
      await bgLog('封面: ${coverPath ?? '下载失败（不影响正片）'}');
    }

    await Store.instance.addItem(DownloadItem(
      id: id,
      title: parsed.title,
      type: parsed.type,
      paths: paths,
      time: DateTime.now().millisecondsSinceEpoch,
      coverPath: coverPath,
      cover: parsed.cover,
    ));
    await bgLog('已写入本地列表，标题: ${parsed.title}');
    await _notify('后台下载完成', '${parsed.title}\n已保存到相册「$album」', id: 200);
  } catch (e, st) {
    await bgLog('后台下载失败: $e\n$st');
    await _notify('后台下载失败', '$e', id: 200);
  }
}

String _short(String s) => s.length <= 60 ? s : '${s.substring(0, 60)}…';

/// 后台 isolate 里发通知是「尽力而为」：
/// 显式给 icon，避免依赖 initialize 里保存的默认图标；任何失败都只记日志，
/// 绝不能因为一条通知发不出去就把下载流程带崩。
Future<void> _notify(String title, String body,
    {required int id, bool alert = true}) async {
  final channelId = alert ? kChannelResult : kChannelProgress;
  final channelName = alert ? '下载结果' : '下载进度';
  try {
    await appNotif.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: alert ? '下载成功/失败与 Cookie 测试结果' : '下载进度的常驻进度条（静默）',
          importance: alert ? Importance.high : Importance.low,
          priority: alert ? Priority.high : Priority.low,
          icon: '@mipmap/ic_launcher',
        ),
      ),
    );
    await bgLog('通知已发送: $title');
  } catch (e) {
    await bgLog('通知发送失败(带 icon): $e');
    // 退一步：不带 icon 再试一次（有些 ROM 对 @mipmap 形式解析不了）
    try {
      await appNotif.show(
        id,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(channelId, channelName,
              importance: alert ? Importance.high : Importance.low,
              priority: alert ? Priority.high : Priority.low),
        ),
      );
      await bgLog('通知已发送(无 icon 兜底): $title');
    } catch (e2) {
      await bgLog('通知彻底发不出去: $e2');
    }
  }
}
