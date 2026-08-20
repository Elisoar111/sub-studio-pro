# 2026-08-19 封装页三问题修复（纯重封装空列表 / 全局项折叠 / 底部溢出）

用户报告：
1. 对 MKV 本身删减轨道（纯重封装，无外部轨道文件）时封装页轨道列表为空
2. 章节/标签等全局项默认应为折叠态，可展开
3. BOTTOM OVERFLOWED BY 67 PIXELS 仍复现

## 修复

### 1. 纯重封装轨道列表为空（mux_screen `_videoGroup`）

- **根因**：视频组内容仅在存在外部指派轨道时渲染源轨道区；纯重封装
  （只勾/不勾源 MKV 轨道）时 `tracks` 为空，源轨道列表被 `if` 掉。
- **修复**：组展开时无条件渲染 `_sourceTracks(v)`，外部轨道列表仅在其
  非空时追加。源音轨/字幕/章节/标签勾选行正常出现。

### 2. 全局项默认折叠（mux_screen `_globalItemsSection`）

- **修复**：章节 / 标签 / 附件收进「全局项（章节✓ · 标签✓ · 附件×N）」
  折叠行（`_globalsOpen` 集合控制，默认空 = 折叠），点击展开后逐项勾选。
  摘要行实时反映勾选状态。

### 3. 底部溢出（三层修复，根因各不同）

**a. 输出设置卡模板区固定高（~200px）**
- `OutputSettingsCard` 新增 `collapsibleTemplate` 参数：模板编辑区默认
  折叠为单行摘要（预览 + 「编辑」），mux 页启用。省出 ~150px 纵向空间。

**b. EmptyState 最小高度 172px 超出 Expanded 槽位（common.dart，真凶）**
- **现象**：窗口 ≤720px 时提取页（默认页签）无视频空态报
  `RenderFlex overflowed by N pixels`；封装页测试在 IndexedStack 离屏
  页同样报错。
- **根因**：`Center > Padding > Column(min)` 内容高度固定 172px，
  Expanded 槽位不足即溢出。用户报的 67px ≈ 172 − 105px 槽位。
- **修复**：EmptyState 改为 LayoutBuilder——高度受限时
  `SingleChildScrollView > ConstrainedBox(minHeight: 视口高) > Center`，
  放得下时视觉与原版一致（居中），放不下时滚动而非溢出；无限高上下文
  （列表内）保持原 Center 行为。

**c. 区内固定行在极小槽位下溢出（≤600px 级）**
- mux 表头行 / extract segment 概要条在槽位小于行自然高度（~31px）时
  Column 溢出 5px。两处固定行包 `Flexible`（FlexFit.loose）松弛，
  正常尺寸视觉不变。

## 验证（red → green）

- `test/mux_screen_layout_test.dart`（LiveTestWidgetsFlutterBinding +
  setSurfaceSize 同步渲染面与 MediaQuery，mkvmerge 现场生成夹具）：
  - 修复前：1280x720 溢出 79px、1024x640 溢出 159px、全局项 tap 落空
  - 修复后：1920x1080 / 1280x800 / 1280x720 / 1024x640 四档尺寸
    纯重封装源轨道可见 + 无任何 RenderFlex 溢出；全局项默认折叠、
    `ensureVisible` 后展开可勾选 —— 5/5 通过
- 全量 `flutter test` 50/50 通过（临时诊断 `_diag_mux_test.dart` 完成
  使命后删除：末轮零溢出异常，仅剩其自身 Card 索引越界）
- `flutter analyze` 全项目零问题

## 经验

- IndexedStack 离屏子页仍参与布局（Offstage 只挡绘制），离屏页的
  RenderFlex 溢出照样上报——双页签页面必须在各页签下分别验证布局。
- 固定高度空态/表头行放在 Expanded 槽内必须处理槽位不足的情况
  （可滚动或 Flexible 松弛），否则小窗口必然报溢出。
