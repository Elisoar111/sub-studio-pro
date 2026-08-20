# 贡献指南

感谢关注 Subtitle Studio Pro！欢迎通过 issue 与 PR 参与贡献。

## 提交 Issue

- **Bug**：附上版本号（关于页可见）、复现步骤；如可能，用「设置 → 维护 → 导出调试包」生成调试包并附上（含日志与环境信息，注意先删除其中的敏感内容如 API Key）
- **功能建议**：说明使用场景与期望行为，而不是只给实现方案

## 提交 PR

1. Fork 并从 `main` 拉分支：`feat/xxx` 或 `fix/xxx`
2. 遵循开发约定（详见 README「开发指南」）：
   - **TDD**：新行为先写失败测试再实现；服务层通过注入缝（`chatOverride`、`gpuDetectOverride` 等）隔离外部进程与网络
   - **布局回归**：UI 改动须通过 800×600 / 1024×700 / 1280×800 三档窗口测试
   - 外部工具相关 UI 用 `ValueListenableBuilder` 监听可用性通知，禁止静态读取
3. 本地门禁全绿后提交：

   ```bash
   dart analyze   # 零问题
   flutter test   # 全部通过
   ```

4. PR 描述写清动机与改动点；commit message 用中文，格式参考 `git log`
5. 提交 PR 即表示同意将贡献内容以 [MIT License](LICENSE) 授权本项目

## 开发环境

见 README「快速上手 → 开发者」。Windows 10 / 11 + Flutter 3.x（CI 固定 3.47.0）；SDK 路径含空格时用仓库根目录的 `run_debug.bat`（含 `.plugin_symlinks` 自愈）。

## 发布流程（维护者）

质量门禁全绿后打 `v*` tag 推送，CI 自动执行：analyze + test → 构建 setup.exe / portable.zip → 生成 `checksums.txt` → 发布 GitHub Release。
