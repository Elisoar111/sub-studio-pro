import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/storage_service.dart';
import 'package:subtitle_studio_pro/services/whisper/whisper_models.dart';
import 'package:subtitle_studio_pro/services/whisper/whisper_service.dart';

/// v1.2.x Whisper 检测提速：检测结果持久化缓存 + 启动后台静默复检。
/// 动机：`whisper --help` 触发 torch 导入需 10~30s，每次启动都探测会
/// 卡住首次进入转写页的可用性判定。
void main() {
  late Directory tmp;
  late File fakeWhisper;

  setUpAll(() {
    StorageService.instance.useMemoryStoreForTesting();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('whisper_cache_test');
    fakeWhisper = File('${tmp.path}\\whisper.exe');
    await fakeWhisper.writeAsBytes(Uint8List.fromList([1, 2, 3, 4]));
    WhisperService.instance.resetForTesting();
  });

  tearDown(() async {
    WhisperService.probeOverride = null;
    await tmp.delete(recursive: true);
  });

  /// 生成与缓存条目一致的 JSON（指纹 = mtimeMs:size）。
  String cacheJson(File f, {String backend = 'openai'}) {
    final stat = f.statSync();
    final fp = '${stat.modified.millisecondsSinceEpoch}:${stat.size}';
    return '{"cmd":"${f.path.replaceAll('\\', '\\\\')}",'
        '"baseArgs":[],"backend":"$backend","label":"test",'
        '"fp":"$fp","pathCfg":"","prefCfg":""}';
  }

  test('缓存命中：init 不等待探测即返回，后台静默复检一次', () async {
    await StorageService.instance.setSetting(
        StorageService.kWhisperDetection, cacheJson(fakeWhisper));

    var probeCalls = 0;
    final probeGate = Completer<void>();
    final revalidated = Completer<void>();
    WhisperService.probeOverride = (cmd, args) async {
      probeCalls++;
      await probeGate.future; // 挂起探测：验证 init 不被其阻塞
      if (!revalidated.isCompleted) revalidated.complete();
      return ProcessResult(0, 0, '', '');
    };

    await WhisperService.instance.init();

    // 快路径：init 已返回、状态即时可用，但 --help 探测仍在挂起中
    expect(WhisperService.instance.isAvailable, isTrue,
        reason: '缓存命中应在探测完成前即恢复可用状态');
    expect(WhisperService.instance.backend, WhisperBackend.openai);
    expect(WhisperService.instance.sourceLabel, 'test');
    expect(revalidated.isCompleted, isFalse,
        reason: 'init 返回时复检不应已完成（否则快路径无意义）');

    // 放行后台复检：恰好一次 --help，结果仍可用
    probeGate.complete();
    await revalidated.future.timeout(const Duration(seconds: 5));
    expect(probeCalls, 1);
    expect(WhisperService.instance.isAvailable, isTrue);
  });

  test('指纹失效（文件被改）：init 走全量探测并重建缓存', () async {
    // 种入过期指纹
    await StorageService.instance.setSetting(StorageService.kWhisperDetection,
        cacheJson(fakeWhisper).replaceFirst(RegExp(r'"fp":"[^"]*"'), '"fp":"0:0"'));
    final fullDetectDone = Completer<void>();
    WhisperService.probeOverride = (cmd, args) async {
      if (!fullDetectDone.isCompleted) fullDetectDone.complete();
      return ProcessResult(0, 0, '', '');
    };

    await WhisperService.instance.init();
    await fullDetectDone.future.timeout(const Duration(seconds: 5));

    // 全量探测命中（模拟 PATH 探测返回成功）→ 可用，且缓存被重建
    expect(WhisperService.instance.isAvailable, isTrue);
    final saved =
        StorageService.instance.getSetting(StorageService.kWhisperDetection);
    expect(saved, isNotEmpty, reason: '全量探测成功后应写入新缓存');
  });

  test('缓存命中但后台复检失败：清缓存并转不可用', () async {
    await StorageService.instance.setSetting(
        StorageService.kWhisperDetection, cacheJson(fakeWhisper));

    final revalidateRan = Completer<void>();
    WhisperService.probeOverride = (cmd, args) async {
      revalidateRan.complete();
      return ProcessResult(0, 1, '', 'gone'); // 非零退出码 = 探测失败
    };

    await WhisperService.instance.init();
    expect(WhisperService.instance.isAvailable, isTrue); // 快路径先可用

    await revalidateRan.future.timeout(const Duration(seconds: 5));
    // 复检失败传播需要一拍
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(WhisperService.instance.isAvailable, isFalse,
        reason: '复检失败应立即转为不可用');
    expect(
      StorageService.instance.getSetting(StorageService.kWhisperDetection),
      '',
      reason: '复检失败应清除缓存',
    );
  });

  test('设置变更（后端偏好）：缓存过期走全量探测', () async {
    // 缓存是 openai 后端，但用户偏好已切 faster
    await StorageService.instance.setSetting(
        StorageService.kWhisperDetection, cacheJson(fakeWhisper));
    await StorageService.instance.setSetting(
        StorageService.kWhisperBackend, 'faster');

    var probed = false;
    WhisperService.probeOverride = (cmd, args) async {
      probed = true;
      return ProcessResult(0, 1, '', 'no'); // 全部探测失败
    };

    await WhisperService.instance.init();

    expect(probed, isTrue, reason: '偏好与缓存不一致时必须全量探测');
    expect(WhisperService.instance.isAvailable, isFalse);
  });
}
