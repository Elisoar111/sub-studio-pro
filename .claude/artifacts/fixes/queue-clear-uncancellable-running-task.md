# Bug: 队列 clearAll/removeTask 移除运行中任务后子进程无法取消且仍写历史

> Status: FIXED
> Mode: (default)
> Severity: functional
> Author: user
> Last updated: 2026-08-20

## Symptom
用户「清空队列」或移除运行中任务后：子进程（ffmpeg/mkvmerge）继续跑完并写盘（CPU 占用、磁盘写入不可见不可控），完成后还会把该任务写入历史记录。

## Expected
移除运行中任务应同时取消其子进程；被用户主动清除的任务不写历史。

## Reproduction
- 命令 / 步骤：`flutter test test/services/queue_clear_running_test.dart`
- 测试位置：`test/services/queue_clear_running_test.dart:63-107`
- 复现稳定性：修复前 2/2 失败（等待取消事件超时），修复后通过；防过度修复的「正常完成仍写历史」用例前后均通过

## Hypotheses & diagnosis
| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| H1 | clearAll/removeTask 先清 `_tokens` map，token 虽仍被 `_runOne` 持有但 cancelTask/cancelAll 再也取不到 → 进程失控 | confirmed (root cause) | 还原修复后测试确认：取消事件 5s 内不触发 |
| H2 | `_runOne` 无条件调用 `_historySaver`，被清除的任务也写历史 | confirmed | 还原修复后历史断言失败 |

## Root cause
`removeTask`/`clearAll` 只清列表和 token map，不调用 token.cancel()——运行中任务的子进程失去唯一取消入口；`_runOne` 收尾时也不检查任务是否仍被用户保留，无条件写历史。

## Fix
- 改动文件：`lib/services/queue_service.dart:211-212, 263-270, 277-285`
- 一句话改了什么：removeTask/clearAll 先 `cancel()` 所有相关 token 再移除；`_runOne` 写历史前检查 `_tasks.contains(task)`
- 代码 diff 摘要：
  ```dart
  void removeTask(String id) {
    _tokens[id]?.cancel();          // ← 新增
    _tasks.removeWhere((t) => t.id == id);
    _tokens.remove(id);
    ...
  }
  void clearAll() {
    for (final t in _tokens.values) { t.cancel(); }  // ← 新增
    ...
  }
  // _runOne 收尾：
  if (_tasks.contains(task)) _historySaver?.call(task);  // ← 守卫
  ```

## Verification
- V-1: 修复前 RED（2 失败）→ 修复后 GREEN ✓
- V-2: 临时还原修复 → 2 测试重新 RED ✓（反向证明测试真捕获 bug）
- V-3: dart analyze 零问题 + flutter test 全量 323/323 ✓

## Regression test
- 路径：`test/services/queue_clear_running_test.dart`
- 名称：`clearAll 取消运行中任务的子进程且不写历史` / `removeTask 取消运行中任务的子进程且不写历史` / `正常运行完成的任务仍写历史（防过度修复）`

## Pattern analysis
| 搜索方式 | 命中数 | 是否本次同类隐患 |
|---|---|---|
| `_tokens` 全部操作点（grep queue_service.dart） | 4 处 | 否——`_runOne` 移除时机正确（任务收尾），其余两处已修 |

## Open questions / Follow-ups
- 无
