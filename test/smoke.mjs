/**
 * 冒烟测试：用假 ctx + 真 HTTP 服务器跑通握手、审批、提问、超时回退与令牌校验。
 * 运行：node test/smoke.mjs   （DSH_HOME 指向临时目录，不碰真实握手文件）
 */
import { createServer } from 'node:http'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import assert from 'node:assert/strict'

const home = await mkdtemp(join(tmpdir(), 'pet-smoke-'))
process.env.DSH_HOME = home

const { apply } = await import('../lib/index.js')

const routes = new Map()
const listeners = new Map()
const disposers = []

const scope = {
  webServer: {
    port: 0,
    register(route) {
      routes.set(route.path, route)
      return () => routes.delete(route.path)
    },
  },
  // 设置卡片的桩：让 registerSettingsCard 走到「注册成功」分支，不再打警告
  settings: {
    register: () => ({
      get: () => ({}),
      update: () => {},
      watch: () => {},
    }),
  },
  on() {},
}

const ctx = {
  logger: { warn: (message) => console.warn('[warn]', message) },
  on(event, listener, options) {
    const list = listeners.get(event) ?? []
    list.push({ listener, options })
    listeners.set(event, list)
    return () => {}
  },
  inject(deps, callback) {
    callback(scope)
  },
}

apply(ctx, { longPollMs: 800, petIdleMs: 4000, approvalTimeoutMs: 3000, questionTimeoutMs: 3000 })

const server = createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1')
  const route = routes.get(url.pathname)
  if (route === undefined) {
    res.writeHead(404).end()
    return
  }
  Promise.resolve(route.handler(req, res)).catch((error) => {
    res.writeHead(500).end(String(error))
  })
})
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
const base = `http://127.0.0.1:${server.address().port}`

const stateFile = join(home, 'pet-bridge.json')
const readHandshake = async () => {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      return JSON.parse(await readFile(stateFile, 'utf8'))
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 25))
    }
  }
  throw new Error('握手文件未写出')
}
const handshake = await readHandshake()
assert.equal(typeof handshake.token, 'string', '握手文件应写出令牌')
assert.equal(typeof handshake.url, 'string', '握手文件应写出地址')
const token = handshake.token
const auth = { 'x-pet-token': token }
const post = (path, body, headers = auth) =>
  fetch(`${base}${path}`, { method: 'POST', headers: { ...headers, 'content-type': 'application/json' }, body: JSON.stringify(body) })

const checks = []
const check = (label, ok) => {
  checks.push({ label, ok })
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}`)
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
/**
 * 桌面宠上线：在线判定只认长轮询，所以每个用例前先挂一个取件请求。
 * 注意这里**只等 150ms 让请求落地**，不能 await 轮询本身（那会把长轮询等完，桌宠又变离线）。
 * 挂着的那个请求放进 waitingPoll，有 pending 事件时会被立刻唤醒，正好拿来断言事件流。
 */
let waitingPoll = null
async function petOnline() {
  waitingPoll = fetch(`${base}/pet/events?since=0`, { headers: auth }).then((res) => res.json())
  await sleep(150)
}

// 1. 握手与令牌
check('无令牌的 /pet/state 被拒', (await fetch(`${base}/pet/state`)).status === 403)
check('带令牌的 /pet/hello 正常', (await fetch(`${base}/pet/hello`, { headers: auth })).status === 200)

// 2. 审批：桌宠取件并允许
const approvalListener = listeners.get('approval/request')[0]
check('审批监听器以 prepend 注册', approvalListener.options?.prepend === true)
await petOnline()
const approvalPromise = approvalListener.listener(
  { agent: { session: { header: { id: 'sess-1' } } }, toolName: 'pwsh', reason: 'workspace-write' },
  async () => 'unavailable',
)
const events = await waitingPoll
const pendingApproval = events.pending[0]
check('桌宠收到待审批项', pendingApproval?.kind === 'approval' && pendingApproval.approval.toolName === 'pwsh')
check('事件流带出 pending 事件', events.events.some((event) => event.type === 'pending'))
check('状态聚合为 asking', events.state === 'asking')
const allowResponse = await post('/pet/answer', { id: pendingApproval.id, decision: 'allow' })
check('作答接口返回 200', allowResponse.status === 200)
check('审批解析为 allowed-once', (await approvalPromise) === 'allowed-once')

// 3. 审批：拒绝
await petOnline()
const denyPromise = approvalListener.listener({ agent: { session: { header: { id: 'sess-1' } } }, toolName: 'pwsh' }, async () => 'unavailable')
await sleep(80)
const pendingDeny = (await (await fetch(`${base}/pet/state`, { headers: auth })).json()).pending[0]
await post('/pet/answer', { id: pendingDeny.id, decision: 'deny' })
check('审批解析为 rejected', (await denyPromise) === 'rejected')

// 4. 提问：选项作答与非法作答
const questionListener = listeners.get('user-questions/request')[0]
await petOnline()
const questionPromise = questionListener.listener(
  {
    agent: { session: { header: { id: 'sess-1' } } },
    questions: [{ id: 'q1', header: '方向', question: '选哪个？', options: [{ label: 'A' }, { label: 'B' }] }],
  },
  async () => {
    throw new Error('should not delegate')
  },
)
await sleep(80)
const pendingQuestion = (await (await fetch(`${base}/pet/state`, { headers: auth })).json()).pending[0]
check('待答问题带出选项', pendingQuestion?.questions?.[0]?.options?.length === 2)
const badAnswer = await post('/pet/answer', { id: pendingQuestion.id, answers: [{ id: 'q1', selected: ['Z'] }] })
check('非法选项被过滤为空答案并接受', badAnswer.status === 200)
check('问题作答形态正确', JSON.stringify(await questionPromise) === JSON.stringify({ answers: [{ id: 'q1', selected: [] }] }))

// 5. 委派：桌宠把决定交回网页
await petOnline()
const delegatePromise = questionListener.listener(
  { agent: { session: { header: { id: 'sess-1' } } }, questions: [{ id: 'q1', question: '？', options: [{ label: 'A' }] }] },
  async () => 'delegated-to-web',
)
await sleep(80)
const pendingDelegate = (await (await fetch(`${base}/pet/state`, { headers: auth })).json()).pending[0]
await post('/pet/answer', { id: pendingDelegate.id, delegate: true })
check('委派后回落到原生应答者', (await delegatePromise) === 'delegated-to-web')

// 6. 超时回退（桌宠在线但一直不答 → 超时后交回）
await petOnline()
const timeoutListener = approvalListener.listener({ agent: { session: { header: { id: 'sess-1' } } }, toolName: 'bash' }, async () => 'fell-back')
check('超时后回落到原生应答者', (await timeoutListener) === 'fell-back')

// 7. 桌宠离线时不接管（心跳过期）
await sleep(4200)
const offline = approvalListener.listener({ agent: { session: { header: { id: 'sess-1' } } }, toolName: 'bash' }, async () => 'offline-fallback')
check('桌宠离线时不接管', (await offline) === 'offline-fallback')

// 8. 免打扰
await petOnline()
const control = await post('/pet/control', { dnd: true })
check('免打扰开关写入成功', (await control.json()).dnd === true)
const dndResult = approvalListener.listener({ agent: { session: { header: { id: 'sess-1' } } }, toolName: 'bash' }, async () => 'dnd-fallback')
check('免打扰时回落到原生应答者', (await dndResult) === 'dnd-fallback')

server.close()
await rm(home, { recursive: true, force: true })

const failed = checks.filter((entry) => !entry.ok)
console.log(`\n${checks.length - failed.length}/${checks.length} 通过`)
process.exit(failed.length === 0 ? 0 : 1)
