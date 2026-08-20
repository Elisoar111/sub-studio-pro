# 2026-08-19 封装页三项需求（含 subtitles 复数 bug）

## 1. bug：源字幕轨在 UI 完全不显示（提取页同源受影响）

- **根因**：mkvmerge -J 输出中字幕轨的 `type` 是复数 `"subtitles"`
  （视频 `video` / 音频 `audio` 单数，唯独字幕复数），而全项目 UI 判断
  均写单数 `'subtitle'`，导致 where 过滤恒空——封装页源轨道区、提取页
  轨道列表的字幕轨全部隐身。
  来源：mkvmerge -J 实际输出脚本示例
  https://gist.github.com/mikemcduffie/5b01725c1fdac35e726c19ebd205f88f
  https://suptosrt.com/pgs-to-srt/mkvtoolnix/
- **修复**：`_parseIdentify`（现公开为 `parseIdentify`）归一化
  `'subtitles' → 'subtitle'`，一处修复全链路（提取页 + 封装页）。
- **回归测试**：test/services/mkvtoolnix_parse_test.dart
  （4 项：复数归一化 / 单数不受影响 / 序号·UID·章节·标签·附件·时长 /
  enabled_track 缺省语义）。

## 2. 「（启用 0 · 未指派 1）」计数标签删除

轨道区标题改回「轨道」。

## 3. 每条轨道的属性 + 类型分类对齐 MKVToolNix

- **源轨道行改版**：MKVToolNix 式 V/A/S 类型徽章（类型色描边）+
  `TID · 编码 · 语言 · 名称 · 规格` 属性串 + 默认/强制/已禁用标志徽章 +
  ℹ 属性弹窗（TID/轨道序号/UID/类型/编码/CodecID/语言/名称/尺寸/声道/
  采样率/起始时间戳/标志——即 MKVToolNix track properties 对话框）。
- **类型分类对齐**：video/audio/subtitles 徽章分类 + 章节、标签、附件
  全局项行（MKVToolNix 的 Chapters/Tags/Attachments 分类）。
- **新增标签开关**：源轨道区显示「标签（轨道/全局 tags）」勾选行
  （`--no-track-tags --no-global-tags`），sourceSel JSON 加 `tags` 键，
  旧任务缺省 true。
- **外部轨道新属性**：
  - 延迟 `--sync`（毫秒，正延后/负提前；属性弹窗编辑）
  - 启用 `--track-enabled`（flag-enabled；禁用轨保留在容器但播放器跳过）
  - MuxTrack 模型加 `delayMs`/`enabled` 字段并序列化
- MkvTrackInfo 补 `enabled`/`uid` 解析（properties.enabled_track/uid）。

## 验证

- `dart analyze` 零问题
- `flutter test` 44/44（含新增 4 项）
