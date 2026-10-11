import 'package:flutter/material.dart';

/// B站页（占位）：等抖音跑稳后再接入
class BilibiliPage extends StatelessWidget {
  const BilibiliPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.tv, size: 72, color: Colors.blue),
          SizedBox(height: 16),
          Text(
            'Hello Bilibili',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 8),
          Text('（B站下载功能后续接入，先占位）',
              style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}
