import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 前台服务里跑的剪贴板轮询任务（flutter_foreground_task v11 API）。
///
/// Android 10+ 限制「后台应用读剪贴板」，本服务靠 FOREGROUND_SERVICE 把进程
/// 保活，并在 onRepeatEvent 里每 2 秒轮询一次。读到的抖音链接通过
/// `sendDataToMain` 发给主 Isolate，由主 Isolate 用已初始化的
/// flutter_local_notifications 弹系统 heads-up（保证插件通道可用）。
///
/// 说明（重要）：部分 Android 10+ 机型在 App 不在焦点时 `Clipboard.getData`
/// 仍可能返回 null（系统限制）。此时回退到「App 回到前台」时的检测
/// （见 douyin_page._checkClipboard），功能不丢失，只是不是「在抖音里也即时弹」。
@pragma('vm:entry-point')
void clipboardTaskStartCallback() {
  FlutterForegroundTask.setTaskHandler(ClipboardTaskHandler());
}

class ClipboardTaskHandler extends TaskHandler {
  static final RegExp _douyinLink =
      RegExp(r'https?://[^\s]*douyin\.com/[^\s]+', caseSensitive: false);

  String? _lastLink;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // 后台 Isolate 需要 ServicesBinding 才能用 Clipboard 的 MethodChannel
    WidgetsFlutterBinding.ensureInitialized();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // 接口为 void，故用 fire-and-forget 的异步轮询
    _poll();
  }

  void _poll() async {
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text ?? '';
      final m = _douyinLink.firstMatch(text);
      if (m == null) return;
      final link = m.group(0)!;
      if (link == _lastLink) return;
      _lastLink = link;
      // 发给主 Isolate：复制到了抖音链接
      FlutterForegroundTask.sendDataToMain(link);
    } catch (_) {
      // 剪贴板受限/不可用时静默
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _lastLink = null;
  }

  @override
  void onNotificationPressed() {}

  /// 常驻通知上的「读取剪贴板」按钮被点击：照 CSDN 文章用透明 Activity 在
  /// 真正获得焦点后读剪贴板（后台读会抛 SecurityException）。这里经原生
  /// native_control 通道启动透明 Activity；若通道不可用则兜底把 App 拉前台。
  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'read_clipboard') _launchProxy();
  }

  Future<void> _launchProxy() async {
    try {
      await const MethodChannel('native_control')
          .invokeMethod<void>('startClipboardProxy');
    } catch (_) {
      // 兜底：把 App 拉到前台，走回前台检测路径
      FlutterForegroundTask.launchApp();
    }
  }
}
