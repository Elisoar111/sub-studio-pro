import 'package:flutter/material.dart';

import 'extract_screen.dart';
import 'mux_screen.dart';

/// 轨道处理合并页：提取 / 封装 双页签（对齐 MKVToolNix 的 mux/extract 一体布局）。
/// 页签切换用 IndexedStack 保持两侧的已选文件与参数状态。
class TrackScreen extends StatefulWidget {
  /// 初始页签：0 = 轨道提取，1 = 封装轨道
  final int initialTab;

  const TrackScreen({super.key, this.initialTab = 0});

  @override
  State<TrackScreen> createState() => _TrackScreenState();
}

class _TrackScreenState extends State<TrackScreen> {
  late int _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_tab == 0 ? '轨道处理 · 提取' : '轨道处理 · 封装'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(
                    value: 0,
                    icon: Icon(Icons.file_download_outlined),
                    label: Text('轨道提取'),
                  ),
                  ButtonSegment(
                    value: 1,
                    icon: Icon(Icons.merge_type),
                    label: Text('封装轨道'),
                  ),
                ],
                selected: {_tab},
                onSelectionChanged: (s) => setState(() => _tab = s.first),
                showSelectedIcon: false,
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  side: WidgetStatePropertyAll(
                    BorderSide(color: scheme.outlineVariant),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      body: IndexedStack(
        index: _tab,
        children: const [
          ExtractScreen(embedded: true),
          MuxScreen(embedded: true),
        ],
      ),
    );
  }
}
