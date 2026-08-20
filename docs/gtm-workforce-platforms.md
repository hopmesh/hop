# GTM, workforce platforms

> Strategy note. The first vertical where Hop is not a nice offline story but the fix for a
> defect the buyer already pays for in staff time. Companion to `docs/positioning.md`.

## The one line

**Sell the transport into gig and staffing platforms. Do not build one.**

Their worker taps clock-in with no data plan. Today that event is lost until the worker gets home. With Hop it makes one hop to a coworker who does have data, and lands at the platform's own API during the shift.

## The defect

A gig worker signs up at home on wifi. They accept a shift on wifi. Then they leave the house.

For a meaningful slice of this workforce, leaving the house means leaving the internet. Prepaid data is out, the plan lapsed, or there is no cell plan at all because free messaging over home wifi is cheaper than a data plan. The phone is not broken and the worker is not remote. They are simply off the network from the moment they walk out the door until they walk back in.

From the platform's side, that worker vanishes at exactly the moment the platform needs them most:

- No clock-in. No clock-out.
- No location, no arrival signal, no progress.
- **A no-show and a no-signal look identical.** The platform cannot tell whether the shift is covered.
- The record is reconstructed afterwards, by hand, from what the worker says happened.

That last one is the line item. Manual timesheet adjustment is an ops cost the platform already carries, and a human-entered guess is a weaker artifact in a wage dispute than a device-signed event.

**Framing check.** The specific pattern, home wifi plus no usable mobile data, is a field hypothesis, not a published statistic, and it should be tested against the buyer's own telemetry rather than asserted. What is published supports the economics underneath it: Pew reports 16 percent of US adults are smartphone dependent, rising to roughly 28 percent under 30,000 dollars of household income, and older Pew work found 44 percent of smartphone owners under 30,000 dollars had let service lapse because it cost too much, with 37 percent hitting a data cap at least occasionally. Cite the first two as current, mark the last two as dated, and let the buyer confirm the rest from their own logs.

## Why a mesh actually works here, when it usually does not

Every consumer mesh product died of cold start. Density was a hope.

Here density is a roster.

- A shift has several workers from the same platform at the same site at the same time.
- The app is already installed, because that is how they get paid. **Distribution is solved before you arrive.**
- The platform can require the app, and often already requires it in the foreground.

And the topology is trivial. This is not a research DTN. The worker does not need a path across a country. **They need one hop to somebody standing nearby who has service**, or to a site device. One hop, occasionally two. That is the easiest possible version of the problem, and it is why this vertical is the right first proof of the fabric.

## The product: their HTTP client

Do not sell a mesh feature. Sell a dependency swap.

The SDK implements the HTTP interface the app already uses. An OkHttp interceptor or `Call.Factory` on Android, a `URLProtocol` on iOS, a `fetch` adapter in React Native. **Call sites do not change.**

- **Connected:** the request goes straight to the origin over normal HTTPS. No mesh, no added latency, no behaviour change. This is the overwhelming majority of traffic and it must stay boring.
- **Not connected:** the same call is sealed and sprayed, hops to a peer with a path, and terminates at the platform's own `hop-endpoint`, which runs it against their real API and seals the response back to the device key.

The platform keeps its API, its models, its auth, its backend. That is the difference between this and adopting a sync database: nobody has to migrate a system of record to get the benefit.

## Delay is survivable, and the layer is what makes it survivable

The naive version of a drop-in client is a lie, because a normal HTTP call returns in milliseconds or fails, and a mesh call can take much longer. Block `fetch` and every spinner, timeout and retry loop in the app breaks.

CQRS plus optimistic responses is the answer, and it belongs **in this layer**, not in the customer's app:

1. **Commands return immediately.** The SDK accepts the write, assigns an idempotency key, returns a synthetic accepted response, and delivers underneath. The app proceeds exactly as it does today.
2. **Queries answer from a local read model** the SDK maintains, so screens render offline instead of spinning.
3. **Reconciliation** applies the real server response whenever it lands, and raises an event when the projection and the truth disagree.
4. **Lifecycle is observable**: stored, in flight, server received, accepted or rejected. Four states, never one spinner. The app can show honest status instead of pretending.

That is the seam that makes the swap real. It is also the thing worth building, because every customer would otherwise rebuild a worse version of it.

**Optimistic is not universal, and the layer must say so.** It is correct for facts the worker owns: clock-in, clock-out, a form, a photo, an incident note. The worker did the thing; the server's job is to record it. It is wrong for contended resources, most obviously accepting the last open slot on a shift, where optimistic acceptance means double booking. The platform declares which endpoints are which, and the default is conservative.

**The bar is not perfection, it is the status quo.** Today the event never arrives and a human retypes it later. A signed device event that arrives late beats a human guess that arrives on time, both on ops cost and on evidence quality. Eventually reaching the worker is strictly better than never reaching them.

## What the platform has to do

Small, but not zero. Name it up front, because this is what an engineer will ask.

| Requirement | Why | Size |
|---|---|---|
| Idempotency key on deferrable writes | Delivery is at-least-once, so the endpoint can see a duplicate | Familiar pattern, small |
| Tolerate out-of-order events | Independent paths mean clock-out can arrive before clock-in | State machine review |
| Authenticate the device key, not just a bearer token | A token may expire before a bundle lands hours later. The Hop address is an Ed25519 public key, so bind it to the worker at enrolment | Design decision, clean |
| Run a `hop-endpoint` in front of the API | It is the origin, bound to one domain, never an open proxy | Deployment |
| Tag which endpoints are deferrable | Writes ride the mesh, freshness-critical reads fail fast as today | Usually a short list |

## Distribution: partner for density, sell for value

Selling platform by platform is the value play and it is slow. There is a faster way to get nodes into the world.

An SDK already inside many of these apps, doing background location for exactly this workforce, already holds the runtime real estate Hop needs: background execution, radio permissions, battery discipline, and a customer base whose core complaint is gaps in the record when connectivity dies. HyperTrack is the clearest example of that class.

- **For them:** their weakest surface is the coverage hole. Hop closes it without changing their product.
- **For us:** one integration puts relay-capable nodes into many apps at once.
- **The compounding part:** Hop is a shared fabric, so any Hop app relays for any other. Their install base becomes relay density for **every** Hop app, including the platform SDKs we sell directly. That is the cold-start problem solved by somebody else's distribution.

Two honest caveats. First, as the founder notes, this only covers the location payload; the platform's own business events still need the direct integration, so a partnership is a beachhead rather than the whole product. Second, the ask is bigger than adding a library: it means enabling a new radio behaviour and a user-facing disclosure that the device may carry sealed traffic for others. Expect a build-versus-buy evaluation, and expect privacy review.

## What this must not become

| Temptation | Why it dies |
|---|---|
| Build a gig marketplace | Wrong business, and it competes with the buyer |
| Define clock semantics in the SDK | The SDK carries bytes. The platform owns what a clock event means. Keep it that way and the timekeeping patent surface stays out of reach |
| Generate geofences or trigger time from location | Same reason. Transport does not decide when work started |
| Optimistic everything | Contended resources need arbitration. Double-booked shifts would be our fault |
| A new system of record | Then it is a migration, and the sale dies |
| Offline chat | Consumer mesh messaging is a graveyard. Density here comes from payroll, not from novelty |

## What breaks it

- Background BLE on iOS is restricted enough that a backgrounded coworker's phone does not reliably relay. This is the single biggest technical risk and it is measurable before any sale.
- Battery cost is visible enough on old devices that the platform pulls the SDK.
- Rosters are too sparse: solo workers, staggered arrivals, one worker per site. Peer relay needs company, so a site gateway becomes mandatory rather than optional.
- The platform will not put an endpoint in front of its API.
- The valuable payloads turn out to be large, so they cannot land before expiry.
- Duplicate or out-of-order events corrupt state because the API cannot be made idempotent cheaply.

## What to prove, in order

1. **Instrument the gap.** Ask a platform three questions they can answer from data they already hold: what share of worker sessions originate on cellular versus wifi, what does the clock-in latency distribution look like, and how many timesheet adjustments happened last month and how many trace to connectivity. This sizes the deal without a single line of code.
2. **Bench the one hop.** Two phones, one in airplane mode, both with the app backgrounded, realistic roster spacing. Measure delivery rate and time to land on both platforms. This is the technical kill test and it is cheap.
3. **Swap the client behind a flag.** In a branch of a real app, point deferrable writes at a `hop-endpoint` in front of staging. Demo a clock-in from an offline phone landing through a coworker.
4. **Then** approach the embedded-SDK partner, with the bench numbers in hand rather than a thesis.

## Source coverage

| ID | Source | State | Limitation |
|---|---|---|---|
| H-POS | `docs/positioning.md` | `live` | Internal strategy note |
| H-DES | `DESIGN.md`, Use Case A and B, non-goals | `live` | Design, not a production SLA. Real-time and exactly-once are explicit non-goals |
| H-MEC | `MECHANISMS.md`, shared fabric and app isolation | `live` | Living catalog, wire versions change |
| H-HOPS | [hops:// protocol](https://hopme.sh/protocol/hops/) | `live` | Whitepaper still forthcoming |
| P-DEP | [Pew, digital divides, Jan 2026](https://www.pewresearch.org/short-reads/2026/01/08/internet-use-smartphone-ownership-digital-divides-in-u-s/) | `live` | Smartphone dependent means no home broadband, which is not the same cohort as no mobile data. Used for economics, not for the specific pattern |
| P-INC | [Pew, mobile technology and home broadband, Jan 2024](https://www.pewresearch.org/internet/2024/01/31/americans-use-of-mobile-technology-and-home-broadband/) | `live` | Income breakdown |
| P-LAPSE | [Pew, portrait of smartphone ownership, 2015](https://www.pewresearch.org/internet/2015/04/01/chapter-one-a-portrait-of-smartphone-ownership/) | `partial` | Service lapse and data cap figures are roughly a decade old. Directionally on point, must be marked dated wherever quoted |
| F-PATTERN | Founder field observation, workers lost on leaving home wifi | `partial` | Unpublished operating experience. Treat as the hypothesis the buyer's telemetry tests, never as a cited statistic in external material |
| C-MESH | FireChat discontinued, Bridgefy cryptanalysis (Royal Holloway, ETH Zurich) | `live` | Evidence that consumer mesh messaging failed, not evidence this vertical succeeds |

No source in this file is `pending`.
