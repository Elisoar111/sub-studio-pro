import 'package:local_notifier/local_notifier.dart';

/// 系统通知服务：批量任务完成/失败时弹出桌面通知，
/// 后台跑任务不用盯屏。
///
/// 基于 local_notifier（Windows toast / macOS NSUserNotification / Linux dbus）。
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  bool _initialized = false;

  /// 初始化（幂等）。在 main() 中调用。
  Future<void> init() async {
    if (_initialized) return;
    try {
      await localNotifier.setup(appName: 'Subtitle Studio Pro');
      _initialized = true;
    } catch (_) {
      // 部分环境（CI / 无桌面会话）可能不支持，静默降级
    }
  }

  /// 发送系统通知（fire-and-forget，不阻塞调用方）。
  void notify({required String title, required String body}) {
    if (!_initialized) return;
    try {
      LocalNotification(title: title, body: body).show();
    } catch (_) {
      // 降级：静默失败，不影响任务流程
    }
  }

  /// 批量任务完成通知。
  void notifyBatchComplete({
    required int success,
    required int failed,
    int cancelled = 0,
  }) {
    final parts = <String>[
      '$success 个成功',
      if (failed > 0) '$failed 个失败',
      if (cancelled > 0) '$cancelled 个取消',
    ];
    final title = failed > 0 ? '批量任务完成（有失败）' : '批量任务完成';
    notify(title: title, body: parts.join('，'));
  }
}
