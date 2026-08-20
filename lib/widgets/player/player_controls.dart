import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/utils/time_format.dart';

/// 播放器顶部控制条：返回 / 标题 / 侧栏开关 / 字幕显隐 / 截图 / 全屏。
class PlayerTopBar extends StatelessWidget {
  /// 标题（如 "1 / 3 · EP01.mp4"）
  final String title;
  final bool fullscreen;
  final VoidCallback onBack;
  final VoidCallback onToggleFullscreen;

  /// 三个侧栏页签：是否激活 + 切换回调
  final bool playlistActive;
  final VoidCallback onTogglePlaylist;
  final bool subtitlePanelActive;
  final VoidCallback onToggleSubtitlePanel;
  final bool infoActive;
  final VoidCallback onToggleInfo;

  final bool subtitleVisible;
  final VoidCallback onToggleSubtitleVisible;
  final VoidCallback onScreenshot;

  const PlayerTopBar({
    super.key,
    required this.title,
    required this.fullscreen,
    required this.onBack,
    required this.onToggleFullscreen,
    required this.playlistActive,
    required this.onTogglePlaylist,
    required this.subtitlePanelActive,
    required this.onToggleSubtitlePanel,
    required this.infoActive,
    required this.onToggleInfo,
    required this.subtitleVisible,
    required this.onToggleSubtitleVisible,
    required this.onScreenshot,
  });

  Widget _panelButton(
    BuildContext context, {
    required bool active,
    required IconData icon,
    required String tip,
    required VoidCallback onTap,
  }) {
    return IconButton(
      tooltip: tip,
      color: active ? Colors.amber : Colors.white,
      icon: Icon(icon),
      onPressed: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Row(
          children: [
            IconButton(
              color: Colors.white,
              icon: Icon(fullscreen ? Icons.fullscreen_exit : Icons.arrow_back),
              onPressed: onBack,
            ),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _panelButton(context,
                active: playlistActive,
                icon: Icons.queue_music,
                tip: '播放列表',
                onTap: onTogglePlaylist),
            _panelButton(context,
                active: subtitlePanelActive,
                icon: Icons.subtitles_outlined,
                tip: '字幕与样式',
                onTap: onToggleSubtitlePanel),
            _panelButton(context,
                active: infoActive,
                icon: Icons.info_outline,
                tip: '视频信息',
                onTap: onToggleInfo),
            IconButton(
              tooltip: '字幕显示/隐藏',
              color: subtitleVisible ? Colors.amber : Colors.white54,
              icon: const Icon(Icons.closed_caption),
              onPressed: onToggleSubtitleVisible,
            ),
            IconButton(
              tooltip: '截图当前帧 (S)',
              color: Colors.white,
              icon: const Icon(Icons.photo_camera_outlined),
              onPressed: onScreenshot,
            ),
            IconButton(
              tooltip: fullscreen ? '退出全屏 (F)' : '全屏 (F)',
              color: Colors.white,
              icon: Icon(fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
              onPressed: onToggleFullscreen,
            ),
          ],
        ),
      ),
    );
  }
}

/// 播放器底部控制条：进度条 / 上一首 / 播放暂停 / 下一首 / 音量 / 倍速 / 音轨。
class PlayerBottomBar extends StatelessWidget {
  final bool playing;
  final Duration position;
  final Duration duration;

  /// 拖动进度条中的临时值（ms）；null = 未在拖动
  final double? dragMs;
  final ValueChanged<double> onDragPosition;
  final ValueChanged<double> onSeek;

  final bool hasPrevious;
  final bool hasNext;
  final VoidCallback onPrevious;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;

  final bool volumePanelOpen;
  final double volume;

  /// 点击喇叭：静音 / 取消静音
  final VoidCallback onToggleMute;

  /// 悬停音量区域：弹出 / 收起滑条
  final ValueChanged<bool> onVolumeHover;
  final ValueChanged<double> onVolumeChanged;

  final double rate;
  final ValueChanged<double> onRateChanged;

  final List<AudioTrack> audioTracks;
  final String activeAudioId;
  final ValueChanged<AudioTrack> onSelectAudioTrack;

  /// 字幕同步偏移（非零时显示角标提示）
  final Duration subtitleOffset;

  const PlayerBottomBar({
    super.key,
    required this.playing,
    required this.position,
    required this.duration,
    required this.dragMs,
    required this.onDragPosition,
    required this.onSeek,
    required this.hasPrevious,
    required this.hasNext,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
    required this.volumePanelOpen,
    required this.volume,
    required this.onToggleMute,
    required this.onVolumeHover,
    required this.onVolumeChanged,
    required this.rate,
    required this.onRateChanged,
    required this.audioTracks,
    required this.activeAudioId,
    required this.onSelectAudioTrack,
    required this.subtitleOffset,
  });

  static const _speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0];

  @override
  Widget build(BuildContext context) {
    final durationMs = duration.inMilliseconds;
    final positionMs = dragMs ?? position.inMilliseconds.toDouble();
    final max = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final pos = positionMs.clamp(0.0, max);

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        padding: const EdgeInsets.only(top: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: Colors.white24,
              ),
              child: Slider(
                value: pos,
                max: max,
                onChanged: onDragPosition,
                onChangeEnd: onSeek,
              ),
            ),
            Row(
              children: [
                IconButton(
                  tooltip: '上一个',
                  color: Colors.white,
                  icon: const Icon(Icons.skip_previous),
                  onPressed: hasPrevious ? onPrevious : null,
                ),
                IconButton(
                  color: Colors.white,
                  iconSize: 32,
                  icon: Icon(playing ? Icons.pause_circle : Icons.play_circle),
                  onPressed: onPlayPause,
                ),
                IconButton(
                  tooltip: '下一个',
                  color: Colors.white,
                  icon: const Icon(Icons.skip_next),
                  onPressed: hasNext ? onNext : null,
                ),
                MouseRegion(
                  onEnter: (_) => onVolumeHover(true),
                  onExit: (_) => onVolumeHover(false),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: volume == 0 ? '取消静音' : '静音',
                        color: Colors.white,
                        icon: Icon(
                          volume == 0
                              ? Icons.volume_off
                              : volume < 50
                                  ? Icons.volume_down
                                  : Icons.volume_up,
                        ),
                        onPressed: onToggleMute,
                      ),
                      // 悬停音量区域时展开滑条（滑条也在区域内，移动不收起）
                      AnimatedOpacity(
                        duration: const Duration(milliseconds: 150),
                        opacity: volumePanelOpen ? 1 : 0,
                        child: IgnorePointer(
                          ignoring: !volumePanelOpen,
                          child: SizedBox(
                            width: volumePanelOpen ? 110 : 0,
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                activeTrackColor: Colors.white,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: Colors.white,
                              ),
                              child: Slider(
                                value: volume.clamp(0.0, 100.0),
                                max: 100,
                                onChanged: onVolumeChanged,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                // 倍速
                PopupMenuButton<double>(
                  tooltip: '倍速播放',
                  color: const Color(0xE6222222),
                  initialValue: _speeds.contains(rate) ? rate : null,
                  onSelected: onRateChanged,
                  itemBuilder: (_) => [
                    for (final s in _speeds)
                      PopupMenuItem(
                        value: s,
                        child: Text(
                          '${s}x${s == rate ? '  ✓' : ''}',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight:
                                s == rate ? FontWeight.bold : FontWeight.w400,
                          ),
                        ),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '${rate}x',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ),
                // 音轨选择
                PopupMenuButton<String>(
                  tooltip: '音轨',
                  color: const Color(0xE6222222),
                  onSelected: (id) {
                    final t = audioTracks.where((t) => t.id == id).firstOrNull;
                    if (t != null) onSelectAudioTrack(t);
                  },
                  itemBuilder: (_) => [
                    for (final t in audioTracks)
                      if (t.id != 'no' && t.id != 'auto')
                        PopupMenuItem(
                          value: t.id,
                          child: Text(
                            '${t.title ?? '音轨 ${t.id}'}'
                            '${t.language != null && t.language!.isNotEmpty ? ' · ${t.language}' : ''}'
                            '${t.id == activeAudioId ? '  ✓' : ''}',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13),
                          ),
                        ),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.graphic_eq, color: Colors.white, size: 20),
                  ),
                ),
                const Spacer(),
                if (subtitleOffset != Duration.zero)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Tooltip(
                      message: '字幕偏移 ${subtitleOffset.inMilliseconds}ms（正值提前）',
                      child: Text(
                        '${subtitleOffset.inMilliseconds > 0 ? '+' : ''}${subtitleOffset.inMilliseconds}ms',
                        style: const TextStyle(color: Colors.amber, fontSize: 12),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(
                    '${formatClock(position)} / ${formatClock(duration)}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
