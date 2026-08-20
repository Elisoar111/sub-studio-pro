import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/utils/time_format.dart';
import '../providers/app_providers.dart';
import '../services/file_service.dart';
import '../widgets/common.dart';
import 'convert_screen.dart';
import 'subtitle_preview_screen.dart';

/// 排序方式
enum _SortBy { name, size, type }

/// 字幕库：导入 / 排序 / 多选 / 批量转换 / 预览。
class SubtitleListScreen extends ConsumerStatefulWidget {
  const SubtitleListScreen({super.key});

  @override
  ConsumerState<SubtitleListScreen> createState() =>
      _SubtitleListScreenState();
}

class _SubtitleListScreenState extends ConsumerState<SubtitleListScreen> {
  final List<PickedFile> _files = [];
  final Set<String> _selected = {};
  _SortBy _sort = _SortBy.name;
  bool _selectionMode = false;

  String _keyOf(PickedFile f) => f.path ?? 'web:${f.name}';

  @override
  void initState() {
    super.initState();
    // 文件关联（v1.5 安装包）：双击字幕文件启动 → 启动参数里的文件
    // 直接进列表（与手动导入同一条数据通道，去重规则一致）
    final startup = ref.read(startupSubtitleFilesProvider);
    for (final path in startup) {
      final f = FileService.pickedFromFile(path);
      if (!_files.any((x) => _keyOf(x) == f.path)) _files.add(f);
    }
  }

  // ───────────────────────── 选择 ─────────────────────────

  Future<void> _pick() async {
    try {
      await FileService.instance.ensureStoragePermissions();
      final picked = await FileService.instance.pickSubtitles();
      if (picked.isEmpty || !mounted) return;
      setState(() {
        for (final f in picked) {
          final k = _keyOf(f);
          if (!_files.any((x) => _keyOf(x) == k)) _files.add(f);
        }
      });
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  void _toggleSelect(String key) {
    setState(() {
      if (!_selected.add(key)) _selected.remove(key);
    });
  }

  void _enterSelection(String key) {
    setState(() {
      _selectionMode = true;
      _selected.add(key);
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  void _toggleSelectAll() {
    final keys = _sorted.map(_keyOf).toList();
    setState(() {
      if (_selected.length == keys.length && keys.isNotEmpty) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(keys);
      }
    });
  }

  void _removeSelected() {
    setState(() {
      _files.removeWhere((f) => _selected.contains(_keyOf(f)));
      _selected.clear();
      _selectionMode = false;
    });
  }

  List<PickedFile> get _selectedFiles => _files
      .where((f) => _selected.contains(_keyOf(f)))
      .toList();

  List<PickedFile> get _sorted {
    final list = List<PickedFile>.of(_files);
    switch (_sort) {
      case _SortBy.name:
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case _SortBy.size:
        list.sort((a, b) => b.size.compareTo(a.size));
      case _SortBy.type:
        list.sort((a, b) {
          final e = p.extension(a.name).compareTo(p.extension(b.name));
          return e != 0 ? e : a.name.compareTo(b.name);
        });
    }
    return list;
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectionMode ? '已选 ${_selected.length} 项' : '字幕库'),
        leading: _selectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelection,
              )
            : null,
        actions: [
          if (_selectionMode) ...[
            TextButton(
              onPressed: _toggleSelectAll,
              child: Text(
                _selected.length == _sorted.length && _sorted.isNotEmpty
                    ? '取消全选'
                    : '全选',
              ),
            ),
            IconButton(
              tooltip: '删除所选',
              icon: const Icon(Icons.delete_outline),
              onPressed: _selected.isEmpty ? null : _removeSelected,
            ),
          ] else ...[
            PopupMenuButton<_SortBy>(
              tooltip: '排序',
              icon: const Icon(Icons.sort),
              onSelected: (v) => setState(() => _sort = v),
              itemBuilder: (_) => [
                for (final (value, label) in const [
                  (_SortBy.name, '按名称'),
                  (_SortBy.size, '按大小'),
                  (_SortBy.type, '按类型'),
                ])
                  PopupMenuItem(
                    value: value,
                    child: Row(
                      children: [
                        Icon(
                          _sort == value
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(label),
                      ],
                    ),
                  ),
              ],
            ),
            PopupMenuButton<String>(
              tooltip: '更多',
              onSelected: (v) {
                if (v == 'clear') {
                  setState(() => _files.clear());
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'clear', child: Text('清空列表')),
              ],
            ),
          ],
        ],
      ),
      floatingActionButton: _selectionMode
          ? null
          : FloatingActionButton.extended(
              onPressed: _pick,
              icon: const Icon(Icons.add),
              label: const Text('导入字幕'),
            ),
      bottomNavigationBar: _selectionMode
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _selected.isEmpty
                            ? null
                            : () => _openConvert(),
                        icon: const Icon(Icons.swap_horiz, size: 18),
                        label: Text('转换所选 (${_selected.length})'),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: _files.isEmpty
          ? EmptyState(
              icon: Icons.closed_caption_off,
              message: '还没有字幕文件\n点击右下角导入 SRT / ASS / SSA / VTT / SUB',
              action: FilledButton.icon(
                onPressed: _pick,
                icon: const Icon(Icons.add),
                label: const Text('导入字幕'),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
              itemCount: _sorted.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (context, i) {
                final f = _sorted[i];
                final key = _keyOf(f);
                final selected = _selected.contains(key);
                final ext = p.extension(f.name).replaceFirst('.', '');
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    if (_selectionMode) {
                      _toggleSelect(key);
                    } else {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SubtitlePreviewScreen(file: f),
                        ),
                      );
                    }
                  },
                  onLongPress: () => _enterSelection(key),
                  child: FileTile(
                    title: f.name,
                    subtitle:
                        '${ext.toUpperCase()} · ${formatBytes(f.size)}'
                        '${f.isWebFile ? ' · 内存文件(Web)' : ''}',
                    icon: Icons.subtitles_outlined,
                    trailing: _selectionMode
                        ? Checkbox(
                            value: selected,
                            onChanged: (_) => _toggleSelect(key),
                          )
                        : const Icon(Icons.chevron_right, size: 20),
                  ),
                );
              },
            ),
    );
  }

  void _openConvert() {
    final files = _selectedFiles;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConvertScreen(files: files),
      ),
    );
  }
}
