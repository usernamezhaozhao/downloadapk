/// 一条已下载的记录（用于「本地列表页」展示与播放）
class DownloadItem {
  final String id;
  final String title;
  final String type; // 'video' | 'image'
  final List<String> paths; // 本地私有目录下的文件路径（供列表预览/系统播放器调用）
  final int time; // 下载完成时间戳(ms)

  DownloadItem({
    required this.id,
    required this.title,
    required this.type,
    required this.paths,
    required this.time,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'type': type,
        'paths': paths,
        'time': time,
      };

  factory DownloadItem.fromJson(Map<String, dynamic> j) => DownloadItem(
        id: j['id'] as String,
        title: j['title'] as String,
        type: j['type'] as String,
        paths: List<String>.from(j['paths'] ?? <String>[]),
        time: j['time'] as int,
      );

  /// 列表里展示用的封面/首图路径
  String? get coverPath => paths.isNotEmpty ? paths.first : null;
}

/// 单个待下载媒体（视频或图片）
class MediaTask {
  final String url;
  final String fileName;
  final String kind; // 'video' | 'image'

  MediaTask(this.url, this.fileName, this.kind);
}
