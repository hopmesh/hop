// hop-soak: looping cross-device P2P send soak with per-round adversarial bug hunt.
// Run via the Workflow tool:  Workflow({ scriptPath: "testkit/soak.workflow.js", args: { rounds: 24 } })
// Drives the fg/bg permutation matrix across the full device fleet (testkit/run-round.sh derives the
// live device list from testkit/devices.sh, so this is device-count-agnostic), then spawns
// parallel critic agents to hunt bugs in each round's results + per-device logs. Accumulates a
// deduped bug ledger. Runs ~rounds rounds (≈ an hour); stop early with TaskStop.
export const meta = {
  name: 'hop-soak',
  description: 'Looping cross-device P2P send soak (fg/bg matrix) + per-round adversarial bug hunt',
  phases: [
    { title: 'Drive', detail: 'run-round.sh drives every device pair for the round profile' },
    { title: 'Hunt', detail: 'parallel critics analyze results + logs for bugs' },
  ],
}

// NOTE: the harness `args` global does not always thread through a scriptPath launch, so these
// defaults are set to the current cutover-verification run (the reachable pixel/xr/jpad trio, a
// bounded 2-round fg/fg + fg/bg pass, a 75s wait so iOS cold-launch sends aren't false-failed).
// Any args that DO arrive still override. Widen ROUNDS / clear PAIRS for a full-fleet soak.
const ROUNDS = (args && args.rounds) || 2
const RESULTS = (args && args.results) || 'testkit/results/cutover'
const MAXWAIT = (args && args.maxwait) || 75
// Ordered-pair override so the soak runs only over the devices actually connected. When empty,
// run-round.sh fans out over every ordered pair of its CORE_IDS (the full fleet).
const PAIRS = (args && args.pairs) || 'pixel:xr xr:pixel pixel:jpad jpad:pixel xr:jpad jpad:xr'
const PROFILES = ['fgfg', 'fgbg', 'bgfg', 'bgbg'] // sender_state/receiver_state, cycled per round

const BUG = {
  type: 'object',
  required: ['bugs'],
  properties: {
    bugs: {
      type: 'array',
      items: {
        type: 'object',
        required: ['signature', 'severity', 'title', 'evidence'],
        properties: {
          signature: { type: 'string', description: 'Stable dedup key, e.g. "nodeliver:xr->bush:bgfg" or "flood:tab" or "anr:pixel".' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low', 'info'] },
          title: { type: 'string' },
          evidence: { type: 'string', description: 'Concrete: marker(s), latency, log lines, link-id churn, byte rates. Quote.' },
          devices: { type: 'array', items: { type: 'string' } },
          suspected_cause: { type: 'string' },
        },
      },
    },
  },
}

// quality-net-07: source the Android device serials from devices.sh instead of hardcoding them (they
// silently rotted when the registry changed). Parse the DEVICES rows for android handles.
function androidSerials() {
  try {
    const fs = require('fs')
    const path = require('path')
    const txt = fs.readFileSync(path.join(__dirname, 'devices.sh'), 'utf8')
    const out = []
    for (const line of txt.split('\n')) {
      const m = line.match(/^\s*"(\w+)\s+android\s+(\S+)\s+/)
      if (m) out.push(`${m[1]}=${m[2]}`)
    }
    return out.join(' ')
  } catch { return '' }
}
const ANDROID_SERIALS = androidSerials()

const LENSES = [
  { key: 'delivery', prompt: `DELIVERY lens. Read ${RESULTS}/<ROUND>.jsonl. Each line: from,to,fromState,toState,marker,delivered(bool),received(int),ackOnSender,latencyS,fromNode,toNode. Flag: any delivered=false (non-delivery, CRITICAL for fg/fg direct pairs, high otherwise); latencyS > 10 on a direct/foreground pair (slow); received=0 but ackOnSender=true mismatches (verification gap); pairs that NEVER deliver across the run. Correlate failures with transport (xr+pixel are BLE-only; others full) and with fg/bg state. A backgrounded receiver that never gets the message is a real bug; a backgrounded sender that can't drain is a real bug.` },
  { key: 'flood-health', prompt: `FLOOD/RADIO lens. Read the per-device logs ${RESULTS}/<ROUND>.<id>.log (android only). The driver emits one LINKFLOW line per bearer link every ~5s, grammar:\n  LINKFLOW link=<g> xport=<T> tx=<bytes> rx=<bytes> txpkts[hs=<n> data=<n> frag=<n>] rxpkts=<n>\nThese counters are CUMULATIVE per link (they reset only on linkDown / relink), so to get a RATE compare the same link=<g> across two timestamps ~5s apart and divide the delta by the elapsed seconds. A HEALTHY idle link's data-pkt and tx deltas are small (a few pkts / a few hundred bytes per 5s). Flag: data-pkt delta climbing >20/sec or tx delta >5KB/sec sustained on an idle link (the gossip flood regressing); hs delta climbing (a re-handshake loop); link-id churn in NODESTATE (e.g. id2..id20, BLE link flapping). Report the per-link byte/pkt RATES you observe and whether they are bounded or climbing.\nIMPORTANT (tolerance): if a log has NO LINKFLOW lines (e.g. a device had no bearer links up this round, or its logcat buffer was cleared before capture), that is NOT a bug by itself, report it as info "no LINKFLOW data this round for <id>" and judge flood health from NODESTATE (upLinks/pend) and delivery latencies instead. Never invent a flood finding from absent instrumentation.` },
  { key: 'crash-stuck', prompt: `CRASH/STUCK lens. Scan the per-device logs ${RESULTS}/<ROUND>.<id>.log AND pull fresh logcat if needed (adb -s <serial> logcat -d | grep -iE "FATAL|ANR|watchdog|0x8BADF00D|cpu_resource|exception|crash|Securing"). Android device serials (from testkit/devices.sh): ${ANDROID_SERIALS || '(none parsed: read testkit/devices.sh)'}. Flag: app crashes/restarts, ANRs/watchdog kills, unhandled exceptions, OOM, and any peer stuck "Securing"/unidentified for the whole round. iOS crash/health is best-effort (no logcat); note if iOS receipt (automation.json) is stale/missing, which can indicate an iOS-side stall.` },
]

const seen = new Set()
const ledger = []

for (let r = 1; r <= ROUNDS; r++) {
  const profile = PROFILES[(r - 1) % PROFILES.length]
  phase('Drive')
  // The runner is a deterministic bash script; the agent just executes it and returns the JSONL.
  await agent(
    `Run exactly this and wait for it to finish (it drives ~20 real device sends, may take several minutes):\n` +
    `  TK_MAXWAIT=${MAXWAIT} bash testkit/run-round.sh ${r} ${RESULTS} ${profile} ${PAIRS ? `'${PAIRS}'` : ''}\n` +
    `Then output the contents of ${RESULTS}/${r}.jsonl verbatim (cat it). That file + the per-device ` +
    `logs ${RESULTS}/${r}.<id>.log are what the bug hunters read next. If the script errors, report the error.`,
    { label: `round${r}:${profile}`, phase: 'Drive' }
  )

  phase('Hunt')
  const roundFindings = await parallel(LENSES.map(lens => () =>
    agent(
      `Round ${r} (profile ${profile}) just completed. ${lens.prompt.replace(/<ROUND>/g, String(r))}\n` +
      `Return structured bugs. Use a STABLE signature per distinct issue so recurring issues dedup across rounds. ` +
      `Be rigorous and quote concrete evidence (markers, latencies, exact log lines, byte rates). If nothing is wrong, return an empty bugs array.`,
      { label: `hunt${r}:${lens.key}`, phase: 'Hunt', schema: BUG, effort: 'high' }
    )
  ))

  const fresh = []
  for (const f of roundFindings.filter(Boolean)) {
    for (const b of (f.bugs || [])) {
      if (b.signature && seen.has(b.signature)) continue
      if (b.signature) seen.add(b.signature)
      fresh.push({ round: r, profile, ...b })
    }
  }
  ledger.push(...fresh)
  const crit = fresh.filter(b => b.severity === 'critical' || b.severity === 'high').length
  log(`round ${r} (${profile}): ${fresh.length} new findings (${crit} crit/high); ledger=${ledger.length}`)
}

// Severity-ordered summary.
const order = { critical: 0, high: 1, medium: 2, low: 3, info: 4 }
ledger.sort((a, b) => (order[a.severity] ?? 9) - (order[b.severity] ?? 9))
return { rounds: ROUNDS, totalFindings: ledger.length, ledger }
