import 'dart:async';

/// 并发探测池：限制同时运行的探测任务数量，防止 IO 争抢。
///
/// 用于 ffprobe 视频信息探测：多文件选择时串行等待体验差，
/// 但全部并发又会瞬间 spawn 数十个子进程。此池用 [limit] 上限
/// （建议 3~4）兼顾吞吐与资源占用。
class ConcurrentProbePool {
  final int limit;
  int _active = 0;
  final _queue = <Future<void> Function()>[];

  ConcurrentProbePool({this.limit = 3});

  /// 逐个调用 [probe] 处理 [inputs] 中的每个元素，
  /// 并发不超过 [limit]；结果通过 [onResult] 回调，
  /// 异常通过 [onError] 回调（不阻断其余任务）。
  Future<void> run<T, R>(
    List<T> inputs,
    Future<R> Function(T input) probe,
    void Function(T input, R result) onResult, {
    void Function(T input, Object error)? onError,
  }) async {
    if (inputs.isEmpty) return;
    final completer = Completer<void>();
    var remaining = inputs.length;

    void maybeStartNext() {
      while (_active < limit && _queue.isNotEmpty) {
        final task = _queue.removeAt(0);
        _active++;
        task().whenComplete(() {
          _active--;
          remaining--;
          if (remaining == 0 && !completer.isCompleted) {
            completer.complete();
          }
          maybeStartNext();
        });
      }
    }

    for (final input in inputs) {
      _queue.add(() async {
        try {
          final result = await probe(input);
          onResult(input, result);
        } catch (e) {
          onError?.call(input, e);
        }
      });
    }
    maybeStartNext();

    return completer.future;
  }
}
