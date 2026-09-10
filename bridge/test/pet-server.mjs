/**
 * 联调用的假 DSH：把桥接插件挂在一个真 HTTP 服务器上，并提供 /test/* 触发假审批与假提问。
 * 运行：DSH_HOME=<临时目录> node test/pet-server.mjs [port]
 */
import { createServer } from 'node:http'

const port = Number(process.argv[2] ?? 3099)
const routes = new Map()
const listeners = new Map()

const scope = {
  webServer: {
    port,
    register(route) {
      routes.set(route.path, route)
      return () => routes.delete(route.path)
    },
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

const { apply } = await import('../dsh/index.js')
apply(ctx, { longPollMs: 20000, petIdleMs: 60000, approvalTimeoutMs: 600000, questionTimeoutMs: 600000 })

const fakeAgent = { session: { header: { id: 'test-session', title: '联调测试会话' } } }

async function fireApproval() {
  const listener = listeners.get('approval/request')[0].listener
  const outcome = await listener({ agent: fakeAgent, toolName: 'pwsh', callId: 'call_abc123', reason: '需要写工作区外的文件（沙箱升级）' }, async () => 'unavailable')
  console.log(`[test] approval outcome = ${outcome}`)
  return outcome
}

async function fireQuestion() {
  const listener = listeners.get('user-questions/request')[0].listener
  const answer = await listener(
    {
      agent: fakeAgent,
      questions: [
        {
          id: 'q1',
          header: '实现方向',
          question: '桌宠确认卡片的默认样式走哪套？',
          detail: '1. 黄色海绵款（当前）\n2. 极简黑白款\n3. 跟随 DSH 主题色',
          options: [
            { label: '黄色海绵款', description: '和桌宠同一套配色' },
            { label: '极简黑白款', description: '不抢注意力' },
            { label: '跟随主题色', description: '读取 DSH 当前主题' },
          ],
        },
      ],
    },
    async () => 'delegated-to-web',
  )
  console.log(`[test] question answer = ${JSON.stringify(answer)}`)
  return answer
}

/** 多题 + 多选 + 长详情，用来验证卡片滚动、复选框与逐题作答。 */
async function fireMultiQuestion() {
  const listener = listeners.get('user-questions/request')[0].listener
  const plan = Array.from({ length: 18 }, (_, index) => `${index + 1}. 计划步骤 ${index + 1}：做点什么`).join('\n')
  const answer = await listener(
    {
      agent: fakeAgent,
      questions: [
        { id: 'q1', header: '方案评审', question: '这份计划可以开工吗？', detail: plan, options: [{ label: '批准开工' }, { label: '先改一版' }] },
        {
          id: 'q2',
          header: '范围',
          question: '这次要覆盖哪些模块？（可多选）',
          options: [{ label: '桌宠本体' }, { label: '桥接插件' }, { label: '文档' }],
          multiSelect: true,
        },
        { id: 'q3', question: '有什么要补充的？（没有就留空）' },
      ],
    },
    async () => 'delegated-to-web',
  )
  console.log(`[test] multi-question answer = ${JSON.stringify(answer)}`)
  return answer
}

const server = createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1')
  if (url.pathname === '/test/approve') {
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ started: true }))
    fireApproval().catch((error) => console.error('[test] approval failed', error))
    return
  }
  if (url.pathname === '/test/question') {
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ started: true }))
    fireQuestion().catch((error) => console.error('[test] question failed', error))
    return
  }
  if (url.pathname === '/test/multi') {
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ started: true }))
    fireMultiQuestion().catch((error) => console.error('[test] multi-question failed', error))
    return
  }
  const route = routes.get(url.pathname)
  if (route === undefined) {
    res.writeHead(404).end()
    return
  }
  Promise.resolve(route.handler(req, res)).catch((error) => {
    console.error('[test] route error', error)
    res.writeHead(500).end(String(error))
  })
})

server.listen(port, '127.0.0.1', () => console.log(`[test] fake DSH bridge on http://127.0.0.1:${port}`))
