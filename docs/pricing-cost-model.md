# Hop backbone — cost model & pricing rationale

> Working doc. GCP rates current as of June 2026 (sources at bottom); treat the
> derived prices as a **starting proposal to tune**, not final. The *shape* of the
> conclusion is robust even if individual rates drift.

## 1. What the hosted backbone actually costs us

Three cost centers, mapped to GCP line items.

### Relay compute — Cloud Run (scale-to-zero)
- Instance-based (CPU always allocated): **$0.000024 / vCPU-s**, **$0.0000025 / GiB-s**, **$0.40 / M requests**. Free tier: 180k vCPU-s, 360k GiB-s, 2M req / month.
- Forwarding small sealed bundles is I/O-bound and cheap. The relay itself is near-free at rest because it scales to zero.
- **The real compute cost is the always-warm edge authenticator (§35)** — it must stay up (min-instances ≥ 1) to reject unauthenticated connections *before* they wake a relay. One warm 1-vCPU / 512-MiB instance ≈ `1 × 2,592,000 s × $0.000024` + `0.5 × 2,592,000 × $0.0000025` ≈ **~$65 / region / month**. This is a **fixed floor**, independent of traffic.

### Mailbox — Firestore (Native, Standard)
- **Writes $1.80 / M**, **reads $0.60 / M**, **deletes $0.20 / M**, **storage $0.18 / GB-month**.
- **Ops dominate, not bytes.** A delivered unicast message touches Firestore several times across its lifecycle (store → drain → purge), and its delivery-ACK rides back as its own bundle doing the same. Conservative per-delivered-message estimate (incl. ACK, locator read, retry slack): **~3 writes, ~4 reads, ~3 deletes**.

### Networking — internet egress (Premium tier)
- ~**$0.12 / GB** (0–1 TB), ~$0.11 (1–10 TB), ~$0.08 (10 TB+). Delivering bundles to devices and fulfilling `hops://` responses is egress.
- **This is the cost that scales with payload size** — small messaging is trivial; large `hops` responses / streaming are the exposure.

## 2. The billable atom is a *chunk*, not a message

A "message" is not the unit we carry or meter. Per §5/§31:

- A small payload is **one bundle**.
- A large payload (file, image, HTTP response) is transparently split by the **carrier
  transport** into ordered, individually-sealed **chunks** (`Payload::Carrier`), each its own
  stored-and-forwarded datagram, reassembled at the destination. A 5 MB image is *many* chunks.
- Open-ended data rides **application streams** (`StreamData` chunks).
- (Below all that, **link frames** fragment a bundle for the BLE MTU — but frames are per-hop and
  ephemeral; they are **not** metered. The backbone meters the **chunk/bundle**.)

So the metering atom is the **chunk** (§35: "relay carried = bundles, count + bytes"), and a large
message costs in proportion to its chunk count. Bill the **data carried** (sum of chunk bytes) and
size is handled correctly by construction — a photo is more chunks than a chat line.

### Cost per million chunks (~4 KB sealed each)

| Component | Calc | Cost / M chunks |
|---|---|---|
| Firestore writes | 3M × $1.80/M | $5.40 |
| Firestore reads | 4M × $0.60/M | $2.40 |
| Firestore deletes | 3M × $0.20/M | $0.60 |
| Storage (held ~days) | ~0.1 GB-mo × $0.18 | ~$0.02 |
| Egress | 4 GB × 1.4 overhead × $0.12 | ~$0.67 |
| **Total** | | **≈ $9 / million chunks** (~$0.000009 each) |

A small message = 1 chunk, so this is also ~$9/M *small* messages. Lean lifecycle (2W/2R/1D) is
~$5/M. **Firestore writes are ~60% of it.**

**Worked example — a 5 MB image.** At ~64 KB/chunk that's ~80 chunks ≈ 320 KB of Firestore-op
overhead + 5 MB egress. Op cost ≈ `80 × $9/M ≈ $0.0007`; egress ≈ `5 MB × 1.4 × $0.12/GB ≈ $0.0008`
→ **~$0.0015 per 5 MB image**, i.e. ~$1.50 per thousand. The image costs ~80× a chat line — exactly
because it's ~80× the chunks — which is why we bill **data carried**, not message count.

**The cost structure, summarized:**
- **Marginal (per message):** tiny — single-digit dollars per million.
- **Fixed (per month):** ~$65 / warm region → **~$150–300/mo** for a small global footprint, regardless of volume.
- **Variable risk:** **egress** on large `hops`/streaming payloads, and **storage** on long retention.

## 3. What this implies for pricing

Pure per-message metering is **misaligned** (marginal cost ≈ 0, so you'd either nickel-and-dime or undercharge) and **unpredictable** (devs hate surprise bills). The cost reality argues for:

**Headline metric = Monthly Active Devices (MAD).** Aligns price with the customer's *reach* (their value), is predictable, and amortizes the fixed floor. This is the Twilio / Auth0 / Segment pattern. Generous included usage per device; **meter overage on the real cost drivers — data carried (chunks), egress, and storage** — so a few huge messages can't masquerade as cheap traffic.

### Proposed tiers (indicative)

| | Free | Pro | Enterprise |
|---|---|---|---|
| **Headline** | $0 | **from $25 / 1,000 MAD / mo** | Custom |
| Active devices | 1,000 MAD | beyond first 1,000 | unlimited / committed |
| Included data carried (chunks) | ~4 GB (≈1 M chunks) | ~2 MB / MAD | committed |
| Included mailbox | 2 GB | 5 MB / MAD | custom |
| Included egress | 10 GB | 50 MB / MAD | custom + residency |
| Data-carried overage | — | ~$15 / M chunks (or ~$4 / GB) | committed rate |
| Egress overage | — | ~$0.18 / GB (≈1.5×) | committed rate |
| Mailbox overage | — | ~$0.75 / GB-mo (≈4×) | committed rate |
| Private/federated backbone | — | — | platform fee + their infra |

Express the "data carried" allowance in **GB** (or chunk-count), not message count — it's the only
unit that's fair across a chat line and a 5 MB image (§2).

### Margin check (1,000 MAD on Pro @ $25)
Included: 500k msgs, 5 GB mailbox, 50 GB egress.
- Cost: msgs `500k × $9/M ≈ $4.50` + mailbox `5 GB × $0.18 ≈ $0.90` + egress `50 GB × $0.12 = $6.00` ≈ **$11.4 cost** vs **$25 revenue** → **~55% gross margin** *before* amortizing the fixed floor across the tenant base. Push to **$39 / 1k MAD** for a healthier ~70% once the floor and support are loaded in.

### Free-tier cost-to-serve
1M msgs (~$9) + small storage/egress ≈ **~$15/tenant/mo of marginal cost**, plus a share of the fixed floor. Acceptable as CAC; bounded by the included caps so no single free tenant can run up egress.

## 4. Levers & guardrails
- **Cut the fixed floor**: make the edge authenticator as small/throttled as possible, and keep warm regions to where demand actually is (don't pre-warm empty regions — §28 already says don't).
- **Cut per-message ops**: batch Firestore writes, collapse ACKs (the delivery-ACK vaccine, §31), and prefer in-flight delivery over store-then-drain when a path is live — every avoided store/drain/purge is 3+ ops saved.
- **Cap egress on Free** hard; meter it with light markup on Pro — it's the only thing that can blow up a bill.
- **Enterprise/private backbones are not MAD-metered** — the customer runs the infra and pays GCP directly; we charge platform/license + support (+ federation add-on, §36).

## Sources
- Cloud Run pricing — https://cloud.google.com/run/pricing
- Firestore pricing — https://cloud.google.com/firestore/pricing
- VPC / internet egress pricing — https://cloud.google.com/vpc/network-pricing
