"use strict";

// Unit tests for the JS layer with a FAKE native module injected: they prove the argument marshalling
// (Uint8Array/string bodies -> base64, base58 addresses passed through, ids decoded back) and the pump
// event routing (node-scoped, decoded fields) without needing the React Native runtime or a real node.

const test = require("node:test");
const assert = require("node:assert/strict");

const { HopNode } = require("../lib/node.js");
const { toBase64, fromBase64, utf8ToBytes } = require("../lib/base64.js");
const { Hop, HopAddress } = require("../lib/index.js");
const { __setHopNativeForTesting } = require("../lib/native.js");

// A fake emitter that lets a test push events and records listeners.
function makeEmitter() {
  const listeners = new Map();
  return {
    addListener(event, cb) {
      const set = listeners.get(event) ?? new Set();
      set.add(cb);
      listeners.set(event, set);
      return { remove: () => set.delete(cb) };
    },
    emit(event, payload) {
      for (const cb of listeners.get(event) ?? []) cb(payload);
    },
  };
}

// A fake native module that records the last call per method and returns canned values.
function makeNative(overrides = {}) {
  const calls = [];
  const record = (name, args, result) => {
    calls.push({ name, args });
    return Promise.resolve(result);
  };
  const base = {
    calls,
    createEphemeral: () => record("createEphemeral", [], 7),
    createWithSecret: (s) => record("createWithSecret", [s], 8),
    openPersistent: (...a) => record("openPersistent", a, 9),
    openKeyed: (...a) => record("openKeyed", a, 10),
    closeNode: (...a) => record("closeNode", a, undefined),
    address: (...a) => record("address", a, "z6Mkexample"),
    secret: (...a) => record("secret", a, toBase64(new Uint8Array(32).fill(1))),
    setName: (...a) => record("setName", a, undefined),
    subscribe: (...a) => record("subscribe", a, undefined),
    publishPrekey: (...a) => record("publishPrekey", a, true),
    tick: (...a) => record("tick", a, undefined),
    isPersistent: (...a) => record("isPersistent", a, true),
    rehydrateDropped: (...a) => record("rehydrateDropped", a, 0),
    isSecured: (...a) => record("isSecured", a, false),
    send: (...a) => record("send", a, toBase64(new Uint8Array(32).fill(9))),
    sendTo: (...a) => record("sendTo", a, toBase64(new Uint8Array(32).fill(8))),
    status: (...a) => record("status", a, { relayed: 3, delivered: true, forwardHops: 4, forwardMs: 120 }),
    acceptInbox: (...a) => record("acceptInbox", a, true),
    sendServiceRequest: (...a) => record("sendServiceRequest", a, toBase64(new Uint8Array(32).fill(5))),
    sendServiceResponse: (...a) => record("sendServiceResponse", a, true),
    acceptServiceResponse: (...a) => record("acceptServiceResponse", a, true),
    startPump: (...a) => record("startPump", a, undefined),
    stopPump: (...a) => record("stopPump", a, undefined),
    linkUp: (...a) => record("linkUp", a, undefined),
    linkDown: (...a) => record("linkDown", a, undefined),
    bytesReceived: (...a) => record("bytesReceived", a, undefined),
    addressToBase58: (...a) => record("addressToBase58", a, "z6MkAddr"),
    addressFromBase58: (...a) => record("addressFromBase58", a, toBase64(new Uint8Array(32).fill(2))),
    addListener() {},
    removeListeners() {},
  };
  return Object.assign(base, overrides);
}

test("send encodes the body to base64, defaults the content type, and decodes the bundle id", async () => {
  const native = makeNative();
  const node = new HopNode(native, makeEmitter(), 7);
  const id = await node.send({ to: "z6MkDest", body: "hi mesh" });
  const call = native.calls.find((c) => c.name === "send");
  assert.deepEqual(call.args, [7, "z6MkDest", "text/plain", toBase64(utf8ToBytes("hi mesh")), false]);
  assert.deepEqual(Array.from(id), Array.from(new Uint8Array(32).fill(9)));
});

test("send passes an explicit content type, requestAck, and raw byte bodies", async () => {
  const native = makeNative();
  const node = new HopNode(native, makeEmitter(), 7);
  const body = new Uint8Array([1, 2, 3, 4]);
  await node.send({ to: "z6MkDest", contentType: "application/cbor", body, requestAck: true });
  const call = native.calls.find((c) => c.name === "send");
  assert.deepEqual(call.args, [7, "z6MkDest", "application/cbor", toBase64(body), true]);
});

test("send resolves null when the native side reports an error", async () => {
  const native = makeNative({ send: () => Promise.resolve(null) });
  const node = new HopNode(native, makeEmitter(), 7);
  assert.equal(await node.send({ to: "z6MkDest", body: "x" }), null);
});

test("status marshals the id and returns the structured status", async () => {
  const native = makeNative();
  const node = new HopNode(native, makeEmitter(), 7);
  const id = new Uint8Array(32).fill(9);
  const status = await node.status(id);
  assert.deepEqual(native.calls.at(-1), { name: "status", args: [7, toBase64(id)] });
  assert.deepEqual(status, { relayed: 3, delivered: true, forwardHops: 4, forwardMs: 120 });
});

test("service request/response marshalling", async () => {
  const native = makeNative();
  const node = new HopNode(native, makeEmitter(), 7);
  await node.sendServiceRequest({ to: "z6MkSvc", service: "echo", method: "GET", args: "ping" });
  assert.deepEqual(native.calls.at(-1).args, [7, "z6MkSvc", "echo", "GET", toBase64(utf8ToBytes("ping"))]);

  const reqId = new Uint8Array(32).fill(5);
  await node.sendServiceResponse({ to: "z6MkCaller", forRequestId: reqId, status: 200, body: "ok" });
  assert.deepEqual(native.calls.at(-1).args, [7, "z6MkCaller", toBase64(reqId), 200, toBase64(utf8ToBytes("ok"))]);
});

test("onMessage only fires for this node's handle and decodes the payload", async () => {
  const native = makeNative();
  const emitter = makeEmitter();
  const node = new HopNode(native, emitter, 7);
  const seen = [];
  node.onMessage((m) => seen.push(m));

  // Wrong node: ignored.
  emitter.emit("HopMesh:message", { node: 99, id: toBase64(new Uint8Array(32)), from: "z6X", contentType: "t", body: "", hops: 1, createdAt: 1 });
  // This node: delivered + decoded.
  emitter.emit("HopMesh:message", {
    node: 7,
    id: toBase64(new Uint8Array(32).fill(3)),
    from: "z6MkSender",
    contentType: "text/plain",
    body: toBase64(utf8ToBytes("hello")),
    hops: 5,
    createdAt: 1234,
  });

  assert.equal(seen.length, 1);
  assert.equal(seen[0].from, "z6MkSender");
  assert.equal(seen[0].hops, 5);
  assert.deepEqual(Array.from(seen[0].id), Array.from(new Uint8Array(32).fill(3)));
  assert.equal(Buffer.from(seen[0].body).toString("utf8"), "hello");
});

test("onOutgoing decodes packets for a JS bearer", async () => {
  const emitter = makeEmitter();
  const node = new HopNode(makeNative(), emitter, 7);
  const packets = [];
  node.onOutgoing((p) => packets.push(p));
  emitter.emit("HopMesh:outgoing", { node: 7, link: 42, bytes: toBase64(new Uint8Array([9, 8, 7])) });
  assert.equal(packets.length, 1);
  assert.equal(packets[0].link, 42);
  assert.deepEqual(Array.from(packets[0].bytes), [9, 8, 7]);
});

test("Hop.ephemeral and Hop.open build nodes over the injected native module", async () => {
  const native = makeNative();
  __setHopNativeForTesting(native, makeEmitter());
  try {
    const node = await Hop.ephemeral();
    assert.equal(node.handle, 7);

    const opened = await Hop.open({ dbPath: "/tmp/hop.db" });
    assert.equal(opened.handle, 9);
    assert.deepEqual(native.calls.find((c) => c.name === "openPersistent").args, ["/tmp/hop.db", "", ""]);

    const keyed = await Hop.open({ dbPath: "/tmp/hop.db", key: new Uint8Array(32).fill(4) });
    assert.equal(keyed.handle, 10);
  } finally {
    __setHopNativeForTesting(null);
  }
});

test("Hop.open resolves null on a negative handle (unusable db path)", async () => {
  __setHopNativeForTesting(makeNative({ openPersistent: () => Promise.resolve(-1) }), makeEmitter());
  try {
    assert.equal(await Hop.open({ dbPath: "/bad" }), null);
  } finally {
    __setHopNativeForTesting(null);
  }
});

test("HopAddress helpers marshal through the native module", async () => {
  const native = makeNative();
  __setHopNativeForTesting(native, makeEmitter());
  try {
    const b58 = await HopAddress.toBase58(new Uint8Array(32).fill(1));
    assert.equal(b58, "z6MkAddr");
    const bytes = await HopAddress.fromBase58("z6MkAddr");
    assert.deepEqual(Array.from(bytes), Array.from(new Uint8Array(32).fill(2)));
  } finally {
    __setHopNativeForTesting(null);
  }
});
