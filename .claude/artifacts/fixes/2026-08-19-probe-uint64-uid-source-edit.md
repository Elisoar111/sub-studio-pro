# 2026-08-19 封装导入视频「无法解析轨道」（超大 UID）+ 源轨属性可编辑

## bug：导入视频无法解析轨道（probe 整体失败）

- **根因**：上一轮在 `parseIdentify` 新增的 `uid: tp['uid'] as int?`。
  Matroska UID 是 uint64 随机数，约半数超出 Dart int（有符号 64 位）范围；
  `jsonDecode` 将超范围整数解析为 **double**，`as int?` 抛
  `TypeError: type 'double' is not a subtype of type 'int?'`，
  probe 的 catch 捕获后返回 null → 视频进 `_unreadable` → 「无法解析轨道」。
- **触发样本**：B 站 MP4 封面附件 uid `14401483379528806630`（> 2^63-1）。
  实测复现链：mkvmerge -J 正常输出（exit 0）→ jsonDecode → double → as int? 抛。
- **修复**：`parseIdentify` 全部整数经局部 `asInt(dynamic v) => v is int ? v : null`
  安全转换（超范围 UID 降级为 null，弹窗不显示该行，其余字段完整）。
  覆盖字段：id / track_number / num_channels / pixel_width / pixel_height /
  minimum_timestamp / uid / attachment id。
- **回归**：
  - test/services/mkvtoolnix_parse_test.dart 新增「超大 UID」用例
    （jsonDecode 字符串构造——Dart 源码整数字面量本身不能超 int64）
  - 真实 mkvmerge -J + 触发 bug 的 MP4 端到端验证通过（临时测试已删）

## 需求：源轨属性可编辑（MKVToolNix 源轨 track options）

- 新模型 `SourceTrackEdit`（mux_track.dart）：id + language/name/isDefault/
  isForced/enabled/delayMs，null = 跟随源；序列化进 sourceSel JSON 的 edits。
- `merge()` 新参数 `sourceEdits`：对源轨 ID 生成 `--language <id>:<lang>`、
  `--track-name`、`--default-track`、`--forced-track`、`--track-enabled`、
  `--sync`（正延后/负提前）。
- UI：源轨行 ℹ→ tune 图标，弹窗可编辑（语言下拉 / 名称 / 延迟 / 三态开关，
  开关值等于源值时自动回落「跟随源」）；「重置」一键还原；行尾「已编辑」
  徽章 + 覆盖后的标志徽章（默认/强制/已禁用/±Nms）；行内属性串显示覆盖值。
- 只对保留轨道写 edits（被排除轨的选项无意义，避免 mkvmerge 警告）。

## 验证

- `dart analyze` 零问题
- `flutter test` 45/45（新增超大 UID 回归）
