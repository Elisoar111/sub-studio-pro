# Subtitle Studio Pro

Windows 字幕组专用视频处理工具（Flutter 桌面版），当前版本 **v2.0**。

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078D6?logo=windows11&logoColor=white)]()
[![Tests](https://img.shields.io/badge/tests-273%2F273-brightgreen)]()
[![analyze](https://img.shields.io/badge/dart%20analyze-0%20issues-brightgreen)]()

字幕组从「拿到生肉」到「发布熟肉」的一站式桌面工具：字幕转码、轨道提取与
封装、AI 翻译、语音转写、烧录压制，全部走批量队列。

## 功能总览

| 模块 | 能力 | 版本 |
|---|---|---|
| 字幕转换 | SRT/ASS/SSA/VTT/MicroDVD 互转；GBK/BIG5 自动检测转 UTF-8；批量 | v1.0 |
| 字幕烧录 | 外挂/内嵌轨烧录；样式预设；ASS 特效保留（libass）；自动匹配同名视频 | v1.0 |
| 视频转码 | x264/x265/VP9 压缩；分辨率/帧率/码率控制；预设管理 | v1.0 |
| 视频播放器 | 播放列表 / 音轨字幕轨切换 / 快捷键 / 字幕样式实时调整 / 时间轴偏移 | v1.0 |
| 轨道处理 | MKVToolNix 工具链：轨道提取（字幕/音频/视频/章节/字体附件）+ 封装（仅 MKV、字体附件勾选带入） | v1.1 |
| 任务队列 | 网络/本地双车道并行调度；取消 / 重试 / 失败详情；历史记录联动 | v1.1 |
| AI 字幕翻译 | OpenAI 兼容 API；术语表/人名表锁定；批间上下文；断点续传；可选润色二阶段；双语合并输出 | v1.2 |
| Whisper 转写 | openai-whisper / faster-whisper 双后端；GPU 自动推荐；VAD 静音过滤；`{episode}` 提示词模板 | v1.2 |
| 术语库与后端扩展 | `.glossary.json` 术语旁车（跨任务共享）；自定义润色指令；whisper.cpp 实验后端；依赖大版本迁移 | v1.3 |
| 自动化与多语言 | 监视文件夹无人值守流水线（配对即烧录）；系统托盘常驻（暂停队列/退出）；中/英界面即时切换 | v2.0 |

基础设施：全局快捷键、参数预设、历史记录、输出路径/文件名模板自定义、
Material 3 多主题（亮/暗/种子色）、zh/en 多语言（跟随系统或手动切换）、
窗口 800×600~全屏自适应。

> 视频处理通过子进程调用外部工具（FFmpeg/FFprobe、MKVToolNix、Whisper CLI），
> 不依赖移动端 FFI 库；工具优先级：设置页自定义路径 → 捆绑 `resources/` → 系统 PATH。

## 技术栈

| 项 | 选型 | 理由 |
|---|---|---|
| 框架 | Flutter（仅 Windows 桌面） | 一套代码、桌面渲染性能好 |
| 状态 | Riverpod + ChangeNotifier 混合 | 编译期安全；存量服务零成本接入 |
| 存储 | Hive | 纯 Dart，无原生依赖，毫秒级读写 |
| 播放 | media_kit（libmpv） | mkv/Hi10P/FLAC 等字幕组格式全覆盖 |
| 窗口 | window_manager | 自定义标题、最小尺寸、全屏 |
| 外部工具 | FFmpeg / MKVToolNix / Whisper | 各领域事实标准，子进程隔离、崩溃互不影响 |

## 项目结构

```
lib/
├── main.dart / app.dart              # 入口：窗口 + media_kit + Hive + 工具检测
├── core/
│   ├── constants.dart                # 支持格式、目录名、Hive Box 名
│   ├── theme.dart                    # Material 3 主题（种子色，亮/暗/系统）
│   └── utils/                        # 滤镜路径转义、文件名模板、字幕匹配、
│                                      #   gMKVExtractGUI 兼容命名、日志环形缓冲
├── models/                           # 纯 Dart 数据模型
│   ├── subtitle.dart                 #   Cue/Style/Document（二分查找 cueAt）
│   ├── queue_task.dart / task_params.dart / task_run_result.dart
│   ├── mux_track.dart / encode_options.dart / video_info.dart / history_entry.dart
├── providers/app_providers.dart      # Riverpod：settings/history/preset/queue
├── l10n/                             # zh/en 双语言 ARB（gen-l10n；托盘经 L10nHolder）
├── screens/                          # 18 个页面
│   ├── home_shell.dart               #   NavigationRail 侧边导航 + 全局快捷键
│   ├── convert / burn / transcode    #   字幕转换 / 烧录 / 转码
│   ├── track_screen.dart             #   轨道处理（提取+封装双页签）
│   ├── translate_screen.dart         #   AI 翻译（术语表/润色开关）
│   ├── whisper_screen.dart           #   语音转写（后端/VAD/GPU/模型管理）
│   ├── player_screen.dart            #   播放器
│   ├── task_queue / history / result / settings / about / subtitle_list / preview
├── services/
│   ├── ffmpeg/                       # 子进程执行器（进度/取消/自定义路径）
│   │                                 #   + 高级 API + -progress 解析
│   ├── mkvtoolnix/                   # mkvmerge/mkvextract 封装（轨道提取/封装）
│   ├── ai/                           # OpenAI 兼容 API 批量翻译（30 cue/批、
│   │                                 #   重试、checkpoint 断点续传、润色）
│   ├── whisper/                      # Whisper CLI 封装（三后端探测、GPU 检测、
│   │                                 #   VAD、{episode} 模板、实时输出）
│   ├── subtitle/                     # 解析/转换/写出/编码检测（Isolate 并行）
│   ├── queue_service.dart            # 双车道调度（网络 ∥ 本地，车道内串行）
│   ├── task_runner.dart              # 各任务类型 → 具体服务的分发执行
│   ├── watch_folder_service.dart     # 监视文件夹无人值守流水线（配对即烧录）
│   ├── tray_service.dart             # 系统托盘（显示主窗 / 暂停队列 / 退出）
│   └── storage_service.dart          # Hive：历史/预设/设置
└── widgets/                          # 通用组件 + 播放器面板（样式/列表/信息/控制）
```

`test/`（45 文件，273 用例）：服务层单测（翻译批次/断点续传/Whisper 参数/
队列调度/字幕解析编码）+ 页面布局回归（800×600/1024×700/1280×800 三档无溢出）。

## 快速开始

```bash
# 1. 外部依赖
#    FFmpeg（必须，full 版含 libass）：https://www.gyan.dev/ffmpeg/builds/
#      bin 加入 PATH，或把 ffmpeg.exe / ffprobe.exe 放入 resources/ffmpeg/
#    MKVToolNix（轨道处理需要）：https://mkvtoolnix.download/ ，目录可在设置页指定
#    Whisper（转写可选）：pip install -U openai-whisper
#      提速后端：pip install -U faster-whisper-ctranslate2

# 2. 依赖与运行
flutter pub get
flutter create --platforms windows .   # 首次生成平台目录
flutter run -d windows
flutter build windows                  # 打包 Release

# 3. 质量门禁
dart analyze                           # 当前 0 issues
flutter test                           # 当前 273/273
```

> - 仓库不含 `resources/ffmpeg/*.exe`（单文件 185MB 超 GitHub 100MB 限制），按上文自行放置或走系统 PATH。
> - 首次构建 media_kit 会联网下载 libmpv DLL（自动）。
> - 开发机 Flutter SDK 路径含空格时 `flutter test` 可能间歇损坏，用根目录 `run_debug.bat`（含 .plugin_symlinks 自愈）。

## 核心设计要点

- **字幕管线纯 Dart**：解析/转换/写出全在 Isolate 中进行，GBK/BIG5/UTF-8 编码
  检测顺序 BOM → 严格 UTF-8 → GBK → BIG5 → Latin-1（严格校验先于宽容解码，
  否则 UTF-8 中文被 GBK 误吞）。
- **AI 翻译批次管线**：30 cue/批、每批 2 次重试、术语表注入 system prompt、
  携带前批尾部 3 条上下文；checkpoint 旁车 `.<输出名>.progress.json`
  （cue 数 + mtime + 语言三重校验）——失败重跑只译未完成批次。
- **工具可用性响应式**：FFmpeg/MKVToolNix/Whisper 状态全部走
  `ValueListenableBuilder`，设置页配置完成即全局刷新，无静态读取。
- **输出命名统一**：内存 `used` 集合 + 磁盘双查去重，杜绝同批次模板撞名覆盖；
  提取扩展名遵循 gMKVExtractGUI v2.15 规则（AVC→`.avc`、HEVC→`.hevc`…）。
- **进度与取消**：FFmpeg 走 `-progress pipe:1` 逐行解析（进度不回退去重）；
  取消 = SIGTERM 子进程；队列取消保留 checkpoint 供断点续传。

## Windows 常见坑（开发必读）

1. **滤镜路径转义**：`subtitles=`/`ass=` 里的盘符冒号、反斜杠、单引号必须转义
   （`C:\Subs\我 的.srt` → `'C\:/Subs/我 的.srt'`），统一走 `escapeFilterPath()`。
2. **libass**：烧录需要 gyan.dev **full** 版；报 `No such filter: subtitles` 即缺 libass。
3. **`-map 0:s:N` 的 N 是流序号不是流索引**（提取内嵌字幕第一大坑）。
4. **长路径**：Windows 默认 260 字符限制，深层目录建议启用 `LongPathsEnabled=1`。
5. **进程取消**：`Process.kill()` 在 Windows 下是 TerminateProcess；应用退出时
   队列子进程随之终止（非守护）。
6. **Whisper 检测慢**：torch 导入需 10~30s，检测放后台线程 + 结果缓存。

## 开发指南

- 新行为先写失败的测试（TDD）；服务层用注入缝（如 `chatOverride`、
  `gpuDetectOverride`）隔离外部进程/网络。
- UI 改动必须在 800×600 / 1024×700 / 1280×800 三档窗口通过布局回归测试。
- 外部工具相关 UI 一律监听可用性通知，禁止静态读取配置。
- 发布前：`dart analyze` 零问题 + `flutter test` 全绿（见 `docs/ROADMAP.md` 门禁节）。

## 路线图

维护与更新计划见 [docs/ROADMAP.md](docs/ROADMAP.md)：
v1.0~v1.3 与 v2.0（监视文件夹、托盘、多语言界面）已全部落地；下一步 v1.5
发布就绪（安装包、自动更新、CI、崩溃日志、隐私声明），期间多语言按页面增量
迁移、whisper.cpp 验证转正。

## License

私人项目，未设开源协议；引用外部工具请遵循其各自协议
（FFmpeg LGPL/GPL、MKVToolNix GPL-2.0、Whisper MIT）。
