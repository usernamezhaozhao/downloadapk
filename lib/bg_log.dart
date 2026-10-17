import 'dart:io';

import 'package:flutter/foundation.dart';

/// 后台 isolate 的日志（只依赖 dart:io，不依赖任何插件）。
///
/// 为什么不走 logcat / 不走插件：通知上的「后台下载」是在一个**全新的后台
/// isolate** 里跑的，那里没注册插件时 `path_provider`/`shared_preferences` 全都
/// 不可用。而 `Directory.systemTemp` 是 dart:io 自带的（Android 上是 App 的
/// cache 目录），主 isolate 读同一个路径就能看到——于是「点了没反应」有了线索。
///
/// 排查入口：「测试」页 →「后台下载日志」。
File get _logFile => File('${Directory.systemTemp.path}/bg_download.log');

Future<void> bgLog(String line) async {
  final ts = DateTime.now().toIso8601String();
  final stamp = ts.length >= 23 ? ts.substring(11, 23) : ts;
  debugPrint('BGDL $line');
  try {
    await _logFile.writeAsString('[$stamp] $line\n',
        mode: FileMode.append, flush: true);
  } catch (_) {
    // 日志写不进去也不能影响主流程
  }
}

Future<String> readBgLog() async {
  try {
    if (!await _logFile.exists()) {
      return '（暂无后台日志：说明「后台下载」这条链路一次都没被触发过，'
          '或者插件连后台 isolate 都没起来）';
    }
    final text = await _logFile.readAsString();
    return text.trim().isEmpty ? '（日志文件是空的）' : text;
  } catch (e) {
    return '读取日志失败：$e';
  }
}

Future<void> clearBgLog() async {
  try {
    if (await _logFile.exists()) await _logFile.delete();
  } catch (_) {}
}
