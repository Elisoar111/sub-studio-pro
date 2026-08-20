import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// 拖拽文件接收区：包裹子 widget，拖入文件时显示高亮覆盖层，
/// 松手后按扩展名过滤并通过 [onFilesDropped] 回调。
///
/// 各功能页用此包裹 body，复用已有的去重逻辑直接入列。
class FileDropZone extends StatefulWidget {
  final Widget child;
  final List<String> acceptedExtensions;
  final void Function(List<String> paths) onFilesDropped;
  final String hint;

  const FileDropZone({
    super.key,
    required this.child,
    required this.acceptedExtensions,
    required this.onFilesDropped,
    this.hint = '松开以添加文件',
  });

  @override
  State<FileDropZone> createState() => _FileDropZoneState();
}

class _FileDropZoneState extends State<FileDropZone> {
  bool _hovering = false;

  bool _accepts(String path) {
    final ext = p.extension(path).toLowerCase();
    final extNoDot = ext.isEmpty ? '' : ext.substring(1);
    return widget.acceptedExtensions.any(
        (e) => e.toLowerCase() == ext || e.toLowerCase() == extNoDot);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: (detail) {
        setState(() => _hovering = false);
        final paths = detail.files
            .map((f) => f.path)
            .where(_accepts)
            .where((path) => File(path).existsSync())
            .toList();
        if (paths.isNotEmpty) widget.onFilesDropped(paths);
      },
      child: Stack(
        children: [
          widget.child,
          if (_hovering)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.12),
                    border: Border.all(
                      color: scheme.primary.withValues(alpha: 0.6),
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: scheme.shadow.withValues(alpha: 0.2),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.file_download_outlined,
                              color: scheme.onPrimaryContainer),
                          const SizedBox(width: 8),
                          Text(
                            widget.hint,
                            style: TextStyle(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
