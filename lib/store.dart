import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

const _kItems = 'dl_items';
const _kCookie = 'cookie';
const _kTestId = 'test_id';
const _kClipboardMonitor = 'clipboard_monitor';

/// 本地持久化：cookie / 测试作品ID / 下载列表索引
class Store {
  Store._();
  static final Store instance = Store._();

  SharedPreferences? _prefs;
  List<DownloadItem> _items = [];

  /// 读本地数据。
  /// [force] = true 时强制从平台侧重新读一次：通知上的「后台下载」是在
  /// 另一个 isolate 里写的数据，主 isolate 手里的 `_items` 会是旧缓存，
  /// 回 App 时用 force 刷新，新下载的作品才会立刻出现在首页列表里。
  Future<void> init({bool force = false}) async {
    _prefs ??= await SharedPreferences.getInstance();
    if (force) {
      // 用 dynamic 调 reload()：不同版本的 shared_preferences 可能没有该方法，
      // 这样写编译期安全，运行期不支持也只是刷新失败（继续用内存缓存）。
      try {
        final dynamic p = _prefs;
        await p.reload();
      } catch (_) {}
    }
    final raw = _prefs!.getString(_kItems);
    if (raw == null) {
      _items = [];
      return;
    }
    try {
      final list = jsonDecode(raw) as List;
      _items = list.map((e) => DownloadItem.fromJson(e)).toList();
    } catch (_) {
      _items = [];
    }
  }

  List<DownloadItem> get items => List.unmodifiable(_items);

  Future<void> addItem(DownloadItem it) async {
    _items.insert(0, it);
    await _persist();
  }

  Future<void> removeItem(String id) async {
    _items.removeWhere((e) => e.id == id);
    await _persist();
  }

  Future<void> _persist() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!
        .setString(_kItems, jsonEncode(_items.map((e) => e.toJson()).toList()));
  }

  String get cookie => _prefs?.getString(_kCookie) ?? '';
  Future<void> setCookie(String v) async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_kCookie, v);
  }

  String get testId => _prefs?.getString(_kTestId) ?? '';
  Future<void> setTestId(String v) async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setString(_kTestId, v);
  }

  /// 剪贴板自动监听开关（复制抖音链接后自动弹横幅并下载）。默认开启。
  bool get clipboardMonitor => _prefs?.getBool(_kClipboardMonitor) ?? true;
  Future<void> setClipboardMonitor(bool v) async {
    _prefs ??= await SharedPreferences.getInstance();
    await _prefs!.setBool(_kClipboardMonitor, v);
  }
}
