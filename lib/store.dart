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

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString(_kItems);
    if (raw != null) {
      try {
        final list = jsonDecode(raw) as List;
        _items = list.map((e) => DownloadItem.fromJson(e)).toList();
      } catch (_) {
        _items = [];
      }
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
