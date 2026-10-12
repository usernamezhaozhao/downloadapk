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
  // 创建下载进度/结果通知通道（与 DownloadService 中常量保持一致）
  await appNotif
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(const AndroidNotificationChannel(
        'download_channel',
        '下载进度',
        description: '抖音下载进度与结果通知',
        importance: Importance.low,
      ));
}
