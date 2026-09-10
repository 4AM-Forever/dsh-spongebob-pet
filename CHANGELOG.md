# 更新日志

## 0.1.0 — 2026-09-10

首个公开版本。

### 功能

- **接管两条 seam**：`approval/request`（工具审批）与 `user-questions/request`（`ask_user_question` 提问/选择），审批走 `prepend` 抢在网页应答者之前。
- **确认卡片最高优先级弹出**：置顶 + 抢焦点 + 任务栏闪烁 + 提示音 + 全屏压暗；卡片支持单选、多选、自定义回答、跳过题目。
- **安全回落**：桌宠没启动 / 离线超过 30 秒 / 免打扰 / 卡片超时（审批 180s、提问 600s）/ 请求被撤销 / DSH 断开，一律 `next()` 交回 DSH 原生网页确认，绝不阻塞。
- **设置页入口**：设置 → 插件 → 「海绵宝宝桌宠」，显示状态（进程 pid、心跳、待答数）并可启动/结束桌宠。
- **桌宠本体零依赖**：PowerShell 5.1 + WPF 矢量绘制，不下载任何二进制；六种表情跟随 DSH 会话状态（idle/thinking/working/error/asking/sleep）。
- **托盘与右键菜单**：显示隐藏、免打扰、打开 DSH 网页、回到右下角、退出；单实例互斥；分辨率变化导致窗口跑出屏幕时自动拉回右下角。

### 安装

```powershell
dsh plugin --profile web add github:4AM-Forever/dsh-spongebob-pet#v0.1
# 重启 dsh web，然后：设置 → 插件 → 海绵宝宝桌宠 → 启动桌宠
```

本地源码安装：`dsh plugin --profile web add <本目录>`

### 验证

- 桥接逻辑自测 **17/17**：`node test/smoke.mjs`（令牌、取件、审批允许/拒绝、提问作答与非法选项、委派、超时、离线、免打扰）。
- 真机链路：`pending=1 / 卡片窗口在屏=True` → 在卡片上作答 → `pending=0`，答案回传 DSH。
- 语法关：`powershell -ExecutionPolicy RemoteSigned -File tools/check-syntax.ps1`（JS/PS1/JSON 共 16 个文件）。

### 已知限制

- 仅 Windows（桌宠本体依赖 Windows PowerShell 5.1 + WPF）。
- 杀软可能拦截「隐藏窗口拉起 PowerShell」这类行为；插件优先让 `explorer.exe` 执行 `pet/start-pet.cmd`（等价于用户双击）规避，直接 spawn 仅作退路。
- 本机网络若无法 HTTPS 访问 `github.com`（实测该环境 `github.com:443` 超时、`api.github.com` 可用），推送需走 SSH。
