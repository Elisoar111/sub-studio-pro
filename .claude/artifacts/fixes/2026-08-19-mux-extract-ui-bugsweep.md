# 2026-08-19 UI 重写后 bug 排查（封装页 / 提取页 / mkvprobe）

排查范围：mux_screen.dart、extract_screen.dart 两个刚重写的页面及其依赖的
MkvToolNixService。方法：逐文件细读 + SDK 源码核对（避免凭记忆误报）。

## 修复的问题

### 1. probe 误拒 mkvmerge 退出码 1（功能 bug，service 层）
- **现象**：带警告的 MKV（轻微损坏、非标准字段——恰是用户最需要提取的
  文件）被整页判为「无法解析」。
- **根因**：`probe()` 用 `exitCode != 0` 判失败，但 mkvmerge -J 的退出码
  语义是 0=成功 / 1=警告（JSON 仍完整有效）/ 2=识别失败。
- **修复**：接受 0 与 1，仅 2（及以上）返回 null。
  mkvtoolnix_service.dart:288-302

### 2. 无视频时未指派池不可见（UX bug，mux）
- **现象**：先添加字幕（进池）但没视频，或删光视频后，池内文件既不显示
  也无法移除——上一轮把池 chip 从输入区移除后引入的回归。
- **修复**：`_tracksZone` 空分支在 EmptyState 下方渲染 `_poolGroup`；
  「指派给视频」菜单在无视频时禁用（防空菜单弹出）。

### 3. `_disabled` 状态残留（状态 bug，mux）
- **现象**：取消某轨道「包含」后移除视频 → 轨道退回池 → 再指派给别的
  视频时行显示未勾选，用户无从得知原因。
- **修复**：`_removeVideo` 退回池时同步 `_disabled.remove(t.path)`
  （与单行移除的清理行为对齐）。

### 4. 列对齐偏移（视觉，mux）
- 表头「文件」左距 88 vs 轨道行文件列 82（拖柄24+勾选36+图标16+间距6）；
  未指派行行首 80 vs 图标列 60。
- **修复**：表头 padding 左 82；未指派行行首 60。

### 5. 「添加视频」未按工具可用性禁用（UX bug，mux）
- **现象**：MKVToolNix 未配置时仍可添加视频，全部显示「无法解析」（实为
  工具缺失）。提取页已做门控，封装页漏了。
- **修复**：输入区按钮与空状态按钮均 `mkvReady` 门控。

## 排除的疑似问题（核对后非 bug）

- `onReorderItem`（新 API 取代 onReorder，SDK 断言二选一；语义为已修正的
  newIndex，现行 `insert(newI, removeAt(oldI))` 用法正确）
- `_probe` 无 catch：service.probe 全 catch 返回 null，不会外抛
- `_selected` key 前缀误删：`|` 非 Windows 合法路径字符，startsWith 安全

## 验证

- `dart analyze` 全项目零问题
- tool/check_gmkv_namer.dart 67/67 通过（exit 0）
