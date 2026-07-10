# Design: opt-in scrubbed crash and diagnostics reporting

Status: design. The implementation needs app-side work (iOS and Android) and is not
yet built. This document defines what "safe" looks like so the implementation does
not leak what Hop exists to protect.

## Why this is hard for Hop

Hop is a metadata-privacy product. A naive crash reporter (drop-in Sentry /
Crashlytics with defaults) would defeat the entire threat model: it would ship
message contents, contact addresses, mailbox tags, device identifiers, and the
network graph to a third party, in the clear, keyed to a stable install id. Any
diagnostics pipeline MUST be opt-in and aggressively scrubbed, or it becomes the
easiest deanonymization vector in the system.

## Principles

1. Off by default. No diagnostics leave the device unless the user explicitly opts
   in, with a plain-language explanation of exactly what is sent.
2. Scrub at the source. The device redacts before anything is queued for upload.
   Never rely on the backend to scrub; assume the backend and the network are
   hostile observers.
3. No stable identity in reports. No `identifierForVendor`, no `ANDROID_ID`, no Hop
   node address, no ratchet/session material, no mailbox tags. A crash report must
   not be linkable across time to a single install or to a Hop identity.
4. No content, no contacts, no graph. Never message bodies, image bytes, peer
   addresses, contact lists, or which peers are linked.
5. Minimal, reviewable payload. Prefer a small, human-auditable report over a rich
   automatic dump.

## What is safe to send (opt-in)

- The crash: exception type, a symbolicated stack trace with only Hop and system
  frames (application frames are fine; ARGUMENTS and locals are NOT).
- Coarse environment: OS name + major version, device model class (not serial),
  app version + build, `HOP_ABI_VERSION`, `BUNDLE_VERSION` (the wire version, from
  `core/hop-core/src/bundle.rs`).
- Coarse state flags: which bearers were enabled (BLE / LAN / relay) as booleans,
  whether the relay was reachable, foreground vs background. Booleans and enums
  only, never addresses or counts that fingerprint.
- A per-report random id (fresh each report) so a user can reference "this crash"
  in a support thread. NOT a stable device or install id.

## What must NEVER be sent

- Any device identifier (`identifierForVendor`, `ANDROID_ID`, IMEI, MAC, advertising id).
- The Hop node address / public key / identity seed.
- Ratchet sessions, prekeys, the SQLCipher key, or any key material.
- Message contents, image bytes, or message counts per contact.
- Contact/peer addresses, mailbox tags, or the link/peer graph.
- Precise location, IP address (strip at the client; the collector must also not log
  source IPs), or timestamps precise enough to correlate with observed traffic.
- Full log buffers. If logs are attached at all, they pass through the same
  allow-list scrubber as everything else.

## Scrubbing implementation notes

- Build a report struct with an explicit ALLOW-LIST of fields. Never serialize an
  arbitrary state object. If a field is not on the allow-list, it does not ship.
- Redact stack-frame arguments and any string that could be an address, key, or
  base58/base64 blob. Symbolicate against the release's dSYM / mapping file
  server-side from the stack alone, not by sending symbols from the device.
- Strip source IP at ingest. The collector must not store or log the connecting IP;
  keying reports on IP would reintroduce the linkability we removed on device.

## Transport and consent

- Consent: a clear settings toggle, default OFF, with a one-screen description of the
  exact fields sent (link to this doc). Re-consent on a material change to the payload.
- Transport: reports upload over TLS to a collector we control (or a self-hosted
  Sentry with client-side scrubbing enforced, PII features disabled server-side).
  Do NOT use a vendor default SDK configuration.
- Queue: at most a small bounded on-device queue; drop oldest on overflow. Never an
  unbounded diagnostics buffer (the app already has an unbounded-history problem to
  fix separately; do not add a second one here).

## Open questions

- Whether to support user-initiated "share diagnostics" (attach a scrubbed report to
  a support message) in addition to automatic opt-in crash upload. The share flow can
  show the user the exact payload before sending, which is stronger consent.
- Retention on the collector and who can read it. Diagnostics must have a short TTL
  and access controls at least as strict as the relay activity stream.
