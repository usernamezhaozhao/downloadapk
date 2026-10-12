import 'dart:convert';
import 'package:http/http.dart' as http;

/// 后端地址（DouK-Downloader，HTTP 明文，已在 manifest 开启 usesCleartextTraffic）
const String kBaseUrl = 'http://8.152.206.46:5555';

/// 固定测试链接（你指定的那条抖音分享，测试 Cookie / 下载时无需手动粘贴）。
/// 若用户输入为空，自动回退到这条，做到「懒人一键测」。
const String kFixedTestLink =
    '9.48 :5pm X@z.Gv 05/22 sEu:/ 时隔六年，曝光一下我的最新简历！ # AI # 程序员 # 简历 # AI编程 # Java AI 时代的简历应该怎么写？ https://v.douyin.com/h3YNa7rE3II/ 复制此链接，打开Dou音搜索，直接观看视频！';

/// 后端返回的失败分类，用于给用户提示「链接失效」还是「解析失败」
class ApiException implements Exception {
  final String kind; // 'link_expired' | 'parse_failed' | 'network' | 'unknown'
  final String message;
  ApiException(this.kind, this.message);
  @override
  String toString() => message;
}

String _classify(String msg) {
  final m = msg.toLowerCase();
  if (m.contains('失效') ||
      m.contains('expired') ||
      m.contains('不存在') ||
      m.contains('not exist') ||
      m.contains('过期')) {
    return 'link_expired';
  }
  if (m.contains('解析') ||
      m.contains('parse') ||
      m.contains('获取') ||
      m.contains('提取') ||
      m.contains('fetch')) {
    return 'parse_failed';
  }
  return 'unknown';
}

Future<Map<String, dynamic>> _postJson(
    String path, Map<String, dynamic> body) async {
  final uri = Uri.parse('$kBaseUrl$path');
  final resp = await http
      .post(uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body))
      .timeout(const Duration(seconds: 30));
  final Map<String, dynamic> json =
      jsonDecode(resp.body) as Map<String, dynamic>;
  if (resp.statusCode != 200) {
    final msg = (json['message'] ?? 'HTTP ${resp.statusCode}').toString();
    throw ApiException(_classify(msg), msg);
  }
  return json;
}

/// 健康自检（你说的「健康 API」）：确认后端在线
Future<String> healthCheck() async {
  final resp = await http
      .get(Uri.parse('$kBaseUrl/token'))
      .timeout(const Duration(seconds: 15));
  if (resp.statusCode != 200) {
    throw ApiException('network', '后端不可达 (HTTP ${resp.statusCode})');
  }
  return 'ok';
}

/// 解析分享短链 -> 完整链接
Future<String> resolveShare(String text) async {
  final json = await _postJson('/douyin/share', {'text': text});
  final url = json['url'];
  if (url == null || url.toString().isEmpty) {
    throw ApiException('parse_failed', '分享链接解析失败: ${json['message']}');
  }
  return url.toString();
}

/// 取单个作品数据（视频直链 / 图文列表 / 标题）
Future<Map<String, dynamic>> fetchDetail(String detailId, String cookie) async {
  final json =
      await _postJson('/douyin/detail', {'detail_id': detailId, 'cookie': cookie});
  final data = json['data'];
  if (data == null) {
    final msg = (json['message'] ?? '未返回数据').toString();
    throw ApiException(_classify(msg), msg);
  }
  if (data is Map) return Map<String, dynamic>.from(data);
  return {'raw': data};
}

/// 测试 cookie 是否有效：支持粘贴「分享链接」或「数字作品ID」两种输入。
/// 链接会先走 /douyin/share 解析出作品ID，再调 /douyin/detail；
/// 能返回数据说明 cookie 有效；返回鉴权错误说明 cookie 失效/过期。
Future<void> testCookie(String cookie, String input) async {
  final id = await _resolveTestId(input);
  final json = await _postJson(
      '/douyin/detail', {'detail_id': id, 'cookie': cookie});
  if (json['data'] == null) {
    final msg = (json['message'] ?? 'cookie 可能无效').toString();
    throw ApiException(_classify(msg), 'cookie 无效: $msg');
  }
}

/// 把用户输入（分享链接 / 短链 / 数字ID）统一解析成作品ID
Future<String> _resolveTestId(String input) async {
  final t = input.trim();
  if (t.isEmpty) throw ApiException('unknown', '请填写测试链接或作品ID');
  // 看起来像链接 -> 走解析
  if (t.contains('douyin') || t.toLowerCase().startsWith('http')) {
    try {
      final url = await resolveShare(t);
      final id = extractDetailId(url);
      if (id != null) return id;
    } catch (_) {
      // 解析失败则兜底当原始 ID 用
    }
  }
  return t;
}

/// 从完整链接里提取抖音作品 ID（如 .../video/733xxxx 或 .../note/733xxxx）
String? extractDetailId(String url) {
  final m = RegExp(r'(?:video|note)/(\d+)').firstMatch(url);
  if (m != null) return m.group(1);
  final m2 = RegExp(r'(\d{15,})').firstMatch(url); // 兜底：长数字 ID
  return m2?.group(1);
}
