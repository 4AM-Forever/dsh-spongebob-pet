# 海绵宝宝桌宠 · DSH 联动

Windows 桌面上的海绵宝宝：DSH 需要**用户确认或选择**（工具审批、`ask_user_question`）时，它跳到屏幕最前面把人叫过来，皇上直接在桌宠上点掉，DSH 立刻继续跑。

参考实现：[clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk)（Electron 像素宠物 + DSH 宿主插件）。本实现改用零依赖的 PowerShell + WPF，并且把它的「只接审批」扩到**审批 + 提问**两条 seam。

![审批卡片](docs/screenshot-approval.png)

## 组成

| 部分 | 位置 | 作用 |
|---|---|---|
| 桥接插件 | `bridge/`（装进 `~/.dsh/profiles/web`） | 挂在 DSH 里：接管 `approval/request` 与 `user-questions/request`，在 dsh web 服务器上开 `/pet/*` 路由，写握手文件 |
| 桌宠 | `pet/`（PowerShell 5.1 + WPF） | 透明置顶宠物窗口 + 托盘 + 最高优先级确认卡片；长轮询取件、作答回传 |

```
DSH(工具要审批) ──waterfall──▶ 桥接插件 ──HTTP/长轮询──▶ 桌宠卡片（置顶/压暗/响铃）
                                    ▲                        │
                                    └──── POST /pet/answer ───┘   （点「允许一次」即刻返回 allowed-once）
```

## 行为与回退

| 情形 | 结果 |
|---|---|
| 桌宠在线且非免打扰 | 桌宠接管，卡片弹到最前；作答后 DSH 按答案继续 |
| 桌宠没启动 / 离线 >30 秒 | 立刻 `next()`，交回 DSH 原生网页确认，不阻塞 |
| 卡片上点「交给网页回答」或按 `Esc` | 同上，转交网页 |
| 超过超时（审批 180 秒 / 提问 600 秒） | 同上，转交网页 |
| 请求被 DSH 撤销（abort） | 卡片自动关闭，结算为 `cancelled` |
| DSH 断开超过 30 秒（重启/退出） | 在途卡片自动关闭并清空待答，重连后由 DSH 重新发起；不会留一张点了没反应的假卡片 |
| 会话策略 `never` | DSH 在自己内部先拒绝，桌宠无从插手 |
| 托盘「免打扰」 | 不再接管，全部回网页 |

安全边界：`/pet/*` 只挂在仅回环的 dsh web 服务器上，且要求 `~/.dsh/pet-bridge.json` 里的随机令牌；令牌每次 DSH 启动重新生成。

## 桌宠状态

| 状态 | 触发 | 表情 |
|---|---|---|
| `idle` | 无活跃轮次 | 待机，轻微摇摆 |
| `thinking` | `turn/start` | 眼珠上瞟 + 「…」 |
| `working` | 工具调用 / 助手输出 | 双臂上下忙活 |
| `error` | 工具失败 / 轮次异常结束 | 叉眼 + 汗滴 |
| `asking` | 有待答请求 | 举双手 + 感叹号 + 「皇上，需要你拍板！」 |
| `sleep` | DSH 失联 | 闭眼 + 「z Z」 |

## 交互

- 左键拖动：挪位置（退出时记住）
- 右键 / 托盘：显示隐藏、免打扰、打开 DSH 网页、回到右下角、退出
- 卡片：审批＝`允许一次` / `拒绝` / `交给网页回答`；提问＝按题勾选或直接写自定义回答 + 提交
- 卡片的压暗遮罩默认开启（`config.json` 的 `dimScreen`），点不到背后窗口，逼你处理；不想这么凶就设 `false`

![提问卡片](docs/screenshot-question.png)

## 安装 / 卸载

桥接插件已经装好（`~/.dsh/profiles/web/package.json` 的 `dsh-spongebob-pet` 依赖 + bundles 条目），**重启 `dsh web` 后生效**：

```powershell
# 重启 DSH（或直接用设置里 dsh-self-update 的「重启」按钮）
dsh web
```

桌宠本体：

```powershell
# 启动 / 重启（推荐：先清残留实例再拉起）
D:\qiz\code-git\OSS\dsh-spongebob-pet\pet\restart-pet.cmd

# 开机自启（写启动文件夹快捷方式）
powershell -ExecutionPolicy Bypass -File pet\install-autostart.ps1 -StartNow

# 停止
powershell -ExecutionPolicy Bypass -File pet\stop-pet.ps1
```

### 从 DSH 网页里启动桌宠

网页半边（`bridge/lib/client.js`）往「设置 → 插件」里加了一个标签页 **海绵宝宝桌宠**：

| 元素 | 含义 |
|---|---|
| 状态行 | 桌宠进程（pid）、心跳是否连上 DSH、待答确认数、接管开关、免打扰 |
| **启动桌宠** | 拉起桌宠（detached，不随 DSH 重启消失） |
| 结束桌宠 | 调 `stop-pet.ps1` 收掉所有桌宠实例 |
| 刷新 | 手动刷新状态（平时每 3 秒自动刷） |

它打的是宿主侧 `/pet/ui/*` 路由：这条通道**不带令牌**（浏览器读不了磁盘），改用同源校验挡 CSRF——POST 必须带 `Origin` 且等于本站，GET 认 `sec-fetch-site`。

宿主侧另有带令牌的等价入口（令牌见 `~/.dsh/pet-bridge.json`）：

```
http://127.0.0.1:3080/pet/launch?token=<token>
http://127.0.0.1:3080/pet/stop?token=<token>
```

插件拉起的桌宠是 detached 的，**不会再随 DSH 重启被收走**。

`~/.dsh/pet-bridge.json` 里还带一份 `diagnostics`（设置项是否注册、schema 是否加载、桌宠 pid、最近一次启动错误）——没有 shell 时靠它看插件内部走到哪一步。

卸载桥接插件：

```powershell
dsh plugin --profile web remove dsh-spongebob-pet
# 再从 profiles/web/package.json 的 dsh.profile.bundles 里删掉 dsh-spongebob-pet
```

## 配置

`pet/config.json`：

| 字段 | 默认 | 含义 |
|---|---|---|
| `topmost` | `true` | 宠物窗口是否常驻置顶 |
| `dimScreen` | `true` | 卡片弹出时是否全屏压暗 |
| `sound` | `true` | 弹出提示音 |
| `dnd` | `false` | 免打扰；桌宠连上 DSH 后会把这个开关同步过去（也可从托盘切换，会写回本文件） |
| `opacity` / `scale` | `1.0` | 宠物透明度 / 缩放 |
| `bridgeUrl` | `""` | 留空＝读握手文件里的地址 |
| `pollTimeout` | `40` | 长轮询客户端超时（秒） |
| `position` | `-1,-1` | 记住的位置，`-1` 表示右下角 |

`bridge/dsh/index.js` 顶部的 `DEFAULTS` 可改接管超时、离线判定、事件缓冲等。

## 目录

```
dsh-spongebob-pet/
├─ bridge/                 DSH 宿主插件（装进 web profile 的就是这个目录）
│  ├─ dsh/index.js         审批/提问接管 + /pet/* 路由 + 握手文件
│  ├─ cordis.patch.yml     bundle 层：把自己插进 profile 树
│  └─ test/                smoke.mjs（17 项逻辑自测）、pet-server.mjs（联调假 DSH）
├─ pet/                    桌宠本体
│  ├─ SpongeBobPet.ps1     主程序：窗口、托盘、状态机、取件循环
│  ├─ lib/Art.ps1          海绵宝宝矢量形象（XAML）与表情元素索引
│  ├─ lib/Card.ps1         确认/选择卡片
│  ├─ lib/Ui.ps1           Win32 调用（置顶/抢焦点/闪烁）与控件工厂
│  └─ config.json          配置
└─ docs/                   截图
```

## 验证过的行为

| 项 | 方式 | 结果 |
|---|---|---|
| 桥接逻辑 17 项（令牌、取件、审批允许/拒绝、提问作答与非法选项、委派、超时、离线、免打扰） | `node bridge/test/smoke.mjs` | 17/17 通过 |
| 审批：允许 | 假 DSH 触发 → 模拟点击「允许一次」 | DSH 侧收到 `allowed-once` |
| 审批：拒绝 | 模拟点击「拒绝」 | DSH 侧收到 `rejected` |
| 提问：单选 + 多选 + 自定义回答 + 跳过 | UI Automation 驱动真卡片作答 | `{"answers":[{"id":"q1","selected":[]},{"id":"q2","selected":["桥接插件","文档"]},{"id":"q3","selected":[],"custom":"这是桌宠写的自定义回答"}]}`，中文无损 |
| 委派：`Esc` / 「交给网页回答」 | 按下 Esc | 桥接侧走 `next()`，回落原生网页应答者 |
| 免打扰 | `config.json` 置 `dnd=true` 后冷启动再触发审批 | 桌宠上线 5 秒内完成同步，审批直接回落（`unavailable`），不弹卡 |
| DSH 断开清理 | 弹着卡片时杀掉桥接服务 | 30 秒后卡片自动关闭、待答清空，桌宠不残留假卡片 |
| 压暗遮罩 | 对比弹卡前后屏幕亮度 | 13.9 vs 25.0（≈44% 变暗） |
| 插件挂载 | `dsh --profile web --dump-config` | 配置树中出现 `id: spongebob-pet` |
| 真机 DSH 链路 | 重启 `dsh web` 后由真人作答 | 待验证（插件需重启才加载） |

## 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| 桌宠一直显示「DSH 没连上」 | `dsh web` 没重启（插件未加载）；确认 `~/.dsh/pet-bridge.json` 存在 |
| 卡片不弹，DSH 网页照常确认 | 桌宠没运行 / 已免打扰 / 离线判定超时；看桌宠气泡文案 |
| 桌宠起不来 | 用 `powershell -STA -File pet\SpongeBobPet.ps1` 前台跑一次看报错 |
| 双开 | 有单实例互斥，第二次启动会直接退出 |
| 改完 `lib/*.ps1` 后乱码报错 | 文件必须存成 **UTF-8 带 BOM**（Windows PowerShell 5.1 认 BOM 才按 UTF-8 读） |

## 版权

形象是给皇上自己桌面用的同人画（代码里用矢量图形现画，不包含任何官方素材）；外观参考《海绵宝宝》，版权归 Nickelodeon。
