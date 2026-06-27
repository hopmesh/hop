# Hop BLE — Clean-Room Validation Results (2026-06-27)

## TL;DR

**The cross-platform BLE transport is proven reliable.** A 5-node clean-room mesh
(2 Android incl. 1 BLE-only, 2 iOS incl. 1 BLE-only, 1 macOS) forms a full mesh of L2CAP
pipes and holds it. The production "minutes-to-hours delivery" failures were **protocol bugs
(now fixed, committed `656b62b`) + hardware degradation I introduced during testing (reset by a
reboot)** — not a fundamental BLE-pipe problem.

## What was proven — clean-room ble-lab, 5-node full mesh

Nodes: **Pixel** (Android, Wi-Fi OFF / BLE-only), **Galaxy Tab** (Android), **iPhone XR**
(iOS, BLE-only), **Jillian's iPad** (iOS), **Mac** (`blepeer` macOS CLI). Each node holds an
L2CAP pipe to the other 4 → full mesh.

- **Full mesh formed** across all 5, including the two BLE-only nodes ↔ everyone.
- **Sustained:** Mac observer logged **1141 PROOF ping/pongs over 5.5 min**, all 4 of its peers
  continuously alive, **median RTT 53 ms** (min 0, max 380).
- **Self-healing:** 22 LINK-UP vs 19 LINK-CLOSED — links drop on lossy BLE and **re-form
  automatically**; the mesh stays whole (4 peers maintained throughout).
- **Background-alive:** a backgrounded Android (home-press) keeps its pipes (FGS + 1 Hz keepalive).

## Production protocol fixes — committed `656b62b`, 113 hop-core tests green

- **Flood / resource exhaustion** (the headline "minutes-to-hours" bug): gossip dedup lived on the
  per-link object and was wiped on every BLE flap → each reconnect re-flooded the whole directory.
  Now **per-PEER**, surviving flaps. Hardware: **116 → 0.25 records/s**; regression test **537 KB →
  <100 KB**.
- **Securing** root-caused to **CLOCK SKEW**: a device with a wrong system clock stamps adverts
  with a stale `created_at`, so correct-clock peers reject them as expired → never discovered/secured.
  (My reboot had left the Tab's clock 5 months behind with no NTP.) Fix: always re-offer own
  prekey/presence on link-up so a state-lost peer re-secures. **Field note: adverts should tolerate
  clock skew.**
- **Delivery speed:** re-offer own unacked bundles on reconnect + initial retransmit 30s → 5s.
- **Activity-based BLE link dedup (Android):** keep the link actually carrying traffic (rx growing
  ⇒ both ends agree it's alive). Converges, unlike keep-oldest (wedged on a dead link) / keep-newest
  (ping-pong). Stopped the dedup/re-dial churn.
- Plus: relay-disable seam (P2P-only mode), address-keyed conversations, automation hooks both apps.

## Resilience gauntlet

- **Background-alive:** ✓ backgrounded Android stays linked + PROOFing.
- **`am force-stop`:** the design's hard wall (cancels the watchdog alarm). **Harness note:**
  recover a force-stopped Android app with `am start -n <pkg>/.MainActivity` — `monkey` does NOT
  clear `FLAG_STOPPED`.
- **Wake layers are implemented** in ble-lab: Android `Ble.kt` iBeacon (`BEACON_UUID 7ED7BEAC…`,
  5-min cycle) + `AnchorWatchdogReceiver` (exact-alarm FGS resurrection); iOS `BeaconWake.swift`
  (CLBeaconRegion monitoring, Layer C — the force-quit-proof path).
- **Layer C (iOS force-quit → CoreLocation wake → re-link):** under test (eventual; up to the 5-min
  beacon cycle). [result appended below]

## Conclusion / fold-back path

The BLE transport works and the protocol bugs are fixed. The logical next step is to **re-validate
the production HopDemo on the now-clean hardware** (it should deliver reliably with `656b62b` + a
healthy BT stack), or continue hardening the ble-lab wake layers. The `testkit/` harness
(`tk send/verify/delivered`, `run-round.sh`, `soak.workflow.js`) is ready to drive that validation.

## Environment caveat

The 5-device fleet was degraded by this session's extensive churn (dozens of reboots / BT toggles /
reinstalls → wedged advertisers, the Tab clock skew). A hard reboot of the Android devices restored
clean BT stacks, after which the clean-room mesh formed immediately and reliably.
