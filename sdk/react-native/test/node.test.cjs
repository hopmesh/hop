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
    relayAdd: (...a) => record("relayAdd", a, true),
    relayNext: (...a) => record("relayNext", a, "wss://relay.example/hop"),
    relayReport: (...a) => record("relayReport", a, undefined),
    relayPool: (...a) => record("relayPool", a, { total: 3, available: 1 }),
    // A channel's register resolves an EMPTY string, which is a success (no service signing key), so
    // the canned value here must be "" and not null; the two are asserted separately below.
    hpsRegister: (...a) => record("hpsRegister", a, ""),
    hpsSubscribe: (...a) => record("hpsSubscribe", a, toBase64(new Uint8Array(32).fill(11))),
    hpsPublish: (...a) => record("hpsPublish", a, toBase64(new Uint8Array(32).fill(12))),
    acceptHpsMessage: (...a) => record("acceptHpsMessage", a, true),
    hpsInvite: (...a) => record("hpsInvite", a, toBase64(new Uint8Array(32).fill(13))),
    hpsAcceptInvite: (...a) => record("hpsAcceptInvite", a, toBase64(new Uint8Array(32).fill(14))),
    hpsDeclineInvite: (...a) => record("hpsDeclineInvite", a, true),
    hpsLeave: (...a) => record("hpsLeave", a, true),
    hpsPending: (...a) => record("hpsPending", a, ["z6MkPend1", "z6MkPend2"]),
    hpsApprove: (...a) => record("hpsApprove", a, toBase64(new Uint8Array(32).fill(15))),
    hpsDeny: (...a) => record("hpsDeny", a, true),
    hpsRekey: (...a) =>
      record("hpsRekey", a, [toBase64(new Uint8Array(32).fill(16)), toBase64(new Uint8Array(32).fill(17))]),
    hpsReach: (...a) => record("hpsReach", a, 4),
    hpsMembers: (...a) => record("hpsMembers", a, ["z6MkMemberA"]),
    hpsMyTopics: (...a) =>
      record("hpsMyTopics", a, [
        { host: "z6MkHost", path: "town/square", kind: "channel", hosting: true, access: "requestToJoin" },
      ]),
    hpsBrowse: (...a) =>
      record("hpsBrowse", a, [
        {
          host: "z6MkHost",
          path: "news",
          kind: "service",
          title: "Town news",
          summary: "what happened",
          access: "open",
        },
      ]),
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

// ---- section 19 relay pool ----

test("relayAdd marks a caller-supplied endpoint configured unless told otherwise", async () => {
  const native = makeNative();
  const node = new HopNode(native, makeEmitter(), 7);
  await node.relayAdd("wss://relay.example/hop");
  assert.deepEqual(native.calls.at(-1), {
    name: "relayAdd",
    args: [7, "wss://relay.example/hop", true],
  });
  await node.relayAdd("wss://gossiped.example/hop", false);
  assert.deepEqual(native.calls.at(-1).args, [7, "wss://gossiped.example/hop", false]);
});

test("relayNext returns the URL to dial, and null when nothing is dialable", async () => {
  const node = new HopNode(makeNative(), makeEmitter(), 7);
  assert.equal(await node.relayNext(), "wss://relay.example/hop");

  // Nothing dialable. A UI must read this together with relayPool: a non-zero total here is
  // "everything is backed off", not "offline".
  const backedOff = makeNative({ relayNext: () => Promise.resolve(null) });
  const degraded = new HopNode(backedOff, makeEmitter(), 7);
  assert.equal(await degraded.relayNext(), null);
  assert.deepEqual(await degraded.relayPool(), { total: 3, available: 1 });
});

test("relayReport and relayPool marshal the handle and the dial outcome", async () => {
  const native = makeNative();
  const node = new HopNode(native, makeEmitter(), 7);
  await node.relayReport("wss://relay.example/hop", false);
  assert.deepEqual(native.calls.at(-1), {
    name: "relayReport",
    args: [7, "wss://relay.example/hop", false],
  });
  assert.deepEqual(await node.relayPool(), { total: 3, available: 1 });
});

// ---- hps:// pub/sub (section 32) ----

test("hpsRegister passes the enum strings through verbatim", async () => {
  const native = makeNative();
  const node = new HopNode(native, makeEmitter(), 7);
  await node.hpsRegister("town/square", "service", "requestToJoin", "discoverable");
  assert.deepEqual(native.calls.at(-1), {
    name: "hpsRegister",
    args: [7, "town/square", "service", "requestToJoin", "discoverable"],
  });

  // The defaults are the closed ones: an unspecified topic is Open-access but Private, never
  // advertised to the mesh by accident.
  await node.hpsRegister("town/square", "channel");
  assert.deepEqual(native.calls.at(-1).args, [7, "town/square", "channel", "open", "private"]);
});

test("hpsRegister distinguishes a channel's empty service key from a failed register", async () => {
  // A channel has no service signing key, so an EMPTY key is the correct successful answer.
  const channel = await new HopNode(makeNative(), makeEmitter(), 7).hpsRegister("town/square", "channel");
  assert.ok(channel instanceof Uint8Array, "a channel register must resolve bytes, not null");
  assert.equal(channel.length, 0);

  // Failure is null, and the two must not be confusable: a caller checking truthiness alone would
  // read a successful channel as a failure, which is why this asserts both shapes.
  const failed = await new HopNode(
    makeNative({ hpsRegister: () => Promise.resolve(null) }),
    makeEmitter(),
    7,
  ).hpsRegister("town/square", "channel");
  assert.equal(failed, null);

  // A service's real key still decodes to its bytes.
  const service = await new HopNode(
    makeNative({ hpsRegister: () => Promise.resolve(toBase64(new Uint8Array(32).fill(6))) }),
    makeEmitter(),
    7,
  ).hpsRegister("news", "service");
  assert.deepEqual(Array.from(service), Array.from(new Uint8Array(32).fill(6)));
});

test("hpsPublish encodes a string body to base64 and decodes the returned bundle id", async () => {
  const native = makeNative();
  const node = new HopNode(native, makeEmitter(), 7);
  const id = await node.hpsPublish("town/square", "hello channel");
  assert.deepEqual(native.calls.at(-1), {
    name: "hpsPublish",
    args: [7, "town/square", toBase64(utf8ToBytes("hello channel"))],
  });
  assert.deepEqual(Array.from(id), Array.from(new Uint8Array(32).fill(12)));

  // Raw bytes go through untouched.
  await node.hpsPublish("town/square", new Uint8Array([1, 2, 3]));
  assert.deepEqual(native.calls.at(-1).args, [7, "town/square", toBase64(new Uint8Array([1, 2, 3]))]);
});

test("hpsSubscribe, invite, accept and approve decode their bundle ids", async () => {
  const native = makeNative();
  const node = new HopNode(native, makeEmitter(), 7);

  const subscribed = await node.hpsSubscribe("z6MkHost", "town/square");
  assert.deepEqual(native.calls.at(-1).args, [7, "z6MkHost", "town/square"]);
  assert.deepEqual(Array.from(subscribed), Array.from(new Uint8Array(32).fill(11)));

  const invited = await node.hpsInvite("town/square", "z6MkGuest");
  assert.deepEqual(native.calls.at(-1).args, [7, "town/square", "z6MkGuest"]);
  assert.deepEqual(Array.from(invited), Array.from(new Uint8Array(32).fill(13)));

  const accepted = await node.hpsAcceptInvite("z6MkHost", "town/square");
  assert.deepEqual(native.calls.at(-1).args, [7, "z6MkHost", "town/square"]);
  assert.deepEqual(Array.from(accepted), Array.from(new Uint8Array(32).fill(14)));

  const approved = await node.hpsApprove("town/square", "z6MkPend1");
  assert.deepEqual(native.calls.at(-1).args, [7, "town/square", "z6MkPend1"]);
  assert.deepEqual(Array.from(approved), Array.from(new Uint8Array(32).fill(15)));
});

test("the boolean hps calls marshal their arguments and pass the result through", async () => {
  const native = makeNative();
  const node = new HopNode(native, makeEmitter(), 7);

  const id = new Uint8Array(32).fill(3);
  assert.equal(await node.acceptHpsMessage(id), true);
  assert.deepEqual(native.calls.at(-1), { name: "acceptHpsMessage", args: [7, toBase64(id)] });

  assert.equal(await node.hpsDeclineInvite("z6MkHost", "town/square"), true);
  assert.deepEqual(native.calls.at(-1).args, [7, "z6MkHost", "town/square"]);

  assert.equal(await node.hpsDeny("town/square", "z6MkPend2"), true);
  assert.deepEqual(native.calls.at(-1).args, [7, "town/square", "z6MkPend2"]);

  // hpsLeave narrows the native (ok, id) pair to just ok on purpose.
  assert.equal(await node.hpsLeave("town/square"), true);
  assert.deepEqual(native.calls.at(-1), { name: "hpsLeave", args: [7, "town/square"] });
});

test("every hps call that resolves a bundle id resolves null when the native side fails", async () => {
  // Each of these decodes base64 on success. A wrapper that forgot the null check would throw inside
  // fromBase64 instead of resolving null, so the failure path needs asserting per call, not once.
  const failing = makeNative({
    hpsSubscribe: () => Promise.resolve(null),
    hpsPublish: () => Promise.resolve(null),
    hpsInvite: () => Promise.resolve(null),
    hpsAcceptInvite: () => Promise.resolve(null),
    hpsApprove: () => Promise.resolve(null),
  });
  const node = new HopNode(failing, makeEmitter(), 7);

  assert.equal(await node.hpsSubscribe("z6MkHost", "town/square"), null);
  assert.equal(await node.hpsPublish("town/square", "dropped"), null);
  assert.equal(await node.hpsInvite("town/square", "z6MkGuest"), null);
  assert.equal(await node.hpsAcceptInvite("z6MkHost", "town/square"), null);
  assert.equal(await node.hpsApprove("town/square", "z6MkPend1"), null);
});

test("hpsRekey marshals the base58 remove list and decodes the returned ids", async () => {
  const native = makeNative();
  const node = new HopNode(native, makeEmitter(), 7);

  const ids = await node.hpsRekey("town/square", "", ["z6MkGone1", "z6MkGone2"]);
  assert.deepEqual(native.calls.at(-1), {
    name: "hpsRekey",
    args: [7, "town/square", "", ["z6MkGone1", "z6MkGone2"]],
  });
  assert.equal(ids.length, 2);
  assert.deepEqual(Array.from(ids[0]), Array.from(new Uint8Array(32).fill(16)));
  assert.deepEqual(Array.from(ids[1]), Array.from(new Uint8Array(32).fill(17)));

  // A plain rotation removes nobody and keeps the path.
  await node.hpsRekey("town/square");
  assert.deepEqual(native.calls.at(-1).args, [7, "town/square", "", []]);
});

test("the hps read calls surface addresses as base58 and counts as numbers", async () => {
  const native = makeNative();
  const node = new HopNode(native, makeEmitter(), 7);

  assert.deepEqual(await node.hpsPending("town/square"), ["z6MkPend1", "z6MkPend2"]);
  assert.deepEqual(native.calls.at(-1), { name: "hpsPending", args: [7, "town/square"] });

  assert.deepEqual(await node.hpsMembers("town/square"), ["z6MkMemberA"]);
  assert.equal(await node.hpsReach("town/square"), 4);
  assert.deepEqual(native.calls.at(-1), { name: "hpsReach", args: [7, "town/square"] });
});

test("hpsMyTopics and hpsBrowse carry the enum strings through to the public unions", async () => {
  const native = makeNative();
  const node = new HopNode(native, makeEmitter(), 7);

  assert.deepEqual(await node.hpsMyTopics(), [
    { host: "z6MkHost", path: "town/square", kind: "channel", hosting: true, access: "requestToJoin" },
  ]);
  assert.deepEqual(native.calls.at(-1), { name: "hpsMyTopics", args: [7] });

  assert.deepEqual(await node.hpsBrowse(), [
    {
      host: "z6MkHost",
      path: "news",
      kind: "service",
      title: "Town news",
      summary: "what happened",
      access: "open",
    },
  ]);

  // An access mode the union does not contain is NOT rewritten to "open". It stays unrecognized, so a
  // UI gating on "open" cannot be tricked into showing a gated topic as an open one.
  const garbage = makeNative({
    hpsMyTopics: () =>
      Promise.resolve([
        { host: "z6MkHost", path: "town/square", kind: "channel", hosting: false, access: "wide-open" },
      ]),
  });
  const topics = await new HopNode(garbage, makeEmitter(), 7).hpsMyTopics();
  assert.equal(topics[0].access, "wide-open");
  assert.notEqual(topics[0].access, "open");
});

test("onHpsMessage only fires for this node's handle and decodes id and body to bytes", async () => {
  const emitter = makeEmitter();
  const node = new HopNode(makeNative(), emitter, 7);
  const seen = [];
  node.onHpsMessage((m) => seen.push(m));

  // Another node's publication on the same emitter: ignored.
  emitter.emit("HopMesh:hpsMessage", {
    node: 99,
    id: toBase64(new Uint8Array(32).fill(1)),
    path: "other/topic",
    sender: "z6MkStranger",
    body: toBase64(utf8ToBytes("not ours")),
  });
  emitter.emit("HopMesh:hpsMessage", {
    node: 7,
    id: toBase64(new Uint8Array(32).fill(3)),
    path: "town/square",
    sender: "z6MkWriter",
    body: toBase64(utf8ToBytes("hello channel")),
  });

  assert.equal(seen.length, 1);
  assert.equal(seen[0].path, "town/square");
  // The writer stays a base58 string; only id and body are binary.
  assert.equal(seen[0].sender, "z6MkWriter");
  assert.deepEqual(Array.from(seen[0].id), Array.from(new Uint8Array(32).fill(3)));
  assert.equal(Buffer.from(seen[0].body).toString("utf8"), "hello channel");
});

test("onHpsInvite decodes its payload and is node-scoped", async () => {
  const emitter = makeEmitter();
  const node = new HopNode(makeNative(), emitter, 7);
  const invites = [];
  node.onHpsInvite((i) => invites.push(i));

  emitter.emit("HopMesh:hpsInvite", { node: 99, host: "z6MkOther", path: "other/topic", kind: "service" });
  emitter.emit("HopMesh:hpsInvite", { node: 7, host: "z6MkHost", path: "town/square", kind: "channel" });

  assert.equal(invites.length, 1);
  assert.deepEqual(invites[0], { host: "z6MkHost", path: "town/square", kind: "channel" });
});

test("hostile repro audit-013: node rejects invalid link, tick, and status numbers", async () => {
  const native = makeNative();
  const node = new HopNode(native, makeEmitter(), 7);

  await assert.rejects(() => node.linkUp(NaN, "dialer"), RangeError);
  await assert.rejects(() => node.linkUp(Infinity, "dialer"), RangeError);
  await assert.rejects(() => node.linkUp(-1, "dialer"), RangeError);
  await assert.rejects(() => node.linkUp(1.5, "dialer"), RangeError);
  await assert.rejects(() => node.linkUp(Number.MAX_SAFE_INTEGER + 100, "dialer"), RangeError);

  await assert.rejects(() => node.tick(NaN), RangeError);
  await assert.rejects(() => node.tick(-1), RangeError);

  await assert.rejects(() => node.sendServiceResponse({
    to: "z6Mkmz...",
    forRequestId: new Uint8Array(32),
    status: 65536,
    body: "test",
  }), RangeError);
});
