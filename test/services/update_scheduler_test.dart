import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/services/update/update_service.dart';

/// 定时自动检查更新调度（v2.1.0）：
/// - start 后按间隔静默检查（复用 checkForUpdatesSilently 语义）；
/// - 发现新版本写 [startupUpdate]（首页横幅已有展示）；
/// - stop 取消定时器；重复 start 幂等（旧定时器先取消，不叠加）。
class _FakeUpdateService extends UpdateService {
  _FakeUpdateService({this.info});

  final UpdateInfo? info;
  int calls = 0;

  @override
  Future<UpdateInfo?> checkLatest({required String currentVersion}) async {
    calls++;
    return info;
  }
}

/// 测试用可控定时器工厂：记录回调与 cancel 状态。
class _FakePeriodicFactory {
  final timers = <_FakeTimer>[];

  Timer call(Duration interval, void Function(Timer) callback) {
    final t = _FakeTimer(callback);
    timers.add(t);
    return t;
  }

  void fireAll() {
    for (final t in List.of(timers)) {
      t.fireIfActive();
    }
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.callback);

  final void Function(Timer) callback;
  bool _active = true;

  void fireIfActive() {
    if (_active) callback(this);
  }

  @override
  bool get isActive => _active;

  @override
  void cancel() => _active = false;

  @override
  int get tick => 0;
}

void main() {
  setUp(() {
    startupUpdate.value = null;
  });

  tearDown(() {
    stopPeriodicUpdateCheck();
    startupUpdate.value = null;
  });

  test('start 后定时触发静默检查', () async {
    final svc = _FakeUpdateService(info: null);
    final factory = _FakePeriodicFactory();

    startPeriodicUpdateCheck(
      service: svc,
      timerFactory: factory.call,
    );

    expect(svc.calls, 0, reason: '启动时不立即检查（启动检查由 main 负责）');
    factory.fireAll();
    await Future<void>.delayed(Duration.zero);
    expect(svc.calls, 1, reason: '间隔到期应触发一次检查');
  });

  test('发现新版本写入 startupUpdate 供首页横幅展示', () async {
    const info = UpdateInfo(
      version: '9.9.9',
      releaseUrl: 'https://github.com/demo/app/releases/tag/v9.9.9',
      setupUrl: null,
      notes: '',
    );
    final svc = _FakeUpdateService(info: info);
    final factory = _FakePeriodicFactory();

    startPeriodicUpdateCheck(
      service: svc,
      timerFactory: factory.call,
    );

    factory.fireAll();
    await Future<void>.delayed(Duration.zero);

    expect(startupUpdate.value?.version, '9.9.9');
  });

  test('stop 后定时器不再触发', () async {
    final svc = _FakeUpdateService(info: null);
    final factory = _FakePeriodicFactory();

    startPeriodicUpdateCheck(
      service: svc,
      timerFactory: factory.call,
    );
    stopPeriodicUpdateCheck();

    factory.fireAll();
    await Future<void>.delayed(Duration.zero);
    expect(svc.calls, 0, reason: 'stop 后旧定时器已取消');
  });

  test('重复 start 幂等：旧定时器取消，不叠加', () async {
    final svc = _FakeUpdateService(info: null);
    final factory = _FakePeriodicFactory();

    startPeriodicUpdateCheck(service: svc, timerFactory: factory.call);
    startPeriodicUpdateCheck(service: svc, timerFactory: factory.call);

    final cancelled =
        factory.timers.where((t) => !t.isActive).toList();
    expect(cancelled, hasLength(1), reason: '二次 start 应取消首个定时器');
  });

  test('检查抛异常时静默吞掉（不打扰用户）', () async {
    final errorSvc = _ThrowingUpdateService();
    final factory = _FakePeriodicFactory();

    startPeriodicUpdateCheck(service: errorSvc, timerFactory: factory.call);
    factory.fireAll();
    // 不抛异常即通过
    await Future<void>.delayed(Duration.zero);
    expect(startupUpdate.value, isNull);
  });
}

class _ThrowingUpdateService extends UpdateService {
  @override
  Future<UpdateInfo?> checkLatest({required String currentVersion}) async {
    throw const SocketException('offline');
  }
}
