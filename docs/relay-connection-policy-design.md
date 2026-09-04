# Relay connection policy: adaptive check-in vs. persistent WebSocket

> Working proposal. Companion to `docs/pricing-cost-model.md` (cost rates) and
> DESIGN.md §28 (the scale-to-zero backbone) / §1509-1512 (the persistent-vs-check-in
> tradeoff, already named there). GCP rates are quoted from the cost-model doc; the
> *shape* of the conclusion is robust even if individual rates drift.

## TL;DR

The relay is a scale-to-zero Cloud Run WebSocket service. A device that holds a
persistent WebSocket keeps its region's instance **warm for the entire time it is
online**, which defeats scale-to-zero exactly when the region is otherwise idle. The
cheapest option that keeps reliability high is **not WebRTC**, it is to make the relay
connection **adaptive**:

- **Foreground (interactive):** hold the socket open, real-time receive, today's behavior.
- **Background (delay-tolerant):** connect → drain the durable mailbox → drop, and re-arm
  on the device's existing background wakes.

Reliability is preserved because the **mailbox is durable in Firestore and survives
scale-to-zero** (DESIGN.md §1372/§1403), the socket is only needed at the moment of
check-in, not continuously. Local proximity bearers (BLE/LAN/Multipeer) are unaffected and
keep delivering in real time regardless of relay policy.

## 1. Why WebRTC is the wrong lever here

WebRTC's value is offloading the **data path** to peer-to-peer so a server stops relaying
bytes. But the relay is not a byte-relay between two online peers, it is
**store-and-forward for an offline recipient** (`services/hop-relayd/src/main.rs:1-18`;
the durable mailbox is the point). WebRTC needs a live peer on the other end; when the
recipient is offline, the case the relay exists for, there is no peer to dial, so WebRTC
cannot deliver at all. It sits *beside* the relay, it does not replace it.

Where it would apply (both peers online, wanting a live stream), it costs three ways:

1. **TURN reintroduces an always-on box.** NAT hole-punching fails ~10-20% of the time, so
   you need TURN. Self-hosted coturn is a mains-on VM, it *breaks scale-to-zero* and likely
   costs more than today's relay. Managed TURN (Cloudflare/Twilio) is metered per-GB egress
   to a third party.
2. **It fights the threat model.** ICE candidate exchange hands each correspondent the
   other's IP. "The network does not learn who is talking to whom" becomes "the peers learn
   each other's network location." WebRTC is already fenced to the browser *leaf* via a
   gateway for exactly this reason (DESIGN.md §1210); promoting it to the native relay path
   is a metadata regression. Forcing relay-only (TURN) mode to avoid the leak throws away
   the cost benefit entirely.
3. **The good P2P case is already covered** by BLE, LAN, and Apple Multipeer when peers are
   physically near (DESIGN.md §1203-1212). The relay is specifically the *not-near,
   maybe-offline* fallback.

Adding WebRTC is net-new infra (there is no STUN/TURN/ICE in the tree today) that does not
reduce the cost below, and weakens the privacy posture.

## 2. The actual cost driver

Cloud Run runs `min_instance_count = 0` with `cpu_idle = true`
(`hopmesh/platform/infra/cloud_run.tf:26,84`, see `docs/repo-catalog.md`). Scale-to-zero only pays off **between** connections. A held
WebSocket is a long-running request, so the region instance stays warm and CPU-allocated
for its whole lifetime. The relay is 1 vCPU / 2 GiB (`hopmesh/platform/infra/cloud_run.tf:77-83`). At the
cost-model doc's rates:

```
vCPU:  1 × 2,592,000 s/mo × $0.000024   ≈ $62.2
mem:   2 × 2,592,000 s/mo × $0.0000025  ≈ $13.0
                                         ─────────
continuously-warm region                ≈ $75 / region-month
```

The cost-model doc says the relay is "near-free at rest **because it scales to zero**"
(`docs/pricing-cost-model.md:13`). The unstated precondition is *at rest*, i.e. **nobody
camping a connection**. Held connections remove that precondition: one foreground device
online 24/7 in an otherwise-idle region costs that region up to ~$75/mo, roughly the same
as the always-warm edge authenticator the doc already calls the dominant fixed cost
(`:14`).

**Where it bites: low regional density.** One instance serves up to `MAX_CONNS = 1_024`
devices (`services/hop-relayd/src/main.rs:67`), and `max_instances_per_region = 1`. So at
high density the warm-instance cost amortizes to near-zero per user. The waste is entirely
in the **long tail**, regions kept warm by a handful of low-traffic always-connected
devices. That is precisely where scale-to-zero was supposed to save money and where
persistent sockets defeat it.

**The honest counter-tradeoff.** Draining-and-dropping means messages that arrive while a
device is disconnected are **stored → drained → purged** in Firestore (~3 writes / ~4 reads
/ ~3 deletes per chunk, `docs/pricing-cost-model.md:18`), whereas a held socket delivers
them **in-flight** with no store. The cost-model doc's own lever #2 (`:96`) prefers
in-flight delivery when a path is live. So the policy is a trade:

```
saved:   warm instance-hours   (dominant at low density; ≈ $75/region-mo ceiling)
added:   Firestore ops on messages that land while disconnected  (≈ $9 / M chunks)
```

Net-cheaper whenever the warm-hours saved exceed the extra ops, i.e. **low-density regions
and low-traffic backgrounded devices**, which is the majority of the tail. This is why the
recommendation is *adaptive*, not "always drain": a busy foreground device on a
high-density region should stay persistent (real-time + no extra ops); a backgrounded
device in a sparse region should check in.

## 3. Proposal, adaptive connection policy

The relay bearer is deliberately dumb (`start`/`stop`/`send`/`sink`, one WS = one link,
owns its own reconnect/backoff, see
`bearers/apple/HopBearerRelay/Sources/HopBearerRelay/RelayBearer.swift` and the Android
mirror). The driver already owns the app-state machinery: an `appActive` flag, the
`didBecomeActive`/`didEnterBackground` observers, a 1 s `backgroundTick`, and
`publishPresence()` that already advertises `fg`/`bg`
(`drivers/apple/HopDriver/Sources/HopDriver/HopBearer.swift:434-450,519-540`).

So the change is small: **the driver decides *when* the relay socket should be up**, and
the bearer gains a "close when quiet" mode.

```
app foreground   ──▶ policy = .persistent    ──▶ relay.start(); hold socket (today)
app background   ──▶ policy = .checkIn(5m)    ──▶ start now, drain, self-close when quiet;
                                                  re-arm on the next background wake
active call/§29  ──▶ force .persistent while a service call / live thread is in flight
```

### 3.1 Bearer: a self-closing check-in mode

The bearer stays content-blind but can time *quiescence*: no inbound frame for N seconds
after link-up ≈ "the offer/pull exchange is drained." In check-in mode it surfaces
`linkDown` and **does not auto-reconnect**, the driver owns re-arm. This reuses the
bearer's existing reconnect suppression (`scheduleReconnect()` already early-returns on
`!started`).

```swift
enum RelayMode {
    case persistent                    // hold open, auto-reconnect on drop (foreground)
    case checkIn(quiescence: Double)   // drain, self-close after `quiescence`s idle, no auto-reconnect
}

// arm after link-up (empty mailbox still closes) and after every inbound frame (resets the clock):
private func armQuiescence() {
    guard case .checkIn(let q) = mode else { return }
    quiesceWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
        guard let self, self.up else { return }
        self.started = false           // suppress auto-reconnect; the driver re-arms check-ins
        self.task?.cancel(with: .goingAway, reason: nil)
        self.handleDown()              // linkDown once; scheduleReconnect() no-ops on !started
    }
    quiesceWork = work
    queue.asyncAfter(deadline: .now() + q, execute: work)
}
```

Touch points: call `armQuiescence()` in `didOpenWithProtocol` (after `receiveLoop()`) and
in the `receiveLoop` success branch. A deliberate drain-close and a real network drop stay
distinguishable, only the driver re-arms.

### 3.2 Driver: flip policy on hooks that already exist

```swift
// foreground: real-time, hold the socket (today's behavior)
onDidBecomeActive { relay.setMode(.persistent); relay.start() }

// background: delay-tolerant check-in against the durable mailbox
onDidEnterBackground { relay.setMode(.checkIn(quiescence: 3.0)) /* let current session drain + self-close */ }

// re-arm inside the existing 1 s backgroundTick, no new timer, just a counter
func backgroundTick() {
    ...
    if !appActive, tickCount % 300 == 0 {          // ~5 min
        relay.setMode(.checkIn(quiescence: 3.0))
        relay.start()                               // stopped bearer restarts cleanly
    }
    pump(flushAfter: true)                          // existing background-drain + sync mirror flush
}
```

The device's existing background wakes, beacon region entry, BG fetch
(`HopBearer.swift:477`, DESIGN.md §1512), are *already* check-in triggers; each just calls
`relay.start()` in check-in mode. Android is the mirror image in `RelayBearer.kt` +
the foreground-service `onResume`/`onPause`.

### 3.3 "Drained" detection

- **v1 (quiescence timer, above):** zero core changes. "No inbound for ~3 s after the
  exchange" ≈ drained. Tiny risk of closing a beat early on a stalled network; the durable
  mailbox + next check-in make that lossless (just slightly higher latency).
- **v2 (explicit core signal, cleaner, later):** surface a "check-in complete / nothing
  pending for this link" event through the FFI so the driver closes deterministically
  instead of on a timer. Not required to ship v1.

## 4. What does *not* change

- **Relay/server:** nothing. It already scales to zero when the last socket drops
  (`hopmesh/platform/infra/cloud_run.tf:1-3`). Drain-and-drop just makes that drop happen minutes sooner.
- **Mailbox durability:** unchanged, reliability rides on Firestore, not the socket.
- **Local bearers:** BLE/LAN/Multipeer deliver in real time regardless of relay policy.
- **Presence + handoff:** presence TTL is 90 s (`services/hop-relayd/src/main.rs`). Between
  check-ins a backgrounded device correctly reads as offline, so senders route via the
  Firestore cross-partition handoff that already exists (§28). The policy composes with the
  backbone model rather than fighting it.
- **`mesh_fanout = 0`** (handoff-only) stays, the relay-to-relay epidemic is the expensive
  egress + N² warm-link path (DESIGN.md §1434/§2008).
- **Relay custody and priority:** priority is an unauthenticated QoS hint on the wire; cross-tenant custody is partitioned by fair share (`core/hop-core/src/node.rs:pick_evict_victim`), so high-priority traffic cannot starve co-tenants' undelivered messages. Under Open policy, effective priority of unstamped or untenanted bundles is clamped to normal (4) so priority=255 from a free identity buys no eviction immunity. Note that an Open relay cannot be fair against pure Sybil volume because fresh sender identities cost nothing; only stamped tenants under Keyed policy receive a guaranteed custody share.

## 5. Tradeoffs

| | Foreground | Background |
|---|---|---|
| Relay socket | held (persistent) | up only during a check-in, then dropped |
| Receive latency | real-time | ≤ check-in interval (5 min knob) |
| Region instance | warm | scales to zero between check-ins |
| Marginal Firestore ops | lower (in-flight delivery) | higher (store→drain→purge for messages arriving while disconnected) |
| Reliability | mailbox + live socket | **durable mailbox**, no message lost, only delayed |
| Local peers | real-time | real-time |

Two knobs govern the tradeoff: **check-in interval** (background receive latency vs. wake
cost) and **quiescence window** (how eagerly to close a drained check-in).

## 6. Rollout & open questions

- Ship v1 (quiescence timer) behind the adaptive policy; measure warm instance-hours per
  region before/after and the delta in Firestore store/drain/purge ops.
- Pick defaults empirically: start `checkIn` interval at 5 min, quiescence at 3 s, tune from
  telemetry.
- **Push-to-check-in (optional, deferred):** a *content-free* "wake and check in" push would
  cut background latency below the check-in interval, but reintroduces APNs/FCM as a
  "message landed" oracle, which DESIGN.md §857 deliberately avoids. Keep it an explicit
  opt-in, not the default.
- **Interactive override:** define precisely what forces `.persistent` beyond foreground , 
  an in-flight service call (§29), an open conversation thread, so a live interaction is
  never throttled to check-in latency.
