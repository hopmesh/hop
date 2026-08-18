// An in-process bearer that wires two Hop nodes to each other.
//
// WHY THIS EXISTS, and why it is not a mock.
//
// @hop-mesh/react-native is a CLIENT SDK, not a transport. Its surface is linkUp / linkDown /
// bytesReceived / onOutgoing, which means the core hands you packets and you are responsible for
// moving them. The native HopDemo apps get their radios from drivers/apple/HopDriver and
// drivers/android/hop-driver, which own the BLE, LAN and relay bearers. The React Native SDK ships no
// bearer at all, so an RN app cannot talk to a second physical device today. That is a real gap, stated
// plainly, not something this file papers over.
//
// What it CAN do is carry packets between two nodes inside one process. That is not a fake: the bytes
// are produced by the real Rust core, sealed with real crypto, and delivered through the real inbox
// path. A message that arrives this way genuinely round-tripped through hop-core. It exercises the
// entire bridge (send, pump, outgoing, bytesReceived, inbox, accept) on whichever platform it runs on,
// with no radios, which is exactly what makes a simulator run worth anything.
//
// What it does NOT prove: radio discovery, real BLE MTU and fragmentation behaviour, or multi-device
// relay across separate hardware. Those need devices, and the Detox suite tags them accordingly.

import type { HopNode } from "@hop-mesh/react-native";

/** One end of the loopback. `link` is an app-chosen id; the two ends must not share one. */
export interface LoopbackEnd {
  node: HopNode;
  link: number;
}

export interface Loopback {
  /** Packet counts, so a test can assert traffic actually moved rather than trusting silence. */
  readonly stats: { aToB: number; bToA: number };
  stop(): void;
}

/**
 * Connect two nodes so each one's outbound packets become the other's inbound bytes.
 *
 * Both links are brought up with opposite roles, mirroring a real dial: one side dialled, the other
 * accepted. The core cares, because the handshake is not symmetric.
 */
export async function connectLoopback(a: LoopbackEnd, b: LoopbackEnd): Promise<Loopback> {
  if (a.link === b.link) {
    // Shared link ids would make each node treat its own traffic as inbound from the peer, which
    // "works" until it silently corrupts session state. Refuse instead.
    throw new Error(`loopback: both ends use link ${a.link}; the ids must differ`);
  }

  const stats = { aToB: 0, bToA: 0 };

  // Subscribe BEFORE linkUp. The pump can emit the handshake's first packets as soon as the link is
  // up, and a subscription registered afterwards would miss them, which shows up later as a session
  // that never completes rather than as an obvious dropped packet.
  const aOut = a.node.onOutgoing(async (out) => {
    if (out.link !== a.link) {
      return;
    }
    stats.aToB += 1;
    await b.node.bytesReceived(b.link, out.bytes);
  });
  const bOut = b.node.onOutgoing(async (out) => {
    if (out.link !== b.link) {
      return;
    }
    stats.bToA += 1;
    await a.node.bytesReceived(a.link, out.bytes);
  });

  // HopRole is "dialer" | "acceptor". These are the real values from types.ts; an earlier draft of
  // this file guessed "initiator"/"responder", which does not exist in the type.
  await a.node.linkUp(a.link, "dialer");
  await b.node.linkUp(b.link, "acceptor");

  return {
    stats,
    stop() {
      aOut.remove();
      bOut.remove();
      void a.node.linkDown(a.link);
      void b.node.linkDown(b.link);
    },
  };
}
