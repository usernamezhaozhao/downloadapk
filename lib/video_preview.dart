import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// App 内嵌视频播放器：用于预览弹窗里直接播放，无需跳出系统播放器。
/// [autoPlay] 为 true 时初始化完成后自动播放。
class VideoPreview extends StatefulWidget {
  final String path;
  final bool autoPlay;

  const VideoPreview(this.path, {super.key, this.autoPlay = true});

  @override
  State<VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<VideoPreview> {
  late final VideoPlayerController _c;
  bool _ready = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _c = VideoPlayerController.file(File(widget.path))
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        if (widget.autoPlay) _c.play();
      }).catchError((e) {
        if (mounted) setState(() => _failed = true);
      });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const SizedBox(
        height: 160,
        child: Center(child: Text('视频初始化失败，可用系统播放器打开')),
      );
    }
    if (!_ready) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return AspectRatio(
      aspectRatio: _c.value.aspectRatio,
      child: Stack(
        alignment: Alignment.center,
        children: [
          VideoPlayer(_c),
          Positioned(
            bottom: 8,
            left: 8,
            right: 8,
            child: Row(
              children: [
                IconButton(
                  color: Colors.white,
                  icon: Icon(_c.value.isPlaying
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_fill),
                  onPressed: () => setState(() {
                    _c.value.isPlaying ? _c.pause() : _c.play();
                  }),
                ),
                Expanded(
                  child: VideoProgressIndicator(
                    _c,
                    allowScrubbing: true,
                    colors: const VideoProgressColors(
                        playedColor: Colors.greenAccent),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
