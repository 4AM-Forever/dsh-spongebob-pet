# 更新日志

## 0.2.0 — 未发布（dev 分支）

### 新增

- **桌宠大小三档**：`大`（220×284，默认）/ `中`（158×204）/ `小`（110×142）。
  - 三个入口：右键菜单与托盘图标的「大小」子菜单、设置 → 插件 →「海绵宝宝桌宠」的三档按钮、直接改 `pet/config.json` 的 `size`。
  - 运行中切换即时生效（桌宠每 ~2.4 秒读一次配置文件），不需要重启桌宠。
  - 宿主侧新增 `POST /pet/ui/size`（同源校验），`/pet/ui/state` 增加 `petSize` 字段。
  - `config.json` 的 `scale` 字段由 `size` 取代。

### 修复

- **设置页点档位后高亮不动、像是没绑定**：`/pet/ui/state` 在「桌宠不是插件拉起、靠长轮询心跳在线」时会抛 `TypeError`（`petRunning()` 认了心跳，`petPid` 却仍取 `petChild.pid`，此时 `petChild` 是 `null`），webserver 把 handler 抛错答成 **400** → 设置页刷新永远失败 → 状态与高亮停在旧值；而写入路由 `/pet/ui/size` 是好的，所以桌宠确实会变、界面却不变。修法：拆出 `petChildAlive()`，只有真正由插件拉起的子进程才取 pid（`stopPet`、`/pet/ui/state`、握手文件 diagnostics 三处同错一并修）。
  - 设置页加**乐观高亮**：点下去立刻选中该档并提示「已切到「小」，等桌宠跟随…」，服务端确认后自动让位给真实值；`petPid` 为 `null` 时状态行不再显示「pid null」。
  - `test/smoke.mjs` 增加 7 条 `/pet/ui/*` 回归用例（含「桌宠靠心跳在线时 state 必须 200」「petPid 允许为 null」「切档后立刻反映」「非法档位 400」），测试用配置路径改为可注入，不再动仓库里的 `pet/config.json`。
- **BOM 导致 `dsh web` 启动崩溃**：`package.json` 带 UTF-8 BOM 时，dsh 启动逐个 `JSON.parse` bundle 清单会抛 `SyntaxError: Unexpected token ''`，进程直接退出。已剥掉仓库里所有不该带 BOM 的文件（`package.json`、`pet/config.json` 以及先前提交进 git 的那份）。
- **宿主读配置失败**：桌宠侧 PowerShell 5.1 的 `Set-Content -Encoding UTF8` 会写 BOM，宿主侧 `JSON.parse(readFileSync(..., 'utf8'))` 不剥 BOM → 设置页读档回退默认值、切档位返回失败。两侧都修：PS 改用手写无 BOM（`[System.IO.File]::WriteAllText(..., UTF8Encoding $false)`），JS 侧抽 `readPetConfig()` 读之前剥 BOM 兜底（手改过的存量文件也不会再翻车）。
- `tools/check-syntax.ps1` 增加 **BOM 规则**：含非 ASCII 的 `.ps1` 必须带 BOM（PS 5.1 无 BOM 按 GBK 读会乱码报错）；其余交给 Node / 浏览器读的文件（`.js`/`.mjs`/`.json`/`.yml`/`.cmd`）**绝不能带 BOM**。这类错误现在提交前就会被拦住（已用带 BOM 的探针文件反向验证）。

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
