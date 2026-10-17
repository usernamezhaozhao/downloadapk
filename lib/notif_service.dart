import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 全局唯一的通知插件实例与点击处理器。
/// 所有页面共用它，避免多个实例互相覆盖 onDidReceiveNotificationResponse 回调。
final FlutterLocalNotificationsPlugin appNotif =
    FlutterLocalNotificationsPlugin();

/// 通知被点击后的回调（payload 为下载作品的 id / 'clip:<链接>'）。
/// 由 main 设置为「跳到首页 + 打开预览」或「跳到抖音页 + 自动下载」。
void Function(String? payload)? onNotifTap;

/// 最近一次 show() 失败的原因（成功即置 null）。
/// 以前所有异常都被 `catch (_) {}` 吞掉，横幅不弹但看不到任何线索；
/// 现在把原因留在全局变量里，「测试」页的通知自检会把它显示出来。
String? lastNotifError;

/// 通知通道 id。
/// 注意：Android 的通道一旦创建，**重要性不可再修改**（改 apply 也不会生效），
/// 所以这里带版本后缀；以后要调重要性必须换新 id。
const String kChannelProgress = 'download_channel'; // 下载进度条：静默
const String kChannelResult = 'result_channel_v1'; // 下载结果：high
const String kChannelBanner = 'banner_v1'; // 剪贴板横幅：max

Future<void> initAppNotif() async {
  await appNotif.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveNotificationResponse: (resp) => onNotifTap?.call(resp.payload),
  );
  final android = appNotif.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();

  // ① 下载进度：常驻进度条，低优先级不打扰
  await android?.createNotificationChannel(const AndroidNotificationChannel(
    kChannelProgress,
    '下载进度',
    description: '下载进度的常驻进度条（静默）',
    importance: Importance.low,
  ));
  // ② 下载结果：成功/失败、Cookie 测试结果
  await android?.createNotificationChannel(const AndroidNotificationChannel(
    kChannelResult,
    '下载结果',
    description: '下载成功/失败与 Cookie 测试结果',
    importance: Importance.high,
  ));
  // ③ 剪贴板横幅：importance max 才会以「悬浮横幅」弹出
  await android?.createNotificationChannel(const AndroidNotificationChannel(
    kChannelBanner,
    '剪贴板提醒',
    description: '检测到抖音链接时的横幅提醒，点击立即下载',
    importance: Importance.max,
  ));
}

/// 发一条 heads-up 横幅通知。返回是否发送成功；失败原因写进 [lastNotifError]。
///
/// 相比旧版去掉了 `largeIcon: DrawableResourceAndroidBitmap('ic_launcher')`：
/// Flutter 模板的启动图标在 `mipmap-*` 里，而这个 API 只会去 `drawable` 里找，
/// 找不到时容易让整条通知构建失败——横幅「从来不弹」的头号嫌疑就在这里。
Future<bool> showHeadsUp(
  String title,
  String body, {
  String? payload,
  int id = 9001,
}) async {
  try {
    await appNotif.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          kChannelBanner,
          '剪贴板提醒',
          channelDescription: '检测到抖音链接时的横幅提醒，点击立即下载',
          importance: Importance.max,
          priority: Priority.max,
          ticker: title,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.public,
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
    lastNotifError = null;
    return true;
  } catch (e) {
    lastNotifError = '$e';
    debugPrint('showHeadsUp failed: $e');
    return false;
  }
}

/// 剪贴板横幅专用封装：把「即将下载的链接」显示出来（解析出标题后作通知标题）。
/// 固定 id 9001：同一条链接的新横幅覆盖旧的，不堆积。
Future<bool> showLinkHeadsUp(String link, {String? title}) {
  final display = link.length > 90 ? '${link.substring(0, 90)}…' : link;
  final body = '即将下载：\n$display\n\n点击「立即下载」开始';
  return showHeadsUp(title ?? '检测到抖音链接', body, payload: 'clip:$link');
}

/// 自检用：查询系统里当前属于本 App 的通知。
/// 返回文案直接给「测试」页显示——这条能一锤定音区分两种失败：
///   · 0 条   → show() 根本没成功（看 [lastNotifError]）
///   · 有 N 条 → 已经发出去了，是系统/厂商设置把它折叠或静音了
Future<String> debugActiveNotifications() async {
  try {
    final dynamic list = await appNotif.getActiveNotifications();
    final n = (list as List).length;
    return n == 0
        ? '系统里当前 0 条本 App 的通知（说明没发出去）'
        : '系统里当前有 $n 条本 App 的通知（已发出；看不到就是被系统折叠/静音了）';
  } catch (e) {
    return '查询失败：$e';
  }
}
