import 'package:flutter/foundation.dart';

import '../../core/utils/logger.dart';

/// 崩溃捕获（v1.5）：
/// - [handleFlutterError] 挂到 `FlutterError.onError`，接住框架渲染/构建异常；
/// - [handleUncaughtError] 挂到 `PlatformDispatcher.instance.onError`，接住
///   未 await 的异步错误（返回 true 阻止二次抛出）；
/// - [install] 一键挂接（main 中最早调用，晚于 ensureInitialized）。
///
/// 所有异常经 [Logger.error] 写内存缓冲与 JSON 落盘，供「导出调试包」带回。
class CrashGuard {
  CrashGuard._();

  static void handleFlutterError(FlutterErrorDetails details) {
    Logger.instance.error('Flutter 异常', details.exception, details.stack);
  }

  static bool handleUncaughtError(Object error, StackTrace stack) {
    Logger.instance.error('未捕获异常', error, stack);
    return true;
  }

  /// 挂接全局异常钩子。日志文件存储需先经 `Logger.attachFileStore` 挂好，
  /// 此处只负责钩子注册。
  static void install() {
    FlutterError.onError = handleFlutterError;
    PlatformDispatcher.instance.onError = handleUncaughtError;
  }
}
