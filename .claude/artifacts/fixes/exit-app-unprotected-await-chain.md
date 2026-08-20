# Bug: main.dart _exitApp 无保护 await 链——托盘清理异常导致应用无法退出

> Status: FIXED
> Mode: (default)
> Severity: functional
> Author: user
> Last updated: 2026-08-20

## Symptom
托盘 `shutdown()` 抛异常时 `windowManager.destroy()` 永不执行——应用无法通过关闭按钮/托盘菜单退出，只能任务管理器杀进程（异常被 CrashGuard 吞掉仅留日志，用户无感知）。

## Expected
退出序列任一步失败都不阻断后续步骤；与 about_screen.dart 升级退出的保护策略一致。

## Reproduction
- 命令 / 步骤：`flutter test test/services/safe_exit_sequence_test.dart`
- 测试位置：`test/services/safe_exit_sequence_test.dart:8-19`
- 复现稳定性：还原修复后 2/2 失败（cleanup 抛异常时 destroy 未执行 / destroy 异常外抛）

## Hypotheses & diagnosis
| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| H1 | `_exitApp` 顺序 await 两步且无 try/catch，第一步抛异常短路第二步 | confirmed (root cause) | 还原修复（去掉 try/catch）后测试「托盘清理抛异常时窗口销毁仍执行」失败：destroy 未执行 |

## Root cause
main.dart 的退出链是裸 await 序列；托盘插件（tray_manager 原生通道）任一异常都会中断窗口销毁。about_screen.dart 同功能早已每步 try/catch，两处实现不一致。

## Fix
- 改动文件：`lib/main.dart:40-67`
- 一句话改了什么：抽出 `safeExitSequence`（每步 try/catch + onError 注入缝记日志），`_exitApp` 委托给它
- 代码 diff 摘要：
  ```dart
  Future<void> safeExitSequence({cleanup, destroy, onError}) async {
    try { await cleanup(); } catch (e) { onError?.call('cleanup', e); }
    try { await destroy(); } catch (e) { onError?.call('destroy', e); }
  }
  Future<void> _exitApp() => safeExitSequence(
    cleanup: TrayService.instance.shutdown,
    destroy: windowManager.destroy,
    onError: (step, e) => Logger.instance.error('退出时 $step 失败', e),
  );
  ```

## Verification
- V-1: 修复后 3/3 GREEN ✓
- V-2: 临时还原（去掉 try/catch）→ 2 测试 RED ✓
- V-3: dart analyze 零问题 + flutter test 全量 323/323 ✓

## Regression test
- 路径：`test/services/safe_exit_sequence_test.dart`
- 名称：`托盘清理抛异常时窗口销毁仍执行` / `窗口销毁抛异常时不外抛` / `正常路径：两步按序执行且无错误回调`

## Pattern analysis
| 搜索方式 | 命中数 | 是否本次同类隐患 |
|---|---|---|
| about_screen.dart `_exitApp`（升级退出） | 1 处 | 否——已有每步 try/catch |
| main.dart 启动链 `await` 无保护（tray init 等） | 若干 | 待确认——TrayService.init 首个 await 前置 `_initialized=true`，setIcon 抛异常会中断 main() 启动（审计 minor，未修） |

## Open questions / Follow-ups
- `tray_service.dart:29-32`：init 的 `_initialized` 前置 + setIcon 异常会中断应用启动（审计 minor 项，超出本次修复范围）
