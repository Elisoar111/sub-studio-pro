# Bug: burnEmbeddedTrack 预提取的临时 SRT 永不删除，临时目录堆积

> Status: FIXED
> Mode: (default)
> Severity: functional
> Author: user
> Last updated: 2026-08-20

## Symptom
内嵌字幕轨烧录后，系统临时目录 `subtitle_studio/` 下残留 `embedded_track_<n>.srt`；多次烧录不断堆积。

## Expected
烧录完成（成功/失败/取消/异常）后临时 SRT 应被删除，烧录产物保留。

## Reproduction
- 命令 / 步骤：`flutter test test/services/ffmpeg/ffmpeg_embedded_cleanup_test.dart`（fake runner 模拟 ffmpeg 落盘，不依赖本机 FFmpeg）
- 测试位置：`test/services/ffmpeg/ffmpeg_embedded_cleanup_test.dart:46-71`
- 复现稳定性：修复前 2/2 失败，修复后 3/3 通过（连续运行）

## Hypotheses & diagnosis
| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| H1 | burnEmbeddedTrack 所有退出路径均无临时文件删除逻辑 | confirmed (root cause) | 修复前代码：extract 后直接 `return burnSubtitles(...)`，无 finally；RED 测试两条路径均检测到残留文件 |
| H2 | 测试路径与 tempDir() 实际落盘路径不一致导致空跑 | confirmed（测试缺陷，非产品 bug） | 初版测试检查 `<tempRoot>/embedded_track_0.srt`，实际落盘 `<tempRoot>/subtitle_studio/...`（tempDir 拼 appDirName），修正后测试才真实 RED |

## Root cause
`burnEmbeddedTrack` 用 `extractTrack` 预提取临时 SRT 后直接转发 `burnSubtitles` 的结果，函数体内没有任何清理语句——成功、失败、取消、异常四条退出路径全部泄漏。

## Fix
- 改动文件：`lib/services/ffmpeg/ffmpeg_service.dart:248-296`
- 一句话改了什么：提取+烧录整体包进 `try/finally`，`finally` 中 `_deleteQuietly(tmpSub)` 静默删除临时文件；新增 `_deleteQuietly` 私有助手（不存在/删除失败均忽略）
- 代码 diff 摘要：
  ```dart
  final tmpSub = p.join(temp, 'embedded_track_$trackIndex.srt');
  try {
    final extract = await extractTrack(...);
    if (!extract.success) return extract;
    return await burnSubtitles(...);
  } finally {
    _deleteQuietly(tmpSub);   // ← 新增：所有退出路径统一清理
  }
  ```

## Verification
- V-1: 修复前 RED（2/2 失败）→ 修复后 GREEN ✓
- V-2: RED 在修复前的未修代码上直接取得（等价于 stash-red 证明，测试真实捕获 bug）✓
- V-3: dart analyze 零问题 + flutter test 全量 314/314 通过 ✓

## Regression test
- 路径：`test/services/ffmpeg/ffmpeg_embedded_cleanup_test.dart:46`
- 名称：`烧录成功后临时字幕被删除，输出产物保留` / `烧录失败时临时字幕同样被删除`
- 附带改动：`pubspec.yaml` dev_dependencies 增加 `path_provider_platform_interface`（测试 fake PathProviderPlatform 所需，锁文件已解析 2.1.3，无版本变更）

## Pattern analysis
| 搜索方式 | 命中数 | 是否本次同类隐患 |
|---|---|---|
| 审查 lib/ 全部临时文件创建点（createTemp/systemTemp/固定名临时文件） | 12 处 | 否——task_runner `_runMux`、mkvtoolnix extractTrackAuto（UUID+finally）、whisper downloadModel 均已有 finally 清理；仅本处缺失，已修 |

## Open questions / Follow-ups
- `ffmpeg_service.dart:262` 固定临时文件名 `embedded_track_<n>.srt`：双开应用实例时同 trackIndex 互踩（后写者覆盖前者，可能烧错字幕）。单实例内因本地车道串行而安全。建议后续改 UUID 命名（同批见审查报告 #6）
- 取消的 ffmpeg 烧录/转码会留半成品输出文件（`ffmpeg_runner_process.dart:338-341`），MKVToolNix 后端取消时会清理，行为不一致（审查报告 #5）
