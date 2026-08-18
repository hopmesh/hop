// Port of the HopDemo presentation logic that already exists twice natively:
// apps/apple/HopDemoKit/Sources/HopDemoKit/DemoFormat.swift (coverage-gated at 95%) and its Android
// twin DemoFormat.kt (gated at 80%).
//
// It is ported rather than reinvented on purpose. These are the only parts of the demo whose correct
// output is already pinned by tests on two platforms, so porting the SEMANTICS gives this app a parity
// target instead of a guess. Where a native helper is inherently platform-bound (makeQrBitmap and
// jpegDownscale are CoreImage / android.graphics), it is deliberately absent here rather than faked:
// see the notes at the bottom.

/** A transport a link can be running over. Mirrors the native demo's transport vocabulary. */
export type Transport = "ble" | "lan" | "relay" | "unknown";

/**
 * Human label for the platform a peer is on. The native demos show the device MODEL name, which is
 * what makes "People nearby" legible when several devices are in the room.
 */
export function platformLabel(platform: string, model?: string): string {
  const p = platform.trim().toLowerCase();
  const base = p === "ios" ? "iOS" : p === "android" ? "Android" : p === "macos" ? "macOS" : "Unknown";
  const m = (model ?? "").trim();
  return m.length > 0 ? `${base} (${m})` : base;
}

/**
 * Single-character transport indicator. The native demos use an icon; RN gets a glyph so the same
 * information is present without pulling an icon set into a demo app.
 */
export function transportIcon(transport: Transport): string {
  switch (transport) {
    case "ble":
      return "B";
    case "lan":
      return "L";
    case "relay":
      return "R";
    default:
      return "?";
  }
}

/**
 * Hop counts arrive from the wire as an unsigned byte and are BLINDED for privacy on some paths, so a
 * raw value can legitimately exceed any sane display range. The native helper clamps rather than
 * showing a nonsense number, and treats anything past the clamp as "far".
 *
 * Kept identical to the native behaviour: negative and non-finite collapse to 0, and the ceiling is 9.
 */
export function normalizeHops(hops: number): number {
  if (!Number.isFinite(hops) || hops <= 0) {
    return 0;
  }
  return Math.min(Math.floor(hops), 9);
}

/**
 * Compact metadata line under a message: how far it travelled and whether the path was secured.
 *
 * `secured` is NOT a field on HopMessage. It is per-peer state, from HopNode.isSecured(address), so
 * the caller queries it separately and passes it in.
 */
export function messageMeta(hops: number, secured: boolean): string {
  const n = normalizeHops(hops);
  const distance = n === 0 ? "direct" : n === 1 ? "1 hop" : `${n} hops`;
  return secured ? `${distance}, secured` : distance;
}

/**
 * Delivery state of something we sent.
 *
 * The field names here are the REAL HopStatus surface (relayed, delivered, forwardHops, forwardMs). An
 * earlier draft of this file invented `accepted` and `secured`, which do not exist on the type; the
 * typechecker caught it. `relayed` is how many distinct peers were handed a copy, which is the honest
 * thing to show while delivery is still unconfirmed, because on a mesh "sent" and "arrived" are
 * genuinely different states.
 */
export function statusText(status: {
  delivered: boolean;
  relayed: number;
  forwardHops: number;
}): string {
  if (status.delivered) {
    const n = normalizeHops(status.forwardHops);
    return n === 0 ? "delivered (direct)" : `delivered (${n === 1 ? "1 hop" : `${n} hops`})`;
  }
  if (status.relayed > 0) {
    return status.relayed === 1 ? "handed to 1 peer" : `handed to ${status.relayed} peers`;
  }
  return "sending";
}

/**
 * Short form of a base58 address for display. Full addresses are long enough to wreck a list row, and
 * the native demos abbreviate the same way: leading and trailing runs joined by an ellipsis.
 */
export function shortAddress(addr: string, run = 6): string {
  const a = addr.trim();
  if (a.length <= run * 2 + 1) {
    return a;
  }
  return `${a.slice(0, run)}\u2026${a.slice(-run)}`;
}

// NOT PORTED, and absent rather than stubbed:
//
//   makeQrBitmap   native uses CoreImage (iOS) and android.graphics (Android) to rasterise the address
//                  as a QR. Rendering a QR in RN needs a dependency this demo does not carry, so the
//                  address is shown as selectable text instead and the UI says so. A stub returning a
//                  blank bitmap would look like a working QR and be worse.
//   jpegDownscale  native photo-attachment path. There is no photo picker in this app yet, so a
//                  downscaler would have no caller.
