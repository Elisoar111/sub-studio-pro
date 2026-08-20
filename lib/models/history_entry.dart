import 'queue_task.dart';

/// 操作历史条目：每次成功的转换/烧录/提取/转码自动记录。
class HistoryEntry {
  final String id;
  final TaskType type;
  final String title;
  final List<String> inputs;
  final String? output;
  final bool success;
  final Map<String, String> params;
  final DateTime timestamp;

  HistoryEntry({
    required this.id,
    required this.type,
    required this.title,
    this.inputs = const [],
    this.output,
    this.success = true,
    this.params = const {},
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'title': title,
        'inputs': inputs,
        'output': output,
        'success': success,
        'params': params,
        'timestamp': timestamp.toIso8601String(),
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        id: json['id'] as String? ?? '',
        type: TaskType.values.asNameMap()[json['type']] ?? TaskType.transcode,
        title: json['title'] as String? ?? '',
        inputs: (json['inputs'] as List? ?? []).whereType<String>().toList(),
        output: json['output'] as String?,
        success: json['success'] as bool? ?? true,
        params: Map<String, String>.from(json['params'] as Map? ?? {}),
        timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ??
            DateTime.now(),
      );
}
