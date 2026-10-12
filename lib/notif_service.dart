import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 全局唯一的通知插件实例与点击处理器。
/// 所有页面共用它，避免多个实例互相覆盖 onDidReceiveNotificationResponse 回调。
final FlutterLocalNotificationsPlugin appNotif =
    FlutterLocalNotificationsPlugin();

/// 通知被点击后的回调（payload 为下载作品的 id；其它通知为 null）。
/// 由 main 设置为「跳到首页 + 打开预览」。
void Function(String? payload)? onNotifTap;

Future<void> initAppNotif() async {
  await appNotif.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveNotificationResponse: (resp) => onNotifTap?.call(resp.payload),
  );
  // 下载进度/结果通道（常驻进度条用，低优先级不吵）
  await appNotif
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(const AndroidNotificationChannel(
        'download_channel',
        '下载进度',
        description: '抖音下载进度与结果通知',
        importance: Importance.low,
      ));
  // 剪贴板横幅提醒通道：importance max → 在 Android 8+ 上以「横幅」
  // 形式悬浮弹出（即使 App 在前台），即用户要的小米那种顶部横幅效果。
  await appNotif
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(const AndroidNotificationChannel(
        'heads_up_channel',
        '剪贴板提醒',
        description: '检测到抖音链接时的横幅提醒，点击立即下载',
        importance: Importance.max,
      ));
}

/// 发一条 heads-up 横幅通知（仿抖音顶部横幅：App 大图标 + 展开正文 + 「立即下载」按钮）。
/// 点通知本体或点按钮都会走 onNotifTap（payload 建议带 'clip:<链接>' 前缀）。
Future<void> showHeadsUp(String title, String body,
    {String? payload}) async {
  try {
    await appNotif.show(
      9001, // 固定 id：同链接新横幅覆盖旧的，不堆积
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'heads_up_channel',
          '剪贴板提醒',
          channelDescription: '检测到抖音链接时的横幅提醒，点击立即下载',
          importance: Importance.max,
          priority: Priority.high,
          // 横幅右侧显示 App 图标（仿抖音横幅样式）
          largeIcon: const DrawableResourceAndroidBitmap('ic_launcher'),
          // 链接较长时下拉展开显示全文
          styleInformation: BigTextStyleInformation(body),
          // 横幅上的「立即下载」按钮，点击后自动收起通知
          actions: const [
            AndroidNotificationAction('download_now', '立即下载',
                cancelNotification: true),
          ],
        ),
      ),
      payload: payload,
    );
  } catch (_) {
    // 通知权限未授予等场景静默失败
  }
}

/// 剪贴板横幅专用封装：把「即将下载的链接」显示出来（若已解析出视频标题
/// 则把标题作为通知标题），点了「立即下载」才真正开始下载。固定 id 9001，
/// 同一条链接新横幅会覆盖旧横幅，不堆积。
Future<void> showLinkHeadsUp(String link, {String? title}) async {
  final display = link.length > 90 ? '${link.substring(0, 90)}…' : link;
  final body = '即将下载：\n$display\n\n点击「立即下载」开始';
  await showHeadsUp(title ?? '检测到抖音链接', body, payload: 'clip:$link');
}
