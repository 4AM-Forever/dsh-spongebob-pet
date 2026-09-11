// 假桥接：给桌宠端到端验收用（tools/e2e-pet-features.ps1 会拉起它）。
// 只实现桌宠真正会调的那几条路由，外部通过 /stub/* 控制推给桌宠的快照与事件。
// 用法：node test/stub-bridge.mjs <port>
import { createServer } from 'node:http'

const port = Number.parseInt(process.argv[2] ?? '0', 10)

const state = {
  seq: 1,
  aggregate: 'idle',
  busyCount: 0,
  sessions: [],
  pending: [],
}
/** 已产生但还没被桌宠取走的事件 */
const queued = []
/** 挂起中的长轮询（有新事件或状态变化时唤醒） */
const waiters = new Set()

const snapshot = () => ({
  ready: true,
  enabled: true,
  dnd: false,
  pluginVersion: 'stub',
  petOnline: true,
  petRunning: false,
  seq: state.seq,
  state: state.aggregate,
  pending: state.pending,
  sessions: state.sessions,
  busyCount: state.busyCount,
})

const json = (res, code, body) => {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8' })
  res.end(JSON.stringify(body))
}

/** 唤醒挂起的长轮询：状态变化时必须回一帧（force），否则等下一个事件才回 */
const wake = () => {
  for (const waiter of [...waiters]) waiter(true)
}

const readBody = (req) =>
  new Promise((resolve) => {
    let raw = ''
    req.on('data', (chunk) => {
      raw += chunk
    })
    req.on('end', () => {
      try {
        resolve(raw === '' ? {} : JSON.parse(raw))
      } catch {
        resolve({})
      }
    })
  })

const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1')
  const path = url.pathname

  if (path === '/pet/hello' || path === '/pet/state') return json(res, 200, snapshot())
  if (path === '/pet/answer' || path === '/pet/control') return json(res, 200, { ok: true })

  if (path === '/pet/events') {
    const since = Number.parseInt(url.searchParams.get('since') ?? '0', 10) || 0
    // force=true：状态变了，哪怕没有事件也要回一帧新快照；
    // force=false：长轮询该挂就挂着，空手回会让桌宠疯狂空转（把收件箱刷爆，真事件全被淹掉）。
    const reply = (force) => {
      const batch = queued.filter((event) => event.seq > since)
      if (!force && batch.length === 0) return
      if (!waiters.delete(reply)) return
      json(res, 200, { ...snapshot(), events: batch, timeout: batch.length === 0 })
    }
    waiters.add(reply)
    reply(false) // 有新事件立刻回，没有就挂着等 /stub/* 唤醒
    req.on('close', () => waiters.delete(reply))
    return
  }

  // ---- 测试脚本用的控制面 ----
  if (path === '/stub/set') {
    const body = await readBody(req)
    if (typeof body.aggregate === 'string') state.aggregate = body.aggregate
    if (Number.isInteger(body.busyCount)) state.busyCount = body.busyCount
    if (Array.isArray(body.sessions)) state.sessions = body.sessions
    wake()
    return json(res, 200, snapshot())
  }
  if (path === '/stub/celebrate') {
    const body = await readBody(req)
    state.seq += 1
    queued.push({
      seq: state.seq,
      type: 'celebrate',
      data: { sessionId: 'sess-a', title: body.title ?? '任务A', durationMs: body.durationMs ?? 12_000 },
    })
    wake()
    return json(res, 200, { ok: true, seq: state.seq })
  }

  return json(res, 404, { error: `unknown route ${path}` })
})

server.listen(port, '127.0.0.1', () => {
  console.log(`stub bridge on http://127.0.0.1:${server.address().port}`)
})
