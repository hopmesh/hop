// A real relay bearer: it carries the core's opaque link packets over hop-relayd's WebSocket front
// door. This is what lets a message leave THIS device and reach a node on another device, which
// src/loopback.ts by construction cannot do.
//
// WHY THIS IS A BEARER AND NOT A MOCK, and how the framing is known rather than guessed.
//
// services/hop-relayd/src/main.rs says it in its own module docs: `--ws host:port` is path B, "each
// link packet is exactly one WS binary frame, so WS supplies the framing", and "the link's Noise XX
// handshake (inside the node) authenticates both ends, the bearer carries opaque bytes and knows
// nothing about the protocol". Its test serve_ws_upgrade_bridges_binary_frames_both_ways_and_reports_down
// pins the contract end to end against a real tungstenite client: an inbound binary frame is delivered
// "verbatim" as one Ev::Data, a packet pushed at the link comes back as one binary frame, and a hard
// disconnect still reports Ev::Down.
//
// So this file adds NOTHING to the wire. No length prefix (that is the raw-TCP bearer, path A, which
// does use a 4-byte big-endian prefix), no hello, no auth message, no envelope. One core packet in,
// one binary frame out, and the reverse. Inventing any of those would make the relay drop the link
// during the handshake, which reads as a crypto failure rather than the framing mistake it is.
//
// What it proves and what it does not. A message that arrives through this bearer really crossed a
// real relay: sealed by the real Rust core on one device, relayed as ciphertext the relay cannot read,
// opened by the real core on the other. It still does not prove radio discovery, because the React
// Native SDK ships no BLE or LAN bearer at all. Reaching a peer here means knowing its address, not
// finding it.

import type {HopNode, Subscription} from '@hop-mesh/react-native';

/** Where the link is: dialing, carrying packets, or gone. */
export type RelayState = 'connecting' | 'up' | 'down';

/** A live relay link. `link` is the core link id the packets flow on. */
export interface RelayLink {
  readonly link: number;
  state(): RelayState;
  close(): Promise<void>;
}

/**
 * State callback. `detail` carries the reason a transition happened, and reports anything that would
 * otherwise be a silent failure: a dropped packet, or a frame the relay should never have sent.
 *
 * The second parameter is optional, so a caller written against the narrower `(s: RelayState) => void`
 * passes here unchanged; TypeScript accepts a function that ignores trailing parameters.
 */
export type RelayStateListener = (state: RelayState, detail?: string) => void;

// A socket that never opens is the failure that shows up as a spinner forever: a TCP connect to an
// address with nothing listening can hang for a long time before the platform gives up, and against a
// LAN IP that is the common case. Bounded here so it surfaces as a rejection carrying the reason.
const CONNECT_TIMEOUT_MS = 10_000;

// App.tsx pairs its two in-process nodes on links 1 and 2. Relay links start well clear of those: two
// bearers sharing one core link id "works" until it silently corrupts session state, so they must
// never overlap.
const FIRST_RELAY_LINK = 1000;
let nextRelayLink = FIRST_RELAY_LINK;

/** The slice of WebSocket this bearer uses. Structural on purpose: see socketConstructor. */
interface RelaySocket {
  binaryType: string;
  send(data: Uint8Array): void;
  close(code?: number, reason?: string): void;
  onopen: (() => void) | null;
  onclose: ((event: {code?: number; reason?: string}) => void) | null;
  onerror: ((event: {message?: string}) => void) | null;
  onmessage: ((event: {data: unknown}) => void) | null;
}

type RelaySocketCtor = new (url: string) => RelaySocket;

/**
 * Resolve the WebSocket constructor from the global scope at CALL time.
 *
 * Not at module load, for two reasons: importing this file must not explode in a runtime with no
 * WebSocket, and a test needs to be able to stub the global. The structural `RelaySocket` above keeps
 * this off lib.dom's `WebSocket` type, which React Native's global does not match exactly (its
 * `binaryType` is a two-value union and its events are React Native's own objects), so the two are
 * structurally compatible for this bearer's use but not unifiable by inference.
 */
function socketConstructor(): RelaySocketCtor {
  const scope: object = globalThis;
  if (!('WebSocket' in scope) || typeof scope.WebSocket !== 'function') {
    throw new Error('relay bearer: this runtime has no global WebSocket');
  }
  // Narrowed to a constructible function above; only its shape cannot be proven at runtime.
  const ctor = scope.WebSocket as unknown as RelaySocketCtor;
  return ctor;
}

/**
 * Bytes of one inbound frame, or null if the frame was not binary.
 *
 * `binaryType = 'arraybuffer'` makes React Native deliver an ArrayBuffer; the view branch covers
 * runtimes that hand back a typed array instead. A text frame returns null: relayd only ever writes
 * Message::Binary on this path, so a string is a protocol violation, and feeding its UTF-8 bytes to
 * the core as a packet would corrupt the session rather than fail visibly.
 */
function frameBytes(data: unknown): Uint8Array | null {
  if (data instanceof ArrayBuffer) {
    if (data.byteLength > 65536) return null;
    return new Uint8Array(data);
  }
  if (data instanceof Uint8Array) {
    if (data.byteLength > 65536) return null;
    return data;
  }
  if (ArrayBuffer.isView(data)) {
    if (data.byteLength > 65536) return null;
    return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  }
  return null;
}

/**
 * Dial `url` and bridge it to `node` as a bearer link.
 *
 * Resolves once the socket is open AND the core has the link up, so a resolved RelayLink means
 * packets can actually move. Rejects when the socket never opens, carrying the reason: a relay that
 * is not there has to be visible, not a spinner.
 *
 * Note what `up` does and does not mean. It means the socket is open and the core is driving the
 * link. It does NOT mean the Noise XX handshake completed or that the relay accepted this node,
 * because the bearer carries opaque bytes and cannot read the protocol. The only proof of that is a
 * message arriving.
 */
export async function connectRelay(
  node: HopNode,
  url: string,
  onState?: RelayStateListener,
): Promise<RelayLink> {
  const Socket = socketConstructor();
  const link = nextRelayLink;
  nextRelayLink += 1;

  let state: RelayState = 'connecting';
  let finished = false;
  let carrying = false;
  let dropped = 0;
  const inbound: Uint8Array[] = [];
  let inboundQueuedBytes = 0;
  const MAX_INBOUND_QUEUED_BYTES = 256 * 1024;

  const report = (next: RelayState, detail?: string): void => {
    if (state === next && detail === undefined) {
      return;
    }
    state = next;
    onState?.(next, detail);
  };

  let failOpen: ((error: Error) => void) | null = null;
  let markOpen: (() => void) | null = null;
  const opened = new Promise<void>((resolve, reject) => {
    markOpen = resolve;
    failOpen = reject;
  });

  const ws = new Socket(url);
  ws.binaryType = 'arraybuffer';

  let outgoing: Subscription | null = null;

  const timer = setTimeout(() => {
    void teardown(`no open within ${CONNECT_TIMEOUT_MS} ms`);
  }, CONNECT_TIMEOUT_MS);

  // The single exit. Every failure and every close funnels through here, so the core never keeps a
  // link whose socket is gone, and so `close()` is idempotent.
  function teardown(detail: string): Promise<void> {
    if (finished) {
      return Promise.resolve();
    }
    finished = true;
    clearTimeout(timer);
    outgoing?.remove();
    outgoing = null;
    try {
      ws.close();
    } catch {
      // Already gone. Closing a dead socket is not a failure worth surfacing.
    }
    inbound.length = 0;
    inboundQueuedBytes = 0;
    report('down', detail);
    // A no-op once `opened` has settled, which is exactly right: a drop after open is a state
    // transition, a drop before open is the reason connectRelay rejects.
    failOpen?.(new Error(`relay ${url}: ${detail}`));
    return carrying ? node.linkDown(link) : Promise.resolve();
  }

  // Inbound frames always queue and then drain here, so there is ONE place that hands bytes to the
  // core. Two invariants live in that: frames arriving before linkUp are held rather than dropped
  // (the core rejects bytes on a link it has not brought up, and losing the relay's first packet
  // stalls the handshake into a link that looks hung), and the bridge calls are issued in frame order
  // with nothing awaited between them, because reordered packets break the ratchet.
  function drain(): void {
    if (!carrying) {
      return;
    }
    for (const bytes of inbound) {
      node.bytesReceived(link, bytes).catch((e: unknown) => {
        report(state, `bytesReceived failed: ${String(e)}`);
      });
    }
    inbound.length = 0;
    inboundQueuedBytes = 0;
  }

  ws.onopen = () => {
    markOpen?.();
  };
  ws.onerror = (event) => {
    const message = event?.message;
    void teardown(message && message.length > 0 ? `socket error: ${message}` : 'socket error');
  };
  ws.onclose = (event) => {
    const code = event?.code;
    const reason = event?.reason;
    const why = code == null ? 'closed' : `closed (${code})`;
    void teardown(reason && reason.length > 0 ? `${why}: ${reason}` : why);
  };
  ws.onmessage = (event) => {
    const bytes = frameBytes(event?.data);
    if (bytes == null) {
      report(state, `rejected non-binary or oversized frame from ${url}`);
      void teardown('protocol violation: non-binary or oversized frame');
      return;
    }
    if (inboundQueuedBytes + bytes.byteLength > MAX_INBOUND_QUEUED_BYTES) {
      void teardown('inbound queue overflow');
      return;
    }
    inboundQueuedBytes += bytes.byteLength;
    inbound.push(bytes);
    drain();
  };

  // Subscribe BEFORE linkUp. The core can emit the handshake's first packet the instant the link is
  // up, and a subscription registered after that misses it, which surfaces later as a session that
  // never completes rather than as an obviously dropped packet.
  outgoing = node.onOutgoing((out) => {
    if (out.link !== link) {
      return;
    }
    if (finished) {
      dropped += 1;
      report(state, `dropped ${dropped} outbound packet(s): the link is down`);
      return;
    }
    try {
      // Exactly one binary frame carrying the packet's bytes and nothing else. React Native's send
      // honours a typed array's byteOffset, so no copy is needed here.
      ws.send(out.bytes);
    } catch (e: unknown) {
      dropped += 1;
      void teardown(`send failed, ${dropped} packet(s) dropped: ${String(e)}`);
    }
  });

  await opened;
  await node.linkUp(link, 'dialer');
  if (finished) {
    // The socket died while the core was bringing the link up. Take the link back down before
    // failing, or the core keeps driving a link with nothing behind it.
    await node.linkDown(link).catch(() => {});
    throw new Error(`relay ${url}: the link went down while coming up`);
  }
  carrying = true;
  clearTimeout(timer);
  drain();
  report('up');

  return {
    link,
    state: () => state,
    close: () => teardown('closed by the app'),
  };
}
