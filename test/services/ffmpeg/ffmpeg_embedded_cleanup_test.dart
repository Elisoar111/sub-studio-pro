import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_runner.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';

/// 内嵌字幕轨烧录的临时文件清理（v2.0.1）：
/// burnEmbeddedTrack 预提取的 `embedded_track_<n>.srt` 临时字幕
/// 在烧录完成（成功 / 失败）后必须删除，防止系统临时目录堆积。
///
/// 用内存 fake runner 模拟 ffmpeg 落盘行为，不依赖本机 FFmpeg。
void main() {
  late Directory tempRoot;
  late _FakeRunner runner;
  late FfmpegService svc;
  late File video;
  late File output;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('embedded_cleanup');
    PathProviderPlatform.instance = _FakePathProvider(tempRoot.path);
    runner = _FakeRunner();
    svc = FfmpegService.forTest(runner);
    video = File('${tempRoot.path}${Platform.pathSeparator}in.mp4')
      ..writeAsBytesSync(List.filled(8, 1));
    output = File('${tempRoot.path}${Platform.pathSeparator}out.mp4');
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  // tempDir() = 系统临时目录/<appDirName>，预提取的 SRT 落在这里
  File tmpSub(int track) => File(p.join(
      tempRoot.path, 'subtitle_studio', 'embedded_track_$track.srt'));

  test('烧录成功后临时字幕被删除，输出产物保留', () async {
    final r = await svc.burnEmbeddedTrack(
      videoPath: video.path,
      trackIndex: 0,
      outputPath: output.path,
    );

    expect(r.success, isTrue);
    expect(output.existsSync(), isTrue, reason: '烧录产物应保留');
    expect(tmpSub(0).existsSync(), isFalse,
        reason: '预提取的临时 SRT 应在烧录后删除');
  });

  test('烧录失败时临时字幕同样被删除', () async {
    runner.failBurn = true;

    final r = await svc.burnEmbeddedTrack(
      videoPath: video.path,
      trackIndex: 0,
      outputPath: output.path,
    );

    expect(r.success, isFalse);
    expect(tmpSub(0).existsSync(), isFalse,
        reason: '失败路径也不应遗留临时 SRT');
  });
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.tempPath);

  final String tempPath;

  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

/// fake ffmpeg：按参数落盘假产物。
/// - 提取（含 `embedded_track_*.srt` 输出）→ 写假 SRT，成功
/// - 烧录（输出为调用方 outputPath）→ [failBurn] 控制成败
class _FakeRunner implements FfmpegRunner {
  bool failBurn = false;

  @override
  Future<TaskRunResult> run(
    FfmpegRunRequest request, {
    void Function(FfmpegProgress progress)? onProgress,
    void Function(String line)? onLog,
    CancelToken? cancelToken,
  }) async {
    final isExtract = request.arguments
        .any((a) => a.contains('embedded_track_') && a.endsWith('.srt'));
    if (isExtract) {
      final out = request.arguments.firstWhere(
          (a) => a.contains('embedded_track_') && a.endsWith('.srt'));
      File(out).writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\nhi\n');
      return const TaskRunResult(success: true);
    }
    if (failBurn) {
      return const TaskRunResult(success: false, error: 'burn failed');
    }
    final out = request.arguments
        .lastWhere((a) => a.endsWith('.mp4') && a != a.toLowerCase());
    File(out).writeAsBytesSync(List.filled(16, 2));
    return const TaskRunResult(success: true);
  }

  @override
  String get platformName => 'fake';
  @override
  bool get isWeb => false;
  @override
  bool get supportsProgressOutput => true;
  @override
  Future<void> init() async {}
  @override
  Future<String> getVersion() async => 'fake-1.0';
  @override
  Future<Map<String, dynamic>?> probe(String path) async => null;
  @override
  Future<void> dispose() async {}
  @override
  bool get isAvailable => true;
  @override
  String? get initError => null;
  @override
  String? get sourceLabel => null;
  @override
  String? get resolvedBinPath => null;
  @override
  Future<Set<String>> availableEncoders() async => const {};
}
