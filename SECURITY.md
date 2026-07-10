# Security Policy

Hop is a metadata-privacy messaging mesh. Security and privacy are the product,
so we treat vulnerability reports as first-class and respond quickly.

## Supported versions

Hop is pre-1.0 and ships from `main`. There is one supported line at a time:
the latest tagged release plus the current `main`. Older tags are not patched;
upgrade to the latest tag or `main` to receive fixes.

| Version              | Supported          |
|----------------------|--------------------|
| latest tag + `main`  | Yes                |
| any earlier tag      | No (upgrade)       |

The wire format is versioned independently of the crate version. See
`HOP_WIRE_VERSION` (core) and `HOP_ABI_VERSION` (`sdk/hop.h`); the CI wire-stability
test pins both so a security fix cannot silently break interop.

## Reporting a vulnerability

Do NOT open a public GitHub issue for a security or privacy vulnerability.

Report privately, in order of preference:

1. GitHub private vulnerability reporting: open the repository's Security tab and
   use "Report a vulnerability" (GitHub Security Advisories). This is the preferred
   channel because it keeps the report, the fix, and the coordinated disclosure in
   one place.
2. Email `jason@waldrip.net` with the subject prefix `[hop-security]`. If you want
   an encrypted channel, say so in a first low-detail message and we will arrange one.

Please include:

- a description of the issue and the component (core protocol, a bearer, a driver,
  the relay/services, infra, or a client app),
- the impact you believe it has (confidentiality, integrity, availability, or
  metadata/traceability),
- a proof of concept or the minimal steps to reproduce,
- the commit SHA or tag you tested, and the platform.

## What to expect

- Acknowledgement of your report as soon as we have triaged it.
- An initial assessment (confirmed / needs-info / not-a-vuln) once we reproduce.
- Coordinated disclosure: we will agree a disclosure date with you, ship the fix
  on `main` (and a tag), then publish an advisory. We credit reporters who want it.

We ask that you give us a reasonable window to remediate before public disclosure,
and that testing does not exfiltrate other users' data, degrade the live relay
fleet, or violate anyone's privacy.

## Threat model summary

Hop's full design and threat model live in `DESIGN.md` (see especially the
metadata-privacy sections, "§39", on untraceable-by-default delivery) and in
`MECHANISMS.md`. The short version:

- End-to-end content is always forward-secret (Double-Ratchet). A send without a
  ratchet is an error, never a static-seal fallback.
- The default delivery path is metadata-private ("§39"): the network does not learn
  who is talking to whom from routing alone. Mailbox tags rotate per epoch.
- Bearers (BLE, LAN, relay, and others) are transports only. Compromise of a bearer
  or the relay fleet must not break content confidentiality or integrity; it can, by
  construction, observe coarse traffic timing and the metadata a given bearer exposes.
- The relay fleet is honest-but-curious infrastructure. It stores sealed bundles and
  routes toward recipients; it cannot read content.

### Known accepted risks (pre-production)

These are documented tradeoffs the team has accepted for the current test phase.
They are tracked and will be closed before a production release. They are listed
here so a reporter does not spend effort on already-known items:

- Client identity secrets and the SQLCipher at-rest key are currently derived from a
  device identifier rather than held in the platform Keychain / Android Keystore /
  Secure Enclave. A process that learns the device id can recompute them. Hardware-held
  key storage and an exportable-encrypted-identity flow are designed in
  `docs/identity-backup-restore-design.md` and pending client work.
- Signed-prekey rotation is designed but not yet implemented; the recognition SPK is
  currently as long-lived as the identity.
- The relay fleet is deployed-off for a P2P-only test phase. Server-side hardening
  items (connection caps, per-source shedding, rate-limiter keying behind the load
  balancer) are tracked in the services runbooks.

If you find something outside this list, we want to hear about it.
