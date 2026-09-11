/**
 * 海绵宝宝桌宠 · 网页半边：在「设置 → 插件」里加一个标签页，
 * 上面是桌宠状态 + 启动/结束 + 大小三档，按钮直接打宿主侧的 /pet/ui/* 路由
 * （同源校验，不带令牌）。手写 bundle（DSH 客户端插件格式），失败只 console.warn，绝不把页面拖下水。
 *
 * 交互约定：操作后 10 秒内把轮询提到 800ms（平时 3s），按钮按下即变「启动中…/结束中…」，
 * 只显示当前可用的那个动作按钮（未启动只给「启动桌宠」，运行中只给「结束桌宠」）。
 */
window.__ModuleLoader__.load({
  id: 'dsh-spongebob-pet',
  factory: (require) => {
    var module = { exports: {} }
    var exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })

    const React = require('react')
    const h = React.createElement

    const LABEL = '海绵宝宝桌宠'
    const CSS_ID = 'dsh-spongebob-pet'
    const SIZE_OPTIONS = [
      { key: 'large', label: '大', hint: '220×284' },
      { key: 'medium', label: '中', hint: '158×204' },
      { key: 'small', label: '小', hint: '110×142' },
    ]

    // 用 CSS 类而不是内联样式：只有类才能拿到 :hover / :active / :disabled 这些真反馈
    const CSS = [
      '.sbp-wrap{display:flex;flex-direction:column;gap:14px;max-width:640px;font-size:13px;line-height:20px}',
      '.sbp-card{border:1px solid var(--dsw-alias-border-l3,#e5e5e5);border-radius:12px;padding:14px 16px;background:var(--dsw-alias-bg-layer-3,#fff)}',
      '.sbp-title{font-size:14px;font-weight:600;margin:0 0 8px}',
      '.sbp-row{display:flex;gap:8px;align-items:center;margin:2px 0}',
      '.sbp-key{color:var(--dsw-alias-label-tertiary,#888);min-width:96px}',
      '.sbp-ok{color:var(--dsw-alias-state-success-primary,#1a9f5b);font-weight:600}',
      '.sbp-off{color:var(--dsw-alias-label-tertiary,#888)}',
      '.sbp-warn{color:var(--dsw-alias-state-error-primary,#d93025)}',
      '.sbp-hint{color:var(--dsw-alias-label-tertiary,#888);font-size:12px}',
      '.sbp-tiny{color:var(--dsw-alias-label-tertiary,#999);font-size:11px}',
      '.sbp-actions{display:flex;gap:10px;align-items:center;margin-top:12px}',
      '.sbp-btn{border:0;border-radius:8px;padding:7px 16px;cursor:pointer;font:inherit;font-weight:600;transition:background .15s,transform .06s,box-shadow .15s}',
      '.sbp-btn:disabled{cursor:default;opacity:.65}',
      '.sbp-btn:not(:disabled):active{transform:translateY(1px) scale(.985)}',
      '.sbp-primary{background:#F6E14B;color:#5A4410}',
      '.sbp-primary:not(:disabled):hover{background:#EFD63A;box-shadow:0 2px 6px rgba(0,0,0,.12)}',
      '.sbp-danger{background:#F3C6C6;color:#7A2E22}',
      '.sbp-danger:not(:disabled):hover{background:#ECB2B2;box-shadow:0 2px 6px rgba(0,0,0,.12)}',
      '.sbp-ghost{border:1px solid var(--dsw-alias-border-l3,#ddd);background:transparent;color:var(--dsw-alias-label-primary,#222);font-weight:400}',
      '.sbp-ghost:not(:disabled):hover{background:rgba(128,128,128,.10)}',
      '.sbp-size{border:1px solid var(--dsw-alias-border-l3,#ddd);border-radius:8px;padding:5px 16px;cursor:pointer;font:inherit;background:transparent;color:var(--dsw-alias-label-primary,#222);transition:background .15s,transform .06s}',
      '.sbp-size:not(:disabled):hover{background:rgba(128,128,128,.10)}',
      '.sbp-size:not(:disabled):active{transform:translateY(1px) scale(.985)}',
      '.sbp-size[data-active="true"]{background:#F6E14B;color:#5A4410;border-color:#F6E14B;font-weight:600}',
      '.sbp-size[data-active="true"]:hover{background:#EFD63A}',
      '.sbp-size:disabled{cursor:default;opacity:.65}',
    ].join('')

    function ensureCss() {
      if (typeof document === 'undefined') return
      if (document.querySelector('style[data-plugin-css="' + CSS_ID + '"]') !== null) return
      const tag = document.createElement('style')
      tag.dataset.plugin = CSS_ID
      tag.dataset.pluginCss = CSS_ID
      tag.textContent = CSS
      document.head.appendChild(tag)
    }

    function request(path, method, body) {
      const init = { method: method || 'GET', headers: { accept: 'application/json' } }
      if (body !== undefined) {
        init.headers['content-type'] = 'application/json'
        init.body = JSON.stringify(body)
      }
      return fetch(path, init).then((res) => {
        if (!res.ok) {
          return res.json().catch(() => ({})).then((payload) => {
            throw new Error(payload.error || ('HTTP ' + res.status))
          })
        }
        return res.json()
      })
    }

    function Row(props) {
      return h('div', { className: 'sbp-row' },
        h('span', { className: 'sbp-key' }, props.label),
        h('span', { className: props.tone ? ('sbp-' + props.tone) : undefined }, props.value),
      )
    }

    function PetSettingsTab() {
      const [state, setState] = React.useState(null)
      const [error, setError] = React.useState(null)
      const [busy, setBusy] = React.useState(null)
      const [optimisticSize, setOptimisticSize] = React.useState(null)
      const [optimisticRun, setOptimisticRun] = React.useState(null)
      const [updatedAt, setUpdatedAt] = React.useState(null)
      // 刚操作过就把轮询提到 800ms，让界面在 1 秒内追上真实状态
      const fastUntil = React.useRef(0)

      const refresh = React.useCallback(() => request('/pet/ui/state')
        .then((next) => { setState(next); setError(null); setUpdatedAt(new Date()) })
        .catch((err) => setError(String(err && err.message ? err.message : err))), [])

      React.useEffect(() => {
        let cancelled = false
        let timer = null
        const tick = () => {
          refresh().then(() => {
            if (cancelled) return
            timer = setTimeout(tick, Date.now() < fastUntil.current ? 800 : 3000)
          })
        }
        tick()
        return () => { cancelled = true; if (timer !== null) clearTimeout(timer) }
      }, [refresh])

      const act = React.useCallback((kind, path, body) => {
        setBusy(kind)
        fastUntil.current = Date.now() + 10_000
        return request(path, 'POST', body)
          .then(() => { setError(null); return refresh() })
          .catch((err) => {
            setOptimisticSize(null)
            setOptimisticRun(null)
            setError(String(err && err.message ? err.message : err))
          })
          .then(() => setBusy(null))
      }, [refresh])

      const serverRunning = state ? state.petRunning === true : false
      const serverStarting = state ? state.petStarting === true : false
      const serverSize = (state && state.petSize) || 'large'

      // 服务端跟上后丢掉乐观值
      React.useEffect(() => {
        if (optimisticSize !== null && optimisticSize === serverSize) setOptimisticSize(null)
        if (optimisticRun === 'starting' && serverRunning) setOptimisticRun(null)
        if (optimisticRun === 'stopping' && !serverRunning && !serverStarting) setOptimisticRun(null)
      }, [optimisticSize, serverSize, optimisticRun, serverRunning, serverStarting])

      const size = optimisticSize || serverSize
      const currentSize = SIZE_OPTIONS.find((option) => option.key === size) || SIZE_OPTIONS[0]
      const waitingSize = optimisticSize !== null && optimisticSize !== serverSize

      const starting = optimisticRun === 'starting' || (!serverRunning && serverStarting)
      const stopping = optimisticRun === 'stopping'
      const running = serverRunning && !stopping
      const pidText = state && state.petPid ? ('（pid ' + state.petPid + '）') : ''
      const runText = stopping ? '结束中…' : (starting ? '启动中…' : (running ? ('运行中' + pidText) : '未运行'))

      const action = (running || stopping)
        ? h('button', {
          className: 'sbp-btn sbp-danger',
          disabled: busy !== null,
          onClick: () => { setOptimisticRun('stopping'); act('stop', '/pet/ui/stop') },
        }, stopping ? '结束中…' : '结束桌宠')
        : h('button', {
          className: 'sbp-btn sbp-primary',
          disabled: busy !== null,
          onClick: () => { setOptimisticRun('starting'); act('launch', '/pet/ui/launch') },
        }, starting ? '启动中…' : '启动桌宠')

      return h('div', { className: 'sbp-wrap' },
        h('div', { className: 'sbp-card' },
          h('h3', { className: 'sbp-title' }, LABEL),
          Row({ label: '桌宠进程', value: runText, tone: running ? 'ok' : ((starting || stopping) ? undefined : 'off') }),
          Row({ label: '心跳', value: serverRunning ? '已连上 DSH' : '未连上', tone: serverRunning ? 'ok' : 'off' }),
          Row({ label: '待答确认', value: state ? String(state.pending) : '—' }),
          Row({ label: '接管确认/提问', value: state && state.enabled ? '开' : '关' }),
          Row({ label: '免打扰', value: state && state.dnd ? '开' : '关' }),

          h('div', { className: 'sbp-row' },
            h('span', { className: 'sbp-key' }, '大小'),
            SIZE_OPTIONS.map((option) => h('button', {
              key: option.key,
              className: 'sbp-size',
              'data-active': option.key === currentSize.key ? 'true' : 'false',
              disabled: busy !== null,
              onClick: () => { setOptimisticSize(option.key); act('size', '/pet/ui/size', { size: option.key }) },
            }, option.label)),
            h('span', { className: 'sbp-tiny' }, waitingSize
              ? ('已切到「' + currentSize.label + '」，等桌宠跟随…')
              : ('当前：' + currentSize.label + '（' + currentSize.hint + '）')),
          ),

          h('div', { className: 'sbp-actions' },
            action,
            h('button', {
              className: 'sbp-btn sbp-ghost',
              disabled: busy !== null,
              onClick: () => {
                setBusy('refresh')
                fastUntil.current = Date.now() + 3000
                refresh().then(() => setBusy(null))
              },
            }, busy === 'refresh' ? '刷新中…' : '刷新'),
            h('span', { className: 'sbp-tiny' }, updatedAt
              ? ('最后更新 ' + updatedAt.toLocaleTimeString() + '（平时 3 秒自动刷新，操作后 0.8 秒）')
              : '正在获取状态…'),
          ),
          h('p', { className: 'sbp-hint' }, '启动后海绵宝宝出现在屏幕右下角：拖动可挪位置，右键菜单或托盘图标里也有「大小」三档。DSH 需要你确认或选择时，它会跳到最前面。'),
          error ? h('p', { className: 'sbp-warn' }, '出错了：' + error) : null,
        ),
      )
    }

    const inject = ['slots']

    function apply(ctx) {
      try {
        ensureCss()
        ctx.slots.inject('settings.plugins.tab', () => ctx.slots.register({
          name: 'settings.plugins.tab',
          id: 'spongebob-pet',
          order: 30,
          label: () => LABEL,
          inject: () => ({}),
        }, PetSettingsTab))
      } catch (error) {
        console.warn('[dsh-spongebob-pet] settings tab registration failed:', error)
      }
    }

    exports.apply = apply
    exports.inject = inject
    return module.exports
  },
})
