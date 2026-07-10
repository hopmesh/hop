# Hop positioning, the narrow waist for intermittent networks

> Strategy/positioning note. Not user-facing copy verbatim, but the source of truth the
> website, deck, and sales narrative draw from.

## The one line

**Hop is the transport layer for intermittent networks, the IP/TCP for a world that isn't
always connected.** Apps and sync engines build *on* Hop; they don't rebuild the radio,
the mesh, and the store-and-forward plumbing themselves.

## The problem with the category today

Every offline-capable product on the market is **vertically integrated**, it ships its own
transport underneath its actual value:

| Product | Its actual value (L7) | The transport it rebuilt (L2-L4) |
|---|---|---|
| Ditto | CRDT data sync, query, subscribe | BLE/Wi-Fi/LAN peer mesh + cloud "Big Peer" |
| Bridgefy | Offline messaging UX + SDK | BLE + Wi-Fi Direct mesh | <!-- docs-token-guard: allow (competitor's transport, not Hop's) -->
| Briar / Berty | Secure messenger | Tor + BLE/Wi-Fi transport |
| Meshtastic | Off-grid text UX | LoRa radio mesh |

They each solved the *same hard transport problem*, discovery, connections, fragmentation,
store-and-forward, reliability across partitions, from scratch, and welded it to one app.
That's wasted effort and a moat made of plumbing, not product.

## The seam Hop splits at

Hop is the **narrow waist** of the hourglass: many bearers below, many apps above, one thin,
sealed, store-and-forward invariant in the middle that everything depends on.

```
L7  apps        messenger · file sync · a Ditto-class CRDT store · offline web · IoT telemetry
L4+ semantics   hops:// (HTTP)   ·   hps:// (pub/sub)   ·   carrier transport / streams
L3  hdp://      sealed, signed, addressed, store-and-forward datagrams      ← THE WAIST
L2  bearer      BLE · L2CAP · TCP/WebSocket · (Wi-Fi Aware, LoRa, …)
```

A vertically integrated product is the whole column. Hop is the **`hdp` waist** plus the
backbone, and it makes the column above it *buildable by anyone* (DESIGN.md §30).

## The competitive reframe

We are not another offline messenger or another sync database. We are a **layer below them**.

- **Ditto is a vertically-integrated offline database; Hop is the transport layer such a
  database could be built on.** Send ops as `hdp` bundles, subscribe to a collection over
  `hps`, discover peers by gossip, converge via the backbone. Different *slot* in the stack.
- If the layer wins, products like Ditto/Bridgefy become **consumers of the fabric, not
  rivals**, and every one of them drives backbone usage, which is what we monetize (§37).
- Be honest: **Ditto itself won't re-platform** onto Hop, they're funded and integrated. The
  prize is the **next** Ditto, and the long tail of apps that should never have to build
  transport.

## What is uniquely Hop (the whitespace none of them have)

1. **Internet egress from offline** (Use Case A), emit a sealed HTTP request that *any*
   online stranger fulfills and relays back. Every competitor is device-to-device only.
2. **One shared fabric across apps**, every Hop app relays for every other (§17); their
   meshes are per-app islands.
3. **True delay-tolerance** (hours-to-days, store-and-forward across partitions) vs.
   "real-time P2P when peers are in range."
4. **Protocol-level identity & naming**, key *is* the address; `hops://` + HNS; a scale-to-zero
   backbone. None of the others have this.

## Why the waist is the position worth holding

The narrow waist is the most defensible spot in any stack (IP, the kernel syscall ABI, S3):
hard to displace because everything above depends on the invariant, and it compounds, more
bearers below and more apps above both make it more valuable. For Hop specifically, the waist
and the business model are the *same* thing: more L7 apps on the fabric → more backbone usage →
more metered revenue (§37). The "shared fabric" thesis (§17) and the platform thesis are one
thesis.

## The trap, and the path through it

**Integrated usually beats layered, until the layer is genuinely better.** Two honest risks:

1. **The seam must help, not tax.** A sync engine on Hop has to be *easier and not slower* than
   rolling its own transport, or developers just do what Ditto did. The concrete enabler is an
   **anti-entropy / reconciliation primitive** above `hdp` (DESIGN.md §38) so a replicated store
   converges efficiently, "what do you have that I don't", rather than brute-forcing it over
   message passing.
2. **You reach the waist *through* a product, not by declaring it.** libp2p came out of IPFS; S3
   came out of Amazon's own infra. Lead early adopters with a killer first-party use case
   (internet-egress-from-offline, or one sharp vertical), architect it as the layer, and let the
   platform position follow. Pitch the *product* to users; build the *waist* underneath.

## Positioning statements (messaging source)

- **For developers** building anything that must work without reliable connectivity, **Hop** is
  the embeddable transport layer that carries sealed messages of any size across devices and the
  internet, **unlike** offline SDKs that lock you into one app's mesh, Hop is a shared fabric
  every app relays for.
- **For platform/infra teams**, **Hop** is the narrow waist for intermittent networks: build your
  sync engine, messenger, or telemetry pipeline on `hdp` instead of rebuilding radios and
  store-and-forward, **unlike** vertically-integrated offline databases, Hop is the layer they'd
  be built on.
