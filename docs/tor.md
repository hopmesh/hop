# Tor: relays reachable over the public internet AND over .onion

> Design + operating doc. Companion to DESIGN.md §19 (the relay pool), §26 (a relay is just
> another bearer), §35 (carriage stamps) and §39 (metadata privacy). Code pointers are exact;
> if one drifts, the code wins and this doc is wrong.

## TL;DR

Every always-on relay serves **two front doors to the same mailbox**: the ordinary
`wss://` endpoint and a Tor onion service, on the **same node**. A client holds both as
ordinary pool candidates and fails over between them on health alone.

Hop ships **no Tor implementation**. A host that wants relay traffic to ride Tor runs a
proxy (the Tor daemon, Orbot on Android, or Arti embedded in the app) and hands the relay
bearer its `host:port`. That is the whole integration.

**What Tor buys, stated exactly: it hides the node's IP address from the relay and from the
network path. It does NOT hide the node's hop address.** Links are mutually authenticated
Noise XX (`core/hop-core/src/link.rs`, `NOISE_PARAMS`), so a relay learns the hop address of
whoever connects over any transport. Anything that implies otherwise is wrong.

## 1. The design

### An .onion URL is not a special case

`RelayPool` (`core/hop-core/src/relay_pool.rs`) stores each endpoint as an **opaque dial
string** and rejects only the empty one. It never parses a URL and never learns a transport.
So `ws://<56-char-v3>.onion/_hop` is an ordinary candidate: added, health scored, backed off,
evicted, failed over, and learnable from a signed reach record exactly like `wss://relay.example/_hop`.

That was already true before this work. What was missing was proof, so it is now pinned by
tests rather than left to a future "let us validate these URLs" change to quietly break:

- `core/hop-core/src/relay_pool.rs` tests: an onion endpoint is accepted and dialable, is
  health scored on the same ladder and backoff curve, fails over **in both directions** with a
  clearnet endpoint, is publishable in a signed reach record, and (deliberately) counts as a
  separate entry from the same operator's clearnet URL so a blocked transport cannot poison
  the other one.
- `core/hop/src/cabi.rs`: the round trip through the C ABI. An onion dial string is roughly
  70 characters where the clearnet ones are roughly 25, and it crosses the ABI through a
  caller-sized buffer, so truncation, not policy, is the real risk at that seam.

### The host supplies the proxy

`RelayBearer` on both platforms takes an optional `socksProxy` spec (`host:port`):

- Apple: `bearers/apple/HopBearerRelay`. Applied via
  `URLSessionConfiguration.proxyConfigurations` with a `ProxyConfiguration(socksv5Proxy:)`.
- Android: `bearers/android/bearer-relay`. Applied via `OkHttpClient.Builder.proxy(...)` with
  a `java.net.Proxy` of type `SOCKS`.

Both hand the **target hostname to the proxy unresolved**, which is the only reason a
`.onion` name can work at all: no resolver on earth can answer it, so Tor has to. That is
asserted, not assumed. Each platform's test suite stands up a real loopback SOCKS5 proxy that
splices into a real loopback WebSocket server, dials a v3-shaped `.onion` URL through it, and
checks the proxy saw SOCKS5 `ATYP 0x03` with the full hostname before the link came up and
carried bytes (`RelayIntegrationTests.testOnionRelayDialsThroughASocksProxyAndOpensALink`,
`RelayBearerSocksTest.anOnionRelayDialsThroughTheProxyWithAnUnresolvedHostname`).

Hosts reach it through driver config: `HopBearer.Config.socksProxy` (Apple) and
`HopConfig.socksProxy` (Android). Unset means dial direct, which is what every existing
caller does.

### The setting has three states, and it fails closed

Not an optional. `direct` (none configured), `via` (a good spec), `unusable` (configured but
does not parse). A typo must never read as "the user did not want a proxy", because that
turns one bad character into a clearnet connection the user believes is proxied. In the
`unusable` state the bearer **refuses to dial** and reports the attempt as a failure, so the
pool scores the endpoint and a UI can show "no reach" instead of a healthy-looking pool that
never connects.

The same refusal covers Apple below iOS 17 / macOS 14, where `proxyConfigurations` does not
exist. The package still supports iOS 16 / macOS 13, and on those a proxied relay simply does
not connect. No reach is a better failure than a silent clearnet fallback.

### Billing is unaffected

The §35 carriage stamp signs `bundle_id || epoch` (`core/hop-core/src/wire_stamp.rs`,
`stamp_message`). It rides the MESSAGE, not the connection, so metering works identically
whether the bundle arrived over TCP or over Tor. Tor does not break billing, and billing does
not deanonymize a Tor client any further than it already does over TCP.

## 2. What Tor fixes, and what it does not

### Fixes

- **The relay does not learn the client's IP address**, and therefore not its network
  location, ISP, or coarse geography.
- **The path does not learn who the client is talking to.** A local network operator sees a
  Tor connection, not a connection to a hop relay.
- **Reach through a network that blocks the relay.** An address-based or port-based block on
  the clearnet endpoint is bypassed by the onion endpoint, and the pool fails over on health
  without any new policy.
- **The relay's own IP is not exposed to the client** when the client uses the onion address.

### Does NOT fix

- **The relay still learns the connecting node's hop address.** Links are mutually
  authenticated Noise XX. Tor hides WHERE you are, never WHO you are at the hop layer. A
  relay can therefore still see that address X was online at time T, and correlate its
  sessions over time, exactly as it can over TCP. If you need that unlinked, the answer is
  identity rotation at the hop layer, not a transport.
- **Traffic analysis.** Timing and volume correlation against a global observer is out of
  scope for Tor and for hop.
- **Anything about bundle contents or addressing.** Those were already covered: a §39 private
  bundle carries no sender, no recipient, and no path, and a traced one is signed end to end.
  Tor adds nothing there, which is exactly why hop can point at a stranger's relay in the
  first place (DESIGN.md §19).
- **Being reachable when Tor is blocked.** See below.

## 3. Why not Tor-only

1. **Tor is blocked in many networks**, by corporate and campus filters and by states. A
   Tor-only design would hand every one of those operators an off switch for hop's internet
   reach. Two transports means blocking one is not blocking the service.
2. **BLE mesh needs no IP at all.** Hop's fallback when every IP path is gone is the local
   mesh, not another IP path. Making Tor mandatory would add a hard dependency to the layer
   that is supposed to be optional.
3. **It re-creates the dependency `RelayPool` exists to remove.** Reach would become a
   function of the Tor network's health rather than of a health-scored set of endpoints.
   Same failure shape as one operator's fleet going dark, which is the bug that motivated the
   pool.
4. **Cost.** Onion service circuits add hops in both directions, and mobile clients pay for
   that in latency, battery, and reconnect churn. Fine as a choice; wrong as the only option.

So: both, on the same node, as two independent entries in the pool.

## 4. Deployment: one always-on relay per continent

The shape (owner's decision): roughly six or seven always-on relays, one per continent, each
serving the HTTPS/WSS path **and** the onion service **on the same node**.

**Why the same node.** The relay's value is its durable mailbox. Two front doors to one store
means a bundle spooled over the clearnet is retrievable over Tor and the reverse. Splitting
them across separate nodes would split the mailbox and turn one relay into two half-relays.

**Why always-on.** An onion service holds a long-lived service key and maintains introduction
points. There is no scale-to-zero for it.

### What would change in infra (NOT changed in this item)

Today the fleet is one **scale-to-zero Cloud Run service per region** (in the private platform repo,
`hopmesh/platform/infra/cloud_run.tf`, `min_instance_count = 0`), fronted by a global anycast load balancer
(`hopmesh/platform/infra/load_balancer.tf`), with the whole serving chain count-gated on `var.relays_enabled`,
which is currently `false` (see `docs/repo-catalog.md`). If and when the onion side is built, this is what would have to
change:

- **A long-lived VM per continent, not Cloud Run.** Cloud Run gives request-scoped CPU, no
  stable process identity across requests, and no durable local key storage, so a Tor daemon
  publishing an onion service does not fit it. The onion half wants a small always-on
  instance running `hop-relayd` plus a Tor daemon whose `HiddenServicePort` points at the
  local relay port. The clearnet half can stay exactly as it is.
- **The service key becomes state that must survive a rebuild.** The onion hostname IS the
  service's public key, so losing the key changes the address for every client that has it.
  It belongs in Secret Manager, provisioned to the instance, never generated fresh by a
  redeploy.
- **Publishing the address.** The onion URL has to reach clients as a `Bundled` or
  `Configured` pool endpoint in app builds, and/or as a signed reach record
  (`core/hop-core/src/reach.rs`) served alongside the clearnet one at `/.well-known/hop`
  (§30). The record signs an opaque endpoint string, so it already carries onion URLs with no
  format change.
- **The load balancer, certificate, and DNS chain are untouched.** Tor terminates at the
  instance, not at the LB. There is no certificate to get for a `.onion` and none is needed
  (see below).
- **Every one of those applies runs in CI**, per `hopmesh/platform/infra/CLAUDE.md`. A merge to `main` in
  the platform repository is the deploy; nothing is applied from a workstation.

## 5. Google Cloud AUP: run an onion SERVICE, never a Tor relay or exit

These are different activities with very different risk, and conflating them is how a cloud
account gets suspended.

**Hosting an onion service for our own relay: low risk.** The Tor daemon makes outbound
connections to the Tor network and accepts inbound circuits addressed to our own service. It
carries **no third-party traffic**, is not an open proxy, and generates no abuse egress. It
is, from the provider's point of view, an outbound-connecting application server.

**Running a Tor relay (guard or middle), and above all an EXIT node: do not.** An exit node
sends **strangers' traffic** out of our IP addresses. That produces abuse complaints, DMCA
and law-enforcement contact, blocklisting of our address ranges, and reads squarely as the
open-proxy and network-abuse behavior a cloud acceptable use policy is written to prohibit.
This is not a "get permission first" item. It is out of scope for this project on any
account, in any project, permanently.

Concretely, the Tor configuration on a relay instance must:

- publish only the hidden service (`HiddenServiceDir` / `HiddenServicePort`),
- set no `ORPort` and no `DirPort`,
- set `ExitRelay 0`,
- and expose no SOCKS port beyond loopback.

Read the current Google Cloud Acceptable Use Policy and Terms before deploying. The paragraph
above is engineering guidance about which activity is which, not a legal opinion, and the
policy text is what governs.

## 6. Operating notes

- **`ws://` over an onion address is correct, not a downgrade.** A v3 onion address IS a
  public key: Tor authenticates and encrypts the circuit to that exact service. On top of
  that, hop's own link layer is mutually authenticated Noise XX. A TLS certificate for a
  `.onion` name is impractical and would add nothing either layer does not already provide.
- **iOS App Transport Security is a likely integration snag.** ATS blocks cleartext loads by
  default, and a `ws://<onion>/` URL is a cleartext load to a non-local host. An app shipping
  this will probably need an ATS exception for the `.onion` domain. The in-tree tests dial
  loopback, which ATS exempts, so this is NOT verified here; verify it in the app when the
  onion side is actually deployed.
- **Point the proxy at loopback.** `127.0.0.1:9050` is the Tor daemon default; Orbot and Arti
  expose their own. A non-loopback SOCKS proxy means trusting whoever runs it with every
  relay connection, including the ability to see which relay you dial.
- **The pool treats the two endpoints independently.** Failing over from clearnet to onion
  costs two consecutive failures on the clearnet entry (`FAILURES_BEFORE_BACKOFF`), and the
  backed-off entry always comes back, so a temporary block does not permanently pin a client
  to Tor.

## 7. Status

Built:

- Onion endpoints flow through `RelayPool`, the node API, and the C ABI, with tests.
- A SOCKS5 proxy hook on both relay bearers, with tests that dial a `.onion` URL through a
  real SOCKS5 proxy, plus fail-closed behavior on a broken spec.
- Driver config on both platforms.

Not built, deliberately:

- No Tor implementation, daemon, or bootstrap logic in this repo.
- No deployed onion service, and no infra change. Section 4 describes what would change.
- No bundled onion endpoints in any client build, because there is no onion service to
  point at yet.
