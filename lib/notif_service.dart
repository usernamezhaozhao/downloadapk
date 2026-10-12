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

/// 发一条 heads-up 横幅通知（自动弹出悬浮显示，点按走 onNotifTap）。
/// [payload] 建议带 'clip:<链接>' 前缀以区分于下载成功跳转。
Future<void> showHeadsUp(String title, String body,
    {String? payload}) async {
  try {
    await appNotif.show(
      9001, // 固定 id：同链接新横幅覆盖旧的，不堆积
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'heads_up_channel',
          '剪贴板提醒',
          importance: Importance.max,
          priority: Priority.high,
        ),
      ),
      payload: payload,
    );
  } catch (_) {
    // 通知权限未授予等场景静默失败
  }
}
