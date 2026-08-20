import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:subtitle_studio_pro/screens/track_screen.dart';
import 'package:subtitle_studio_pro/services/mkvtoolnix/mkvtoolnix_service.dart';

/// 封装页布局回归测试（dev-fix）：
/// - 纯重封装（无外部轨道，仅对源 MKV 删减轨道）时源轨道列表必须渲染
/// - 章节/标签等全局项默认折叠，展开后可勾选
/// - 常见窗口尺寸下整页不得出现 RenderFlex 底部溢出
///
/// 夹具在 setUpAll 用本机 mkvmerge 现场生成（静音 WAV 音轨 + 多语言 SRT
/// 字幕 + 章节 + 全局标签），无外部媒体依赖；检测不到 MKVToolNix 时跳过。
///
/// 必须用 LiveTestWidgetsFlutterBinding：默认的 Automated binding 把测试
/// 跑在 FakeAsync zone 里，widget 代码发起的 dart:io（mkvmerge -J 探测）
/// 完成事件永远无法派发，探测不结束 → 不确定动画常驻 → pumpAndSettle
/// 必然超时。Live binding 下一切异步均为真实时间，探测可正常完成。
///
/// 窗口尺寸必须用 setSurfaceSize：Live binding 的
/// createViewConfigurationFor 只认 _surfaceSize（setSurfaceSize 设置），
/// 不认 tester.view.physicalSize（渲染面仍是默认 800x600）。
/// view 物理尺寸与 DPR 同步设置，保证 MediaQuery 与渲染面一致。
void main() {
  LiveTestWidgetsFlutterBinding();

  final tmp = Directory.systemTemp.createTempSync('mux_layout_test');

  setUpAll(() async {
    final mkvmerge = <String>[
      r'D:\Program Files\MKVToolNix\mkvmerge.exe',
      r'C:\Program Files\MKVToolNix\mkvmerge.exe',
      r'C:\Program Files (x86)\MKVToolNix\mkvmerge.exe',
    ].firstWhereOrNull((p) => File(p).existsSync());
    if (mkvmerge == null) {
      throw StateError('未找到 mkvmerge，跳过封装页布局测试');
    }

    // 静音 WAV：48kHz 立体声 16bit 3 秒
    final wav = File('${tmp.path}${Platform.pathSeparator}silence.wav');
    const dataLen = 48000 * 2 * 2 * 3;
    final bw = wav.openSync(mode: FileMode.write);
    void ascii(String s) => bw.writeFromSync(s.codeUnits);
    void i32(int v) => bw.writeFromSync([
          v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff,
        ]);
    void i16(int v) => bw.writeFromSync([v & 0xff, (v >> 8) & 0xff]);
    ascii('RIFF');
    i32(36 + dataLen);
    ascii('WAVE');
    ascii('fmt ');
    i32(16);
    i16(1);
    i16(2);
    i32(48000);
    i32(48000 * 2 * 2);
    i16(4);
    i16(16);
    ascii('data');
    i32(dataLen);
    bw.writeFromSync(List<int>.filled(dataLen, 0));
    bw.closeSync();

    // 多语言 SRT
    const srt = '1\n00:00:00,000 --> 00:00:02,000\n测试\n';
    for (final lang in ['chi', 'eng', 'jpn', 'kor']) {
      File('${tmp.path}${Platform.pathSeparator}$lang.srt').writeAsStringSync(srt);
    }

    // 章节与全局标签
    File('${tmp.path}${Platform.pathSeparator}chapters.xml').writeAsStringSync('''
<?xml version="1.0"?>
<Chapters>
  <EditionEntry>
    <ChapterAtom>
      <ChapterTimeStart>00:00:00.000</ChapterTimeStart>
      <ChapterDisplay><ChapterString>开场</ChapterString></ChapterDisplay>
    </ChapterAtom>
    <ChapterAtom>
      <ChapterTimeStart>00:00:02.000</ChapterTimeStart>
      <ChapterDisplay><ChapterString>中段</ChapterString></ChapterDisplay>
    </ChapterAtom>
  </EditionEntry>
</Chapters>
''');
    File('${tmp.path}${Platform.pathSeparator}tags.xml').writeAsStringSync('''
<Tags>
  <Tag>
    <Simple><Name>TITLE</Name><String>测试影片</String></Simple>
  </Tag>
</Tags>
''');

    // 字体附件夹具（mkvmerge 不校验字体内容，任意字节即可附加）
    for (final font in ['TestFontA.ttf', 'TestFontB.otf']) {
      File('${tmp.path}${Platform.pathSeparator}$font')
          .writeAsBytesSync(List<int>.filled(256, 0x1a));
    }

    final fixture = File('${tmp.path}${Platform.pathSeparator}fixture.mkv');
    final r = await Process.run(mkvmerge, [
      '-o', fixture.path,
      '--language', '0:chi', '--track-name', '0:中文配音',
      '${tmp.path}${Platform.pathSeparator}chi.srt',
      '--language', '0:eng', '${tmp.path}${Platform.pathSeparator}eng.srt',
      '--language', '0:jpn', '${tmp.path}${Platform.pathSeparator}jpn.srt',
      '--language', '0:kor', '${tmp.path}${Platform.pathSeparator}kor.srt',
      '--chapters', '${tmp.path}${Platform.pathSeparator}chapters.xml',
      '--attach-file', '${tmp.path}${Platform.pathSeparator}TestFontA.ttf',
      '--attach-file', '${tmp.path}${Platform.pathSeparator}TestFontB.otf',
      '--language', '0:jpn', wav.path,
      '--global-tags', '${tmp.path}${Platform.pathSeparator}tags.xml',
    ]);
    expect(r.exitCode, anyOf(0, 1), reason: '夹具生成失败：${r.stderr}');

    await MkvToolNixService.instance.init();
    expect(MkvToolNixService.instance.isAvailable, isTrue,
        reason: 'MKVToolNix 不可用，无法运行封装页布局测试');
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  /// 条件等待（替代固定 sleep）：每轮推进 100ms 真实时间并出一帧，
  /// 直到条件成立或超时。探测是真实 mkvmerge 进程，耗时不受测试控制。
  Future<bool> waitFor(
      WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < 100; i++) {
      if (condition()) return true;
      await tester.pump(const Duration(milliseconds: 100));
    }
    return condition();
  }

  /// 注入视频路径并等真实 mkvmerge -J 探测完成（源轨道标题出现）。
  Future<void> addVideo(WidgetTester tester, String path) async {
    FilePickerPlatform.instance = _FakePicker([path]);
    // 输入区的「添加视频」排在空态按钮之前
    await tester.tap(find.text('添加视频').first);
    await tester.pump();
    final ok = await waitFor(
        tester, () => find.text('源轨道').evaluate().isNotEmpty);
    expect(ok, isTrue, reason: 'mkvmerge -J 探测超时未完成');
    // 探测完成后进度条消失，无持续动画，可安全 settle
    await tester.pumpAndSettle();
  }

  /// 一致地设置窗口逻辑尺寸（渲染面 + MediaQuery 同步）。
  Future<void> setWindowSize(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
  }

  for (final size in [
    const Size(1920, 1080),
    const Size(1280, 800),
    const Size(1280, 720),
    const Size(1024, 640),
  ]) {
    testWidgets('纯重封装：源轨道可见且 ${size.width}x${size.height} 无溢出',
        (tester) async {
      await setWindowSize(tester, size);
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.reset();
      });

      await tester.pumpWidget(const MaterialApp(home: TrackScreen(initialTab: 1)));
      await tester.pumpAndSettle();

      await addVideo(
        tester,
        '${tmp.path}${Platform.pathSeparator}fixture.mkv',
      );

      // 问题 1：纯重封装（无外部轨道）时源轨道区必须渲染
      expect(find.text('源轨道'), findsOneWidget);
      // 源音轨默认勾选行（WAV 音轨 TID 0）
      expect(find.byType(Checkbox), findsWidgets);

      // 问题 3：任意尺寸都不得出现 RenderFlex 溢出
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('附件大类（字体/章节/标签）默认折叠，逐层展开', (tester) async {
    await setWindowSize(tester, const Size(1280, 800));
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      tester.view.reset();
    });

    await tester.pumpWidget(const MaterialApp(home: TrackScreen(initialTab: 1)));
    await tester.pumpAndSettle();

    await addVideo(tester, '${tmp.path}${Platform.pathSeparator}fixture.mkv');
    expect(find.text('源轨道'), findsOneWidget);

    // 问题 2：附件大类默认折叠，子项行均不渲染
    expect(find.text('章节'), findsNothing);
    expect(find.text('标签（轨道/全局 tags）'), findsNothing);
    expect(find.textContaining('字体 2/2'), findsNothing);
    expect(find.textContaining('TestFontA.ttf'), findsNothing);

    // 展开附件大类：字体子组头 + 章节/标签勾选行可见；字体明细仍折叠
    final attachRow = find.textContaining('附件（');
    await tester.ensureVisible(attachRow);
    await tester.pumpAndSettle();
    await tester.tap(attachRow);
    await tester.pumpAndSettle();
    expect(find.textContaining('字体 2/2'), findsOneWidget);
    expect(find.text('章节'), findsOneWidget);
    expect(find.text('标签（轨道/全局 tags）'), findsOneWidget);
    // 字体明细（各字体行）默认折叠
    expect(find.textContaining('TestFontA.ttf'), findsNothing);

    // 再展开字体子组：逐个字体行可见，默认全勾选（保留）
    final fontGroup = find.textContaining('字体 2/2');
    await tester.ensureVisible(fontGroup);
    await tester.pumpAndSettle();
    await tester.tap(fontGroup);
    await tester.pumpAndSettle();
    expect(find.textContaining('AID 1 · TTF · TestFontA.ttf'), findsOneWidget);
    expect(find.textContaining('AID 2 · OTF · TestFontB.otf'), findsOneWidget);
    expect(find.text('保留'), findsNWidgets(2));

    // 取消勾选第二个字体：行状态变「排除」，摘要变 1/2
    // （页面上源轨道行也有 Checkbox，须定位字体行内的复选框）
    final row2 = find.textContaining('AID 2 · OTF · TestFontB.otf');
    await tester.ensureVisible(row2);
    await tester.pumpAndSettle();
    final row2Box = find.descendant(
      of: find
          .ancestor(of: row2, matching: find.byType(Row))
          .first
          .first,
      matching: find.byType(Checkbox),
    );
    await tester.tap(row2Box);
    await tester.pumpAndSettle();
    expect(find.text('排除'), findsOneWidget);
    expect(find.text('保留'), findsOneWidget);
    expect(find.textContaining('字体 1/2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// file_picker 12 注入缝：fake 平台接口实现（FilePicker 静态门面
/// 委托 FilePickerPlatform.instance，fake 需混入 MockPlatformInterfaceMixin
/// 才能通过 PlatformInterface.verifyToken）。
class _FakePicker extends FilePickerPlatform with MockPlatformInterfaceMixin {
  _FakePicker(this.paths);

  final List<String> paths;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async =>
      [for (final path in paths) _FakePlatformFile(path)];

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async =>
      null;
}

/// 本地磁盘文件的 PlatformFile 最小实现（v12 起为抽象类，不可直接构造）。
base class _FakePlatformFile extends PlatformFile {
  _FakePlatformFile(this.filePath);

  final String filePath;

  @override
  String get name => filePath.split(RegExp(r'[\\/]')).last;

  @override
  Uri get uri => Uri.file(filePath);

  @override
  XFile get xFile => XFile(filePath);

  @override
  Future<int> length() async =>
      File(filePath).existsSync() ? File(filePath).lengthSync() : 0;

  @override
  Future<Uint8List> readAsBytes() => File(filePath).readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() =>
      File(filePath).openRead().cast<Uint8List>();
}

extension<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
