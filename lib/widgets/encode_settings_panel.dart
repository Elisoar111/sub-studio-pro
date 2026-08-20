import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../models/encode_options.dart';
import '../services/ffmpeg/ffmpeg_service.dart';
import 'common.dart';

/// ── 输出编码设置面板 ──
/// 烧录 / 转码 / 压缩共用的参数区：分辨率、CRF、码率、帧率、容器、
/// 音频编码、快速起播，以及「压缩方案」快捷预设。
///
/// 使用方式（受控组件）：
/// ```dart
/// final _encodeKey = GlobalKey<EncodeSettingsPanelState>();
/// EncodeSettingsPanel(key: _encodeKey, onChanged: (_) {});
/// // 读取：_encodeKey.currentState!.options
/// ```
class EncodeSettingsPanel extends StatefulWidget {
  final VideoEncodeOptions initial;
  final ValueChanged<VideoEncodeOptions> onChanged;

  const EncodeSettingsPanel({
    super.key,
    this.initial = const VideoEncodeOptions(),
    required this.onChanged,
  });

  @override
  EncodeSettingsPanelState createState() => EncodeSettingsPanelState();
}

class EncodeSettingsPanelState extends State<EncodeSettingsPanel> {
  late VideoEncodeOptions _o = widget.initial;

  late final TextEditingController _crfCtrl =
      TextEditingController(text: '${widget.initial.crf}');
  late final TextEditingController _customWCtrl =
      TextEditingController(text: widget.initial.customWidth?.toString() ?? '');
  late final TextEditingController _customHCtrl =
      TextEditingController(text: widget.initial.customHeight?.toString() ?? '');
  late final TextEditingController _videoBitrateCtrl =
      TextEditingController(
          text: widget.initial.videoBitrateKbps?.toString() ?? '');

  /// 当前完整编码设置（父组件在提交时读取）。
  VideoEncodeOptions get options => _o;

  void _syncControllers() {
    _crfCtrl.text = '${_o.crf}';
    _customWCtrl.text = _o.customWidth?.toString() ?? '';
    _customHCtrl.text = _o.customHeight?.toString() ?? '';
    _videoBitrateCtrl.text = _o.videoBitrateKbps?.toString() ?? '';
  }

  void _emit() => widget.onChanged(_o);

  @override
  void dispose() {
    _crfCtrl.dispose();
    _customWCtrl.dispose();
    _customHCtrl.dispose();
    _videoBitrateCtrl.dispose();
    super.dispose();
  }

  // ───────────────────────── 构建 ─────────────────────────

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '输出设置',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildResolution(context),
          const SizedBox(height: 12),
          _buildEncoder(context),
          const SizedBox(height: 12),
          _buildQuality(context),
          const SizedBox(height: 12),
          _buildFpsContainer(context),
          const SizedBox(height: 12),
          _buildAudio(context),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('快速起播（MP4 moov 前置）',
                style: TextStyle(fontSize: 13)),
            value: _o.fastStart,
            onChanged: (v) => setState(() {
              _o = VideoEncodeOptions(
                resolution: _o.resolution,
                customWidth: _o.customWidth,
                customHeight: _o.customHeight,
                crf: _o.crf,
                x264Preset: _o.x264Preset,
                videoBitrateKbps: _o.videoBitrateKbps,
                fps: _o.fps,
                container: _o.container,
                audioCodec: _o.audioCodec,
                audioBitrateKbps: _o.audioBitrateKbps,
                copyAudio: _o.copyAudio,
                fastStart: v,
                encoder: _o.encoder,
              );
              _emit();
            }),
          ),
          const Divider(height: 16),
          _buildCompressPresets(context),
        ],
      ),
    );
  }

  Widget _buildEncoder(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('编码器（硬件加速可选）',
            style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 8),
        // 探测系统 FFmpeg 支持的编码器，仅显示可用项
        FutureBuilder<Set<String>>(
          future: FfmpegService.instance.availableEncoders(),
          builder: (context, snapshot) {
            final available = snapshot.data ?? const <String>{};
            final candidates = <VideoEncoder, String>{
              VideoEncoder.x264: '软件 x264（兼容性最好）',
              VideoEncoder.h264Nvenc: 'NVIDIA NVENC H.264（加速 5~10 倍）',
              VideoEncoder.hevcNvenc: 'NVIDIA NVENC HEVC（加速 5~10 倍）',
              VideoEncoder.h264Amf: 'AMD AMF H.264（加速）',
              VideoEncoder.h264Qsv: 'Intel QSV H.264（加速）',
            };
            final items = <DropdownMenuItem<VideoEncoder>>[
              for (final e in candidates.entries)
                if (e.key == VideoEncoder.x264 ||
                    available.contains(e.key.codecName))
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
            ];
            // 当前选择不可用时回退软编
            final selected = items.any((i) => i.value == _o.encoder)
                ? _o.encoder
                : VideoEncoder.x264;
            return LabeledDropdown<VideoEncoder>(
              label: '视频编码',
              value: selected,
              items: items,
              onChanged: (v) => setState(() {
                if (v != null) {
                  _o = _copyWith(encoder: v);
                  _emit();
                }
              }),
            );
          },
        ),
      ],
    );
  }

  Widget _buildResolution(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('分辨率', style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 8),
        SegmentedButton<ResolutionPreset>(
          segments: const [
            ButtonSegment(value: ResolutionPreset.original, label: Text('原画')),
            ButtonSegment(value: ResolutionPreset.p1080, label: Text('1080p')),
            ButtonSegment(value: ResolutionPreset.p720, label: Text('720p')),
            ButtonSegment(value: ResolutionPreset.p480, label: Text('480p')),
            ButtonSegment(value: ResolutionPreset.custom, label: Text('自定义')),
          ],
          selected: {_o.resolution},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() {
            _o = _copyWith(resolution: s.first);
            _emit();
          }),
        ),
        if (_o.resolution == ResolutionPreset.custom) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _customWCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: '宽度 (px)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => _applyCustomSize(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _customHCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: '高度 (px)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => _applyCustomSize(),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  void _applyCustomSize() {
    final w = int.tryParse(_customWCtrl.text);
    final h = int.tryParse(_customHCtrl.text);
    setState(() {
      _o = _copyWith(customWidth: w, customHeight: h);
      _emit();
    });
  }

  Widget _buildQuality(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('画质 (CRF)', style: Theme.of(context).textTheme.bodyMedium),
            const Spacer(),
            Text('${_o.crf}',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 12),
            SizedBox(
              width: 110,
              child: TextField(
                controller: _videoBitrateCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: '码率 kbps(可空)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => _applyBitrate(),
              ),
            ),
          ],
        ),
        Slider(
          value: _o.crf.toDouble(),
          min: 14,
          max: 32,
          divisions: 18,
          label: 'CRF ${_o.crf}',
          onChanged: (v) => setState(() {
            _o = _copyWith(crf: v.round());
            _emit();
          }),
        ),
        Text(
          'CRF 越小画质越好、文件越大（18 高质量 / 23 均衡 / 28 小体积）；'
          '码率填了则优先按固定码率编码',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        LabeledDropdown<String>(
          label: 'x264 速度',
          value: _o.x264Preset,
          items: [
            for (final p in const [
              'ultrafast', 'superfast', 'veryfast', 'faster',
              'fast', 'medium', 'slow', 'slower',
            ])
              DropdownMenuItem(value: p, child: Text(p)),
          ],
          onChanged: (v) => setState(() {
            if (v != null) {
              _o = _copyWith(x264Preset: v);
              _emit();
            }
          }),
        ),
      ],
    );
  }

  void _applyBitrate() {
    final k = int.tryParse(_videoBitrateCtrl.text);
    setState(() {
      _o = _copyWith(videoBitrateKbps: k);
      _emit();
    });
  }

  Widget _buildFpsContainer(BuildContext context) {
    // DropdownMenuItem 的 value 不能为 null（Flutter 会把 null 视为"未选择"），
    // 因此用 -1 哨兵表示"保持源帧率"。
    final fpsValue = _o.fps ?? -1.0;
    return Column(
      children: [
        LabeledDropdown<double>(
          label: '帧率',
          value: fpsValue,
          items: const [
            DropdownMenuItem<double>(value: -1, child: Text('保持源帧率')),
            DropdownMenuItem<double>(value: 24, child: Text('24 fps')),
            DropdownMenuItem<double>(value: 25, child: Text('25 fps')),
            DropdownMenuItem<double>(value: 30, child: Text('30 fps')),
            DropdownMenuItem<double>(value: 60, child: Text('60 fps')),
          ],
          onChanged: (v) => setState(() {
            if (v == null) return;
            _o = _copyWith(fps: v == -1 ? null : v);
            _emit();
          }),
        ),
        const SizedBox(height: 12),
        LabeledDropdown<String>(
          label: '容器格式',
          value: _o.container,
          items: [
            for (final c in AppConstants.outputContainers)
              DropdownMenuItem(value: c, child: Text(c.toUpperCase())),
          ],
          onChanged: (v) => setState(() {
            if (v != null) {
              _o = _copyWith(container: v);
              _emit();
            }
          }),
        ),
      ],
    );
  }

  Widget _buildAudio(BuildContext context) {
    final copy = _o.copyAudio;
    return Column(
      children: [
        LabeledDropdown<String>(
          label: '音频编码',
          value: copy ? 'copy' : _o.audioCodec,
          items: const [
            DropdownMenuItem(value: 'aac', child: Text('AAC（兼容性最好）')),
            DropdownMenuItem(value: 'opus', child: Text('Opus（体积小）')),
            DropdownMenuItem(value: 'mp3', child: Text('MP3')),
            DropdownMenuItem(value: 'copy', child: Text('直拷（不重编码，最快）')),
          ],
          onChanged: (v) => setState(() {
            if (v == null) return;
            _o = _copyWith(
              audioCodec: v == 'copy' ? _o.audioCodec : v,
              copyAudio: v == 'copy',
            );
            _emit();
          }),
        ),
        if (!copy) ...[
          const SizedBox(height: 12),
          LabeledDropdown<int>(
            label: '音频码率',
            value: _o.audioBitrateKbps,
            items: [
              for (final k in const [96, 128, 192, 256, 320])
                DropdownMenuItem(value: k, child: Text('$k kbps')),
            ],
            onChanged: (v) => setState(() {
              if (v != null) {
                _o = _copyWith(audioBitrateKbps: v);
                _emit();
              }
            }),
          ),
        ],
      ],
    );
  }

  Widget _buildCompressPresets(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('压缩方案', style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            ActionChip(
              avatar: const Icon(Icons.high_quality, size: 18),
              label: const Text('高质量'),
              onPressed: () => _applyCompress(crf: 18, preset: 'medium'),
            ),
            ActionChip(
              avatar: const Icon(Icons.balance, size: 18),
              label: const Text('均衡'),
              onPressed: () => _applyCompress(crf: 23, preset: 'medium'),
            ),
            ActionChip(
              avatar: const Icon(Icons.compress, size: 18),
              label: const Text('小体积'),
              onPressed: () => _applyCompress(
                  crf: 28, preset: 'faster', resolution: ResolutionPreset.p720),
            ),
          ],
        ),
      ],
    );
  }

  void _applyCompress({
    required int crf,
    required String preset,
    ResolutionPreset resolution = ResolutionPreset.original,
  }) {
    setState(() {
      _o = _copyWith(crf: crf, x264Preset: preset, resolution: resolution);
      _syncControllers();
      _emit();
    });
  }

  VideoEncodeOptions _copyWith({
    ResolutionPreset? resolution,
    int? customWidth,
    int? customHeight,
    int? crf,
    String? x264Preset,
    int? videoBitrateKbps,
    double? fps,
    String? container,
    String? audioCodec,
    int? audioBitrateKbps,
    bool? copyAudio,
    bool? fastStart,
    VideoEncoder? encoder,
  }) {
    return VideoEncodeOptions(
      resolution: resolution ?? _o.resolution,
      customWidth: customWidth ?? _o.customWidth,
      customHeight: customHeight ?? _o.customHeight,
      crf: crf ?? _o.crf,
      x264Preset: x264Preset ?? _o.x264Preset,
      videoBitrateKbps: videoBitrateKbps ?? _o.videoBitrateKbps,
      fps: fps ?? _o.fps,
      container: container ?? _o.container,
      audioCodec: audioCodec ?? _o.audioCodec,
      audioBitrateKbps: audioBitrateKbps ?? _o.audioBitrateKbps,
      copyAudio: copyAudio ?? _o.copyAudio,
      fastStart: fastStart ?? _o.fastStart,
      encoder: encoder ?? _o.encoder,
    );
  }
}
