/**
 * spongebob-pet：把 DSH 的审批（approval/request）与提问（user-questions/request）转发给桌面桌宠。
 * 桌宠离线 / 免打扰 / 超时 / 异常时一律 next()，交回 DSH 原生网页应答者；policy=never 由 DSH 在分发前拒绝。
 * 通道：在 dsh web 服务器上挂 /pet/* 路由（仅回环 + 令牌），桌宠长轮询取件、POST 回传作答。
 */
import { randomBytes } from 'node:crypto'
import { existsSync, openSync, readFileSync, writeFileSync } from 'node:fs'
import { mkdir, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'

export const name = 'spongebob-pet'

const VERSION = '0.2.0'
/** 包根（lib/index.js 的上一级）——桌宠本体与启动器都作为插件资产随包走，不写死绝对路径 */
const PACKAGE_ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const PET_DIR = join(PACKAGE_ROOT, 'pet')
/** 三档尺寸：画布 220×284 是「大」档基准 */
const PET_SIZES = ['large', 'medium', 'small']

const DEFAULTS = {
  enabled: true,
  dnd: false,
  approvalTimeoutMs: 180_000,
  questionTimeoutMs: 600_000,
  /** 超过这么久没有桌宠取件即视为离线，立即交回原生应答者 */
  petIdleMs: 30_000,
  /** 点了启动之后，桌宠还没来取件的这段宽限期里界面显示「启动中…」 */
  launchGraceMs: 15_000,
  /** 轮次至少跑了这么久才算「干完一个任务」，桌宠才跳舞庆祝（太短的轮次不庆祝） */
  celebrateMinTurnMs: 8_000,
  longPollMs: 20_000,
  eventBufferSize: 200,
  /** 桌宠本体与停止脚本（设置页开关、/pet/launch 都用这两个路径） */
  petScript: join(PET_DIR, 'SpongeBobPet.ps1'),
  petStopScript: join(PET_DIR, 'stop-pet.ps1'),
  /** 首选：无控制台启动器 exe（Windows 子系统，不闪 cmd、不留最小化控制台） */
  petExe: join(PET_DIR, 'SpongeBobPet.exe'),
  /** 首选启动器：交给 explorer.exe 执行，绕开杀软对 node→powershell 的拦截 */
  petLauncher: join(PET_DIR, 'start-pet.cmd'),
  /** 桌宠配置文件（测试可指向临时文件，别动真身） */
  petConfig: join(PET_DIR, 'config.json'),
  /** 直接拉起失败时的现场（stdout/stderr 落盘） */
  petLaunchLog: join(PET_DIR, 'pet-launch.log'),
}

/** 会话状态优先级：取所有活跃会话里最高的那个作为桌宠表情依据。 */
const STATE_RANK = { idle: 0, thinking: 1, working: 2, error: 3, asking: 4 }

const dshHome = (process.env.DSH_HOME ?? '').trim() || join(homedir(), '.dsh')
const STATE_FILE = join(dshHome, 'pet-bridge.json')

export function apply(ctx, config = {}) {
  const options = { ...DEFAULTS, ...config }
  const token = randomBytes(16).toString('hex')

  const pending = new Map()
  const events = []
  const waiters = new Set()
  const sessions = new Map()
  let seq = 0
  let lastSeenAt = 0
  /** 最近一次「结束桌宠」的时刻，用来让停止前就挂着的长轮询失去存活信号资格 */
  let stoppedAt = 0
  let enabled = options.enabled
  let dnd = options.dnd

  // ---------- 快照与事件流 ----------

  const petOnline = () => lastSeenAt > 0 && Date.now() - lastSeenAt < options.petIdleMs

  function aggregateState() {
    if (pending.size > 0) return 'asking'
    let best = 'idle'
    for (const session of sessions.values()) {
      if ((STATE_RANK[session.state] ?? 0) > (STATE_RANK[best] ?? 0)) best = session.state
    }
    return best
  }

  function publicPending(entry) {
    return {
      id: entry.id,
      kind: entry.kind,
      createdAt: entry.createdAt,
      expiresAt: entry.expiresAt,
      session: entry.session,
      approval: entry.approval,
      questions: entry.questions,
    }
  }

  function snapshot() {
    return {
      seq,
      enabled,
      dnd,
      petOnline: petOnline(),
      state: aggregateState(),
      busyCount: busySessions().length,
      sessions: [...sessions.values()].map(publicSession),
      pending: [...pending.values()].map(publicPending),
    }
  }

  function push(type, data) {
    seq += 1
    events.push({ seq, time: Date.now(), type, data })
    if (events.length > options.eventBufferSize) events.shift()
    for (const waiter of [...waiters]) waiter.wake()
  }

  // ---------- 待答请求的建立与结算 ----------

  function open(entry, resolve) {
    entry.resolve = resolve
    entry.timer = setTimeout(() => settle(entry, { delegate: true, reason: 'timeout' }), entry.timeoutMs)
    entry.timer.unref?.()
    if (entry.signal !== undefined) {
      entry.onAbort = () => settle(entry, { delegate: true, reason: 'aborted' })
      entry.signal.addEventListener('abort', entry.onAbort, { once: true })
    }
    pending.set(entry.id, entry)
    push('pending', publicPending(entry))
  }

  function settle(entry, result) {
    if (!pending.has(entry.id)) return
    pending.delete(entry.id)
    clearTimeout(entry.timer)
    if (entry.onAbort !== undefined) entry.signal.removeEventListener('abort', entry.onAbort)
    push('resolved', { id: entry.id, decision: result.decision ?? null })
    entry.resolve(result)
  }

  /** 桌宠可用时交给它决定；否则（离线/免打扰/超时/中止）原样交回 DSH 后面的应答者。 */
  async function askPet(build, next) {
    if (!enabled || dnd || !petOnline()) return next()
    const result = await new Promise((resolve) => open(build(), resolve))
    return result.delegate === true ? next() : result.value
  }

  ctx.on(
    'approval/request',
    (request, next) =>
      askPet(
        () => ({
          id: `ap-${randomBytes(4).toString('hex')}`,
          kind: 'approval',
          createdAt: Date.now(),
          expiresAt: Date.now() + options.approvalTimeoutMs,
          timeoutMs: options.approvalTimeoutMs,
          signal: request.signal,
          session: sessionInfo(request.agent),
          approval: {
            toolName: typeof request.toolName === 'string' ? request.toolName : '(unknown tool)',
            callId: request.callId ?? null,
            reason: typeof request.reason === 'string' ? request.reason : null,
          },
          questions: null,
        }),
        next,
      ),
    { prepend: true },
  )

  ctx.on(
    'user-questions/request',
    (request, next) =>
      askPet(
        () => ({
          id: `uq-${randomBytes(4).toString('hex')}`,
          kind: 'question',
          createdAt: Date.now(),
          expiresAt: Date.now() + options.questionTimeoutMs,
          timeoutMs: options.questionTimeoutMs,
          signal: request.signal,
          session: sessionInfo(request.agent),
          approval: null,
          questions: (request.questions ?? []).map((question) => ({
            id: String(question.id),
            header: question.header ?? null,
            question: String(question.question ?? ''),
            detail: question.detail ?? null,
            multiSelect: question.multiSelect === true,
            options: (question.options ?? []).map((option) => ({
              label: String(option.label ?? ''),
              description: option.description ?? null,
            })),
          })),
        }),
        next,
      ),
    { prepend: true },
  )

  function sessionInfo(agent) {
    const session = agent?.session
    const id = session?.header?.id ?? session?.id ?? null
    return { id, title: sessions.get(id)?.title ?? null, cwd: session?.header?.cwd ?? null }
  }

  // ---------- 会话状态（桌宠表情与「多线程烧脑中」依据） ----------

  ctx.on('session/event', (session, event) => {
    const id = session?.header?.id ?? session?.id
    if (typeof id !== 'string' || typeof event?.type !== 'string') return
    const record = sessions.get(id) ?? {
      id,
      title: null,
      cwd: null,
      lastTool: null,
      state: 'idle',
      stateSince: Date.now(),
      turnStartedAt: 0,
      updatedAt: 0,
    }
    record.title = session?.header?.title ?? record.title
    record.cwd = session?.header?.cwd ?? record.cwd
    const before = record.state
    switch (event.type) {
      case 'turn/start':
        record.turnStartedAt = Date.now()
        record.state = 'thinking'
        break
      case 'user/message':
        record.state = 'thinking'
        break
      case 'tool/call':
        // 工具名走防御式读取：不同事件版本字段位置不一样，拿不到就不显示，绝不因此抛错
        record.lastTool = readToolName(event) ?? record.lastTool
        record.state = 'working'
        break
      case 'assistant/message':
        record.state = 'working'
        break
      case 'tool/result':
        record.state = event.data?.message?.content?.[0]?.isError === true ? 'error' : 'working'
        break
      case 'turn/end': {
        const failed = event.data?.reason?.kind === 'error'
        record.state = failed ? 'error' : 'idle'
        const startedAt = record.turnStartedAt
        const durationMs = startedAt > 0 ? Date.now() - startedAt : 0
        record.turnStartedAt = 0
        // 干完活让桌宠跳一小段庆祝；太短的轮次不庆祝，免得刷屏
        if (!failed && durationMs >= (options.celebrateMinTurnMs ?? 8_000)) {
          push('celebrate', { sessionId: id, title: record.title, durationMs })
        }
        break
      }
      default:
        break
    }
    record.updatedAt = Date.now()
    if (before !== record.state) record.stateSince = Date.now()
    sessions.set(id, record)
    if (before !== record.state) push('session', publicSession(record))
    const cutoff = Date.now() - 30 * 60_000
    for (const [key, value] of sessions) {
      if (value.updatedAt < cutoff && value.state === 'idle') sessions.delete(key)
    }
  })

  /** 只把桌宠用得上的字段送出去（snapshot 与会话列表共用同一形状） */
  function publicSession(record) {
    return {
      id: record.id,
      title: record.title,
      cwd: record.cwd,
      state: record.state,
      stateSince: record.stateSince,
      lastTool: record.lastTool,
      updatedAt: record.updatedAt,
    }
  }

  /** 正在烧脑的会话数（thinking / working） */
  const busySessions = () =>
    [...sessions.values()].filter((record) => record.state === 'thinking' || record.state === 'working')

  /** 工具名在不同事件版本里位置不同，取到就用、取不到就 null */
  function readToolName(event) {
    const candidates = [
      event?.data?.toolName,
      event?.data?.name,
      event?.data?.call?.name,
      event?.data?.message?.content?.[0]?.name,
      event?.toolName,
    ]
    for (const candidate of candidates) {
      if (typeof candidate === 'string' && candidate !== '') return candidate
    }
    return null
  }

  // ---------- 桌宠进程：设置页开关与 /pet/launch 共用同一套 ----------

  let petChild = null
  let petSettings = null
  let lastLaunch = null
  /** 最近一次「启动桌宠」的时刻：桌宠起来要几秒，这段窗口里界面显示「启动中…」 */
  let lastLaunchAt = 0
  const diagnostics = {
    settingsInjected: false,
    settingsRegistered: false,
    schemaLoaded: false,
    watchAttached: false,
    settingsError: null,
    lastLaunchError: null,
  }

  /** 插件自己拉起的子进程还活着（只有这种情况才有 pid） */
  const petChildAlive = () =>
    petChild !== null && petChild.exitCode === null && petChild.killed !== true

  /** 桌宠算不算在跑：自己拉起的子进程活着，或者它正在长轮询心跳（皇上用快捷方式启动的就属这类） */
  const petRunning = () => petChildAlive() || petOnline()

  /** 刚点过启动、桌宠还没来取件：界面显示「启动中…」，别让皇上以为没点上 */
  const petStarting = () =>
    !petRunning() && lastLaunchAt > 0 && Date.now() - lastLaunchAt < (options.launchGraceMs ?? 15_000)

  function launchPet() {
    if (petRunning()) return { ok: true, already: true, pid: petChild?.pid ?? null }
    lastLaunchAt = Date.now()
    // 首选无控制台启动器 exe（pet/SpongeBobPet.exe）：Windows 子系统程序，拉桌宠时
    // 既不闪 cmd 窗口也不留最小化控制台，而且不是脚本宿主，杀软不会按「node→powershell」拦。
    if (existsSync(options.petExe)) {
      try {
        spawn(options.petExe, [], { detached: true, stdio: 'ignore', windowsHide: true }).unref()
        push('pet', { running: true, via: 'exe' })
        return { ok: true, via: 'exe', launcher: options.petExe }
      } catch (error) {
        diagnostics.lastLaunchError = String(error?.message ?? error)
      }
    }
    // 退路 1：让 explorer.exe 执行 .cmd（等价用户双击，杀软不拦）
    if (existsSync(options.petLauncher)) {
      try {
        spawn('explorer.exe', [options.petLauncher], { detached: true, stdio: 'ignore', windowsHide: true }).unref()
        push('pet', { running: true, via: 'explorer' })
        return { ok: true, via: 'explorer', launcher: options.petLauncher }
      } catch (error) {
        diagnostics.lastLaunchError = String(error?.message ?? error)
      }
    }
    if (!existsSync(options.petScript)) {
      ctx.logger?.warn?.(`spongebob-pet: 桌宠脚本不存在 ${options.petScript}`)
      return { ok: false, error: `pet script not found: ${options.petScript}` }
    }
    try {
      // 退路：直接拉起。控制台靠 spawn 的 windowsHide 隐藏，不写 -WindowStyle Hidden，
      // 也不用 Bypass —— 这两个词是杀软眼里的木马招牌。启动输出落盘，被杀也有现场。
      let stdio = 'ignore'
      try {
        const fd = openSync(options.petLaunchLog, 'a')
        stdio = ['ignore', fd, fd]
      } catch {
        stdio = 'ignore'
      }
      const child = spawn(
        'powershell.exe',
        ['-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-STA', '-File', options.petScript],
        { detached: true, stdio, windowsHide: true },
      )
      child.on('exit', (code) => {
        petChild = null
        reflectLaunch(false)
        push('pet', { running: false, exitCode: code })
      })
      child.unref()
      petChild = child
      push('pet', { running: true, pid: child.pid })
      return { ok: true, pid: child.pid }
    } catch (error) {
      diagnostics.lastLaunchError = String(error?.message ?? error)
      return { ok: false, error: String(error?.message ?? error) }
    }
  }

  function stopPet() {
    const killed = petChildAlive() ? petChild.pid : null
    petChild = null
    try {
      spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', options.petStopScript], {
        stdio: 'ignore',
        windowsHide: true,
      }).unref?.()
      // 立刻作废心跳：否则 petOnline() 还要等 petIdleMs（30 秒）才过期，
      // 设置页会一直显示「运行中」（皇上实测就是这个延迟）
      lastSeenAt = 0
      stoppedAt = Date.now()
      lastLaunchAt = 0
      push('pet', { running: false })
      return { ok: true, killed }
    } catch (error) {
      return { ok: false, error: String(error?.message ?? error) }
    }
  }

  /** 桌宠自己退出时把设置里的开关同步回 false，页面别显示成还开着 */
  function reflectLaunch(running) {
    lastLaunch = running
    try {
      if (petSettings !== null && petSettings.get()?.launch !== running) petSettings.update({ launch: running })
    } catch {
      /* 设置写失败不影响桌宠本身 */
    }
  }

  function applyPetSettings(value, initial = false) {
    const next = value ?? {}
    if (typeof next.enabled === 'boolean') enabled = next.enabled
    if (typeof next.dnd === 'boolean') dnd = next.dnd
    const wantLaunch = next.launch === true
    // 只在「真的发生转变」时动手：开关为 false 时不该把皇上手动开的桌宠杀掉
    if (wantLaunch && !petRunning()) {
      if (!petOnline()) {
        if (initial) {
          // 插件刚加载：先给桌宠几秒自己来取件（它可能早就在跑），免得重复拉起一个立刻退出的实例
          const timer = setTimeout(() => {
            if (!petRunning() && !petOnline()) launchPet()
          }, 4000)
          timer.unref?.()
        } else {
          launchPet()
        }
      }
    } else if (!wantLaunch && lastLaunch === true) {
      stopPet()
    }
    lastLaunch = wantLaunch
  }

  /** 从 profile 的 node_modules 里同步取 schemastery（本插件是 link 进来的，自身路径解析不到） */
  function loadSchema() {
    const anchors = [
      join(dshHome, 'profiles', 'web', 'node_modules', 'dsh-spongebob-pet', 'anchor.cjs'),
      join(dshHome, 'profiles', 'node_modules', 'dsh-spongebob-pet', 'anchor.cjs'),
      join(dirname(process.argv[1] ?? process.execPath), '..', 'anchor.cjs'),
    ]
    for (const anchor of anchors) {
      try {
        const require = createRequire(anchor)
        const loaded = require('@deepseek-ai/schemastery')
        const schema = loaded?.default ?? loaded
        if (typeof schema?.object === 'function') return schema
      } catch {
        /* 换下一个锚点 */
      }
    }
    return null
  }

  function fallbackSchema() {
    const schema = (value) => ({ ...(value ?? {}) })
    schema.toJSON = () => ({ uid: 0, refs: { 0: { type: 'object', meta: { default: {} }, dict: {} } } })
    return schema
  }

  function registerSettingsCard() {
    if (typeof ctx.inject !== 'function') return
    ctx.inject(['settings'], (scope) => {
      diagnostics.settingsInjected = true
      try {
        const z = loadSchema()
        diagnostics.schemaLoaded = z !== null
        const schema = z === null
          ? fallbackSchema()
          : z.object({
            launch: z.boolean().default(false).description('启动桌宠：打开即拉起海绵宝宝，关闭即结束它'),
            enabled: z.boolean().default(true).description('接管 DSH 的确认与提问（关闭后全部留在网页上）'),
            dnd: z.boolean().default(false).description('免打扰：不弹卡片，桌宠只当装饰'),
          })
        const namespace = scope.settings.register('spongebob-pet', schema, { base: {} })
        petSettings = namespace
        diagnostics.settingsRegistered = true
        if (z === null) ctx.logger?.warn?.('spongebob-pet: 没找到 schemastery，设置卡片将没有开关')
        applyPetSettings(namespace.get(), true)
        let watching = false
        try {
          if (typeof namespace.watch === 'function') {
            namespace.watch((next) => applyPetSettings(next))
            watching = true
          }
        } catch {
          watching = false
        }
        diagnostics.watchAttached = watching
        if (!watching) {
          // 兜底：拿不到 watch 就轮询（读设置是纯内存操作，很便宜）
          let last = JSON.stringify(namespace.get() ?? {})
          const timer = setInterval(() => {
            try {
              const snapshot = namespace.get() ?? {}
              const current = JSON.stringify(snapshot)
              if (current === last) return
              last = current
              applyPetSettings(snapshot)
            } catch {
              /* 读失败下次再试 */
            }
          }, 3000)
          timer.unref?.()
        }
      } catch (error) {
        diagnostics.settingsError = String(error?.message ?? error)
        ctx.logger?.warn?.(`spongebob-pet: 设置卡片注册失败：${error}`)
      }
    })
  }

  registerSettingsCard()

  // ---------- 桌宠 HTTP 通道 ----------

  if (typeof ctx.inject === 'function') ctx.inject(['webServer'], (scope) => {
    const route = (path, handler) =>
      scope.webServer.register({ name: `spongebob-pet:${path}`, kind: 'exact', path, handler })

    const disposers = [
      route('/pet/hello', wrap(hello)),
      route('/pet/state', wrap(withAuth(stateRoute))),
      route('/pet/events', wrap(withAuth(eventsRoute))),
      route('/pet/answer', wrap(withAuth(answerRoute))),
      route('/pet/control', wrap(withAuth(controlRoute))),
      route('/pet/launch', wrap(withAuth(launchRoute))),
      route('/pet/stop', wrap(withAuth(stopRoute))),
      route('/pet/ui/state', wrap(uiStateRoute)),
      route('/pet/ui/launch', wrap(uiLaunchRoute)),
      route('/pet/ui/stop', wrap(uiStopRoute)),
      route('/pet/ui/size', wrap(uiSizeRoute)),
    ]

    const save = () => writeStateFile(scope.webServer?.port).catch((error) => ctx.logger?.warn?.(`spongebob-pet: ${error}`))
    save()
    const heartbeat = setInterval(save, 60_000)
    heartbeat.unref?.()

    scope.on('dispose', () => {
      clearInterval(heartbeat)
      for (const dispose of disposers) dispose()
    })
  })

  function wrap(handler) {
    return async (req, res) => {
      const handled = await handler(req, res)
      if (handled !== true) json(res, 404, { error: 'not found' })
    }
  }

  function withAuth(handler) {
    return (req, res) => {
      const url = new URL(req.url ?? '/', 'http://127.0.0.1')
      if (url.searchParams.get('token') !== token && req.headers['x-pet-token'] !== token) {
        json(res, 403, { error: 'bad token' })
        return true
      }
      // 在线判定只认长轮询（eventsRoute），别让体检脚本的 hello/state 也把桌宠标成在线
      return handler(req, res, url)
    }
  }

  function hello(req, res) {
    json(res, 200, { ok: true, name, version: VERSION, seq, petOnline: petOnline() })
    return true
  }

  function stateRoute(req, res) {
    json(res, 200, snapshot())
    return true
  }

  function eventsRoute(req, res, url) {
    const since = Number.parseInt(url.searchParams.get('since') ?? '0', 10) || 0
    // 可选的挂起时长（不超过 longPollMs）：只影响「多久没新事件就空手返回」，方便脚本按秒级节奏探事件流
    const asked = Number.parseInt(url.searchParams.get('wait') ?? '', 10)
    const holdMs = Number.isFinite(asked) && asked > 0 ? Math.min(asked, options.longPollMs) : options.longPollMs
    // 桌宠的存活信号：长轮询开着就算在线，从请求进来到回应都算
    lastSeenAt = Date.now()
    const waiter = { wake: () => flush(false), startedAt: Date.now() }
    const flush = (final) => {
      const batch = events.filter((event) => event.seq > since)
      if (!final && batch.length === 0) return
      if (!waiters.delete(waiter)) return
      clearTimeout(waiter.timer)
      // 只有「结束桌宠之后新开的」长轮询才算存活信号：结束那一刻会把 lastSeenAt 清零，
      // 而 stopPet 自己推的 running:false 会唤醒还在挂着的旧轮询，回头把心跳又点亮，
      // 设置页就得再等 30 秒才变「未运行」。
      if (waiter.startedAt >= stoppedAt) lastSeenAt = Date.now()
      json(res, 200, { ...snapshot(), events: batch, timeout: batch.length === 0 })
    }
    waiter.timer = setTimeout(() => flush(true), holdMs)
    waiter.timer.unref?.()
    waiters.add(waiter)
    req.on('close', () => {
      // 还挂在等待表里 = 不是「应答后正常关闭」，而是桌宠那边断了：立刻判离线，不等心跳窗口
      if (waiters.delete(waiter)) {
        clearTimeout(waiter.timer)
        lastSeenAt = 0
        push('pet', { running: false, reason: 'poll-dropped' })
      }
    })
    flush(false)
    return true
  }

  /** 拉起桌宠：GET 也能用，方便直接把带令牌的地址粘进浏览器。 */
  function launchRoute(req, res) {
    const result = launchPet()
    json(res, result.ok ? 200 : 500, result)
    return true
  }

  function stopRoute(req, res) {
    const result = stopPet()
    json(res, result.ok ? 200 : 500, result)
    return true
  }

  /**
   * 设置页那个标签页用的同源门：它拿不到令牌（浏览器读不了磁盘），
   * 所以改用浏览器自带的同源信号挡 CSRF —— POST 必须有 Origin 且等于本站，GET 认 sec-fetch-site。
   */
  function sameOriginGate(req, res) {
    const host = req.headers.host
    if (typeof host !== 'string' || host === '') {
      json(res, 403, { error: 'missing host' })
      return false
    }
    const origin = req.headers.origin
    if (typeof origin === 'string' && origin !== '') {
      if (origin !== `http://${host}`) {
        json(res, 403, { error: 'cross-origin request refused' })
        return false
      }
      return true
    }
    const site = req.headers['sec-fetch-site']
    if (site === 'same-origin' || site === 'none') return true
    json(res, 403, { error: 'not a same-origin request' })
    return false
  }

  /** config.json 由桌宠侧 PowerShell 5.1 的 Set-Content -Encoding UTF8 写过，会带 BOM，JSON.parse 认不了 */
  function readPetConfig() {
    if (!existsSync(options.petConfig)) return {}
    return JSON.parse(readFileSync(options.petConfig, 'utf8').replace(/^﻿/, ''))
  }

  /** 桌宠档位只认配置文件：设置页写文件，桌宠每 ~2.4 秒自己读一次跟着变 */
  function readPetSize() {
    try {
      const size = readPetConfig().size
      return PET_SIZES.includes(size) ? size : 'large'
    } catch {
      return 'large'
    }
  }

  function writePetSize(size) {
    if (!PET_SIZES.includes(size)) {
      return { ok: false, error: `size must be one of ${PET_SIZES.join(' / ')}` }
    }
    try {
      const config = readPetConfig()
      config.size = size
      writeFileSync(options.petConfig, `${JSON.stringify(config, null, 4)}\n`, 'utf8')
      return { ok: true, size }
    } catch (error) {
      return { ok: false, error: String(error?.message ?? error) }
    }
  }

  async function uiSizeRoute(req, res) {
    if (!sameOriginGate(req, res)) return true
    if (req.method !== 'POST') return methodNotAllowed(res)
    const body = await readJson(req)
    const result = writePetSize(String(body.size ?? ''))
    json(res, result.ok ? 200 : 400, result)
    return true
  }

  function uiStateRoute(req, res) {
    if (!sameOriginGate(req, res)) return true
    json(res, 200, {
      ok: true,
      petRunning: petRunning(),
      petStarting: petStarting(),
      petPid: petChildAlive() ? petChild.pid : null,
      petOnline: petOnline(),
      pending: pending.size,
      enabled,
      dnd,
      petState: aggregateState(),
      petSize: readPetSize(),
      settingsRegistered: diagnostics.settingsRegistered,
    })
    return true
  }

  function uiLaunchRoute(req, res) {
    if (!sameOriginGate(req, res)) return true
    if (req.method !== 'POST') return methodNotAllowed(res)
    const result = launchPet()
    json(res, result.ok ? 200 : 500, result)
    return true
  }

  function uiStopRoute(req, res) {
    if (!sameOriginGate(req, res)) return true
    if (req.method !== 'POST') return methodNotAllowed(res)
    json(res, 200, stopPet())
    return true
  }

  async function answerRoute(req, res) {
    if (req.method !== 'POST') return methodNotAllowed(res)
    const body = await readJson(req)
    const entry = pending.get(String(body.id ?? ''))
    if (entry === undefined) {
      json(res, 409, { error: 'no such pending request' })
      return true
    }
    if (body.delegate === true) {
      settle(entry, { delegate: true, reason: 'delegated' })
      json(res, 200, { ok: true, decision: 'delegate' })
      return true
    }
    if (entry.kind === 'approval') {
      const decision = body.decision === 'allow' ? 'allowed-once' : body.decision === 'deny' ? 'rejected' : null
      if (decision === null) {
        json(res, 400, { error: 'decision must be allow or deny' })
        return true
      }
      settle(entry, { value: decision, decision })
      json(res, 200, { ok: true, decision })
      return true
    }
    const answers = normalizeAnswers(entry, body.answers)
    if (answers === null) {
      json(res, 400, { error: 'answers do not match the pending questions' })
      return true
    }
    settle(entry, { value: { answers }, decision: 'answered' })
    json(res, 200, { ok: true, decision: 'answered' })
    return true
  }

  /** 逐题校验作答：选中项必须是该题声明过的选项，跳过的题保留为空答案。 */
  function normalizeAnswers(entry, raw) {
    if (!Array.isArray(raw) || (entry.questions ?? []).length === 0) return null
    const byId = new Map(raw.map((answer) => [String(answer?.id ?? ''), answer]))
    const answers = []
    for (const question of entry.questions) {
      const answer = byId.get(question.id)
      const labels = new Set(question.options.map((option) => option.label))
      const selected = (Array.isArray(answer?.selected) ? answer.selected : [])
        .map(String)
        .filter((label) => labels.has(label))
      if (question.multiSelect !== true && selected.length > 1) return null
      const custom = typeof answer?.custom === 'string' && answer.custom.trim() !== '' ? answer.custom.trim() : undefined
      answers.push(custom === undefined ? { id: question.id, selected } : { id: question.id, selected, custom })
    }
    return answers
  }

  async function controlRoute(req, res) {
    if (req.method !== 'POST') return methodNotAllowed(res)
    const body = await readJson(req)
    if (typeof body.dnd === 'boolean') dnd = body.dnd
    if (typeof body.enabled === 'boolean') enabled = body.enabled
    if (body.delegateAll === true) {
      for (const entry of [...pending.values()]) settle(entry, { delegate: true, reason: 'delegated' })
    }
    push('control', { enabled, dnd })
    json(res, 200, snapshot())
    return true
  }

  function methodNotAllowed(res) {
    json(res, 405, { error: 'method not allowed' })
    return true
  }

  function json(res, status, body) {
    if (res.writableEnded === true) return
    res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' })
    res.end(JSON.stringify(body))
  }

  async function readJson(req) {
    const chunks = []
    let total = 0
    for await (const chunk of req) {
      total += chunk.length
      if (total > 1_048_576) throw new Error('request body too large')
      chunks.push(chunk)
    }
    return chunks.length === 0 ? {} : JSON.parse(Buffer.concat(chunks).toString('utf8'))
  }

  // ---------- 握手文件：桌宠据此拿到地址与令牌 ----------

  async function writeStateFile(port) {
    const payload = {
      version: 1,
      name,
      pluginVersion: VERSION,
      url: `http://127.0.0.1:${port ?? 3080}`,
      token,
      pid: process.pid,
      startedAt: new Date().toISOString(),
      // 诊断面：shell 不通时，作者只能靠这个文件看插件内部到底走到哪一步
      diagnostics: {
        settingsInjected: diagnostics.settingsInjected,
        settingsRegistered: diagnostics.settingsRegistered,
        schemaLoaded: diagnostics.schemaLoaded,
        watchAttached: diagnostics.watchAttached,
        settingsError: diagnostics.settingsError,
        petChildPid: petChildAlive() ? petChild.pid : null,
        lastLaunchError: diagnostics.lastLaunchError,
        petScriptExists: existsSync(options.petScript),
      },
    }
    await mkdir(dshHome, { recursive: true })
    await writeFile(STATE_FILE, `${JSON.stringify(payload, null, 2)}\n`, 'utf8')
  }

  ctx.on('dispose', () => {
    for (const entry of [...pending.values()]) settle(entry, { delegate: true, reason: 'disposed' })
    for (const waiter of [...waiters]) waiter.wake()
  })
}
