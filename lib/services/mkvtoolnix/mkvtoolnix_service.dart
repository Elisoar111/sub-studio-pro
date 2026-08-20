import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants.dart';
import '../../core/utils/logger.dart';
import '../../models/mux_track.dart';
import '../ffmpeg/ffmpeg_runner.dart';
import '../storage_service.dart';

/// ── MKVToolNix 集成（对齐 gMKVExtractGUI 的实现方式）──
///
/// gMKVExtractGUI 本身不解析 MKV，只做 GUI：
/// - 轨道分析：mkvmerge -J（JSON 输出，毫秒级，含轨道/附件/章节/标签）
/// - 提取执行：mkvextract（tracks / attachments / chapters / tags / cuesheet）
/// - 进度：解析 stdout 的 "Progress: N%" 行
///
/// 本服务在应用内等价实现：
/// - [probe]：mkvmerge -J → MkvFileInfo（轨道 ID 即 mkvextract 的 TID/AID）
/// - [extractTrackAuto]：提取唯一入口（MKV 直提；非 MKV 先无损转封临时
///   MKV 再提），底层 [extractTrack] 走 mkvextract
/// - [merge]：mkvmerge 封装（唯一封装后端；退出码 1=警告视为成功，2=失败）
/// - 定位顺序：设置目录 → 捆绑 resources/mkvtoolnix → 应用工具目录（导入
///   副本，见 [importTools]）→ 常见安装路径 → 系统 PATH
///
/// 提取与封装不再使用 FFmpeg（烧录 / 转码 / 转换仍走 FFmpeg）。

/// mkvmerge -J 的一条轨道。
class MkvTrackInfo {
  final int id;

  /// mkvmerge -J `properties.track_number`（1-based 全局轨道序号，
  /// gMKVExtractGUI 命名用；注意与 [id]（mkvextract 用的 0-based）不同）
  final int number;

  /// video / audio / subtitle
  final String type;

  /// CodecID（S_TEXT/UTF8、A_AAC、V_MPEG4/ISO/AVC…）
  final String codecId;

  /// 人类可读编码名（ffprobe 风格归一化，供 UI 与扩展名映射复用）
  final String codec;

  /// ISO 639-2 原始值（含 und，gMKV 命名与显示均保留）
  final String language;

  final String trackName;
  final bool defaultTrack;
  final bool forcedTrack;

  /// MKVToolNix flag-enabled（enabled_track；禁用轨保留在容器但不播放）
  final bool enabled;

  /// 容器内轨道 UID
  final int? uid;
  final int? channels;
  final int? samplingRate;
  final int? pixelWidth;
  final int? pixelHeight;

  /// mkvmerge -J `properties.minimum_timestamp`（纳秒）。
  /// gMKVExtractGUI 的 DELAY 命名来源：音轨 − 视频轨。
  final int? minTimestampNs;

  const MkvTrackInfo({
    required this.id,
    required this.type,
    required this.codecId,
    required this.codec,
    this.number = 0,
    this.language = '',
    this.trackName = '',
    this.defaultTrack = false,
    this.forcedTrack = false,
    this.enabled = true,
    this.uid,
    this.channels,
    this.samplingRate,
    this.pixelWidth,
    this.pixelHeight,
    this.minTimestampNs,
  });

  bool get isBitmapSubtitle =>
      codecId.startsWith('S_HDMV/PGS') || codecId.startsWith('S_VOBSUB');
}

/// mkvmerge -J 的一条附件。
class MkvAttachmentInfo {
  final int id;
  final String fileName;
  final String contentType;

  const MkvAttachmentInfo({
    required this.id,
    required this.fileName,
    this.contentType = '',
  });

  /// 归一化到 ffprobe 风格（AttachmentStreamInfo.codec 用）。
  String get codecKind {
    final ext = p.extension(fileName).toLowerCase().replaceFirst('.', '');
    if (ext == 'ttf') return 'ttf';
    if (ext == 'otf') return 'otf';
    if (contentType.contains('truetype')) return 'ttf';
    if (contentType.contains('opentype')) return 'otf';
    return ext.isEmpty ? 'bin' : ext;
  }
}

/// mkvmerge -J 解析结果。
class MkvFileInfo {
  final String path;
  final Duration duration;
  final List<MkvTrackInfo> tracks;
  final List<MkvAttachmentInfo> attachments;
  final bool hasChapters;
  final bool hasTags;

  const MkvFileInfo({
    required this.path,
    this.duration = Duration.zero,
    this.tracks = const [],
    this.attachments = const [],
    this.hasChapters = false,
    this.hasTags = false,
  });
}

class MkvToolNixService {
  MkvToolNixService._();

  static final MkvToolNixService instance = MkvToolNixService._();

  String? _mkvmergeBin;
  String? _mkvextractBin;
  String? _version;
  String? _sourceLabel;
  bool _available = false;
  String? _error;
  bool _checked = false;

  /// mkvmerge -J 探测结果缓存：以「路径 + mtime」为键，
  /// 同一文件不重复探测。跨页面共享（提取页 / 封装页 / 队列执行）。
  final Map<String, ({MkvFileInfo info, String mtime})> _probeCache = {};

  /// 进行中的探测（防同文件并发重复探测）。
  final Map<String, Future<MkvFileInfo?>> _inFlight = {};

  /// 缓存上限（避免无限增长，LRU 淘汰）。
  static const _maxCacheSize = 64;

  /// 可用性变化通知：设置页配置/导入后，已构建的页面（IndexedStack 中
  /// 不会因路由返回而重建）据此实时刷新警告横幅与按钮状态。
  final ValueNotifier<bool> availability = ValueNotifier<bool>(false);

  bool get isAvailable => _available;
  String? get version => _version;
  String? get sourceLabel => _sourceLabel;
  String? get error => _error;

  /// 当前使用的 mkvmerge 完整路径（PATH 命中时为可执行名；不可用为 null）。
  String? get mkvmergePath => _available ? _mkvmergeBin : null;

  // ───────────────────────── 定位 / 检测 ─────────────────────────

  /// 检测 MKVToolNix（幂等）。设置页修改目录后调 [configure] 重检。
  Future<void> init() async {
    if (_checked) return;
    _checked = true;
    if (!Platform.isWindows) {
      _error = 'MKVToolNix 集成仅支持 Windows';
      return;
    }
    final configured = StorageService.instance.getSetting(
      StorageService.kMkvtoolnixDir,
    );
    final appTools = await _appToolsDir();
    final candidates = <({String dir, String label})>[
      if (configured.isNotEmpty) (dir: configured, label: '自定义路径'),
      (dir: _bundledDir(), label: '捆绑版'),
      if (appTools != null) (dir: appTools, label: '应用内导入'),
      (dir: 'C:\\Program Files\\MKVToolNix', label: '系统安装'),
      (dir: 'C:\\Program Files (x86)\\MKVToolNix', label: '系统安装'),
      (dir: 'D:\\Program Files\\MKVToolNix', label: '系统安装'),
      (dir: 'D:\\Program Files (x86)\\MKVToolNix', label: '系统安装'),
    ];
    for (final c in candidates) {
      if (await _tryDir(c.dir)) {
        _sourceLabel = c.label;
        _available = true;
        availability.value = true;
        Logger.instance.log(
          '检测到 MKVToolNix $_version（来源：$_sourceLabel）',
          tag: 'MKVTOOLNIX',
        );
        return;
      }
    }
    // 最后尝试系统 PATH（无目录，直接按可执行名调用）
    if (await _tryDir(null)) {
      _sourceLabel = '系统 PATH';
      _available = true;
      availability.value = true;
      return;
    }
    availability.value = false;
    _error = '未检测到 MKVToolNix：轨道提取与封装完全依赖它。'
        '请安装 MKVToolNix，或在本页选择其安装目录/导入到应用内。';
  }

  /// 捆绑目录（发布时随 exe 分发：<exe目录>/resources/mkvtoolnix/）。
  String _bundledDir() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      return p.join(exeDir.path, 'resources', 'mkvtoolnix');
    } catch (_) {
      return '';
    }
  }

  /// 应用内导入目录（文档目录/subtitle_studio/tools/mkvtoolnix）。
  Future<String?> _appToolsDir() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      return p.join(docs.path, AppConstants.appDirName, 'tools', 'mkvtoolnix');
    } catch (_) {
      return null;
    }
  }

  /// 目录可用性检测（null = 按 PATH 调用）。
  Future<bool> _tryDir(String? dir) async {
    final merge = dir == null ? 'mkvmerge.exe' : p.join(dir, 'mkvmerge.exe');
    final extract =
        dir == null ? 'mkvextract.exe' : p.join(dir, 'mkvextract.exe');
    try {
      if (dir != null &&
          (!File(merge).existsSync() || !File(extract).existsSync())) {
        return false;
      }
      final r = await Process.run(merge, ['--version'],
          stdoutEncoding: utf8, stderrEncoding: utf8);
      if (r.exitCode != 0) return false;
      final first = (r.stdout as String).split('\n').first.trim();
      final m = RegExp(r'mkvmerge v([\d.]+)').firstMatch(first);
      _version = m?.group(1) ?? first;
      _mkvmergeBin = merge;
      _mkvextractBin = extract;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 配置自定义目录（空串清除）。保存后需重新 [init] 检测。
  Future<void> configure(String? dir) async {
    final clean = (dir == null || dir.isEmpty) ? '' : dir;
    await StorageService.instance.setSetting(
      StorageService.kMkvtoolnixDir,
      clean,
    );
    _checked = false;
    _available = false;
    availability.value = false;
    _version = null;
    _sourceLabel = null;
    _error = null;
    _mkvmergeBin = null;
    _mkvextractBin = null;
    await init();
  }

  /// 从安装目录把 MKVToolNix 工具导入应用内（拷贝 exe / dll / 数据文件）。
  /// 导入后无需系统安装即可使用（便携化"移植"）。
  Future<String?> importTools(String sourceDir) async {
    final src = Directory(sourceDir);
    if (!src.existsSync() ||
        !File(p.join(sourceDir, 'mkvmerge.exe')).existsSync()) {
      return null;
    }
    final dest = await _appToolsDir();
    if (dest == null) return null;
    await Directory(dest).create(recursive: true);
    // MKVToolNix 安装目录为扁平结构：拷贝全部顶层文件（exe/dll/dat）
    await for (final e in src.list()) {
      if (e is File) {
        await e.copy(p.join(dest, p.basename(e.path)));
      }
    }
    return dest;
  }

  /// 指定文件是否适合 mkv 后端（Matroska 家族）。
  static bool isMatroska(String path) {
    final ext = p.extension(path).toLowerCase();
    return ext == '.mkv' || ext == '.webm';
  }

  // ───────────────────────── 探测（mkvmerge -J） ─────────────────────────

  /// 解析 MKV 全部轨道 / 附件 / 章节 / 标签。失败返回 null（调用方回退 ffprobe）。
  ///
  /// 结果以「路径 + 文件 mtime」为键缓存：同一文件在 mtime 未变时
  /// 不重复 spawn mkvmerge -J。跨页面共享（提取页 / 封装页 / 队列）。
  Future<MkvFileInfo?> probe(String path) async {
    if (!_available || _mkvmergeBin == null) return null;

    // 检查缓存：路径 + mtime 一致则命中
    try {
      final stat = File(path).statSync();
      final mtimeKey = stat.modified.millisecondsSinceEpoch.toString();
      final cached = _probeCache[path];
      if (cached != null && cached.mtime == mtimeKey) {
        return cached.info;
      }
    } catch (_) {
      // 文件不存在或无法访问，继续走正常探测
    }

    // 防并发重复探测：同一路径的进行中探测复用 Future
    final inFlight = _inFlight[path];
    if (inFlight != null) return inFlight;

    final future = _doProbe(path);
    _inFlight[path] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(path);
    }
  }

  Future<MkvFileInfo?> _doProbe(String path) async {
    try {
      final r = await Process.run(_mkvmergeBin!, ['-J', path],
          stdoutEncoding: utf8, stderrEncoding: utf8);
      // mkvmerge -J 退出码：0 = 成功，1 = 警告（JSON 仍完整有效，
      // 常见于轻微损坏的 MKV），2 = 识别失败。1 不能当失败。
      if (r.exitCode != 0 && r.exitCode != 1) return null;
      final json = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      final info = parseIdentify(json, path);
      // 缓存结果
      try {
        final stat = File(path).statSync();
        final mtimeKey = stat.modified.millisecondsSinceEpoch.toString();
        if (_probeCache.length >= _maxCacheSize) {
          _probeCache.remove(_probeCache.keys.first);
        }
        _probeCache[path] = (info: info, mtime: mtimeKey);
      } catch (_) {}
      return info;
    } catch (e) {
      Logger.instance.error('mkvmerge -J 失败: $path', e);
      return null;
    }
  }

  /// 清除探测缓存（文件修改/删除后失效自愈，一般无需手动调用）。
  void clearProbeCache() => _probeCache.clear();

  /// 使指定路径的缓存失效。
  void invalidateProbe(String path) => _probeCache.remove(path);

  /// 解析 mkvmerge -J 的 JSON（公开供回归测试：type 复数归一化等）。
  ///
  /// 整数一律经安全转换：Matroska UID 是 uint64 随机数，约半数超出
  /// Dart int（有符号 64 位）范围，jsonDecode 会将其解析为 double，
  /// 直接 `as int?` 会抛 TypeError 使整个 probe 失败。
  static MkvFileInfo parseIdentify(Map<String, dynamic> json, String path) {
    int? asInt(dynamic v) => v is int ? v : null;

    // duration 在不同版本位于 container.properties 或顶层 container_properties
    final container = json['container'] as Map<String, dynamic>? ?? const {};
    final props =
        (json['container_properties'] as Map<String, dynamic>?) ??
        (container['properties'] as Map<String, dynamic>?) ??
            const {};
    final durationMs = (props['duration'] as num?)?.toDouble();

    final tracks = (json['tracks'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((t) {
          final tp = t['properties'] as Map<String, dynamic>? ?? const {};
          final codecId = tp['codec_id'] as String? ?? '';
          // mkvmerge -J 的 type 枚举为 video/audio/subtitles（字幕为复数），
          // 归一化为单数供 UI 统一判断
          final rawType = t['type'] as String? ?? '';
          final type = rawType == 'subtitles' ? 'subtitle' : rawType;
          final lang = tp['language'] as String?;
          final sampling = tp['sampling_frequency'];
          return MkvTrackInfo(
            id: asInt(t['id']) ?? 0,
            number: asInt(tp['track_number']) ?? 0,
            type: type,
            codecId: codecId,
            codec: _normalizeCodec(codecId),
            language: lang ?? '',
            trackName: tp['track_name'] as String? ?? '',
            defaultTrack: tp['default_track'] as bool? ?? false,
            forcedTrack: tp['forced_track'] as bool? ?? false,
            channels: asInt(tp['num_channels']),
            samplingRate: sampling is num ? sampling.toInt() : null,
            pixelWidth: asInt(tp['pixel_width']),
            pixelHeight: asInt(tp['pixel_height']),
            minTimestampNs: asInt(tp['minimum_timestamp']),
            enabled: tp['enabled_track'] as bool? ?? true,
            uid: asInt(tp['uid']),
          );
        })
        .toList();

    final attachments = (json['attachments'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((a) => MkvAttachmentInfo(
              id: asInt(a['id']) ?? 0,
              fileName: a['file_name'] as String? ?? '',
              contentType: a['content_type'] as String? ?? '',
            ))
        .toList();

    return MkvFileInfo(
      path: path,
      duration: Duration(milliseconds: ((durationMs ?? 0) * 1000).round()),
      tracks: tracks,
      attachments: attachments,
      hasChapters: (json['chapters'] as List? ?? const []).isNotEmpty,
      hasTags: (json['global_tags'] as List? ?? const []).isNotEmpty ||
          (json['track_tags'] as List? ?? const []).isNotEmpty,
    );
  }

  /// CodecID → ffprobe 风格编码名（复用提取页的扩展名/图形字幕判断）。
  static String _normalizeCodec(String codecId) {
    if (codecId.startsWith('S_TEXT/UTF8')) return 'subrip';
    if (codecId.startsWith('S_TEXT/SSA') || codecId.startsWith('S_SSA')) {
      return 'ssa';
    }
    if (codecId.startsWith('S_TEXT/ASS') || codecId.startsWith('S_ASS')) {
      return 'ass';
    }
    if (codecId.startsWith('S_TEXT/WEBVTT')) return 'webvtt';
    if (codecId.startsWith('S_HDMV/PGS')) return 'pgs';
    if (codecId.startsWith('S_VOBSUB')) return 'dvd_subtitle';
    if (codecId.startsWith('S_KATE')) return 'kate';
    if (codecId.startsWith('A_')) {
      final sub = codecId.substring(2);
      return switch (sub) {
        'AAC' => 'aac',
        'AC3' => 'ac3',
        'EAC3' => 'eac3',
        'DTS' => 'dts',
        'MP3' => 'mp3',
        'MP2' => 'mp2',
        'FLAC' => 'flac',
        'OPUS' => 'opus',
        'VORBIS' => 'vorbis',
        'TRUEHD' => 'truehd',
        _ => codecId.startsWith('A_PCM') ? 'pcm_s16le' : sub.toLowerCase(),
      };
    }
    if (codecId.startsWith('V_')) {
      final sub = codecId.substring(2);
      if (sub.startsWith('MPEG4/ISO/AVC')) return 'h264';
      if (sub.startsWith('MPEG-H/HEVC')) return 'hevc';
      if (sub.startsWith('VP9')) return 'vp9';
      if (sub.startsWith('VP8')) return 'vp8';
      if (sub.startsWith('AV1')) return 'av1';
      if (sub.startsWith('MPEG4/ISO/ASP')) return 'mpeg4';
      if (sub.startsWith('MS/VFW/FOURCC')) return 'xvid';
      return sub.toLowerCase();
    }
    return codecId;
  }

  /// 文本字幕轨（mkvextract 支持 -c 字符集转换的类型）。
  static bool isTextSubtitle(String codecId) =>
      codecId.startsWith('S_TEXT/') ||
      codecId.startsWith('S_ASS') ||
      codecId.startsWith('S_SSA');

  // ───────────────────────── 提取（mkvextract） ─────────────────────────

  /// 单轨提取。[trackType]：
  /// - video / audio / subtitle → `tracks TID:dest`
  /// - attachment → `attachments AID:dest`
  /// - chapters / tags → 对应模式单输出（全局，不用轨道 ID）
  /// - cuesheet → 逐轨模式 `cuesheet TID:dest`
  ///
  /// MKV 文本字幕按容器规范即为 UTF-8，mkvextract 原样写出，
  /// 无需（也不存在）字符集转换参数。
  Future<TaskRunResult> extractTrack({
    required String videoPath,
    required int id,
    required String trackType,
    required String outputPath,
    Duration? totalDuration,
    void Function(FfmpegProgress progress)? onProgress,
    void Function(String line)? onLog,
    CancelToken? cancelToken,
  }) async {
    if (!_available || _mkvextractBin == null) {
      return TaskRunResult(success: false, error: _error ?? 'MKVToolNix 不可用');
    }
    final args = <String>[videoPath];
    switch (trackType) {
      case 'attachment':
        args.addAll(['attachments', '$id:$outputPath']);
      case 'chapters':
        args.addAll(['chapters', outputPath]);
      case 'tags':
        args.addAll(['tags', outputPath]);
      case 'cuesheet':
        args.addAll(['cuesheet', '$id:$outputPath']);
      default:
        args.addAll(['tracks', '$id:$outputPath']);
    }
    return _runTool(
      _mkvextractBin!,
      args,
      expectedOutputs: [outputPath],
      // mkvextract 退出码：0 成功；1 警告（产物有效，如个别坏包被跳过）；
      // 2 错误。警告按成功处理（gMKVExtractGUI 同语义）
      warningIsSuccess: true,
      totalDuration: totalDuration,
      onProgress: onProgress,
      onLog: onLog,
      cancelToken: cancelToken,
    );
  }

  /// 自动提取（唯一入口）：MKV/WebM 直接 mkvextract；其余容器先用
  /// mkvmerge 无损转封为临时 MKV 再提取（全程流拷贝不重编码），
  /// 完成后删除临时文件。
  ///
  /// [id] = mkvmerge -J 的轨道/附件 ID；[typeOrdinal] = 该轨在同类型中的
  /// 序号，转封后按序号重定位（防容器转换导致 ID 漂移）。
  Future<TaskRunResult> extractTrackAuto({
    required String videoPath,
    required int id,
    required String trackType,
    required String outputPath,
    int typeOrdinal = 0,
    Duration? totalDuration,
    void Function(FfmpegProgress progress)? onProgress,
    void Function(String line)? onLog,
    CancelToken? cancelToken,
  }) async {
    if (!_available || _mkvextractBin == null || _mkvmergeBin == null) {
      return TaskRunResult(success: false, error: _error ?? 'MKVToolNix 不可用');
    }
    if (isMatroska(videoPath)) {
      return extractTrack(
        videoPath: videoPath,
        id: id,
        trackType: trackType,
        outputPath: outputPath,
        totalDuration: totalDuration,
        onProgress: onProgress,
        onLog: onLog,
        cancelToken: cancelToken,
      );
    }

    // 非 MKV：先无损转封为临时 MKV（mkvmerge 全流拷贝）。
    // 两阶段进度映射：转封占 0→45%、提取占 45→100%，避免进度回跳
    final temp = await tempDir();
    final tmpMkv = p.join(temp, 'mkvextract_${const Uuid().v4()}.mkv');
    final remux = await _runTool(
      _mkvmergeBin!,
      ['-o', tmpMkv, videoPath],
      expectedOutputs: [tmpMkv],
      warningIsSuccess: true,
      totalDuration: totalDuration,
      onProgress: _phaseProgress(onProgress, totalDuration, 0, 45),
      onLog: onLog,
      cancelToken: cancelToken,
    );
    try {
      if (!remux.success) return remux;
      final actualId = await _resolveTrackId(tmpMkv, id, trackType, typeOrdinal);
      return await extractTrack(
        videoPath: tmpMkv,
        id: actualId,
        trackType: trackType,
        outputPath: outputPath,
        totalDuration: totalDuration,
        onProgress: _phaseProgress(onProgress, totalDuration, 45, 100),
        onLog: onLog,
        cancelToken: cancelToken,
      );
    } finally {
      _deleteQuiet(tmpMkv);
    }
  }

  /// 把 _runTool 的 0–100% 进度重映射到 [from]–[to] 区间（百分比）。
  /// totalDuration 缺失时无法换算，原样透传。
  static void Function(FfmpegProgress)? _phaseProgress(
    void Function(FfmpegProgress progress)? onProgress,
    Duration? totalDuration,
    double from,
    double to,
  ) {
    if (onProgress == null) return null;
    final totalMs = totalDuration?.inMilliseconds ?? 0;
    if (totalMs <= 0) return onProgress;
    return (pr) {
      final scaled =
          pr.time.inMilliseconds * (to - from) + totalMs * from / 100;
      onProgress(FfmpegProgress(
        time: Duration(milliseconds: scaled.round()),
      ));
    };
  }

  /// 转封后重定位轨道 ID：优先同类型序号，其次原 ID，最后该类型首轨。
  Future<int> _resolveTrackId(
    String mkvPath,
    int id,
    String trackType,
    int typeOrdinal,
  ) async {
    final info = await probe(mkvPath);
    if (info == null) return id;
    final ids = switch (trackType) {
      'attachment' => info.attachments.map((a) => a.id).toList(),
      'video' || 'audio' || 'subtitle' =>
        info.tracks.where((t) => t.type == trackType).map((t) => t.id).toList(),
      _ => const <int>[],
    };
    if (ids.isEmpty) return id;
    if (typeOrdinal >= 0 && typeOrdinal < ids.length) return ids[typeOrdinal];
    if (id >= 0 && id < ids.length) return ids[id];
    return ids.first;
  }

  /// 临时目录（文档目录/subtitle_studio/tmp）。
  Future<String> tempDir() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = p.join(docs.path, AppConstants.appDirName, AppConstants.dirTemp);
      await Directory(dir).create(recursive: true);
      return dir;
    } catch (_) {
      return Directory.systemTemp.path;
    }
  }

  static void _deleteQuiet(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  // ───────────────────────── 封装（mkvmerge） ─────────────────────────

  /// mkvmerge 封装（MKV 输出，真 MKVToolNix 语义，唯一封装后端）：
  /// - 视频/源音轨/源字幕轨按 [keepAudioIds]/[keepSubIds] 逐条选择流拷贝
  /// - 源字体附件按 [keepAttachmentIds] 逐个选择（null = 全保留）；
  ///   新字体另经 [tracks] 的附件以 --attach-file 添加
  /// - 逐轨 --language/--track-name/--default-track/--forced-track
  /// - 无转码能力（轨均为流拷贝；需转码的场景走转码页先行处理）
  Future<TaskRunResult> merge({
    required String videoPath,
    required List<MuxTrack> tracks,
    required String outputPath,

    /// 保留的源音轨 ID（mkvmerge -J）：null = 全保留，[] = 全排除
    List<int>? keepAudioIds,

    /// 保留的源字幕轨 ID：null = 全保留，[] = 全排除
    List<int>? keepSubIds,

    /// 保留的源附件 ID（-J 附件 ID 从 1 起）：null = 全保留（mkvmerge
    /// 默认），[] = 全排除，非空 = 只保留列出的附件
    List<int>? keepAttachmentIds,

    /// 是否保留源章节（默认保留）
    bool keepChapters = true,

    /// 是否保留源标签（global/track tags，默认保留）
    bool keepTags = true,

    /// 源轨道属性覆盖（MKVToolNix 源轨 track options，
    /// null 字段跟随源；仅对保留的轨道生效）
    List<SourceTrackEdit> sourceEdits = const [],
    Duration? totalDuration,
    void Function(FfmpegProgress progress)? onProgress,
    void Function(String line)? onLog,
    CancelToken? cancelToken,
  }) async {
    if (!_available || _mkvmergeBin == null) {
      return TaskRunResult(success: false, error: _error ?? 'MKVToolNix 不可用');
    }

    final args = <String>['-o', outputPath];

    // ── 源视频（第一个输入）选项 ──
    if (keepAudioIds != null) {
      if (keepAudioIds.isEmpty) {
        args.add('--no-audio');
      } else {
        args.addAll(['--audio-tracks', keepAudioIds.join(',')]);
      }
    }
    if (keepSubIds != null) {
      if (keepSubIds.isEmpty) {
        args.add('--no-subtitles');
      } else {
        args.addAll(['--subtitle-tracks', keepSubIds.join(',')]);
      }
    }
    if (keepAttachmentIds != null) {
      if (keepAttachmentIds.isEmpty) {
        args.add('--no-attachments');
      } else {
        args.addAll(['--attachments', keepAttachmentIds.join(',')]);
      }
    }
    if (!keepChapters) args.add('--no-chapters');
    if (!keepTags) {
      args
        ..add('--no-track-tags')
        ..add('--no-global-tags');
    }

    // ── 源轨道属性覆盖（作用于紧随其后的源视频，轨道用 -J 的 ID）──
    for (final e in sourceEdits) {
      if (e.language != null && e.language!.isNotEmpty) {
        args.addAll(['--language', '${e.id}:${e.language}']);
      }
      if (e.name != null && e.name!.isNotEmpty) {
        args.addAll(['--track-name', '${e.id}:${e.name}']);
      }
      if (e.isDefault != null) {
        args.addAll(['--default-track', '${e.id}:${e.isDefault! ? 1 : 0}']);
      }
      if (e.isForced != null) {
        args.addAll(['--forced-track', '${e.id}:${e.isForced! ? 1 : 0}']);
      }
      if (e.enabled != null) {
        // mkvmerge v100 已移除旧名 --track-enabled（会被当作输入文件名，
        // 整条命令以退出码 2 失败），必须用 --track-enabled-flag
        args.addAll(['--track-enabled-flag', '${e.id}:${e.enabled! ? 1 : 0}']);
      }
      if (e.delayMs != null && e.delayMs != 0) {
        args.addAll(['--sync', '${e.id}:${e.delayMs}']);
      }
    }
    args.add(videoPath);

    // ── 新增轨道（每输入轨 0 号轨） ──
    for (final t in tracks) {
      if (t.type == MuxTrackType.attachment) continue;
      if (t.language.isNotEmpty && t.language != 'und') {
        args.addAll(['--language', '0:${t.language}']);
      }
      if (t.title.isNotEmpty) args.addAll(['--track-name', '0:${t.title}']);
      // 显式写 0/1，避免继承源轨默认标记
      args.addAll(['--default-track', '0:${t.isDefault ? 1 : 0}']);
      // 外部输入轨默认即启用；仅在禁用时写
      // --track-enabled-flag（旧名 --track-enabled 已被 mkvmerge v100 移除）
      if (!t.enabled) args.addAll(['--track-enabled-flag', '0:0']);
      if (t.type == MuxTrackType.subtitle) {
        args.addAll(['--forced-track', '0:${t.isForced ? 1 : 0}']);
      }
      // MKVToolNix sync：正数延后 / 负数提前（毫秒）
      if (t.delayMs != 0) args.addAll(['--sync', '0:${t.delayMs}']);
      args.add(t.path);
    }

    // ── 附件（--attach-file，mimetype 自动识别） ──
    for (final t in tracks) {
      if (t.type != MuxTrackType.attachment) continue;
      args.addAll(['--attach-file', t.path]);
    }

    return _runTool(
      _mkvmergeBin!,
      args,
      expectedOutputs: [outputPath],
      // mkvmerge：0 成功；1 警告（仍产出文件）；2 错误
      warningIsSuccess: true,
      totalDuration: totalDuration,
      onProgress: onProgress,
      onLog: onLog,
      cancelToken: cancelToken,
    );
  }

  /// 第一条源音轨的 mkvmerge -J ID（无音轨/探测失败返回 null）。
  ///
  /// 复用 [probe] 的缓存：同一文件已探测过则不再 spawn mkvmerge -J。
  Future<int?> firstAudioTrackId(String videoPath) async {
    final info = await probe(videoPath);
    if (info == null) return null;
    for (final t in info.tracks) {
      if (t.type == 'audio') return t.id;
    }
    return null;
  }

  // ───────────────────────── 进程执行核心 ─────────────────────────

  /// 运行 mkv 工具子进程：
  /// - 进度：stdout/stderr 逐行解析 `Progress: N%`（mkv 工具用 \r 刷新
  ///   进度行，需按 \r 和 \n 共同分行）
  /// - 取消：CancelToken → Process.kill
  /// - [warningIsSuccess]：mkvmerge 退出码 1（警告）视为成功
  Future<TaskRunResult> _runTool(
    String bin,
    List<String> args, {
    List<String> expectedOutputs = const [],
    bool warningIsSuccess = false,
    Duration? totalDuration,
    void Function(FfmpegProgress progress)? onProgress,
    void Function(String line)? onLog,
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled ?? false) {
      return TaskRunResult.cancelledResult;
    }

    Process? process;
    final logBuffer = StringBuffer();
    var lastPct = -1;

    void onCancel() {
      try {
        process?.kill();
      } catch (_) {}
    }

    cancelToken?.addListener(onCancel);

    Future<void> lines(Stream<List<int>> raw) => raw
        .transform(utf8.decoder)
        .transform(const LineSplitter()) // 按 \n 分行
        .forEach((line) {
        // 进度行用 \r 刷新（一行内含多段），逐段解析
        for (final seg in line.split('\r')) {
          final s = seg.trim();
          if (s.isEmpty) continue;
          final m = RegExp(r'Progress:\s*(\d+)%').firstMatch(s);
          if (m != null) {
            final pct = int.parse(m.group(1)!);
            if (pct != lastPct) {
              lastPct = pct;
              final totalMs = totalDuration?.inMilliseconds ?? 0;
              onProgress?.call(FfmpegProgress(
                time: Duration(
                    milliseconds: totalMs > 0 ? totalMs * pct ~/ 100 : 0),
              ));
            }
          } else {
            logBuffer.writeln(s);
            onLog?.call(s);
          }
        }
      });

    try {
      process = await Process.start(bin, args);
      final outDone = lines(process.stdout);
      final errDone = lines(process.stderr);
      final exitCode = await process.exitCode;
      await outDone;
      await errDone;

      final cancelled = cancelToken?.isCancelled ?? false;
      final log = logBuffer.toString();

      if (cancelled) {
        // 清理被杀进程留下的半成品输出（mkv 工具被 kill 时不自删；
        // Windows 上句柄释放可能稍滞后，删除失败则留待临时清理兜底）
        for (final out in expectedOutputs) {
          _deleteQuiet(out);
        }
        return TaskRunResult(
            success: false, cancelled: true, error: '任务已取消', log: log);
      }

      final outputs = <TaskOutputFile>[];
      for (final out in expectedOutputs) {
        try {
          final f = File(out);
          if (f.existsSync()) {
            outputs.add(TaskOutputFile(name: p.basename(out), path: out));
          }
        } catch (_) {}
      }

      final ok = exitCode == 0 || (warningIsSuccess && exitCode == 1);
      if (ok) {
        return TaskRunResult(success: true, outputs: outputs, log: log);
      }
      return TaskRunResult(
          success: false, error: _friendlyError(exitCode, log), log: log);
    } catch (e) {
      Logger.instance.error('MKVToolNix 进程执行异常', e);
      return TaskRunResult(success: false, error: 'MKVToolNix 进程异常: $e');
    } finally {
      cancelToken?.removeListener(onCancel);
    }
  }

  static String _friendlyError(int exitCode, String log) {
    final lower = log.toLowerCase();
    if (lower.contains('no chapters')) return '文件中不含章节';
    if (lower.contains('no tags')) return '文件中不含标签';
    if (lower.contains('already exists')) return '输出文件已存在';
    if (lower.contains('not found') || lower.contains('cannot open')) {
      return '找不到输入文件或轨道';
    }
    final lines = log.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final tail = lines.length <= 6 ? lines : lines.sublist(lines.length - 6);
    return 'MKVToolNix 执行失败（退出码 $exitCode），最后日志：\n${tail.join('\n')}';
  }
}
