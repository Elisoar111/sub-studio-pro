import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../core/utils/filename_template.dart';
import '../providers/app_providers.dart';
import '../services/file_service.dart';
import '../services/ffmpeg/ffmpeg_service.dart';
import '../services/mkvtoolnix/mkvtoolnix_service.dart';
import '../services/storage_service.dart';
import '../services/whisper/whisper_models.dart';
import '../services/whisper/whisper_service.dart';
import '../widgets/common.dart';

/// 设置页（锚点导航结构化）：宽窗口左侧锚点（外观 / 输出 / 环境依赖 /
/// AI / 维护）+ 右侧滚动内容，点击锚点跳转分组、滚动时高亮跟随；
/// 窄窗口（< 840）退化为纯滚动列表。
///
/// 分组构成：外观 = 主题；输出 = 输出默认值；环境依赖 = FFmpeg +
/// MKVToolNix + Whisper；AI = 翻译 API；维护 = 临时文件清理。
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

/// 锚点分组。
enum _Group { appearance, output, env, ai, maintenance }

class _GroupNav {
  final _Group group;
  final IconData icon;
  final String label;
  const _GroupNav(this.group, this.icon, this.label);
}

const _kAnchorModeMinWidth = 840.0;

/// 分组头部越过视口顶部多少像素后切换高亮。
const _kActiveSwitchOffset = 140.0;

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _ffmpegCtrl = TextEditingController(
      text: StorageService.instance.getSetting(StorageService.kFfmpegPath));
  late final TextEditingController _ffprobeCtrl = TextEditingController(
      text: StorageService.instance.getSetting(StorageService.kFfprobePath));
  late final TextEditingController _tplCtrl = TextEditingController(
      text: SettingsProvider.instance.filenameTemplate);
  late final TextEditingController _aiKeyCtrl = TextEditingController(
      text: SettingsProvider.instance.aiApiKey);
  late final TextEditingController _aiUrlCtrl = TextEditingController(
      text: SettingsProvider.instance.aiBaseUrl);
  late final TextEditingController _aiModelCtrl = TextEditingController(
      text: SettingsProvider.instance.aiModel);

  late final TextEditingController _mkvDirCtrl = TextEditingController(
      text: StorageService.instance.getSetting(StorageService.kMkvtoolnixDir));

  late final TextEditingController _whisperPathCtrl = TextEditingController(
      text: StorageService.instance.getSetting(StorageService.kWhisperPath));
  late final TextEditingController _whisperCacheCtrl = TextEditingController(
      text: StorageService.instance.getSetting(StorageService.kWhisperCacheDir));

  /// Whisper 后端偏好（v1.2：auto / openai / faster）
  WhisperBackend _whisperBackend = WhisperBackend.fromCode(
      StorageService.instance.getSetting(StorageService.kWhisperBackend));

  /// 自定义色相（与预设二选一，最后操作生效）
  double? _customHue;

  static const _groupNavs = [
    _GroupNav(_Group.appearance, Icons.palette_outlined, '外观'),
    _GroupNav(_Group.output, Icons.output_outlined, '输出'),
    _GroupNav(_Group.env, Icons.handyman_outlined, '环境依赖'),
    _GroupNav(_Group.ai, Icons.smart_toy_outlined, 'AI'),
    _GroupNav(_Group.maintenance, Icons.build_outlined, '维护'),
  ];

  /// 每个分组头部（首个 SectionCard）的定位 key。
  final Map<_Group, GlobalKey> _groupKeys = {
    for (final n in _groupNavs) n.group: GlobalKey(),
  };

  /// 右侧滚动视口（宽模式定位分组用）。
  final GlobalKey _contentKey = GlobalKey();
  final ScrollController _scrollCtrl = ScrollController();
  _Group _active = _Group.appearance;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_syncActive);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _ffmpegCtrl.dispose();
    _ffprobeCtrl.dispose();
    _tplCtrl.dispose();
    _aiKeyCtrl.dispose();
    _aiUrlCtrl.dispose();
    _aiModelCtrl.dispose();
    _mkvDirCtrl.dispose();
    _whisperPathCtrl.dispose();
    _whisperCacheCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFfmpeg() async {
    final path = await FileService.instance.pickExecutable(title: '选择 ffmpeg.exe');
    if (path != null) setState(() => _ffmpegCtrl.text = path);
  }

  Future<void> _pickFfprobe() async {
    final path = await FileService.instance.pickExecutable(title: '选择 ffprobe.exe');
    if (path != null) setState(() => _ffprobeCtrl.text = path);
  }

  Future<void> _saveFfmpegPaths() async {
    final ffmpegPath = _ffmpegCtrl.text.trim();
    final ffprobePath = _ffprobeCtrl.text.trim();
    await StorageService.instance
        .setSetting(StorageService.kFfmpegPath, ffmpegPath);
    await StorageService.instance
        .setSetting(StorageService.kFfprobePath, ffprobePath);

    // 重新配置并检测
    await FfmpegService.instance.reconfigureFfmpeg(
      ffmpegPath: ffmpegPath.isEmpty ? null : ffmpegPath,
      ffprobePath: ffprobePath.isEmpty ? null : ffprobePath,
    );
    await ref.read(settingsProvider).refreshFfmpegStatus();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('FFmpeg 路径已保存并重新检测')),
      );
    }
  }

  Future<void> _cleanTemp() async {
    await FileService.instance.cleanupTempFiles();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('临时文件已清理')),
      );
    }
  }

  Future<void> _pickMkvDir() async {
    final dir = await FileService.instance.pickDirectory();
    if (dir != null) setState(() => _mkvDirCtrl.text = dir);
  }

  Future<void> _saveMkvDir() async {
    await MkvToolNixService.instance.configure(_mkvDirCtrl.text.trim());
    if (mounted) setState(() {});
  }

  /// 从 MKVToolNix 安装目录把工具导入应用内（便携化，免系统安装）。
  Future<void> _importMkvTools() async {
    final src = await FileService.instance.pickDirectory();
    if (src == null || !mounted) return;
    final dest = await MkvToolNixService.instance.importTools(src);
    if (!mounted) return;
    if (dest == null) {
      showErrorSnack(context, '导入失败：所选目录中没有 mkvmerge.exe');
      return;
    }
    await MkvToolNixService.instance.configure(dest);
    setState(() => _mkvDirCtrl.text = dest);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('MKVToolNix 已导入应用内并启用')),
      );
    }
  }

  // ───────────────────────── Whisper ─────────────────────────

  Future<void> _pickWhisperPath() async {
    final path = await FileService.instance.pickExecutable(
        title: '选择 whisper.exe 或 python.exe');
    if (path != null) setState(() => _whisperPathCtrl.text = path);
  }

  Future<void> _pickWhisperCacheDir() async {
    final dir = await FileService.instance.pickDirectory();
    if (dir != null) setState(() => _whisperCacheCtrl.text = dir);
  }

  Future<void> _saveWhisper() async {
    await WhisperService.instance.configure(
      _whisperPathCtrl.text.trim(),
      _whisperCacheCtrl.text.trim(),
      backendCode: _whisperBackend.code,
    );
    if (mounted) setState(() {});
  }

  Future<void> _pickDefaultOutDir() async {
    final dir = await FileService.instance.pickDirectory();
    if (dir != null) {
      await ref.read(settingsProvider).setDefaultOutputDir(dir);
    }
  }

  Future<void> _saveTemplate() async {
    await ref
        .read(settingsProvider)
        .setFilenameTemplate(_tplCtrl.text.trim());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('默认文件名模板已保存')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: LayoutBuilder(builder: (context, cons) {
        // 全量构建（SingleChildScrollView）而非惰性 ListView：锚点跳转
        // 依赖各分组 GlobalKey 的 context 始终存在，视口外的卡片不能被销毁
        final content = SingleChildScrollView(
          key: _contentKey,
          controller: _scrollCtrl,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ..._contentChildren(settings, scheme),
              // 宽模式尾部留白（约一屏）：尾部分组后的内容太短时
              // maxScrollExtent 不够，锚点无法把该分组对齐视口顶部
              if (cons.maxWidth >= _kAnchorModeMinWidth)
                SizedBox(height: cons.maxHeight),
            ],
          ),
        );
        if (cons.maxWidth < _kAnchorModeMinWidth) return content;
        return Row(
          children: [
            SizedBox(width: 212, child: _navPanel(scheme)),
            VerticalDivider(
              width: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.5),
            ),
            Expanded(child: content),
          ],
        );
      }),
    );
  }

  /// 右侧内容：按分组排列全部区块（组内间距 12，组间 24）。
  List<Widget> _contentChildren(SettingsProvider settings, ColorScheme scheme) {
    Widget groupHead(_Group g, Widget child) =>
        KeyedSubtree(key: _groupKeys[g], child: child);
    return [
      groupHead(_Group.appearance, _themeSection(settings, scheme)),
      const SizedBox(height: 24),
      groupHead(_Group.output, _outputSection(settings)),
      const SizedBox(height: 24),
      groupHead(_Group.env, _ffmpegSection(settings, scheme)),
      const SizedBox(height: 12),
      _mkvtoolnixSection(scheme),
      const SizedBox(height: 12),
      _whisperSection(scheme),
      const SizedBox(height: 24),
      groupHead(_Group.ai, _aiSection(settings, scheme)),
      const SizedBox(height: 24),
      groupHead(_Group.maintenance, _maintenanceSection()),
    ];
  }

  /// 左侧锚点导航：点击跳转到对应分组，当前分组高亮。
  Widget _navPanel(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Text(
            '设置分组',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                ),
          ),
        ),
        for (final n in _groupNavs)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            child: ListTile(
              leading: Icon(n.icon, size: 20),
              title: Text(n.label),
              selected: _active == n.group,
              selectedColor: scheme.primary,
              selectedTileColor: scheme.primary.withValues(alpha: 0.08),
              dense: true,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              onTap: () => _jumpTo(n.group),
            ),
          ),
      ],
    );
  }

  /// 点击锚点：平滑滚动到分组头部（对齐视口顶部）。
  void _jumpTo(_Group g) {
    final ctx = _groupKeys[g]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      alignment: 0,
    );
  }

  /// 滚动联动：高亮「头部已越过视口顶部（含切换缓冲）」的最后一个分组。
  void _syncActive() {
    final vp = _contentKey.currentContext?.findRenderObject();
    if (vp is! RenderBox || !vp.attached) return;
    final vpTop = vp.localToGlobal(Offset.zero).dy;
    var next = _groupNavs.first.group;
    for (final n in _groupNavs) {
      final box = _groupKeys[n.group]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      if (top - vpTop <= _kActiveSwitchOffset) next = n.group;
    }
    if (next != _active) setState(() => _active = next);
  }

  /// FFmpeg 区块（烧录 / 转码后端）。
  Widget _ffmpegSection(SettingsProvider settings, ColorScheme scheme) {
    return SectionCard(
      title: 'FFmpeg 路径',
      icon: Icons.terminal_outlined,
      trailing: _statusChip(settings),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (settings.ffmpegError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                settings.ffmpegError!,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.error,
                ),
              ),
            )
          else if (settings.ffmpegVersion != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '检测到 FFmpeg：${settings.ffmpegVersion}'
                '（来源：${settings.ffmpegSource ?? '未知'}）',
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.primary,
                ),
              ),
            ),
          _pathField(
            label: 'ffmpeg.exe',
            controller: _ffmpegCtrl,
            onBrowse: _pickFfmpeg,
            hint: '留空 = 使用系统 PATH 中的 ffmpeg',
          ),
          const SizedBox(height: 8),
          _pathField(
            label: 'ffprobe.exe',
            controller: _ffprobeCtrl,
            onBrowse: _pickFfprobe,
            hint: '留空 = 使用系统 PATH 中的 ffprobe',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _saveFfmpegPaths,
            icon: const Icon(Icons.check, size: 18),
            label: const Text('保存并重新检测'),
          ),
          const SizedBox(height: 8),
          Text(
            '提示：FFmpeg 仅用于字幕烧录与视频转码（需含 libass 的完整版，'
            '如 gyan.dev 的 full 版）。\n轨道提取与封装已改由 MKVToolNix 完成，'
            '无需配置 FFmpeg。\n下载：https://www.gyan.dev/ffmpeg/builds/',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  /// 维护区块。
  Widget _maintenanceSection() {
    return SectionCard(
      title: '维护',
      icon: Icons.build_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            onPressed: _cleanTemp,
            icon: const Icon(Icons.cleaning_services_outlined),
            label: const Text('清理临时文件'),
          ),
        ],
      ),
    );
  }

  // ───────────────────────── MKVToolNix ─────────────────────────

  /// MKVToolNix 区块：状态 / 自定义目录 / 应用内导入（便携化）。
  /// 提取（mkvextract）与封装（mkvmerge）完全依赖此工具。
  Widget _mkvtoolnixSection(ColorScheme scheme) {
    final svc = MkvToolNixService.instance;
    return SectionCard(
      title: 'MKVToolNix（提取 / 封装）',
      icon: Icons.extension_outlined,
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: (svc.isAvailable ? scheme.primary : scheme.error)
              .withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          svc.isAvailable ? '可用' : '未检测到',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: svc.isAvailable ? scheme.primary : scheme.error,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (svc.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                svc.error!,
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            )
          else if (svc.version != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '检测到 MKVToolNix v${svc.version}'
                '（来源：${svc.sourceLabel ?? '未知'}）',
                style: TextStyle(fontSize: 12, color: scheme.primary),
              ),
            ),
          _pathField(
            label: 'MKVToolNix 目录',
            controller: _mkvDirCtrl,
            onBrowse: _pickMkvDir,
            hint: '留空 = 自动检测（捆绑版 → 应用内导入 → 常见安装路径 → PATH）',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _saveMkvDir,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('保存并重新检测'),
              ),
              OutlinedButton.icon(
                onPressed: _importMkvTools,
                icon: const Icon(Icons.download, size: 18),
                label: const Text('从安装目录导入'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '轨道提取（mkvextract）与封装（mkvmerge）完全基于 MKVToolNix，'
            '不再使用 FFmpeg。「导入」会把 mkvmerge / mkvextract 复制进应用'
            '数据目录，之后无需系统安装即可使用。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────── Whisper ─────────────────────────

  /// Whisper 区块：状态 / 自定义路径（whisper.exe / python.exe / 目录）/
  /// 模型缓存目录。保存后重检；转写页监听 availability 通知实时刷新。
  Widget _whisperSection(ColorScheme scheme) {
    final svc = WhisperService.instance;
    final available = svc.isAvailable;
    return SectionCard(
      title: 'Whisper（语音转写）',
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (svc.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                svc.error!,
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            )
          else if (available)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                '检测到 Whisper（来源：${svc.sourceLabel ?? '未知'}，'
                '后端：${svc.backend?.label ?? '未知'}）',
                style: TextStyle(fontSize: 12, color: scheme.primary),
              ),
            ),
          _pathField(
            label: 'Whisper 路径',
            controller: _whisperPathCtrl,
            onBrowse: _pickWhisperPath,
            hint: '留空 = 自动检测（conda/Python Scripts → PATH → python -m）；'
                '可填 whisper.exe / python.exe 或其所在目录',
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<WhisperBackend>(
            initialValue: _whisperBackend,
            decoration: const InputDecoration(
              labelText: '转写后端',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final b in WhisperBackend.values)
                DropdownMenuItem(value: b, child: Text(b.label)),
            ],
            onChanged: (v) =>
                setState(() => _whisperBackend = v ?? WhisperBackend.auto),
          ),
          const SizedBox(height: 8),
          _pathField(
            label: '模型缓存目录',
            controller: _whisperCacheCtrl,
            onBrowse: _pickWhisperCacheDir,
            hint: '留空 = openai-whisper 默认 ~/.cache/whisper',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _saveWhisper,
            icon: const Icon(Icons.check, size: 18),
            label: const Text('保存并重新检测'),
          ),
          const SizedBox(height: 8),
          Text(
            '基础后端 openai-whisper（Python）：pip install -U openai-whisper；'
            '提速可选 faster-whisper（CLI 兼容，CPU 转写约快 4 倍，'
            '支持 VAD 静音过滤）：pip install -U faster-whisper-ctranslate2。\n'
            'whisper.cpp 评估结论（v1.2）：无 Python 依赖、分发友好，'
            '但 CLI 参数面与 GUI 集成成本高，暂不集成，追求速度推荐 '
            'faster-whisper。首次转写会自动下载所选模型，'
            '也可在转写页「模型管理」预下载。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────── 主题设置（详细） ─────────────────────────

  Widget _themeSection(SettingsProvider settings, ColorScheme scheme) {
    return SectionCard(
      title: '主题设置',
      icon: Icons.palette_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 三模式
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                  value: ThemeMode.system,
                  label: Text('跟随系统'),
                  icon: Icon(Icons.brightness_auto, size: 18)),
              ButtonSegment(
                  value: ThemeMode.light,
                  label: Text('亮色'),
                  icon: Icon(Icons.light_mode, size: 18)),
              ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text('暗色'),
                  icon: Icon(Icons.dark_mode, size: 18)),
            ],
            selected: {settings.themeMode},
            showSelectedIcon: false,
            onSelectionChanged: (s) =>
                ref.read(settingsProvider).setThemeMode(s.first),
          ),
          const SizedBox(height: 16),
          Text('种子色',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            '点击即切换，实时生效（无需重启）；深浅色均自动保证对比度。',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          // 预设主题色板
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              for (final preset in AppTheme.presets)
                _seedSwatch(preset, scheme),
            ],
          ),
          const SizedBox(height: 16),
          // 自定义色相滑杆
          Text('自定义颜色',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: settings.seedColor,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: scheme.outlineVariant,
                    width: 1.5,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 10,
                    activeTrackColor: Colors.transparent,
                    inactiveTrackColor: Colors.transparent,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 10),
                  ),
                  child: Slider(
                    value: _customHue ??
                        HSVColor.fromColor(settings.seedColor).hue,
                    max: 360,
                    onChanged: (h) {
                      setState(() => _customHue = h);
                      final seed = HSVColor.fromAHSV(1, h, 0.72, 0.95)
                          .toColor();
                      ref.read(settingsProvider).setSeedColor(seed);
                    },
                  ),
                ),
              ),
            ],
          ),
          // 彩虹渐变轨道
          IgnorePointer(
            child: Container(
              height: 6,
              margin: const EdgeInsets.only(left: 40, right: 18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                gradient: LinearGradient(
                  colors: [
                    for (final h in [
                      0.0, 60.0, 120.0, 180.0, 240.0, 300.0, 360.0
                    ])
                      HSVColor.fromAHSV(1, h, 0.72, 0.95).toColor(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _seedSwatch(ThemePreset preset, ColorScheme scheme) {
    final selected =
        ref.watch(settingsProvider).seedColor.toARGB32() ==
            preset.seed.toARGB32();
    return Tooltip(
      message: preset.name,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          setState(() => _customHue = null);
          ref.read(settingsProvider).setSeedColor(preset.seed);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: preset.seed,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.onSurface : scheme.outlineVariant,
              width: selected ? 3 : 1.5,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: preset.seed.withValues(alpha: 0.45),
                      blurRadius: 10,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: selected
              ? const Icon(Icons.check, size: 18, color: Colors.white)
              : null,
        ),
      ),
    );
  }

  // ───────────────────────── 输出默认值 ─────────────────────────

  Widget _outputSection(SettingsProvider settings) {
    final scheme = Theme.of(context).colorScheme;
    final preview = FilenameTemplate.render(
      _tplCtrl.text.trim(),
      sourceName: '示例视频.mp4',
      extension: 'mp4',
    );
    return SectionCard(
      title: '输出默认值',
      icon: Icons.output_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '所有任务（转换 / 烧录 / 提取 / 转码）默认使用以下设置，'
            '每个任务仍可单独覆盖。',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          // 默认输出目录
          Row(
            children: [
              Icon(Icons.folder_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  settings.defaultOutputDir.isEmpty
                      ? '未设置（各功能使用应用文档目录下的子目录）'
                      : settings.defaultOutputDir,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: settings.defaultOutputDir.isEmpty
                            ? scheme.onSurfaceVariant
                            : null,
                      ),
                ),
              ),
              TextButton.icon(
                onPressed: _pickDefaultOutDir,
                icon: const Icon(Icons.drive_file_move_outline, size: 16),
                label: const Text('选择…'),
              ),
              if (settings.defaultOutputDir.isNotEmpty)
                Tooltip(
                  message: '恢复默认',
                  child: IconButton(
                    icon: const Icon(Icons.restart_alt, size: 18),
                    onPressed: () => ref
                        .read(settingsProvider)
                        .setDefaultOutputDir(''),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // 默认文件名模板
          TextField(
            controller: _tplCtrl,
            decoration: const InputDecoration(
              labelText: '默认文件名模板',
              hintText: '留空 = 各功能内置默认（如 {原文件名}_burned）',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final v in FilenameTemplate.variables.keys)
                ActionChip(
                  label: Text(v, style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() {
                    _tplCtrl.text = '${_tplCtrl.text}$v';
                  }),
                ),
              ActionChip(
                label: const Text('{原文件名}_burned_{时间戳}',
                    style: TextStyle(fontSize: 11)),
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(
                    () => _tplCtrl.text = '{原文件名}_burned_{时间戳}'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '预览：$preview',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFamily: 'Consolas',
                ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _saveTemplate,
              icon: const Icon(Icons.check, size: 18),
              label: const Text('保存模板'),
            ),
          ),
        ],
      ),
    );
  }

  /// AI 翻译：OpenAI 兼容 API（Key / BaseURL / 模型）。
  Widget _aiSection(SettingsProvider settings, ColorScheme scheme) {
    return SectionCard(
      title: 'AI 字幕翻译',
      icon: Icons.smart_toy_outlined,
      trailing: Chip(
        label: Text(settings.aiReady ? '已配置' : '未配置',
            style: const TextStyle(fontSize: 11)),
        avatar: Icon(
          settings.aiReady ? Icons.check_circle : Icons.error_outline,
          size: 16,
          color: settings.aiReady ? Colors.green : scheme.error,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _aiUrlCtrl,
            decoration: const InputDecoration(
              labelText: 'API BaseURL',
              hintText: 'https://api.openai.com（自动补 /v1）',
              prefixIcon: Icon(Icons.link),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _aiModelCtrl,
            decoration: const InputDecoration(
              labelText: '模型',
              hintText: 'gpt-4o-mini / deepseek-chat / …',
              prefixIcon: Icon(Icons.memory),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _aiKeyCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API Key',
              hintText: 'sk-…',
              prefixIcon: Icon(Icons.key),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '仅保存在本机（Hive）；翻译时字幕文本会发送到该 API 服务商。'
            '兼容 OpenAI / DeepSeek / 中转等 chat/completions 接口。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: () async {
                await SettingsProvider.instance.setAiConfig(
                  apiKey: _aiKeyCtrl.text,
                  baseUrl: _aiUrlCtrl.text,
                  model: _aiModelCtrl.text,
                );
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('AI 翻译配置已保存')),
                  );
                }
              },
              icon: const Icon(Icons.check, size: 18),
              label: const Text('保存配置'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(SettingsProvider settings) {
    final ok = settings.ffmpegReady;
    return Chip(
      label: Text(ok ? 'FFmpeg 就绪' : '未检测到 FFmpeg',
          style: const TextStyle(fontSize: 11)),
      avatar: Icon(
        ok ? Icons.check_circle : Icons.error_outline,
        size: 16,
        color: ok ? Colors.green : Theme.of(context).colorScheme.error,
      ),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _pathField({
    required String label,
    required TextEditingController controller,
    required VoidCallback onBrowse,
    required String hint,
  }) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: '浏览…',
          icon: const Icon(Icons.folder_open),
          onPressed: onBrowse,
        ),
      ],
    );
  }
}
