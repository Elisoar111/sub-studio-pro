import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../core/utils/time_format.dart';
import '../models/queue_task.dart';
import '../models/task_params.dart';
import '../models/video_info.dart';
import '../services/ffmpeg/ffmpeg_runner.dart';
import '../services/ffmpeg/ffmpeg_service.dart';
import '../services/concurrent_probe_pool.dart';
import '../services/file_service.dart';
import '../services/queue_service.dart';
import '../services/whisper/whisper_models.dart';
import '../services/whisper/whisper_service.dart';
import '../widgets/common.dart';
import '../widgets/file_drop_zone.dart';
import '../widgets/output_settings_card.dart';
import 'settings_screen.dart';
import 'task_queue_screen.dart';

/// Whisper 字幕页：视频 / 音频批量转字幕。
///
/// 参考 WhisperElectron 主窗体：文件选择 → 快速配置（模型 / 语言 /
/// 格式 / GPU）→ 扩展选项（预设 / 提示词 / 跳过已存在）→ 开始。
/// - 输出目录默认与源文件同目录，可自定义统一目录
/// - 输出文件名固定为「源文件主名_模型名.扩展名」（重名自动 _1/_2…），
///   不支持模板（与提取页 gMKV 规则同理）
/// - 转写期间结果实时输出（stdout 逐行），可随时回到本页反复查看
class WhisperScreen extends StatefulWidget {
  const WhisperScreen({super.key});

  @override
  State<WhisperScreen> createState() => _WhisperScreenState();
}

class _WhisperScreenState extends State<WhisperScreen> {
  final List<PickedFile> _files = [];

  /// 已探测的媒体信息（时长供队列进度百分比）
  final Map<String, VideoInfo> _info = {};

  /// 进行中的探测数（并发探测时布尔会提前熄灭，计数才能正确门控 _start）
  int _pendingProbes = 0;

  String _model = 'small';
  String _language = ''; // 空 = 自动检测
  String _format = 'srt';
  bool _useGpu = false;

  /// 用户手动改过 GPU 开关后尊重手动值（自动推荐只作初始默认）
  bool _gpuTouched = false;

  /// VAD 静音过滤（仅 faster-whisper 后端生效，默认开）
  bool _vadFilter = true;
  int _preset = 1;
  bool _skipExisting = true;

  /// 选中模型的缓存状态（模型管理对话框关闭后刷新）
  WhisperModelStatus? _modelStatus;

  /// 自定义输出目录（null = 与各源文件同目录）
  String? _outputDir;

  final _promptCtrl = TextEditingController();
  final _customCtrl = TextEditingController();

  /// 实时输出面板滚动（跟随最新行；用户上翻查看历史时暂停跟随）
  final _liveScroll = ScrollController();
  bool _liveStick = true;

  String _keyOf(PickedFile f) => f.path ?? 'web:${f.name}';

  /// 单个文件的输出目录：自定义目录 > 源文件所在目录。
  String _outDirFor(String path) => _outputDir ?? p.dirname(path);

  @override
  void initState() {
    super.initState();
    _liveScroll.addListener(() {
      if (!_liveScroll.hasClients) return;
      final pos = _liveScroll.position;
      _liveStick = pos.pixels >= pos.maxScrollExtent - 120;
    });
    _refreshModelStatus();
    _recommendGpu();
  }

  /// GPU 自动推荐：检测到 NVIDIA 显卡 → 开关默认勾选（用户可改）。
  Future<void> _recommendGpu() async {
    final has = await WhisperService.detectNvidiaGpu();
    if (!has || !mounted || _gpuTouched) return;
    setState(() => _useGpu = true);
  }

  @override
  void dispose() {
    _promptCtrl.dispose();
    _customCtrl.dispose();
    _liveScroll.dispose();
    super.dispose();
  }

  Future<void> _refreshModelStatus() async {
    final list = await WhisperService.instance.listModels();
    if (!mounted) return;
    setState(() {
      _modelStatus = list.where((m) => m.name == _model).firstOrNull;
    });
  }

  // ───────────────────────── 文件选择 / 探测 ─────────────────────────

  void _handleDroppedFiles(List<String> paths) {
    final accepted = <PickedFile>[];
    for (final path in paths) {
      final ext = p.extension(path).toLowerCase();
      final extNoDot = ext.isEmpty ? '' : ext.substring(1);
      if (AppConstants.videoExtensions.contains(extNoDot) ||
          AppConstants.audioExtensions.contains(extNoDot)) {
        final f = FileService.pickedFromFile(path);
        if (!_files.any((x) => _keyOf(x) == _keyOf(f))) accepted.add(f);
      }
    }
    if (accepted.isEmpty) return;
    setState(() {
      _files.addAll(accepted);
      _pendingProbes += accepted.length;
    });
    ConcurrentProbePool(limit: 3).run(
      accepted,
      (f) async => FfmpegService.instance.probeVideo(f.path!),
      (f, info) {
        if (!mounted) return;
        setState(() => _info[_keyOf(f)] = info);
      },
      onError: (f, e) {
        if (!mounted) return;
        setState(() => _info[_keyOf(f)] = VideoInfo.unknown(f.path!));
      },
    ).whenComplete(() {
      if (mounted) setState(() => _pendingProbes = 0);
    });
  }

  Future<void> _pickFiles() async {
    try {
      final picked = await FileService.instance.pickMediaFiles();
      if (picked.isEmpty || !mounted) return;
      setState(() {
        for (final f in picked) {
          final k = _keyOf(f);
          if (!_files.any((x) => _keyOf(x) == k)) _files.add(f);
        }
      });
      final newFiles = picked
          .where((f) => !_files.any((x) => _keyOf(x) == _keyOf(f)))
          .toList();
      setState(() => _pendingProbes += newFiles.length);
      ConcurrentProbePool(limit: 3).run(
        newFiles,
        (f) async => FfmpegService.instance.probeVideo(f.path!),
        (f, info) {
          if (!mounted) return;
          setState(() => _info[_keyOf(f)] = info);
        },
        onError: (f, e) {
          if (!mounted) return;
          setState(() => _info[_keyOf(f)] = VideoInfo.unknown(f.path!));
        },
      ).whenComplete(() {
        if (mounted) setState(() => _pendingProbes = 0);
      });
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  // ───────────────────────── 提交任务 ─────────────────────────

  Future<void> _start() async {
    if (_files.isEmpty) {
      showErrorSnack(context, '请先选择视频或音频文件');
      return;
    }
    if (!WhisperService.instance.isAvailable) {
      showErrorSnack(context, 'Whisper 不可用：请先在设置页安装或配置 openai-whisper');
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      );
      return;
    }
    if (_pendingProbes > 0) {
      showErrorSnack(context, '正在探测媒体信息，请稍候再开始');
      return;
    }
    final q = QueueService.instance;
    final prompt = _promptCtrl.text.trim();
    final custom = _customCtrl.text.trim();
    var count = 0;
    for (final f in _files) {
      final path = f.path;
      if (path == null) continue;
      final key = _keyOf(f);
      q.addTask(
        type: TaskType.whisper,
        title: '转写 ${p.basename(path)}（$_model）',
        params: {
          TaskParams.videoPath: path,
          TaskParams.outputPath: _outDirFor(path),
          TaskParams.whisperModel: _model,
          if (_language.isNotEmpty) TaskParams.whisperLanguage: _language,
          TaskParams.whisperFormat: _format,
          TaskParams.whisperGpu: '$_useGpu',
          TaskParams.whisperPreset: '$_preset',
          if (prompt.isNotEmpty) TaskParams.whisperPrompt: prompt,
          if (WhisperService.instance.backend == WhisperBackend.faster &&
              _vadFilter)
            TaskParams.vadFilter: '1',
          if (_preset == 6 && custom.isNotEmpty)
            TaskParams.whisperCustomParams: custom,
          TaskParams.skipExisting: '$_skipExisting',
          TaskParams.totalDurationMs:
              '${_info[key]?.duration.inMilliseconds ?? 0}',
        },
      );
      count++;
    }
    if (count == 0) {
      if (mounted) showErrorSnack(context, '所选文件没有本地路径，无法转写');
      return;
    }
    q.start();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TaskQueueScreen()),
    );
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Whisper 字幕')),
      body: FileDropZone(
        acceptedExtensions: const [
          ...AppConstants.videoExtensions,
          ...AppConstants.audioExtensions,
        ],
        onFilesDropped: _handleDroppedFiles,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
          _serviceCard(context),
          const SizedBox(height: 12),
          _liveCard(context),
          const SizedBox(height: 12),
          _filesCard(context),
          const SizedBox(height: 12),
          _settingsCard(context, scheme),
          const SizedBox(height: 12),
          OutputSettingsCard(
            initialDir: _outputDir,
            onDirChanged: (dir) => setState(() => _outputDir = dir),
            initialTemplate: '',
            templateFallback: '',
            onTemplateChanged: (_) {},
            showTemplate: false,
            defaultDirLabel: '默认：与各源文件同目录',
            previewSourceName: _previewName(),
            previewExtension: WhisperService.outputExtensionFor(_format)
                .replaceFirst('.', ''),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              '输出文件名：源文件主名_模型名${WhisperService.outputExtensionFor(_format)}'
              '（同名已存在时自动改为 _1、_2…）',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            dense: true,
            title: const Text('跳过已存在的输出文件'),
            subtitle: const Text(
                '输出目录已有同名字幕时直接标记成功，不再重复转写',
                style: TextStyle(fontSize: 12)),
            value: _skipExisting,
            onChanged: (v) => setState(() => _skipExisting = v),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<bool>(
            valueListenable: WhisperService.instance.availability,
            builder: (context, available, _) => FilledButton.icon(
              onPressed: available ? _start : null,
              icon: const Icon(Icons.mic),
              label: Text('开始转写（${_files.length} 个文件）'),
            ),
          ),
        ],
        ),
      ),
    );
  }

  /// 输出预览主名：`<主名>_<模型>`。
  String? _previewName() {
    if (_files.isEmpty) return '示例视频_$_model';
    final path = _files.first.path;
    if (path == null) return null;
    return '${p.basenameWithoutExtension(path)}_$_model';
  }

  /// Whisper 服务状态卡：可用性 + 来源 + 去设置。
  /// 用 ValueListenableBuilder 监听 availability，配置后实时刷新
  /// （约定：不得静态读取 isAvailable）。
  Widget _serviceCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<bool>(
      valueListenable: WhisperService.instance.availability,
      builder: (context, available, _) {
        final svc = WhisperService.instance;
        return SectionCard(
          title: '转写引擎',
          icon: Icons.mic_none,
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: (available ? scheme.primary : scheme.error)
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              available ? '可用' : '未检测到',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: available ? scheme.primary : scheme.error,
              ),
            ),
          ),
          child: Row(
            children: [
              Icon(
                available ? Icons.check_circle : Icons.error_outline,
                size: 18,
                color: available ? Colors.green : scheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  available
                      ? '已检测到 Whisper（来源：${svc.sourceLabel ?? '未知'}）'
                      : (svc.error ?? '未检测到 Whisper：Whisper 字幕依赖 openai-whisper'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const SettingsScreen()),
                ),
                child: const Text('去设置'),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 实时输出面板：转写期间 stdout 逐行显示；结束后内容保留，
  /// 随时回到本页反复查看；上翻暂停自动跟随，回到底部恢复。
  Widget _liveCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<WhisperLiveOutput?>(
      valueListenable: WhisperService.instance.liveOutput,
      builder: (context, live, _) {
        if (live == null) return const SizedBox.shrink();
        final running = live.running;
        if (running && _liveStick) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_liveScroll.hasClients) {
              _liveScroll.jumpTo(_liveScroll.position.maxScrollExtent);
            }
          });
        }
        return SectionCard(
          title: '实时输出',
          icon: Icons.terminal_outlined,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: (running ? scheme.primary : Colors.green)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (running)
                      const SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.6),
                      )
                    else
                      const Icon(Icons.check, size: 11, color: Colors.green),
                    const SizedBox(width: 4),
                    Text(
                      running ? '转写中' : '已完成',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: running ? scheme.primary : Colors.green,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '清空',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () =>
                    WhisperService.instance.liveOutput.value = null,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${live.inputName} · 模型 ${live.model} · '
                '${live.lines.length} 行 · '
                '${live.startedAt.toLocal().toString().substring(11, 19)} 开始',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 240,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: live.lines.isEmpty
                    ? Center(
                        child: Text(
                          running ? '正在加载模型，等待输出…' : '无输出内容',
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      )
                    : ListView.builder(
                        controller: _liveScroll,
                        itemCount: live.lines.length,
                        itemBuilder: (context, i) => Text(
                          live.lines[i],
                          style: const TextStyle(
                            fontSize: 11,
                            fontFamily: 'Consolas',
                            height: 1.45,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _filesCard(BuildContext context) {
    return SectionCard(
      title: '媒体文件（${_files.length}）',
      icon: Icons.library_music_outlined,
      trailing: TextButton(
        onPressed: _pickFiles,
        child: const Text('选择文件'),
      ),
      child: _files.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: StepGuide(steps: [
                '点击右上「选择文件」，或把视频 / 音频拖进页面',
                '首次使用请到「设置 → Whisper」配置可执行文件并下载模型',
                '识别在后台队列执行，完成后自动生成字幕',
              ]),
            )
          : Column(
              children: [
                for (final f in _files)
                  FileTile(
                    title: f.name,
                    subtitle: _fileSubtitle(f),
                    icon: _isAudio(f.path)
                        ? Icons.graphic_eq
                        : Icons.movie_outlined,
                    onRemove: () {
                      setState(() {
                        _files.remove(f);
                        _info.remove(_keyOf(f));
                      });
                    },
                  ),
              ],
            ),
    );
  }

  String _fileSubtitle(PickedFile f) {
    final path = f.path;
    final info = _info[_keyOf(f)];
    final dur = info != null && info.duration.inMilliseconds > 0
        ? formatClock(info.duration)
        : null;
    final dir = path != null ? p.dirname(path) : '';
    return dur != null ? '$dir · 时长 $dur' : dir;
  }

  static bool _isAudio(String? path) {
    if (path == null) return false;
    return const {
      '.mp3', '.wav', '.flac', '.m4a', '.aac', '.ogg', '.opus', '.wma',
      '.ac3', '.eac3', '.dts',
    }.contains(p.extension(path).toLowerCase());
  }

  Widget _settingsCard(BuildContext context, ColorScheme scheme) {
    final modelInfo = whisperModelInfo[_model];
    return SectionCard(
      title: '转写设置',
      icon: Icons.tune,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LabeledDropdown<String>(
            label: '模型',
            value: _model,
            items: [
              for (final cat in whisperModelCategories) ...[
                DropdownMenuItem<String>(
                  enabled: false,
                  child: Text(
                    cat.name,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                ),
                for (final m in cat.models)
                  DropdownMenuItem(
                    value: m,
                    child: Text(m),
                  ),
              ],
            ],
            onChanged: (v) {
              if (v == null) return;
              setState(() => _model = v);
              _refreshModelStatus();
            },
          ),
          const SizedBox(height: 6),
          _modelDetailRow(context, scheme, modelInfo),
          const Divider(height: 24),
          Text('转写语言', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final lang in whisperLanguages)
                ChoiceChip(
                  label: Text(lang.name),
                  selected: _language == lang.code,
                  onSelected: (_) => setState(() => _language = lang.code),
                ),
            ],
          ),
          if (_model.endsWith('.en'))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '英文专用模型只识别英文，语言参数将固定为 en',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
          const Divider(height: 24),
          LabeledDropdown<String>(
            label: '输出格式',
            value: _format,
            items: [
              for (final f in whisperFormats)
                DropdownMenuItem(
                  value: f.name,
                  child: Tooltip(
                    message: f.desc,
                    child: Text(f.name.toUpperCase()),
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _format = v);
            },
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('使用 GPU（CUDA）'),
            subtitle: const Text('需已安装 PyTorch CUDA 版，否则回退 CPU；'
                '检测到 NVIDIA 显卡时默认勾选',
                style: TextStyle(fontSize: 12)),
            value: _useGpu,
            onChanged: (v) => setState(() {
              _gpuTouched = true;
              _useGpu = v;
            }),
          ),
          // VAD 静音过滤：仅 faster-whisper 后端支持（openai CLI 无此参数）
          ValueListenableBuilder<WhisperBackend?>(
            valueListenable: WhisperService.instance.activeBackend,
            builder: (context, backend, _) {
              final faster = backend == WhisperBackend.faster;
              return SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('VAD 静音过滤'),
                subtitle: Text(
                  faster
                      ? '跳过无语音片段，减少幻听 hallucination 并加速'
                      : '仅 faster-whisper 后端支持（设置页可切换后端）',
                  style: const TextStyle(fontSize: 12),
                ),
                value: faster && _vadFilter,
                onChanged: faster
                    ? (v) => setState(() => _vadFilter = v)
                    : null,
              );
            },
          ),
          const Divider(height: 24),
          LabeledDropdown<int>(
            label: '参数预设',
            value: _preset,
            items: [
              for (var i = 0; i < whisperPresets.length; i++)
                DropdownMenuItem(
                  value: i + 1,
                  child: Text(whisperPresets[i].name),
                ),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _preset = v);
            },
          ),
          if (_preset == 6) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _customCtrl,
              decoration: const InputDecoration(
                labelText: '自定义 CLI 参数',
                hintText: r'例如：--beam_size 8 --temperature 0.2',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _promptCtrl,
            decoration: const InputDecoration(
              labelText: '初始提示词（可选）',
              hintText: '专有名词 / 人名等；支持 {episode} 占位符',
              helperText: '{episode} 转写时按文件名自动替换为集数'
                  '（如 "Show - 12 [1080p]" → 12，EP03 / 第05话 同理）',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '首次使用某模型时 whisper 会自动下载（模型也可在上方「模型管理」预下载）；'
            '任务进入队列串行执行，可随时取消。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  /// 模型详情行：说明 · 大小 · 显存 · 缓存状态 + 管理按钮。
  Widget _modelDetailRow(
      BuildContext context, ColorScheme scheme, WhisperModelInfo? info) {
    final cached = _modelStatus?.downloaded ?? false;
    return Row(
      children: [
        Expanded(
          child: Text(
            [
              if (info != null) info.desc,
              if (info != null) '磁盘 ${info.size}',
              if (info != null) '显存 ${info.vram}',
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: (cached ? Colors.green : scheme.error).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            cached ? '已缓存' : '未下载',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: cached ? Colors.green : scheme.error,
            ),
          ),
        ),
        TextButton.icon(
          onPressed: _openModelManager,
          icon: const Icon(Icons.download_for_offline_outlined, size: 18),
          label: const Text('模型管理'),
        ),
      ],
    );
  }

  // ───────────────────────── 模型管理对话框 ─────────────────────────

  Future<void> _openModelManager() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _ModelManagerDialog(),
    );
    await _refreshModelStatus();
  }
}

/// 模型管理对话框：按分组列出全部模型，支持预下载 / 删除 / 查看缓存。
class _ModelManagerDialog extends StatefulWidget {
  const _ModelManagerDialog();

  @override
  State<_ModelManagerDialog> createState() => _ModelManagerDialogState();
}

class _ModelManagerDialogState extends State<_ModelManagerDialog> {
  List<WhisperModelStatus>? _models;
  String? _downloading;
  String? _error;
  final List<String> _log = [];
  CancelToken? _token;
  final _logCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _token?.cancel();
    _logCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _models = null);
    final list = await WhisperService.instance.listModels();
    if (mounted) setState(() => _models = list);
  }

  Future<void> _download(String name) async {
    setState(() {
      _downloading = name;
      _error = null;
      _log.clear();
    });
    final token = CancelToken();
    _token = token;
    final r = await WhisperService.instance.downloadModel(
      model: name,
      onLog: (line) {
        if (!mounted) return;
        setState(() => _log.add(line));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_logCtrl.hasClients) _logCtrl.jumpTo(_logCtrl.position.maxScrollExtent);
        });
      },
      cancelToken: token,
    );
    if (!mounted) return;
    setState(() => _downloading = null);
    await _load();
    if (!mounted) return;
    if (!r.success) setState(() => _error = r.error);
  }

  Future<void> _delete(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除模型 $name'),
        content: const Text('仅删除本地缓存文件，可随时重新下载。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await WhisperService.instance.deleteModel(name);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('Whisper 模型管理')),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _downloading == null ? _load : null,
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
                ),
              ),
            Expanded(
              child: _models == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        for (final cat in whisperModelCategories) ...[
                          Padding(
                            padding:
                                const EdgeInsets.fromLTRB(4, 12, 4, 6),
                            child: Text(
                              cat.name,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: scheme.primary,
                              ),
                            ),
                          ),
                          for (final m in cat.models)
                            _modelRow(m, scheme),
                        ],
                      ],
                    ),
            ),
            if (_downloading != null || _log.isNotEmpty) ...[
              const Divider(height: 16),
              SizedBox(
                height: 110,
                child: ListView.builder(
                  controller: _logCtrl,
                  itemCount: _log.length,
                  itemBuilder: (context, i) => Text(
                    _log[i],
                    style: const TextStyle(
                        fontSize: 11, fontFamily: 'Consolas'),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_downloading != null)
          OutlinedButton(
            onPressed: () => _token?.cancel(),
            child: const Text('取消下载'),
          ),
        TextButton(
          onPressed: _downloading == null
              ? () => Navigator.of(context).pop()
              : null,
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _modelRow(String name, ColorScheme scheme) {
    final status = _models?.where((m) => m.name == name).firstOrNull;
    final cached = status?.downloaded ?? false;
    final info = whisperModelInfo[name];
    final busy = _downloading == name;
    return ListTile(
      dense: true,
      leading: Icon(
        cached ? Icons.check_circle : Icons.cloud_download_outlined,
        size: 20,
        color: cached ? Colors.green : scheme.onSurfaceVariant,
      ),
      title: Text(name, style: const TextStyle(fontFamily: 'Consolas')),
      subtitle: Text(
        [
          info?.desc ?? '',
          if (cached && status != null) '已缓存 ${_fmtSize(status.sizeBytes)}'
          else '磁盘 ${info?.size ?? ''} · 显存 ${info?.vram ?? ''}',
        ].where((s) => s.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      trailing: busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _downloading != null
              ? null
              : cached
                  ? TextButton(
                      onPressed: () => _delete(name),
                      child: const Text('删除'),
                    )
                  : FilledButton.tonalIcon(
                      onPressed: () => _download(name),
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('下载'),
                    ),
    );
  }

  static String _fmtSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return v >= 100 || i == 0
        ? '${v.toStringAsFixed(0)} ${units[i]}'
        : '${v.toStringAsFixed(1)} ${units[i]}';
  }
}
