# Fix: ASS/SSA 文本列解析丢失（工具链恢复后暴露的潜伏 bug）

- **Date**: 2026-08-19
- **Mode**: 默认
- **Symptom**: `flutter test` 恢复运行后，SSA v4 (Marked) 用例失败：`rawText` 为空字符串
- **Severity**: 影响 ASS/SSA 字幕全部解析场景（预览/格式转换）

## 背景：工具链为何恢复

用户把 Flutter SDK 从 `D:\Flutter SDK\Flutter`（含空格）迁到 `D:\Flutter_SDK\Flutter`，
根治了 Dart 3.13 hooks runner 空格路径未加引号的问题。迁移后需处理两件事：

1. **D: 虚拟盘（vmcache 覆盖层）的 rename-replace 缺陷**：对「基础层文件」（从 VM 外部
   移入的，如整个 SDK 目录）执行 `Move-Item -Force` 覆盖必失败（ERROR_ALREADY_EXISTS）；
   VM 内新建的「上层文件」则正常。flutter 每次启动都会在
   `update_engine_version.ps1` 里 Move-Item 覆盖 `engine.stamp` → 全部 flutter 命令
   启动即失败。修复：删除 `engine.stamp` 一次，flutter 重新生成后落在上层，此后正常。
   （原地写入 [.NET Copy overwrite] 与改名到不存在路径均正常，仅 rename-replace 异常）
2. **`.dart_tool/package_config.json` 残留旧 SDK 路径**：flutter_test 等 SDK 内置包
   解析到已不存在的 `D:/Flutter%20SDK/...` → `flutter pub get` 重新生成即恢复。

## Root Cause

`lib/services/subtitle/subtitle_parser.dart` `_parseAss`：

```dart
final rawText = parts.skip(eventFormat.length).join(',').trim();  // 错误
```

Text 是 Format 的**最后一列**，其内容（可能含逗号）从 `parts[列数-1]` 开始。
`skip(eventFormat.length)` 跳过了整个格式列数，把 Text 第一段丢掉：
- 文本不含逗号 → `rawText` 为空（SSA v4 用例即此）
- 文本含逗号 → 只剩逗号后溢出段，首段丢失（如「含逗号文本, 仍然要完整」只剩后者）

普通 ASS（`Layer, Start, ..., Text` 十列）走同一代码路径，同样受影响。

## Fix

```dart
final textIdx = eventFormat.indexOf('text');
if (startIdx < 0 || endIdx < 0 || textIdx < 0) continue;
// Text 是 Format 最后一列，内容可能含逗号：从 text 列起拼接全部剩余段
final rawText = parts.skip(textIdx).join(',').trim();
```

## Verification

- `flutter test --no-pub`：**22/22 全部通过**（修复前 SSA v4 用例 rawText='' 失败）
- `flutter analyze --no-pub`：No issues found
- 验证均在新 SDK 路径 `D:\Flutter_SDK\Flutter` 下真实执行（含 comma-text 用例
  「含逗号文本, 仍然要完整」完整保留）

## 环境备忘

- 用户 PATH 仍指向旧路径 `D:\Flutter SDK\Flutter\bin`（已不存在）→ 需改为
  `D:\Flutter_SDK\Flutter\bin` 并重启终端
- 遗留清理：`D:\Flutter.exe`、`D:\FlutterLink`（上一会话调试产物，沙箱不允许我删）
- `tool/check_media_uri.dart` 临时脚本已删（工具链恢复后由
  `test/core/media_uri_test.dart` 承担回归职责）
