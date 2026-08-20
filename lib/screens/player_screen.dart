import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../core/utils/media_uri.dart';
import '../models/subtitle.dart';
import '../models/video_info.dart';
import '../providers/app_providers.dart';
import '../services/file_service.dart';
import '../services/ffmpeg/ffmpeg_runner.dart';
import '../services/ffmpeg/ffmpeg_service.dart';
import '../services/subtitle/subtitle_parser.dart';
import '../widgets/common.dart';
import '../widgets/player/player_controls.dart';
import '../widgets/player/playlist_panel.dart';
import '../widgets/player/subtitle_style_panel.dart';
import '../widgets/player/video_info_panel.dart';
import '../widgets/subtitle_overlay.dart';

/// 侧栏页签
enum _PanelTab { playlist, subtitle, info }

/// 视频播放页（media_kit / libmpv，Windows 全格式）。
///
/// 本类只负责状态与播放器生命周期；UI 委托给 widgets/player/ 下的组件：
/// - [PlaylistPanel] 播放列表侧栏
/// - [SubtitleStylePanel] 字幕与样式侧栏
/// - [VideoInfoPanel] FFprobe 元数据侧栏
/// - [PlayerTopBar] / [PlayerBottomBar] 浮层控制条
///
/// 功能：播放列表自动连播、音轨/内嵌字幕轨切换、外部字幕叠加、
/// 字幕样式实时调整、同步偏移、快捷键（空格/←→/↑↓/F/S）、倍速 0.25x~4x。
class PlayerScreen extends StatefulWidget {
  /// 为空时在页面内先选择视频
  final String? videoPath;

  /// 可选：初始叠加的字幕文件
  final String? subtitlePath;

  const PlayerScreen({super.key, this.videoPath, this.subtitlePath});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  Player? _player;
  VideoController? _videoController;

  // ── 播放列表 ──
  final List<String> _playlist = [];
  int _index = -1;

  // ── 外部字幕（可加载多个，切换显示）──
  final List<String> _subtitleFiles = [];
  final Map<String, SubtitleDocument> _subDocs = {};
  int _activeSub = -1;
  bool _subtitleVisible = true;
  SubtitleOverlayStyle _style = const SubtitleOverlayStyle();
  Duration _offset = Duration.zero;

  // ── 自动字幕选择 ──
  /// 等待内嵌轨道信息就绪后自动选择
  bool _autoSubPending = false;

  /// 已收到本视频的轨道信息（用于区分“未就绪”与“确无内嵌字幕轨”）
  bool _tracksSeen = false;

  /// 用户已手动选择过字幕 → 本视频不再自动切换
  bool _userPickedSub = false;

  // ── 轨道（mpv 内嵌音轨 / 字幕轨）──
  Tracks _tracks = const Tracks();
  Track _track = const Track();

  // ── 播放状态 ──
  bool _loading = false;
  String? _error;
  bool _controlsVisible = true;
  Timer? _hideTimer;
  bool _fullscreen = false;
  bool _showVolume = false;
  double _volume = 100;

  /// 静音前的音量（取消静音时恢复）
  double _lastVolume = 100;
  double _rate = 1.0;
  double? _dragMs;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  final List<StreamSubscription> _subs = [];

  // ── 侧栏 / 视频信息 ──
  _PanelTab? _panel;
  final Map<String, VideoInfo> _infoCache = {};
  VideoInfo? _info;
  bool _probing = false;

  String? get _currentPath =>
      (_index >= 0 && _index < _playlist.length) ? _playlist[_index] : null;

  @override
  void initState() {
    super.initState();
    if (widget.videoPath != null) {
      _openPlaylist([widget.videoPath!]);
    }
    if (widget.subtitlePath != null) {
      _loadSubtitle(widget.subtitlePath!, user: true);
    }
  }

  void _disposePlayer() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _player?.dispose();
    _player = null;
    _videoController = null;
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _disposePlayer();
    if (_fullscreen) {
      windowManager.setFullScreen(false);
    }
    super.dispose();
  }

  // ───────────────────────── 打开 / 播放列表 ─────────────────────────

  /// 打开播放列表（自动连播由 libmpv 处理；单文件走 Media）。
  Future<void> _openPlaylist(List<String> paths, {int index = 0}) async {
    if (paths.isEmpty) return;
    _disposePlayer();
    setState(() {
      _loading = true;
      _error = null;
      _playlist
        ..clear()
        ..addAll(paths);
      _index = index;
      _controlsVisible = true;
      _playing = false;
      _position = Duration.zero;
      _duration = Duration.zero;
      _rate = 1.0;
      _tracks = const Tracks();
      _track = const Track();
      _autoSubPending = false;
      _tracksSeen = false;
      _userPickedSub = false;
    });
    _probeCurrent();
    try {
      final player = Player();
      final controller = VideoController(player);
      _subs.add(player.stream.playing.listen((v) {
        if (mounted) setState(() => _playing = v);
      }));
      _subs.add(player.stream.position.listen((v) {
        if (mounted) setState(() => _position = v);
      }));
      _subs.add(player.stream.duration.listen((v) {
        if (mounted) setState(() => _duration = v);
      }));
      _subs.add(player.stream.completed.listen((v) {
        if (v && mounted) setState(() => _controlsVisible = true);
      }));
      _subs.add(player.stream.volume.listen((v) {
        if (mounted) setState(() => _volume = v);
      }));
      _subs.add(player.stream.rate.listen((v) {
        if (mounted) setState(() => _rate = v);
      }));
      _subs.add(player.stream.tracks.listen((v) {
        if (mounted) setState(() => _tracks = v);
        _tracksSeen = true;
        _maybeAutoSelectSubtitle();
      }));
      _subs.add(player.stream.track.listen((v) {
        if (mounted) setState(() => _track = v);
      }));
      _subs.add(player.stream.playlist.listen((pl) {
        if (mounted && pl.index != _index && pl.index >= 0) {
          setState(() {
            _index = pl.index;
            _position = Duration.zero;
            _duration = Duration.zero;
            // 清空上一集的轨道快照：否则 _autoSelectSubtitle 会立刻用
            // 过期 track id 选中（新轨道事件尚未到达）
            _tracks = const Tracks();
            _track = const Track();
          });
          _probeCurrent();
          // 新视频载入后 mpv 会把轨道重置为 auto（内嵌字幕自动恢复渲染），
          // 需重新关闭，避免与外部字幕叠加层形成双重字幕
          player.setSubtitleTrack(SubtitleTrack.no());
          _userPickedSub = false;
          _autoSubPending = false;
          _tracksSeen = false;
          _autoSelectSubtitle();
        }
      }));

      if (paths.length == 1) {
        await player.open(mediaFromPath(paths.first));
      } else {
        await player.open(Playlist(
          [for (final path in paths) mediaFromPath(path)],
          index: index,
        ));
      }
      // 默认关闭 mpv 内嵌字幕渲染，由外部字幕叠加层接管（可在轨道菜单切换）
      await player.setSubtitleTrack(SubtitleTrack.no());
      if (!mounted) {
        player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _videoController = controller;
        _loading = false;
      });
      _autoSelectSubtitle();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _pickVideos() async {
    try {
      final picked = await FileService.instance.pickVideos(multi: true);
      if (picked.isEmpty || !mounted) return;
      final paths =
          picked.map((f) => f.path).whereType<String>().toList();
      if (paths.isEmpty) {
        showErrorSnack(context, '无法获取文件路径');
        return;
      }
      // 无播放中内容 → 直接开新列表；否则追加到现有列表
      if (_player == null) {
        await _openPlaylist(paths);
      } else {
        setState(() {
          for (final path in paths) {
            if (!_playlist.contains(path)) _playlist.add(path);
          }
        });
        await _player!.add(mediaFromPath(paths.first));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已添加 ${paths.length} 个视频到播放列表')),
          );
        }
      }
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  void _clearPlaylist() {
    _disposePlayer();
    setState(() {
      _playlist.clear();
      _index = -1;
    });
  }

  void _jumpTo(int i) {
    final player = _player;
    if (player == null || i < 0 || i >= _playlist.length) return;
    if (i == _index) return;
    // 重新打开列表并定位（media_kit 1.1.x 无 jumpToItem）
    _openPlaylist(List.of(_playlist), index: i);
  }

  void _next() {
    if (_index < _playlist.length - 1) _jumpTo(_index + 1);
  }

  void _previous() {
    if (_index > 0) _jumpTo(_index - 1);
  }

  void _removeAt(int i) {
    if (i < 0 || i >= _playlist.length) return;
    setState(() => _playlist.removeAt(i));
    if (_playlist.isEmpty) {
      _disposePlayer();
      setState(() => _index = -1);
      return;
    }
    if (i < _index) {
      setState(() => _index -= 1);
    } else if (i == _index) {
      _openPlaylist(List.of(_playlist),
          index: _index < _playlist.length ? _index : _playlist.length - 1);
    }
  }

  // ───────────────────────── 字幕 ─────────────────────────

  /// 自动选择字幕（每个视频载入后调用一次），优先级：
  /// 1. 内嵌字幕轨（中文优先，mpv 原生渲染）；
  /// 2. 确无内嵌轨 → 与视频同目录同名的字幕文件（含语言后缀变体）；
  /// 3. 用户手动选择后不再自动切换（切下一集时重新自动选择）。
  Future<void> _autoSelectSubtitle() async {
    if (_userPickedSub) return;
    final embedded = _embeddedSubtitles();
    if (embedded.isNotEmpty) {
      _autoSubPending = false;
      _selectEmbeddedSubtitle(_preferChinese(embedded));
      return;
    }
    if (_tracksSeen) {
      // 轨道信息已就绪且确无内嵌字幕 → fallback 到同名外部字幕
      _autoSubPending = false;
      await _loadSidecarIfAny();
      return;
    }
    _autoSubPending = true; // 等待轨道信息事件
  }

  List<SubtitleTrack> _embeddedSubtitles() => _tracks.subtitle
      .where((t) => t.id != 'no' && t.id != 'auto')
      .toList();

  Future<void> _loadSidecarIfAny() async {
    final path = _currentPath;
    if (path == null) return;
    final sidecar = _findSidecarSubtitle(path);
    if (sidecar != null) await _loadSubtitle(sidecar);
  }

  /// 同目录同名 sidecar 字幕查找：精确同名优先，其次 basename + 语言后缀变体
  /// （如 EP01.zh.ass / EP01.chs.srt / EP01.en.srt）。
  String? _findSidecarSubtitle(String videoPath) {
    const exts = {'srt', 'ass', 'ssa', 'vtt', 'sub'};
    final base = p.basenameWithoutExtension(videoPath).toLowerCase();
    String? variant;
    try {
      for (final e in Directory(p.dirname(videoPath)).listSync()) {
        if (e is! File) continue;
        final fb = p.basenameWithoutExtension(e.path).toLowerCase();
        final ext = p.extension(e.path).toLowerCase().replaceFirst('.', '');
        if (!exts.contains(ext)) continue;
        if (fb == base) return e.path;
        variant ??= fb.startsWith('$base.') ? e.path : null;
      }
    } catch (_) {}
    return variant;
  }

  /// 轨道信息事件到达后的自动选择：有内嵌轨则选之，确无则 fallback sidecar。
  void _maybeAutoSelectSubtitle() {
    if (!_autoSubPending || _userPickedSub || !mounted) return;
    final embedded = _embeddedSubtitles();
    if (embedded.isNotEmpty) {
      _autoSubPending = false;
      _selectEmbeddedSubtitle(_preferChinese(embedded));
    } else if (_tracksSeen) {
      _autoSubPending = false;
      _loadSidecarIfAny();
    }
  }

  /// 中文轨道优先（zh / chs / cht / chi / zho / chinese 标记）。
  SubtitleTrack _preferChinese(List<SubtitleTrack> tracks) {
    const zh = {'zh', 'chs', 'cht', 'chi', 'zho', 'chinese'};
    for (final t in tracks) {
      final lang = t.language?.toLowerCase();
      if (lang != null && zh.any(lang.startsWith)) return t;
    }
    return tracks.first;
  }

  /// 手动关闭所有字幕（外部 + 内嵌）。
  void _closeSubtitles() {
    setState(() {
      _activeSub = -1;
      _userPickedSub = true;
    });
    _player?.setSubtitleTrack(SubtitleTrack.no());
  }

  Future<void> _loadSubtitle(String path, {bool user = false}) async {
    try {
      final doc = await SubtitleParser.parseFile(path);
      if (!mounted) return;
      setState(() {
        if (!_subtitleFiles.contains(path)) _subtitleFiles.add(path);
        _subDocs[path] = doc;
        _activeSub = _subtitleFiles.indexOf(path);
        _subtitleVisible = true;
        if (user) _userPickedSub = true;
      });
      // 外部字幕显示时关闭 mpv 内嵌字幕渲染
      _player?.setSubtitleTrack(SubtitleTrack.no());
    } catch (e) {
      if (mounted) showErrorSnack(context, '字幕解析失败：$e');
    }
  }

  Future<void> _pickSubtitle() async {
    try {
      final picked = await FileService.instance.pickSubtitles(multi: true);
      if (picked.isEmpty || !mounted) return;
      for (final f in picked) {
        final path = f.path;
        if (path == null) continue;
        await _loadSubtitle(path, user: true);
      }
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  void _selectSubFile(int i) {
    if (i < -1 || i >= _subtitleFiles.length) return;
    setState(() {
      _activeSub = i;
      if (i >= 0) _subtitleVisible = true;
    });
    if (i >= 0) {
      _player?.setSubtitleTrack(SubtitleTrack.no());
    }
  }

  void _removeSubAt(int i) {
    if (i < 0 || i >= _subtitleFiles.length) return;
    setState(() {
      _subtitleFiles.removeAt(i);
      if (_activeSub == i) {
        _activeSub = -1;
      } else if (_activeSub > i) {
        _activeSub -= 1;
      }
    });
  }

  /// 选择内嵌字幕轨（mpv 渲染，样式由视频内嵌决定）。
  void _selectEmbeddedSubtitle(SubtitleTrack t) {
    setState(() => _activeSub = -1);
    _player?.setSubtitleTrack(t);
  }

  void _nudgeOffset(int ms) {
    setState(() {
      final v = _offset.inMilliseconds + ms;
      _offset = Duration(milliseconds: v.clamp(-30000, 30000));
    });
  }

  // ───────────────────────── 控制 ─────────────────────────

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    // 暂停、侧栏/音量面板打开、进度条拖动中 → 控制条保持可见
    if (!_playing || _panel != null || _showVolume || _dragMs != null) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  Future<void> _toggleFullscreen() async {
    final fs = !_fullscreen;
    await windowManager.setFullScreen(fs);
    if (mounted) {
      setState(() {
        _fullscreen = fs;
        if (fs) _panel = null;
      });
    }
  }

  Future<void> _seekTo(double ms) async {
    await _player?.seek(Duration(milliseconds: ms.round()));
  }

  void _skip(int seconds) {
    final target = _position + Duration(seconds: seconds);
    _seekTo(target.inMilliseconds.toDouble());
  }

  void _setVolume(double v) {
    final vol = v.clamp(0.0, 100.0);
    if (vol > 0) _lastVolume = vol;
    setState(() => _volume = vol);
    _player?.setVolume(vol);
  }

  /// 喇叭按钮：静音 / 取消静音（恢复静音前音量）。
  void _toggleMute() {
    if (_volume > 0) {
      _lastVolume = _volume;
      _setVolume(0);
    } else {
      _setVolume(_lastVolume <= 0 ? 100 : _lastVolume);
    }
  }

  void _setRate(double r) {
    setState(() => _rate = r);
    _player?.setRate(r);
  }

  void _togglePanel(_PanelTab tab) {
    setState(() => _panel = _panel == tab ? null : tab);
  }

  /// S 键截图当前帧（FFmpeg 单帧导出）。
  Future<void> _screenshot() async {
    final path = _currentPath;
    if (path == null) return;
    try {
      final settings = SettingsProvider.instance;
      final dir = settings.defaultOutputDir.isNotEmpty
          ? settings.defaultOutputDir
          : await FfmpegService.instance.tempDir();
      Directory(dir).createSync(recursive: true);
      final out = p.join(
        dir,
        '${p.basenameWithoutExtension(path)}_'
        '${DateTime.now().millisecondsSinceEpoch}.png',
      );
      final t = (_position.inMilliseconds / 1000).toStringAsFixed(3);
      final result = await FfmpegService.instance.runner.run(
        FfmpegRunRequest(
          arguments: [
            '-y', '-ss', t, '-i', path, '-frames:v', '1', out,
          ],
          progressOutput: false,
          expectedOutputs: [out],
        ),
      );
      if (!mounted) return;
      if (result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('截图已保存：$out')),
        );
      } else {
        showErrorSnack(context, result.error ?? '截图失败');
      }
    } catch (e) {
      if (mounted) showErrorSnack(context, '截图失败：$e');
    }
  }

  void _probeCurrent() {
    final path = _currentPath;
    if (path == null) return;
    final cached = _infoCache[path];
    if (cached != null) {
      setState(() => _info = cached);
      return;
    }
    setState(() {
      _probing = true;
      _info = null;
    });
    FfmpegService.instance.probeVideo(path).then((info) {
      _infoCache[path] = info;
      if (mounted) {
        setState(() {
          _info = info;
          _probing = false;
        });
      }
    }).catchError((e) {
      if (mounted) {
        setState(() {
          _info = null;
          _probing = false;
        });
      }
    });
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: player == null ? AppBar(title: const Text('视频预览')) : null,
      body: player == null
          ? _buildEmpty()
          : Row(
              children: [
                Expanded(child: _buildPlayer(player)),
                if (_panel != null && !_fullscreen) _buildPanel(),
              ],
            ),
    );
  }

  Widget _buildEmpty() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white70),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 56),
              const SizedBox(height: 12),
              Text('播放失败：$_error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _playlist.isNotEmpty
                    ? () => _openPlaylist(List.of(_playlist))
                    : _pickVideos,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    // 未选择视频
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.play_circle_outline, color: Colors.white54, size: 72),
          const SizedBox(height: 12),
          const Text('选择本地视频进行播放与字幕预览',
              style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
          const Text('支持 mp4 / mov / mkv / avi / flv / webm / ts / rmvb / wmv 等',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _pickVideos,
            icon: const Icon(Icons.video_file),
            label: const Text('选择视频（可多选）'),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayer(Player player) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space):
            () => player.playOrPause(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _skip(-5),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _skip(5),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _setVolume(_volume + 5),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _setVolume(_volume - 5),
        const SingleActivator(LogicalKeyboardKey.keyF): _toggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.keyS): _screenshot,
      },
      child: Focus(
        autofocus: true,
        canRequestFocus: true,
        child: MouseRegion(
          // 桌面端：鼠标移动即唤出控制条（无需点击），静止 3 秒自动隐藏
          onHover: (_) {
            if (!_controlsVisible) {
              setState(() => _controlsVisible = true);
            }
            _scheduleHide();
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
          child: Stack(
            children: [
              Positioned.fill(
                child: Video(
                  controller: _videoController!,
                  fit: BoxFit.contain,
                  // 禁用 media_kit 内置控制条（红色进度条），
                  // 交互全部由自绘白色控制条接管
                  controls: NoVideoControls,
                ),
              ),
              Positioned.fill(
                child: SubtitleOverlay(
                  position: _position,
                  offset: _offset,
                  document: _activeSub >= 0
                      ? _subDocs[_subtitleFiles[_activeSub]]
                      : null,
                  visible: _subtitleVisible,
                  style: _style,
                ),
              ),
              if (_controlsVisible) ...[
                PlayerTopBar(
                  title: _index >= 0 && _playlist.isNotEmpty
                      ? '${_index + 1} / ${_playlist.length} · ${p.basename(_currentPath ?? '')}'
                      : '',
                  fullscreen: _fullscreen,
                  onBack: _fullscreen
                      ? _toggleFullscreen
                      : () => Navigator.of(context).pop(),
                  onToggleFullscreen: _toggleFullscreen,
                  playlistActive: _panel == _PanelTab.playlist,
                  onTogglePlaylist: () => _togglePanel(_PanelTab.playlist),
                  subtitlePanelActive: _panel == _PanelTab.subtitle,
                  onToggleSubtitlePanel: () => _togglePanel(_PanelTab.subtitle),
                  infoActive: _panel == _PanelTab.info,
                  onToggleInfo: () => _togglePanel(_PanelTab.info),
                  subtitleVisible: _subtitleVisible,
                  onToggleSubtitleVisible: () {
                    setState(() => _subtitleVisible = !_subtitleVisible);
                    _scheduleHide();
                  },
                  onScreenshot: _screenshot,
                ),
                PlayerBottomBar(
                  playing: _playing,
                  position: _position,
                  duration: _duration,
                  dragMs: _dragMs,
                  onDragPosition: (v) => setState(() => _dragMs = v),
                  onSeek: (v) {
                    setState(() => _dragMs = null);
                    _seekTo(v);
                  },
                  hasPrevious: _index > 0,
                  hasNext: _index < _playlist.length - 1,
                  onPrevious: _previous,
                  onPlayPause: () {
                    player.playOrPause();
                    _scheduleHide();
                  },
                  onNext: _next,
                  volumePanelOpen: _showVolume,
                  volume: _volume,
                  onToggleMute: _toggleMute,
                  onVolumeHover: (enter) {
                    if (_showVolume != enter) {
                      setState(() => _showVolume = enter);
                    }
                  },
                  onVolumeChanged: _setVolume,
                  rate: _rate,
                  onRateChanged: _setRate,
                  audioTracks: _tracks.audio,
                  activeAudioId: _track.audio.id,
                  onSelectAudioTrack: player.setAudioTrack,
                  subtitleOffset: _offset,
                ),
              ],
            ],
          ),
        ),
        ),
      ),
    );
  }

  // ───────────────────────── 右侧栏 ─────────────────────────

  Widget _buildPanel() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 320,
      color: scheme.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 头部
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              border: Border(
                bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    switch (_panel) {
                      _PanelTab.playlist => '播放列表（${_playlist.length}）',
                      _PanelTab.subtitle => '字幕与样式',
                      _ => '视频信息',
                    },
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _panel = null),
                ),
              ],
            ),
          ),
          Expanded(
            child: switch (_panel) {
              _PanelTab.playlist => PlaylistPanel(
                  playlist: _playlist,
                  currentIndex: _index,
                  onAdd: _pickVideos,
                  onClear: _clearPlaylist,
                  onJump: _jumpTo,
                  onRemove: _removeAt,
                ),
              _PanelTab.subtitle => _buildSubtitlePanel(),
              _ => VideoInfoPanel(
                  path: _currentPath,
                  info: _info,
                  probing: _probing,
                ),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSubtitlePanel() {
    final embedded = _tracks.subtitle
        .where((t) => t.id != 'no' && t.id != 'auto')
        .toList();
    return SubtitleStylePanel(
      files: _subtitleFiles,
      cueCounts: {
        for (final e in _subDocs.entries) e.key: e.value.count,
      },
      activeFileIndex: _activeSub,
      onSelectFile: (v) => _selectSubFile(v ?? -1),
      onRemoveFile: _removeSubAt,
      onLoad: _pickSubtitle,
      embeddedTracks: embedded,
      activeEmbeddedId: _activeSub == -1
          ? (_track.subtitle.id == 'no' || _track.subtitle.id == 'auto'
              ? 'none'
              : _track.subtitle.id)
          : '',
      onSelectEmbedded: (id) {
        final t = embedded.where((x) => x.id == id).firstOrNull;
        if (t != null) _selectEmbeddedSubtitle(t);
      },
      onCloseSubtitles: _closeSubtitles,
      offset: _offset,
      onNudgeOffset: _nudgeOffset,
      onResetOffset: () => setState(() => _offset = Duration.zero),
      style: _style,
      onStyleChanged: (s) => setState(() => _style = s),
      visible: _subtitleVisible,
      onVisibleChanged: (v) => setState(() => _subtitleVisible = v),
    );
  }
}
