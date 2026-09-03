// What this test is for: the relay bearer's whole job is framing, and framing is the one thing that
// fails invisibly. A stray length prefix or a coalesced write does not throw; the relay just drops the
// link during the Noise handshake, and that reads as a crypto bug on a phone. So the wire behaviour is
// pinned here, with no hardware, against a fake socket and a fake node.
//
// It asserts exactly what services/hop-relayd's own test asserts from the other side
// (serve_ws_upgrade_bridges_binary_frames_both_ways_and_reports_down): one core packet is exactly one
// binary frame, verbatim in both directions, and a close reports the link down.
//
// It does NOT prove two devices exchanged a message. Nothing here touches a relay or a radio.

import type {HopNode, HopOutgoing} from '@hop-mesh/react-native';
import {connectRelay, RelayState} from '../src/relayBearer';

type SocketEvent = {data: unknown};

// The fake socket. Nothing is driven by time: the test fires onopen / onmessage / onclose itself, so
// the assertions are about the bearer's behaviour rather than about a scheduler.
class FakeSocket {
  static last: FakeSocket | null = null;

  binaryType = '';
  closes = 0;
  readonly sent: unknown[] = [];
  onopen: (() => void) | null = null;
  onclose: ((event: {code?: number; reason?: string}) => void) | null = null;
  onerror: ((event: {message?: string}) => void) | null = null;
  onmessage: ((event: SocketEvent) => void) | null = null;

  constructor(readonly url: string) {
    FakeSocket.last = this;
  }

  send(data: unknown): void {
    this.sent.push(data);
  }

  close(): void {
    this.closes += 1;
  }
}

class FakeNode {
  readonly linkUps: Array<{link: number; role: string}> = [];
  readonly linkDowns: number[] = [];
  readonly received: Array<{link: number; bytes: Uint8Array}> = [];
  private listeners: Array<(out: HopOutgoing) => void> = [];

  linkUp(link: number, role: string): Promise<void> {
    this.linkUps.push({link, role});
    return Promise.resolve();
  }

  linkDown(link: number): Promise<void> {
    this.linkDowns.push(link);
    return Promise.resolve();
  }

  bytesReceived(link: number, bytes: Uint8Array): Promise<void> {
    this.received.push({link, bytes});
    return Promise.resolve();
  }

  onOutgoing(cb: (out: HopOutgoing) => void): {remove(): void} {
    this.listeners.push(cb);
    return {
      remove: () => {
        this.listeners = this.listeners.filter((l) => l !== cb);
      },
    };
  }

  /** Emit what the core's pump would emit. Returns how many subscribers saw it. */
  emitOutgoing(out: HopOutgoing): number {
    const seen = this.listeners.length;
    for (const l of [...this.listeners]) {
      l(out);
    }
    return seen;
  }
}

// The bearer resolves `globalThis.WebSocket` per call, which is the seam this test uses.
const realWebSocket = (globalThis as Record<string, unknown>).WebSocket;

function installFakeSocket(): void {
  (globalThis as Record<string, unknown>).WebSocket = FakeSocket;
}

beforeEach(() => {
  FakeSocket.last = null;
  installFakeSocket();
});

afterEach(() => {
  (globalThis as Record<string, unknown>).WebSocket = realWebSocket;
  jest.useRealTimers();
});

/** Dial, let the socket open, and hand back the pieces. */
async function dial(url = 'ws://relay.test:8080/') {
  const node = new FakeNode();
  const states: Array<{state: RelayState; detail?: string}> = [];
  const pending = connectRelay(node as unknown as HopNode, url, (state, detail) =>
    states.push({state, detail}),
  );
  // The socket is constructed synchronously, before connectRelay's first await.
  const socket = FakeSocket.last;
  if (socket == null) {
    throw new Error('connectRelay did not construct a socket');
  }
  socket.onopen?.();
  const relay = await pending;
  return {node, socket, relay, states};
}

test('the fake socket is actually the one under test', () => {
  // Without this, a botched global stub would make every assertion below vacuous: the bearer would
  // build a real WebSocket, the test would time out or pass on nothing.
  expect((globalThis as Record<string, unknown>).WebSocket).toBe(FakeSocket);
});

test('opening brings the core link up as the dialer and reports up', async () => {
  const {node, socket, relay, states} = await dial();

  expect(socket.url).toBe('ws://relay.test:8080/');
  // Inbound frames must arrive as bytes now, not as a Blob needing an async read that would reorder.
  expect(socket.binaryType).toBe('arraybuffer');
  expect(node.linkUps).toEqual([{link: relay.link, role: 'dialer'}]);
  expect(relay.state()).toBe('up');
  expect(states.map((s) => s.state)).toEqual(['up']);
});

test('an outgoing packet becomes exactly one binary frame, byte for byte, with no header', async () => {
  const {node, socket, relay} = await dial();

  const packet = new Uint8Array([0x00, 0x01, 0xfe, 0xff, 0x41]);
  expect(node.emitOutgoing({link: relay.link, bytes: packet})).toBe(1);

  // One packet in, one frame out. Not two writes, not a coalesced buffer.
  expect(socket.sent).toHaveLength(1);
  const frame = socket.sent[0];
  if (!(frame instanceof Uint8Array)) {
    throw new Error(`frame is not bytes: ${Object.prototype.toString.call(frame)}`);
  }
  // Length equality is the header assertion: a 4-byte length prefix, a 1-byte type tag or any other
  // envelope would make this longer than the packet.
  expect(frame.byteLength).toBe(packet.byteLength);
  expect([...frame]).toEqual([...packet]);
});

test('packets for another link are not written to this socket', async () => {
  const {node, socket, relay} = await dial();

  node.emitOutgoing({link: relay.link + 7, bytes: new Uint8Array([9, 9, 9])});

  // The loopback bearer shares the same node and its own link id. Cross-writing would corrupt both.
  expect(socket.sent).toEqual([]);
});

test('an inbound frame becomes exactly one bytesReceived with the same bytes', async () => {
  const {node, socket, relay} = await dial();

  const payload = new Uint8Array([0x7f, 0x00, 0x80, 0xff]);
  socket.onmessage?.({data: payload.buffer});

  expect(node.received).toHaveLength(1);
  expect(node.received[0].link).toBe(relay.link);
  expect(node.received[0].bytes.byteLength).toBe(payload.byteLength);
  expect([...node.received[0].bytes]).toEqual([...payload]);
});

test('inbound frames are delivered in arrival order', async () => {
  const {node, socket} = await dial();

  socket.onmessage?.({data: new Uint8Array([1]).buffer});
  socket.onmessage?.({data: new Uint8Array([2]).buffer});
  socket.onmessage?.({data: new Uint8Array([3]).buffer});

  // Reordered packets break the ratchet, and the bearer awaits nothing between bridge calls.
  expect(node.received.map((r) => [...r.bytes])).toEqual([[1], [2], [3]]);
});

test('a text frame is refused rather than fed to the core as a packet', async () => {
  const {node, socket, states} = await dial();

  socket.onmessage?.({data: 'not-a-binary-frame'});

  // Handing those UTF-8 bytes to the core would corrupt the session instead of failing visibly.
  expect(node.received).toEqual([]);
  expect(states.some((s) => (s.detail ?? '').includes('non-binary'))).toBe(true);
});

test('a close takes the core link down and reports state down', async () => {
  const {node, socket, relay, states} = await dial();

  socket.onclose?.({code: 1006, reason: 'relay went away'});
  await Promise.resolve();

  expect(node.linkDowns).toEqual([relay.link]);
  expect(relay.state()).toBe('down');
  const last = states[states.length - 1];
  expect(last.state).toBe('down');
  expect(last.detail).toContain('1006');
  expect(last.detail).toContain('relay went away');
});

test('a send attempted after the link is down is reported, never dropped quietly', async () => {
  const {node, socket, relay, states} = await dial();

  socket.onclose?.({code: 1001});
  await Promise.resolve();
  // The subscription is removed on teardown, so nothing reaches the socket. Prove that rather than
  // assume it: a write to a dead socket must not look like a successful send.
  const delivered = node.emitOutgoing({link: relay.link, bytes: new Uint8Array([1, 2, 3])});

  expect(delivered).toBe(0);
  expect(socket.sent).toEqual([]);
  expect(states[states.length - 1].state).toBe('down');
});

test('close is idempotent and does not take the link down twice', async () => {
  const {node, socket, relay} = await dial();

  await relay.close();
  await relay.close();

  expect(node.linkDowns).toEqual([relay.link]);
  expect(socket.closes).toBe(1);
  expect(relay.state()).toBe('down');
});

test('a frame that arrives before linkUp resolves is held, not dropped', async () => {
  const node = new FakeNode();
  // A gate the test opens by hand, so the window between linkUp being called and resolving is real
  // rather than a matter of scheduling luck. Initialised to a no-op because control-flow analysis
  // cannot see an assignment made inside a promise executor.
  let releaseLinkUp = (): void => {};
  const linkUpGate = new Promise<void>((resolve) => {
    releaseLinkUp = resolve;
  });
  node.linkUp = (link: number, role: string) => {
    node.linkUps.push({link, role});
    return linkUpGate;
  };

  const pending = connectRelay(node as unknown as HopNode, 'ws://relay.test:8080/');
  const socket = FakeSocket.last;
  if (socket == null) {
    throw new Error('connectRelay did not construct a socket');
  }
  socket.onopen?.();
  await Promise.resolve();
  await Promise.resolve();

  socket.onmessage?.({data: new Uint8Array([0xa1, 0xa2]).buffer});
  // The core rejects bytes on a link it has not brought up, so this frame must wait rather than be
  // handed over early and lost. Losing the relay's first packet stalls the Noise handshake.
  expect(node.received).toEqual([]);

  expect(node.linkUps).toHaveLength(1);
  releaseLinkUp();
  const relay = await pending;

  expect(node.received).toHaveLength(1);
  expect([...node.received[0].bytes]).toEqual([0xa1, 0xa2]);
  expect(relay.state()).toBe('up');
});

test('a socket that errors before opening rejects with the reason', async () => {
  const node = new FakeNode();
  const states: RelayState[] = [];
  const pending = connectRelay(node as unknown as HopNode, 'ws://dead.test:8080/', (state) =>
    states.push(state),
  );
  const socket = FakeSocket.last;
  if (socket == null) {
    throw new Error('connectRelay did not construct a socket');
  }
  socket.onerror?.({message: 'connection refused'});

  // A relay that is not there has to be visible. A pending promise here is the spinner-forever bug.
  await expect(pending).rejects.toThrow(/connection refused/);
  expect(states).toContain('down');
  // linkUp never resolved, so there is no link to take down.
  expect(node.linkDowns).toEqual([]);
});

test('a socket that never opens times out rather than hanging', async () => {
  jest.useFakeTimers();
  const node = new FakeNode();
  const pending = connectRelay(node as unknown as HopNode, 'ws://silent.test:8080/');
  const socket = FakeSocket.last;
  if (socket == null) {
    throw new Error('connectRelay did not construct a socket');
  }

  jest.advanceTimersByTime(10_000);

  await expect(pending).rejects.toThrow(/no open within/);
  expect(socket.closes).toBe(1);
});

test('each link gets its own id', async () => {
  const first = await dial();
  const second = await dial();

  // Two bearers sharing a core link id silently corrupts session state.
  expect(second.relay.link).not.toBe(first.relay.link);
});
