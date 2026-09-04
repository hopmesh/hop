# Hop commercial coverage limits and positioning statement

This document records the customer evidence limits and positioning posture for the Hop
mesh network as of the pre-production evaluation phase (BIZ-006).

## 1. Commercial customer and pilot status

As of the current pre-production release phase:
- **No paying or piloting customers:** There is currently no public or repository evidence
  of paying customers, contracted pilot partners, or verified production deployments
  for any vertical.
- **Demonstrations and scenario models:** Public materials across the marketing site
  (including use-case pages for consumer messaging, managed backbone infrastructure,
  developer embedders, public safety and defense, and hardware/LoRa) present technical
  demonstrations, scenario models, and simulation outputs. They represent protocol
  capabilities rather than production reference accounts.

When formal design-partner agreements or pilot trials are confirmed, verified case studies
and proof points will be published to substantiate specific vertical claims.

## 2. Go-to-market priorities and multi-vertical rationale

Internal go-to-market analysis (detailed in `docs/gtm-workforce-platforms.md`) identifies
**mobile workforce and shift-platform transport** as the highest-conviction near-term
Ideal Customer Profile (ICP). This focus targets operational pain points (such as lost
clock-in events and timesheet disputes in low-connectivity areas) where delay-tolerant
mesh transport directly reduces administrative costs.

Simultaneously, the platform explores multiple vertical markets in parallel
(consumer messaging, industrial operations, field operations, and IoT transport)
based on the shared-fabric architecture of Hop:
1. **Shared relay density:** Hop is a shared transport fabric. Nodes deployed for one
   application automatically relay sealed, encrypted bundles for other applications.
2. **Cold-start mitigation:** Pursuing multiple vertical integrations widens the geographic
   distribution of physical nodes, accelerating the arrival of critical mesh density.
3. **Core protocol generality:** The underlying bundle and store protocols are content-agnostic;
   the same protocol primitives serve emergency notifications, telematics, and peer messaging.
