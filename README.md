# Subtitle Studio Pro（Windows 桌面版）

字幕组专用视频处理工具，**仅面向 Windows 10/11 桌面**。当前版本 **v1.2**。

核心能力：

- **字幕处理**：格式转换（含 GBK/BIG5 编码）、硬字幕烧录、内嵌字幕提取、视频转码压缩
- **轨道处理（v1.1，MKVToolNix 工具链）**：轨道提取（字幕/音轨/视频/章节/字体附件）与
  封装（仅 MKV 容器、字体附件勾选带入、GBK/BIG5 字幕自动转 UTF-8）
- **AI 字幕翻译（v1.2）**：OpenAI 兼容 API 批量翻译；术语表/人名表锁定、批间上下文
  携带、断点续传（失败不重译已成功批次）、可选译文润色二阶段、双语合并输出
- **Whisper 语音转写（v1.2）**：openai-whisper / faster-whisper（`whisper-ctranslate2`）
  双后端；GPU 自动推荐、VAD 静音过滤、初始提示词 `{episode}` 集数模板
- **基础设施**：批量任务队列（网络/本地双车道并行）、参数预设、历史记录、
  视频播放器（播放列表 / 音轨字幕轨切换 / 字幕样式实时调整）、全功能输出路径自定义、
  多主题设置

视频处理通过**调用外部工具可执行文件**（子进程）完成：FFmpeg/FFprobe、
MKVToolNix（mkvmerge/mkvextract）、Whisper CLI，不依赖移动端 FFI 库。

---

## 1. 技术栈

| 项 | 选型 | 理由 |
|---|---|---|
| 状态管理 | **Riverpod**（flutter_riverpod） | 编译期安全、异步支持好、自动管理生命周期 |
| 数据库 | **Hive** | 纯 Dart，Windows 无原生依赖，毫秒级读写 |
| FFmpeg | **系统 FFmpeg 可执行文件**（`Process.start`） | 桌面无移动端 FFI 库，直接调进程最可靠；支持自定义路径 |
| 视频播放 | **media_kit**（libmpv） | Windows 全格式（mkv/Hi10P/FLAC 等字幕组常见格式） |
| 文件选择 | **file_picker**（WIN32 原生对话框） | 免权限，桌面开箱即用 |
| 窗口管理 | **window_manager** | 自定义标题、尺寸、最小尺寸、全屏 |

---

## 2. 项目结构

```
lib/
├── main.dart                        # 入口：窗口管理 + media_kit + Hive + FFmpeg 检测 + Riverpod
├── app.dart                         # ProviderScope + Material 3（浅/深色）
│
├── core/
│   ├── constants.dart               # 支持格式、目录名、Hive Box 名
│   ├── theme.dart                   # ⭐ Material 3 主题（fromSeed 种子色，亮/暗/跟随系统，实时切换）
│   └── utils/
│       ├── ffmpeg_path_escape.dart  # ⭐ 滤镜路径/文本转义（烧录最大坑）
│       ├── time_format.dart         # 时间戳 / 字节 / ETA 格式化
│       ├── logger.dart              # 内存环形缓冲日志器（可导出）
│       ├── media_uri.dart           # 本地路径 → file:// URI（media_kit）
│       └── filename_template.dart   # ⭐ 输出文件名模板渲染（{原文件名}/{时间戳} 等变量）
│
├── models/                          # 数据模型（纯 Dart，可复用）
│   ├── subtitle.dart                # SubtitleCue/Style/Document（含二分查找 cueAt）
│   ├── video_info.dart              # VideoInfo + 视频/音频/字幕轨信息
│   ├── queue_task.dart              # TaskType/TaskStatus/QueueTask
│   ├── history_entry.dart           # 操作历史
│   └── preset.dart                  # 参数预设
│
├── services/
│   ├── ffmpeg/
│   │   ├── ffmpeg_runner.dart           # 执行接口 + 进度/结果/CancelToken + 错误翻译
│   │   ├── ffmpeg_runner_process.dart   # ⭐ 系统 FFmpeg 子进程执行器（进度/取消/自定义路径）
│   │   ├── ffmpeg_service.dart          # ⭐ 高级 API：probeVideo/burnSubtitles/burnEmbeddedTrack/
│   │   │                                #   extractSubtitles/transcode + VideoEncodeOptions
│   │   └── progress_parser.dart         # 解析 `-progress pipe:1` 输出
│   ├── subtitle/                        # 字幕底层实现
│   │   ├── encoding_detector.dart       # ⭐ BOM→严格UTF-8→GBK→BIG5→Latin-1
│   │   ├── subtitle_parser.dart         # ⭐ SRT/ASS/SSA/VTT/MicroDVD 解析（Isolate）
│   │   ├── subtitle_writer.dart         # 序列化
│   │   └── subtitle_converter.dart      # ⭐ 格式转换（纯 Dart、内存高效、批量）
│   ├── subtitle_service.dart            # ⭐ 字幕服务门面（parse/convert/detectEncoding）
│   ├── file_service.dart                # 文件选择/保存（Windows 原生对话框）
│   ├── queue_service.dart               # ⭐ 任务队列（串行、进度回写、取消、历史联动）
│   └── storage_service.dart                # Hive：历史/预设/设置（FFmpeg 路径 + 默认输出目录/文件名模板 + 主题）
│
├── providers/app_providers.dart     # Riverpod：settings/history/preset/queue + FFmpeg 状态
│
├── screens/
│   ├── home_shell.dart              # ⭐ NavigationRail 侧边导航（桌面宽屏）
│   ├── home_screen.dart             # 首页概览（功能网格 + FFmpeg 状态 + 任务面板）
│   ├── subtitle_list_screen.dart    # 字幕库
│   ├── subtitle_preview_screen.dart # 字幕内容预览
│   ├── convert_screen.dart          # 字幕格式转换（批量 + 编码 + 输出目录/文件名模板）
│   ├── burn_screen.dart             # ⭐ 字幕烧录（自动匹配/内嵌轨/样式预设 + 输出目录/文件名模板）
│   ├── extract_screen.dart          # 字幕提取（输出目录/文件名模板）
│   ├── transcode_screen.dart        # 转码/压缩（输出目录/文件名模板）
│   ├── player_screen.dart           # ⭐ 全新播放器（播放列表/音轨字幕轨切换/快捷键/样式实时调整/同步偏移）
│   ├── task_queue_screen.dart       # 任务队列
│   ├── history_screen.dart          # 历史记录
│   ├── preset_screen.dart           # 预设管理
│   ├── result_screen.dart           # 结果页（预览/分享/重命名/另存为/删除）
│   ├── settings_screen.dart         # ⭐ 设置（主题三模式+种子色 + 默认输出路径/文件名模板 + FFmpeg 路径）
│
└── widgets/
    ├── common.dart                  # SectionCard/InfoRow/EmptyState/FileTile/LabeledDropdown
    ├── feature_grid.dart            # 首页功能网格
    ├── encode_settings_panel.dart   # 烧录/转码共用的输出编码设置
    ├── subtitle_overlay.dart        # ⭐ 字幕叠加层（按 position 渲染 + 样式实时调整 + 时间轴偏移）
    └── progress_panel.dart          # 任务进度面板
```

---

## 3. 快速开始

```bash
# 1. 外部依赖
#    FFmpeg（必须！full 版含 libass 才能烧录字幕）
#      https://www.gyan.dev/ffmpeg/builds/  → 解压 → bin 加入系统 PATH
#      或将 ffmpeg.exe / ffprobe.exe 放入 resources/ffmpeg/（优先级：自定义路径 > 捆绑目录 > PATH）
#    MKVToolNix（轨道提取/封装功能需要）：mkvtoolnix 目录可在设置页指定，或加入 PATH
#    Whisper（语音转写可选）：pip install -U openai-whisper
#      提速可选：pip install -U faster-whisper-ctranslate2

# 2. 依赖
flutter pub get

# 3. 生成 Windows 平台目录（首次）
flutter create --platforms windows .

# 4. 运行
flutter run -d windows
# 打包：flutter build windows
# 质量门禁：dart analyze && flutter test（当前 192/192 全绿）
```

> - 仓库不含 `resources/ffmpeg/*.exe`（单文件 185MB 超 GitHub 限制），克隆后按上文自行放置或依赖系统 PATH。
> - 首次构建 media_kit 会联网下载 libmpv 的 DLL（media_kit_libs_windows_video 自动处理）。
> - 开发机 Flutter SDK 路径含空格时，`flutter test`/`dart run` 可能间歇损坏；本仓库提供 `run_debug.bat`（含 .plugin_symlinks 自愈逻辑）。

---

## 4. 核心代码说明

### 4.1 入口 `main.dart`（窗口管理 + Hive + FFmpeg 路径检测）

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();                       // 1) libmpv

  await windowManager.ensureInitialized();            // 2) 窗口
  const windowOptions = WindowOptions(
    size: Size(1200, 800), minimumSize: Size(1000, 700),
    center: true, title: 'Subtitle Studio Pro', titleBarStyle: TitleBarStyle.normal,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show(); await windowManager.focus();
  });

  await StorageService.instance.init();               // 3) Hive

  final ffmpegPath = StorageService.instance.getSetting(StorageService.kFfmpegPath);
  final ffprobePath = StorageService.instance.getSetting(StorageService.kFfprobePath);
  final ffmpeg = await FfmpegService.create(          // 4) FFmpeg（自定义路径优先，否则 PATH）
    ffmpegPath: ffmpegPath.isEmpty ? null : ffmpegPath,
    ffprobePath: ffprobePath.isEmpty ? null : ffprobePath,
  );

  await SettingsProvider.instance.load();             // 5) 状态
  await HistoryProvider.instance.load();
  await PresetProvider.instance.load();
  await SettingsProvider.instance.refreshFfmpegStatus();

  QueueService.instance.init(                         // 6) 队列
    ffmpeg: ffmpeg,
    onTaskFinished: (task) => HistoryProvider.instance.addFromTask(task),
  );

  runApp(const ProviderScope(child: SubtitleStudioApp()));
}
```

### 4.2 `ffmpeg_runner_process.dart`（FFmpeg 进程调用核心）

```dart
// 执行：Process.start（不经 shell，参数直接传递，空格/中文路径安全）
process = await Process.start(
  _ffmpegBin, args,
  stdoutEncoding: utf8,          // -progress 输出（ASCII）
  stderrEncoding: systemEncoding,// 日志（可能含中文路径，GBK）
);

// 进度：stdout 逐行解析 `-progress pipe:1`（out_time_ms / out_time / speed）
final stdoutDone = process.stdout.transform(const LineSplitter()).forEach((line) {
  progressParser.feed(line);
  final p = progressParser.progress;
  if (p != null) report(p);       // report 内部做「进度不回退」去重
});
// 日志：stderr
final stderrDone = process.stderr.transform(const LineSplitter()).forEach((line) {
  logBuffer.writeln(line); onLog?.call(line);
});

final exitCode = await process.exitCode;
await stdoutDone; await stderrDone;

// 取消：直接终止子进程
void onCancel() => process?.kill(ProcessSignal.sigterm);

// 自定义路径：configure({ffmpegPath, ffprobePath}) + init() 重新检测
```

进度百分比：`progress.time / totalDuration`（`totalDuration` 由 FFprobe 预探测，
见 `ffmpeg_service.dart` 的 `probeVideo`）。

### 4.3 `subtitle_service.dart`（字幕服务门面）

纯 Dart 解析/转换，委托 `services/subtitle/` 下的 parser / converter / writer /
encoding_detector。编码检测顺序：BOM → 严格 UTF-8 → GBK → BIG5 → Latin-1
（GBK 必须先于 UTF-8 严格校验之后，否则 UTF-8 中文会被误判乱码）。

### 4.4 视频播放与字幕预览（全新升级）

- 支持极广泛的视频格式（mp4, mov, mkv, avi, flv, webm, ts, m2ts, rmvb, wmv 等），基于 libmpv 支持几乎所有常见格式。
- 播放器核心功能：
  - 播放/暂停、进度条拖动（支持精确 seek）、音量控制、倍速播放（0.25x ~ 4x）、全屏切换。
  - **播放列表**：支持添加多个视频文件，自动连续播放，可手动切换上一个/下一个。
  - **音轨与字幕轨选择**：对于多音轨/多字幕轨的视频，可在播放器菜单中切换当前使用的音频流和字幕流。
  - **快捷键**：空格键播放/暂停，左右方向键快退/快进 5 秒，上下方向键调节音量，F 键全屏，S 键截图当前帧。
  - **字幕实时预览**：
    - 支持加载外部字幕文件（SRT、ASS、SSA、VTT）并叠加显示在视频上。
    - **字幕样式实时调整**：可在播放时动态修改字幕的字体、大小、颜色、边框、阴影、位置、透明度，即时生效。
    - 支持多字幕轨切换，可同时加载多个字幕文件。
    - 字幕同步偏移：可在播放时整体提前/延迟字幕时间轴（±500ms 微调）。
- 视频信息展示：通过 FFprobe 获取详细元数据（分辨率、时长、编码格式、码率、帧率、音轨信息等）并显示在播放器侧边栏。

> 实现要点（media_kit）：`Player() + VideoController(player)` 订阅
> `player.stream.playing / position / duration / tracks` 驱动 UI；
> 播放列表用 `player.open(Playlist([...]))` + `next()/previous()` 自动连播；
> 音轨/字幕轨切换用 `player.setAudioTrack()/setSubtitleTrack()`；
> 倍速 `player.setRate()`、精确 seek `player.seek()`；
> 截图（S 键）可用 FFmpeg 单帧导出实现；
> 字幕叠加层 `subtitle_overlay.dart` 接收 `position` 二分查找渲染当前 cue，
> **样式实时调整与时间轴偏移（±500ms）直接作用于该层，无需重载字幕文件**。

### 4.5 完整功能示例：字幕烧录

「选择视频 + 字幕 → 自动匹配 → 构建 FFmpeg 命令 → 入队 → 进度回传 → 历史记录」
完整链路见 `burn_screen.dart` + `queue_service.dart` + `ffmpeg_service.dart`：

```dart
// burn_screen._start：自动匹配后入队
final match = matchSubtitlePairs(videos, subs);
for (final (video, subtitle) in match.pairs) {
  queue.addTask(type: TaskType.burn, title: '烧录 ${basename(video)}', params: {
    ...encode.toParams(),
    TaskParams.videoPath: video,
    TaskParams.subtitlePath: subtitle,
    TaskParams.outputPath: out,
    TaskParams.useAssFilter: useAss.toString(),
    if (forceStyle != null) TaskParams.forceStyle: forceStyle,
    TaskParams.totalDurationMs: '${info?.duration.inMilliseconds ?? 0}',
  });
}
queue.start();

// ffmpeg_service.burnSubtitles：构建命令
final subFilter = useAssFilter
    ? "ass=${escapeFilterPath(subtitlePath)}"
    : "subtitles=${escapeFilterPath(subtitlePath)}";
args.addAll(['-vf', subFilter + stylePart]);  // + scale 滤镜 + 编码参数
```

### 4.6 输出路径自定义

适用于**字幕格式转换、字幕烧录、字幕提取、视频转码**所有产生输出文件的功能：

- 所有涉及输出文件的功能均需支持用户自定义输出目录。
- 在任务设置界面提供“输出目录”选择按钮，调用系统文件夹选择器（`getDirectoryPath()`），显示所选路径。
- 支持**文件名模板**：用户可设置输出文件名规则，例如 `{原文件名}_burned_{时间戳}` 或 `{原文件名}_cn`。
- **全局默认输出路径**：在应用设置中可设置默认输出目录（如 `D:\Output`），所有任务默认使用该目录，也可在每个任务中单独覆盖。
- 批量任务同样遵循上述规则，可统一设置输出目录，或为每个任务单独指定。

> 实现要点：模板变量渲染统一走 `core/utils/filename_template.dart`；
> 默认输出目录与文件名模板存入 Hive（`StorageService`），任务级设置优先于全局默认值。

### 4.7 主题设置（详细）

- 提供亮色、暗色、跟随系统三种模式。
- 支持自定义种子色（`ColorScheme.fromSeed`），内置多种预设主题（如紫色、蓝色、绿色、橙色、粉色等）。
- 主题设置存储在 Hive 中，启动时加载。
- 深色模式优化，确保对比度合理。
- 以上主题设置变更需实时生效，无需重启应用。

> 实现要点：`core/theme.dart` 用 `ColorScheme.fromSeed(seedColor)` 生成浅/深两套
> Material 3 主题；`ThemeMode.light / dark / system` 三模式切换；
> 设置项经 Riverpod provider 通知 `MaterialApp` 重建，即时生效。

---

## 5. Windows 平台配置（windows/runner）

项目不含 `windows/` 目录时先执行 `flutter create --platforms windows .` 生成。
窗口标题 / 尺寸 / 最小尺寸由 **window_manager** 在 Dart 层控制（见 `main.dart`），
无需修改 C++ 代码。如需进一步定制：

- **窗口标题/图标**：`windows/runner/main.cpp` 中 `window.Create(L"Subtitle Studio Pro", ...)`
  与 `windows/runner/resources/app_icon.ico`（替换即可）。
- **CMakeLists.txt**：本项目无需修改（media_kit / window_manager 自动注入）。
- 应用 ID：`windows/runner/Runner.rc` 中的版本信息按需修改。

> window_manager 版本 0.3.x 支持 `setFullScreen`（播放器全屏用）、`setMinimumSize` 等。

---

## 6. 注意事项（Windows 常见坑）

1. **滤镜路径转义（烧录第一大坑）**：Windows 盘符冒号、反斜杠、单引号、空格会让
   `subtitles=`/`ass=` 解析失败。必须转义：`C:\Subs\我的 字幕.srt` →
   `'C\:/Subs/我的 字幕.srt'`。统一走 `escapeFilterPath()`，禁止手写拼接。

2. **FFmpeg 路径配置**：应用不捆绑 FFmpeg。检测顺序：设置中自定义路径 → 系统 PATH。
   未检测到时不崩溃，在首页/设置页给出提示；设置页可手动指定 `ffmpeg.exe`/`ffprobe.exe`。

3. **libass**：烧录字幕需要含 libass 的 FFmpeg（gyan.dev 的 **full** 版；essentials 版
   不含 libass）。错误日志含 "No such filter: subtitles" 时即为缺 libass。

4. **进程管理**：`Process.start` 不经 shell，参数（含空格/中文路径）直接传递，无需引号。
   取消用 `Process.kill()`（Windows 下为 TerminateProcess）。窗口关闭时队列进程会随
   应用退出而终止（子进程非守护）。

5. **长路径**：Windows 默认 260 字符限制，深层目录 + 长文件名可能导致 FFmpeg 打开失败。
   建议启用系统「长路径支持」（组策略 `LongPathsEnabled=1`），或缩短输出目录。

6. **`-map 0:s:N` 的 N 是字幕流序号不是流索引**：提取内嵌字幕时，第一个字幕轨是
   `0:s:0`（而非其绝对流索引）。

7. **media_kit（libmpv）依赖**：首次构建联网下载 libmpv DLL；发布时确保
   `media_kit_libs_windows_video` 的 DLL 被正确打包（默认自动）。

8. **窗口焦点/全屏**：播放器全屏用 `windowManager.setFullScreen`（桌面无系统状态栏，
   `SystemChrome` 无效）。全屏退出需恢复，避免窗口停留无边框状态。

9. **编码检测**：GBK 几乎任意字节都能解码成功，必须先做严格 UTF-8 校验再试 GBK
   （`EncodingDetector` 已按此实现）；UTF-16 字幕走 BOM 分支。

10. **webm 容器**：libvpx-vp9 没有 x264 的 `-preset` 选项（`_videoArgs` 已跳过）；WebM
    音频强制 libopus。

---

## 7. 实用 FFmpeg 命令示例（6 个）

1) **字幕格式转换（SRT → ASS）**
```bash
ffmpeg -i in.srt out.ass
# -i 输入；输出扩展名决定封装；FFmpeg 内置字幕转换器（纯文本，无需 libass）
```

2) **烧录 SRT 硬字幕（白字黑边）**
```bash
ffmpeg -i in.mp4 -vf "subtitles='in.srt':force_style='FontName=Noto Sans CJK SC,FontSize=20,Outline=1,Shadow=0,PrimaryColour=&H00FFFFFF&,OutlineColour=&H00000000&'" -c:v libx264 -preset medium -crf 20 -c:a aac -b:a 128k -movflags +faststart -y out.mp4
# -vf subtitles：libass 渲染；force_style 覆盖样式（路径必须转义）；-crf 20 高质量；+faststart 流媒体起播
```

3) **烧录 ASS（保留原样式与特效）**
```bash
ffmpeg -i in.mp4 -vf "ass='subs.ass':fontsdir='C\:/Fonts'" -c:v libx264 -crf 20 -c:a copy -y out.mp4
# ass 滤镜完整保留 ASS 样式/卡拉OK；fontsdir 指定中文字体目录避免豆腐块；音频直拷省时
```

4) **提取 MKV 内嵌字幕轨**
```bash
ffmpeg -i in.mkv -map 0:s:0 -c:s srt -y out.srt
# -map 0:s:0 第一个字幕流；-c:s srt 转 SRT（也可 ass/webvtt）
```

5) **视频转码压缩（720p + 小体积）**
```bash
ffmpeg -i in.mp4 -vf "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1" -c:v libx264 -preset faster -crf 28 -c:a aac -b:a 96k -movflags +faststart -y out.mp4
# scale 等比缩小；pad 黑边补齐偶数尺寸；-crf 28 小体积；preset faster 加速编码
```

6) **只提取流（无重编码，秒级无损）**
```bash
ffmpeg -i in.mkv -map 0:v:0 -c:v copy -map 0:a:1 -c:a copy out.mp4
# -c copy 流拷贝无损且极快；-map 精确选择第 2 个音频轨
```

---

## 8. 依赖（pubspec.yaml）

完整内容见仓库 `pubspec.yaml`。要点：

```yaml
environment:
  sdk: '>=3.3.0 <4.0.0'
  flutter: '>=3.19.0'

dependencies:
  flutter_riverpod: ^2.5.1        # 状态管理
  hive: ^2.2.3                    # 本地存储
  hive_flutter: ^1.1.0
  path_provider: ^2.1.4           # 文档/临时目录
  path: ^1.9.0
  file_picker: ^8.1.4             # 文件选择（Windows）
  media_kit: ^1.1.11              # 播放器（libmpv）
  media_kit_video: ^1.2.5
  media_kit_libs_video: ^1.0.5
  share_plus: ^9.0.0              # 分享（Windows 降级为另存为）
  cross_file: ^0.3.4
  charset: ^1.0.0                 # GBK/BIG5 解码
  window_manager: ^0.3.9          # 窗口管理
  uuid: ^4.5.1
```
