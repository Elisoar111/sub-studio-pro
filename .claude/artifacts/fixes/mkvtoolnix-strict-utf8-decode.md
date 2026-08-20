# Bug: mkvtoolnix 严格 UTF-8 解码——含 GBK 文件名的文件令任务整体失败

> Status: FIXED
> Mode: (default)
> Severity: functional
> Author: user
> Last updated: 2026-08-20

## Symptom
对含旧式 ANSI/GBK 文件名或轨道名的媒体文件执行提取/封装：mkvmerge/mkvextract 输出中的非 UTF-8 字节令 `utf8.decoder` 抛 FormatException，任务以「MKVToolNix 进程异常」失败；`mkvmerge -J` 探测则静默返回 null（界面显示探测失败）。

## Expected
坏字节替换为 U+FFFD 继续解析——与 Whisper 后端（`Utf8Decoder(allowMalformed: true)`）、FFmpeg 后端（systemEncoding）的解码策略一致。

## Reproduction
- 命令 / 步骤：`flutter test test/services/mkvtoolnix_decode_test.dart`
- 测试位置：`test/services/mkvtoolnix_decode_test.dart:11-22`
- 复现稳定性：还原修复（allowMalformed: false）后测试失败抛 FormatException

## Hypotheses & diagnosis
| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| H1 | 三处解码点均用严格 UTF-8：`_runTool` 流式 transform（845 行）、`_tryDir` 版本检测（249 行）、`_doProbe` JSON 探测（343 行）——同一根因 | confirmed (root cause) | 严格解码下 GBK 字节流测试抛 FormatException；whisper_service.dart:1040 已用 allowMalformed 证明项目内已有正确模式 |

## Root cause
mkv 工具输出按文档应为 UTF-8，但旧文件/旧封装工具（第三方 mux 写入的非标准元数据）会产生 GBK/ANSI 字节；严格解码把可容忍的坏字节升级为整个任务失败。三个调用点（流式解码、版本检测、JSON 探测）复制了同一严格策略。

## Fix
- 改动文件：`lib/services/mkvtoolnix/mkvtoolnix_service.dart:136-139, 253-254, 347-348, 818-821, 854-855`
- 一句话改了什么：新增 `_lenientUtf8`（`Utf8Codec(allowMalformed: true)`）统一三处解码；流式路径抽为 `@visibleForTesting static decodeToolLines`
- 代码 diff 摘要：
  ```dart
  const _lenientUtf8 = Utf8Codec(allowMalformed: true);
  // _tryDir / _doProbe:
  Process.run(..., stdoutEncoding: _lenientUtf8, stderrEncoding: _lenientUtf8);
  // _runTool:
  static Stream<String> decodeToolLines(Stream<List<int>> raw) =>
      raw.transform(_lenientUtf8.decoder).transform(const LineSplitter());
  ```

## Verification
- V-1: 修复后 3/3 GREEN ✓
- V-2: 临时还原（allowMalformed: false）→ GBK 字节测试 RED（FormatException）✓
- V-3: dart analyze 零问题 + flutter test 全量 323/323 ✓

## Regression test
- 路径：`test/services/mkvtoolnix_decode_test.dart`
- 名称：`含非 UTF-8 字节（GBK 文件名）的输出不抛异常` / `多字节序列跨 chunk 边界仍正确解码` / `正常 UTF-8 输出按行原样解码`

## Pattern analysis
| 搜索方式 | 命中数 | 是否本次同类隐患 |
|---|---|---|
| grep 全仓库进程输出解码点（utf8.decoder / stdoutEncoding） | 5 处 | 否——whisper（allowMalformed）、ffmpeg（systemEncoding）、subtitle 解析（编码探测器多级回退）策略均正确；mkvtoolnix 3 处已全部修复 |

## Open questions / Follow-ups
- `task_runner.dart:312-314` `_ensureUtf8Subtitle` 失败静默返回 null → GBK 字幕乱码进容器且任务报成功（审计 minor，无日志，未修）
