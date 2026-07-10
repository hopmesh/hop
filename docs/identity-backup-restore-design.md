# Design: exportable encrypted identity and device-loss recovery

Status: design. The implementation needs app-side work (iOS and Android) plus a
small core surface for import/export; it is not yet built. This document defines the
target so the implementation is safe.

## The problem

Today, a device's Hop identity secret and its SQLCipher at-rest key are both derived
from a device identifier (`identifierForVendor` on iOS, `ANDROID_ID` on Android) via
a fixed public string:

- `seed = SHA256("hop.identity.v1|" + deviceId)`
- `dbKey = SHA256("hop.db.key.v1|" + deviceId)`

Two problems fall out of this:

1. Not secret. The device id is not a secret. Any co-vendor app (same Apple Team,
   any app on a rooted Android) or a forensic image can recompute the identity secret
   and the db key, giving full impersonation and full decryption. On macOS hosts the
   vendor id is nil, so the identity is random every launch.
2. No recovery. Because the identity is bound to a specific device id, there is no
   supported way to move a Hop identity to a new device or restore it after loss. A
   lost or wiped device is a lost identity: the user reappears as a new node and
   loses their recognized-contact relationships.

This design replaces the derive-from-device-id scheme with hardware-held keys plus
an explicit, user-controlled encrypted export.

## Target key custody

- Identity secret (the Ed25519 seed) and the SQLCipher db key are generated with a
  CSPRNG on first run and stored in platform hardware-backed key storage:
  - iOS: the Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and, where
    available, a Secure Enclave-wrapped key. Never derived from `identifierForVendor`.
  - Android: the Android Keystore (StrongBox where present). Never derived from
    `ANDROID_ID`.
- The FFI contract already anticipates this: the C ABI expects the host to generate
  and store the secret in the platform Keychain/Keystore (see `hop.swift`, the F-25
  note). This design is the host-side implementation of that expectation.
- Migration from the current scheme: on first launch after the update, if a device-id
  derived identity exists, generate a hardware-held key, re-key the SQLCipher db to
  the new key (SQLCipher supports `PRAGMA rekey`), and keep the SAME Hop node address
  by importing the existing identity secret into hardware storage rather than minting
  a new one. This preserves recognized-contact relationships across the upgrade.

## Encrypted identity export (backup)

Goal: let a user back up their identity so they can restore it on a new device,
WITHOUT the export being usable by anyone who obtains the file.

- Export bundle contents: the identity secret (Ed25519 seed), the current ratchet
  sessions and recognized-contact state, and optionally the message history. NOT the
  raw SQLCipher db key (the restore re-keys locally).
- Encryption: the bundle is encrypted with a key derived from a user-supplied
  passphrase via a memory-hard KDF (Argon2id) with a random salt, using an AEAD
  (XChaCha20-Poly1305). The passphrase never leaves the device; the KDF parameters
  and salt travel in the (authenticated) header.
- Format: a versioned, self-describing container (magic + version + KDF params + salt
  + nonce + ciphertext + tag) so a future format change is detectable and refused
  rather than mis-decrypted.
- The export is inert without the passphrase. A file leak alone does not compromise
  the identity; a weak passphrase does, so the UI must set expectations (use a strong
  passphrase, this is the one thing that protects the file).
- Where it goes: the user chooses (share sheet to their own cloud, a file, a QR/paper
  transfer for the small identity-only variant). Hop does not upload it anywhere by
  default.

## Restore / device-loss recovery

- On a new device, the user imports the encrypted export and enters the passphrase.
  The app derives the KDF key, decrypts and authenticates the bundle, generates a
  FRESH hardware-held db key, opens a new SQLCipher db keyed to it, and imports the
  identity secret into hardware storage plus the ratchet/contact state.
- The restored node keeps the SAME Hop address, so recognized contacts continue to
  recognize it. Ratchet sessions are restored, so in-flight conversations continue to
  be forward-secret without a re-handshake (subject to the ratchet's own replay/skip
  rules).
- If the user has NO backup (true device loss with no export), recovery is not
  possible by construction: the identity secret was only ever in hardware storage and
  in the (missing) export. The user starts as a new node and re-establishes recognized
  contacts. This is the correct privacy tradeoff; there is deliberately no server-side
  key escrow.

## What this design explicitly rejects

- No server-side key escrow or "recover with your phone number/email." That would give
  the infrastructure the ability to impersonate or decrypt, which the threat model
  forbids.
- No derive-from-device-id fallback in production. The device-id scheme stays only as
  a documented dev-reliability convenience on hosts without hardware key storage
  (e.g. a macOS test host), gated so it can never be the production path.

## Interaction with signed-prekey rotation

Recognition uses a signed prekey (SPK) that is currently as long-lived as the
identity (rotation is designed but unimplemented). The export/restore format should
carry the current SPK and its rotation state so a restored device resumes on the same
SPK schedule rather than resetting it. Track this together with the SPK-rotation work.

## Implementation surface (for the eventual build)

- Core: a small import/export API on the C ABI to serialize/deserialize the identity
  + ratchet + contact state (the crypto for the container can live host-side, but the
  state extraction needs a core surface).
- iOS: Keychain/Secure Enclave storage, the export/restore UI, Argon2id + XChaCha20.
- Android: Keystore/StrongBox storage, the export/restore UI, the same KDF + AEAD.
- Migration: one-time re-key of existing device-id-derived installs, preserving the
  node address.
