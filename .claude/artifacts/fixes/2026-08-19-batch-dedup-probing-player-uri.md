# Fix: 批次去重 / 探测门控 / 内嵌轨样式 / 播放器 file URI

- **Date**: 2026-08-19
- **Mode**: 默认（多文件中等复杂度）
- **Symptom**: ① 同批次任务输出文件互相覆盖；② burn 页并发探测时进度条提前消失、按钮提前恢复；③ 内嵌字幕轨烧录忽略所选样式；④ 文件名含 `#` 的视频无法播放
- **Severity**: ① 数据覆盖 ② UI 状态错误 ③ 功能不符预期 ④ 功能失败

## Root Causes & Fixes

| # | 文件 | 根因 | 修复 |
|---|---|---|---|
| 1 | `lib/screens/burn_screen.dart` | `_probing` 已改名 `_pendingProbes`（上一轮），UI 两处引用未同步 → 编译错误 | `if (_pendingProbes > 0)` + `onPressed` 门控 |
| 2 | 同上 | `_uniqueOutPath` 只查磁盘；同批次模板渲染出同名时（不同源文件渲染同名），后入队任务覆盖先入队 | `_start()` 维护 `used` 集合（lowercase 文件名），`_uniqueOutPath` 双查内存+磁盘 |
| 3 | `lib/screens/transcode_screen.dart` `convert_screen.dart` `translate_screen.dart` | 同 #2 的同类问题（各自内联去重循环只查磁盘） | 同样加 `used` 集合 |
| 4 | `burn_screen.dart` + `queue_service.dart` | 内嵌轨模式 params 缺 `useAssFilter`/`forceStyle`/`fontsDir`；queue 调 `burnEmbeddedTrack` 时也未传 → 样式选择被忽略，恒为默认 subtitles 滤镜 | 两端补齐参数传递 |
| 5 | `lib/core/utils/media_uri.dart` | 手工拼 `file:///$path` 未做百分号编码；文件名含 `#` 时被 mpv 当 fragment 截断（`%`/空格同类风险） | `Uri.file(path).toString()` 标准编码 |

（mux/extract 页经检查已有 `used` 去重，无需改动。）

## Verification

- `dart analyze`：**No issues found**（修复前 2 个 `_probing` undefined_identifier 编译错误）
- media_uri red→green（`dart tool/check_media_uri.dart`，绕过 build hooks）：
  - 修复前：4 项 FAIL（`#` 产生 fragment `01%20%5B%E5%90%88%E9%9B%86%5D/video.mkv`、路径丢失；`?` 同理）
  - 修复后：5 项 PASS（含 `%`、中文空格往返还原）
  - `?` 用例已删：Windows 文件名不允许 `?`（`Uri.file` 正确抛 ArgumentError），不可能输入
- 长期回归测试：`test/core/media_uri_test.dart`（flutter test 恢复后生效）

## 环境发现（重要）

**本机 `flutter test` / `dart run` 当前无法运行**：Flutter SDK 装在含空格路径
`D:\Flutter SDK\Flutter`，Dart 3.13 的 native-assets hooks runner 经 shell 调用
`dart.exe compile kernel ...` / hook 执行时未给路径加引号，cmd 在空格处截断报
`'D:\Flutter' 不是内部或外部命令`。触发链：path_provider_foundation →
objective_c（带 `hook/build.dart`，Windows 上本应空操作）。

**用户侧修复建议（任选其一）**：
1. 把 Flutter SDK 移到无空格路径（如 `D:\Flutter\Flutter`）并更新 PATH —— 治本；
2. 升级 Flutter/Dart 到修复了 hooks runner 引号问题的版本。

**遗留清理**（沙箱限制 D 盘根目录写删，需用户手动执行）：
```powershell
Remove-Item D:\Flutter.exe -Force        # 调试垫片（拦截 D:\Flutter 未加引号调用）
Remove-Item D:\FlutterLink -Force -Recurse  # 失效 junction
Remove-Item C:\Users\44516\Flutter.exe -Force  # 垫片编译副本（若存在）
```

## 回归防护

- `test/core/media_uri_test.dart` 已入仓（5 用例：普通路径、`#` fragment、`%`、中文空格往返）
