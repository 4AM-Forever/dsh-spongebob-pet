/**
 * 海绵宝宝桌宠 · 网页半边：在「设置 → 插件」里加一个标签页，
 * 上面是桌宠状态 + 启动/结束按钮，按钮直接打宿主侧的 /pet/ui/* 路由（同源校验，不带令牌）。
 * 手写 bundle（DSH 客户端插件格式），失败只 console.warn，绝不把页面拖下水。
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

    const styles = {
      wrap: { display: 'flex', flexDirection: 'column', gap: '14px', maxWidth: '640px', fontSize: '13px', lineHeight: '20px' },
      card: { border: '1px solid var(--dsw-alias-border-l3, #e5e5e5)', borderRadius: '12px', padding: '14px 16px', background: 'var(--dsw-alias-bg-layer-3, #fff)' },
      title: { fontSize: '14px', fontWeight: 600, margin: '0 0 8px' },
      row: { display: 'flex', gap: '8px', alignItems: 'baseline', margin: '2px 0' },
      key: { color: 'var(--dsw-alias-label-tertiary, #888)', minWidth: '96px' },
      ok: { color: 'var(--dsw-alias-state-success-primary, #1a9f5b)', fontWeight: 600 },
      off: { color: 'var(--dsw-alias-label-tertiary, #888)' },
      warn: { color: 'var(--dsw-alias-state-error-primary, #d93025)' },
      buttons: { display: 'flex', gap: '10px', marginTop: '12px' },
      primary: { border: '0', borderRadius: '8px', padding: '7px 16px', cursor: 'pointer', font: 'inherit', fontWeight: 600, background: '#F6E14B', color: '#5A4410' },
      minor: { border: '1px solid var(--dsw-alias-border-l3, #ddd)', borderRadius: '8px', padding: '7px 16px', cursor: 'pointer', font: 'inherit', background: 'transparent', color: 'var(--dsw-alias-label-primary, #222)' },
      hint: { color: 'var(--dsw-alias-label-tertiary, #888)', fontSize: '12px' },
    }

    function request(path, method) {
      return fetch(path, { method: method || 'GET', headers: { accept: 'application/json' } }).then((res) => {
        if (!res.ok) return res.json().catch(() => ({})).then((body) => { throw new Error(body.error || ('HTTP ' + res.status)) })
        return res.json()
      })
    }

    function Row(props) {
      return h('div', { style: styles.row },
        h('span', { style: styles.key }, props.label),
        h('span', { style: props.tone ? styles[props.tone] : undefined }, props.value),
      )
    }

    function PetSettingsTab() {
      const [state, setState] = React.useState(null)
      const [error, setError] = React.useState(null)
      const [busy, setBusy] = React.useState(false)

      const refresh = React.useCallback(() => {
        request('/pet/ui/state')
          .then((next) => { setState(next); setError(null) })
          .catch((err) => setError(String(err && err.message ? err.message : err)))
      }, [])

      React.useEffect(() => {
        refresh()
        const timer = setInterval(refresh, 3000)
        return () => clearInterval(timer)
      }, [refresh])

      const act = React.useCallback((path) => {
        setBusy(true)
        request(path, 'POST')
          .then(() => { setError(null); refresh() })
          .catch((err) => setError(String(err && err.message ? err.message : err)))
          .then(() => setBusy(false))
      }, [refresh])

      const running = state && state.petRunning === true
      const online = state && state.petOnline === true

      return h('div', { style: styles.wrap },
        h('div', { style: styles.card },
          h('h3', { style: styles.title }, LABEL),
          Row({ label: '桌宠进程', value: running ? ('运行中（pid ' + state.petPid + '）') : '未运行', tone: running ? 'ok' : 'off' }),
          Row({ label: '心跳', value: online ? '已连上 DSH' : '未连上', tone: online ? 'ok' : 'off' }),
          Row({ label: '待答确认', value: state ? String(state.pending) : '—' }),
          Row({ label: '接管确认/提问', value: state && state.enabled ? '开' : '关' }),
          Row({ label: '免打扰', value: state && state.dnd ? '开' : '关' }),
          h('div', { style: styles.buttons },
            h('button', { style: styles.primary, disabled: busy || running, onClick: () => act('/pet/ui/launch') }, running ? '桌宠已在跑' : '启动桌宠'),
            h('button', { style: styles.minor, disabled: busy || !running, onClick: () => act('/pet/ui/stop') }, '结束桌宠'),
            h('button', { style: styles.minor, disabled: busy, onClick: refresh }, '刷新'),
          ),
          h('p', { style: styles.hint }, '启动后海绵宝宝出现在屏幕右下角：拖动可挪位置，右键有菜单（免打扰／隐藏／退出）。DSH 需要你确认或选择时，它会跳到最前面。'),
          error ? h('p', { style: styles.warn }, '出错了：' + error) : null,
        ),
      )
    }

    const inject = ['slots']

    function apply(ctx) {
      try {
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
