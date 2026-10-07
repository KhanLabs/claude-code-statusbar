import type { EngineInterface, Register } from 'claude-code'

// Graceful by design: this add-on never interrupts a turn and never touches a
// prompt the person is typing. When the context reaches the limit while Claude
// is working, it adds one polite note asking Claude to pause at the next
// natural stopping point. Only when the session is idle does it run
// /handoff, then /clear, then /pickup <that handoff>.
//
// It expects the /handoff and /pickup skills from this repo's `skills` folder.

const DEFAULT_THRESHOLD = 300_000
const POLL_MS = 15_000
const QUIET_MS = 8_000 // after a turn ends, let queued messages start first
const PENDING_MS = 30 * 60_000 // how long a clear that was asked for may take
const SNOOZE_MS = 10 * 60_000 // after a failed handoff, wait before trying again
const REMIND_AFTER = 40_000 // a second, shorter reminder if the context grows this much more

function pauseNote(n: number, limit: number, again: boolean): string {
  return (
    `Automatic note from the auto-handoff add-on (not typed by the user). ` +
    `The context is at ${Math.round(n / 1000)}k tokens; the limit is ${Math.round(limit / 1000)}k. ` +
    (again ? 'It is still growing. ' : '') +
    `Please pause when you can: finish the step you are in (do not stop in the middle of an edit or a test run), ` +
    `save your progress in your work-list file if you have one, commit if that is safe, and end your turn without ` +
    `starting a new large item. This is a request, not an order to stop at once. After your turn ends, /handoff, ` +
    `/clear and /pickup run by themselves and you carry on from the handoff.`
  )
}

const FOCUS =
  'This is an automatic handoff because the context is large. Make next step 1 something to start at once. ' +
  'If the work has a work-list file (for example docs/PLAN.md), name it in next step 1 and say to carry on ' +
  'with its in-progress item without asking the user. The next session continues on its own.'

type Phase = 'idle' | 'handoff' | 'cleared'
type Pending = { slug: string; at: number }

const s = {
  threshold: DEFAULT_THRESHOLD,
  handoffsDir: '', // from the option, else <config folder>/handoffs
  busy: false,
  lastStart: 0,
  lastEnd: 0,
  phase: 'idle' as Phase,
  since: 0,
  endsSince: 0,
  tries: 0,
  snoozeUntil: 0,
  running: false,
  shown: '',
  asked: false,
  reminded: false,
}

function k(n: number): string {
  return `${Math.round(n / 1000)}k`
}

function join(base: string, name: string): string {
  const sep = base.includes('\\') ? '\\' : '/'
  return base.replace(/[\\/]+$/, '') + sep + name
}

async function configDir($: EngineInterface): Promise<string> {
  const fromEnv = await $.env.get('CLAUDE_CONFIG_DIR')
  if (fromEnv) return fromEnv
  const home = (await $.env.get('USERPROFILE')) ?? (await $.env.get('HOME')) ?? '.'
  return join(home, '.claude')
}

async function folder($: EngineInterface): Promise<string> {
  return s.handoffsDir || join(await configDir($), 'handoffs')
}

async function newestHandoff($: EngineInterface) {
  const entries = await $.fs.list(await folder($)).catch(() => [])
  return entries
    .filter(f => f.kind === 'file' && f.name.endsWith('.md'))
    .sort((a, b) => b.mtimeMs - a.mtimeMs)[0]
}

async function askHandoff($: EngineInterface) {
  s.since = await $.clock.now()
  s.endsSince = 0
  await $.command.run({ command: 'handoff', args: FOCUS })
}

async function tick($: EngineInterface) {
  if (s.running) return
  s.running = true
  try {
    const now = await $.clock.now()
    const usage = await $.session.usage()
    const n = usage.context.tokens ?? 0

    // Passive readout: the status line and a small file other tools can read.
    const label = `ctx ${k(n)}/${k(s.threshold)}${s.phase === 'idle' ? '' : ' · ' + s.phase}`
    if (label !== s.shown) {
      s.shown = label
      $.ui.status(label)
      await $.fs
        .write(
          join(await configDir($), 'auto-handoff-status.json'),
          JSON.stringify({ tokens: n, threshold: s.threshold, over: n >= s.threshold, phase: s.phase, busy: s.busy }) +
            '\n',
        )
        .catch(() => undefined)
    }

    // A clear was asked for: run /pickup once the context is small again.
    const pending = (await $.store.get('pickup')) as Pending | undefined
    if (pending) {
      if (s.busy) return
      if (n < s.threshold / 3) {
        await $.store.delete('pickup')
        s.phase = 'idle'
        await $.command.run({ command: 'pickup', args: pending.slug })
      } else if (now - pending.at > PENDING_MS) {
        await $.store.delete('pickup')
        s.phase = 'idle'
        s.snoozeUntil = now + SNOOZE_MS
        $.ui.toast('auto-handoff: the clear did not happen, so /pickup was not run.')
      }
      return
    }

    if (n < s.threshold / 3) {
      s.asked = false
      s.reminded = false
    }

    // Over the limit while Claude is working: ask it, once, to pause at a
    // natural stopping point. It is a request, not an interruption. The note
    // reaches Claude with its next tool result; it may finish what it is
    // doing first. Then, when the turn has ended on its own, the handoff runs.
    if (s.phase === 'idle' && s.busy && n >= s.threshold) {
      if (!s.asked) {
        s.asked = true
        await $.session.append({
          message: { type: 'user', content: [{ type: 'text', text: pauseNote(n, s.threshold, false) }] },
        })
        $.ui.toast(`auto-handoff: context is at ${k(n)}. Asked Claude to pause when it can.`)
      } else if (!s.reminded && n >= s.threshold + REMIND_AFTER) {
        s.reminded = true
        await $.session.append({
          message: { type: 'user', content: [{ type: 'text', text: pauseNote(n, s.threshold, true) }] },
        })
      }
      return
    }

    if (s.phase === 'idle') {
      if (n < s.threshold || s.busy || now < s.snoozeUntil) return
      if (now - s.lastEnd < QUIET_MS) return
      const draft = await $.prompt.read()
      if (draft.text.trim() !== '') return // the person is typing: wait
      s.phase = 'handoff'
      s.tries = 0
      $.ui.toast(`auto-handoff: context is at ${k(n)}. Writing the handoff now.`)
      await askHandoff($)
      return
    }

    if (s.phase === 'handoff') {
      if (s.busy) return // never cut in on a running turn
      if (s.endsSince === 0) {
        // the handoff turn has not run yet; give it a minute to start
        if (now - s.since > 60_000) s.phase = 'idle'
        return
      }
      const file = await newestHandoff($)
      // valid only if it was written during or after the latest turn
      if (file !== undefined && file.mtimeMs >= s.lastStart - 1_000) {
        const draft = await $.prompt.read()
        if (draft.text.trim() !== '') return // typing: clear later
        const slug = file.name.replace(/\.md$/, '')
        await $.store.set('pickup', { slug, at: now } satisfies Pending)
        s.phase = 'cleared'
        try {
          await $.command.run({ command: 'clear' })
        } catch (err) {
          $.ui.toast(
            `auto-handoff: could not run /clear (${String(err).slice(0, 80)}). Run /clear; /pickup will follow by itself.`,
          )
        }
        return
      }
      if (s.tries++ < 2) {
        await askHandoff($)
      } else {
        s.phase = 'idle'
        s.snoozeUntil = now + SNOOZE_MS
        $.ui.toast('auto-handoff: no handoff file was written. Trying again in 10 minutes.')
      }
    }
  } catch (err) {
    $.ui.toast(`auto-handoff: ${String(err).slice(0, 120)}`)
    s.phase = 'idle'
  } finally {
    s.running = false
  }
}

export const register: Register = (on, options) => {
  const limit = Number(options.thresholdTokens)
  s.threshold = Number.isFinite(limit) && limit >= 50_000 ? limit : DEFAULT_THRESHOLD
  s.handoffsDir = typeof options.handoffsDir === 'string' ? options.handoffsDir.trim() : ''

  on('turn.start', async ($, e, next) => {
    s.busy = true
    s.lastStart = await $.clock.now()
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      s.busy = false
      s.lastEnd = await $.clock.now()
      if (s.phase === 'handoff') s.endsSince++
    }
    return next(e)
  })

  on('session.start', ($, e, next) => {
    $.clock.every(POLL_MS, () => {
      void tick($)
    })
    return next(e)
  })
}
