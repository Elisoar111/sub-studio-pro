# Bug: 纯重封装任务被队列拒绝（封装轨道列表为空）+ 表头标签移除

> Status: FIXED
> Mode: (default)
> Severity: functional（用户核心场景完全不可用）
> Author: user
> Last updated: 2026-08-19

## Symptom

1. 同一 MKV 视频文件，取消勾选部分源轨道后封装，任务失败，报错
   「封装轨道列表为空」。
2. （UI 需求）添加视频后，顶部表头标签「文件 / 语言 / 轨道名称 /
   默认 / 强制」要求删除。

## Expected

1. 纯重封装（无外部轨道文件，仅按勾选删减源 MKV 轨道）是合法任务，
   应成功产出只含勾选轨道的 MKV。
2. 轨道表不渲染列头行。

## Reproduction

- 步骤：封装页添加 MKV → 取消勾选部分源音轨/字幕 → 开始封装 →
  队列任务失败，错误文案「封装轨道列表为空」。
- 测试位置：`test/services/mux_pure_remux_test.dart`（夹具
  audio@0 + subs@1,2,3，mkvmerge 现场生成，真实执行队列与 mkvmerge）
- 复现稳定性：2/2 reliably fails（确定性逻辑分支，无时序因素）

## Hypotheses & diagnosis

| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| H1 | `_runMux` 把「外部轨道为空」当错误拒绝；纯重封装任务 tracksJson='[]' 直接命中该守卫 | confirmed (root cause) | RED 测试错误文案逐字匹配 `queue_service.dart` 旧 271-277 行的返回值；mkvmerge 未被调用 |
| H2 | mkvmerge 对部分勾选参数（--audio-tracks/--subtitle-tracks）语义不兼容导致 exit 2 | eliminated | 本机 mkvmerge v100 直测：`--audio-tracks 0 --subtitle-tracks 1` 等全部组合 exit 0，产物轨道正确；-J 的 id 即选项轨道 ID（0-based 全局连续） |

## Root cause

上一轮迁移到 MKVToolNix 时，`_runMux` 沿用了 v1 语义：「外部轨道列表为空
且无旧版 subtitlePaths 参数」→ 返回失败「封装轨道列表为空」。但引入
sourceSel（源轨道逐条勾选）后，**零外部轨道 + 源轨道删减**成为合法的
纯重封装任务，该守卫把用户最核心的「对 MKV 本身删减轨道」场景整体拒绝。
（用户上一轮报的「封装轨道列表为空」实际就是这个队列错误——当时只修了
UI 显示层 `_videoGroup`，队列层拦截仍在。）

## Fix

- `lib/services/queue_service.dart:270-291`：`tracks.isEmpty` 分支只保留
  v1 旧任务（subtitlePaths）降级重建；无旧参数时 tracks 保持空继续走
  merge（mkvmerge 收到纯源视频 + keepAudioIds/keepSubIds 选择）。
- `lib/screens/mux_screen.dart`：删除 `_tableHeader`（文件/语言/轨道
  名称/默认/强制列头行）及其调用，列表分支简化为直接 Scrollbar+ListView。

## Verification

- V-1: `flutter test test/services/mux_pure_remux_test.dart` RED（2/2
  失败，错误文案逐字匹配）→ 修复后 GREEN（2/2 通过，产物轨道构成
  断言：部分勾选 → `audio@jpn + subtitles@chi`；默认选择 → `audio@jpn`）
- V-2: 临时回退修复一行 → 测试重新 RED（证明测试真捕获 bug）→ 恢复后 GREEN
- V-3: 全量 `flutter test` 52/52 通过；`flutter analyze` 零问题
- V-4: 临时诊断脚本 `tool/_diag_mux_args.dart` 已删除（mkvmerge ID 语义
  实验结论已沉淀到本工件）

## Regression test

- 路径：`test/services/mux_pure_remux_test.dart`
- 名称：「取消勾选部分源字幕后封装必须成功（不再报「封装轨道列表为空」）」
  「默认选择（音轨保留、内嵌字幕全不保留）的纯重封装成功」

## Pattern analysis

| 搜索方式 | 命中数 | 是否本次同类隐患 |
|---|---|---|
| `rg "tracks.isEmpty" lib/` | 2 | 否：extract_screen.dart:850 是 UI 信息提示（「该文件没有可提取的轨道」），空即真无内容，非误拒 |
| `rg "为空'" lib/services/queue_service.dart` | 0（修复后） | — |

无同类隐患。

## 附：mkvmerge 轨道 ID 语义实验结论（本机 v100）

- MKV 输入：`mkvmerge -J` 的 `id` 即 `--audio-tracks/--subtitle-tracks/
  --language` 等选项使用的轨道 ID（0-based，文件内全局连续，视频→音频→
  字幕排列）。
- `--audio-tracks <不存在或非音频的 ID>`：不报错，该类轨道全不保留，
  exit 1（警告，应用视为成功）——应用侧按 -J 的 type 过滤，不会生成错 ID。

## Open questions / Follow-ups

- 用户消息第 3 点未写完（仅一个「3」），待补充。

## 追加（同日）：源字体附件可选（勾选保留）

用户追加需求：「字体也加入可选择的状态」。

**关键事实修正**：merge 对源附件此前未加任何选项，mkvmerge 默认
**复制全部源附件**——UI 一直宣称「不带入」与实际产物不符（本机 v100
实测：无选项 = 全保留）。本次顺势把语义做正。

**mkvmerge 附件选项语义**（本机 v100 实测）：
- 无选项：源附件全复制
- `--no-attachments`：全排除
- `--attachments <ids>`：只保留列出的（附件 ID 从 1 起，与轨道 0 起不同）
- 不存在的 ID：静默空结果（exit 0，不报错）

**实现链路**：
- `MkvToolNixService.merge` 新增 `keepAttachmentIds`：
  null = 全保留（默认，兼容旧任务）、[] = `--no-attachments`、
  非空 = `--attachments id,id`
- `_parseSourceSel` 返回值扩为 6 元组，`fonts` 缺失（旧任务）= null 全保留
- `_SourceSel.fonts` 集合，探测时默认全选（与 mkvmerge 默认行为一致，
  字体常为 ASS 字幕渲染必需）
- UI `_fontRow` 加 Checkbox（勾选=保留/排除，排除行置灰），
  字体子组头显示「字体 N/M（全部排除）」实时计数，
  「附件（…）」大类摘要显示「字体N/M · 章节✓ · 标签✓」
- `_start()` sourceSel 序列化 `fonts`

**验证**（red → green）：
- `mux_pure_remux_test.dart` 新增 3 用例（先 RED：fonts 被忽略、产物
  带全部附件）：勾选 [1] → 产物只含 AID1；[] → 无附件；无 fonts 字段
  （旧任务）→ 全保留（兼容）——5/5 GREEN
- 布局测试：字体行默认全勾选（「保留」×2），取消第二个后
  「排除」+ 摘要 1/2 ——通过（Checkbox 定位用 Row ancestor，因源轨道
  行也有 Checkbox）
- 全量 `flutter test` 55/55；`flutter analyze` 零问题

## 追加（同日）：附件大类三层结构重组（用户澄清需求）

用户澄清第 2 点原意：「把字体什么的都列出来，把章节和字体统统归于
附件，再分为字体和章节，字体再展开显示各个字体」。

改造 `mux_screen.dart` `_globalItemsSection`（原「全局项」行）：

```
附件（字体×2 · 章节✓ · 标签✓）   ← 大类折叠头（默认折叠）
├─ 字体 ×2（源附件不带入封装…）   ← 子组折叠头（默认折叠）
│   ├─ AID 1 · TTF · TestFontA.ttf        [不带入]
│   └─ AID 2 · OTF · TestFontB.otf        [不带入]
├─ 章节 ☑                              ← 勾选行（保留/丢弃）
└─ 标签（轨道/全局 tags） ☑             ← 勾选行（保留/丢弃）
```

- 新增状态 `_fontsOpen`（视频路径 → 字体子组展开），与 `_globalsOpen`
  独立两级折叠
- 字体行为只读明细（硬约束：封装不映射源附件，新字体经添加轨道文件），
  行格式 gMKV 等宽风格 `AID {id} · {类型} · {文件名}`
- 测试：夹具追加 `--attach-file` 两个字体；断言三级默认折叠 → 展开
  附件大类出「字体 ×2 / 章节 / 标签」→ 再展开字体子组出两个字体行
- 关键事实：**mkvmerge -J 的附件 ID 从 1 起**（tracks 从 0 起），断言
  用 AID 1/2（首次用 0/1 断言失败定位）
- 验证：布局测试 5/5、全量 52/52、analyze 零问题
