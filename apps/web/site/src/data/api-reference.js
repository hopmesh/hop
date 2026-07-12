// Unified interface reference. The point isn't per-language doc dumps, it's the SAME
// flows across languages, where the code is nearly identical because the driver does
// the platform work (discovery, connections, background, power) behind the scenes.
// These are seeded by hand now; the intent is to GENERATE them from the C ABI
// (sdk/hop.h) and its language wrappers so they track the real API, then weave
// in per-language notes. Shape: each flow has one shared description + a snippet per
// language. Add languages to `apiLangs` and a matching key to each `samples`.
const S = 'var(--tok-str)', K = 'var(--tok-kw)', C = 'var(--tok-comment)';
const s = (x) => `<span style="color:${S}">${x}</span>`;
const k = (x) => `<span style="color:${K}">${x}</span>`;

export const apiLangs = [
  { id: 'rust', label: 'Rust' },
  { id: 'swift', label: 'Swift' },
  { id: 'objc', label: 'Objective-C' },
  { id: 'kotlin', label: 'Kotlin' },
  { id: 'java', label: 'Java' },
];

export const apiFlows = [
  {
    id: 'open',
    title: 'Open a node',
    desc: 'Open a node from your 32-byte secret. The driver owns key storage and the radios, you just hand it the key, and the secret is the address.',
    samples: {
      rust: `${k('let')} node = HopNode::open(secret)?;`,
      swift: `${k('let')} node = ${k('try')} HopNode(secret: secret)`,
      objc: `HopNode *node = [HopNode openWithSecret:secret error:&err];`,
      kotlin: `${k('val')} node = HopNode.open(secret)`,
      java: `HopNode node = HopNode.open(secret);`,
    },
  },
  {
    id: 'send-device',
    title: 'Send to a device',
    desc: 'Address a sealed payload to another device by its public key. You don\'t pick a route or a bearer, the driver relays it across whatever it has.',
    samples: {
      rust: `node.send(Destination::device(peer), Payload::message(${s('"on my way"')}))?;`,
      swift: `${k('try')} node.send(to: .device(peer), payload: .message(${s('"on my way"')}))`,
      objc: `[node sendTo:[Destination device:peer] payload:[Payload message:${s('@"on my way"')}] error:&err];`,
      kotlin: `node.send(Destination.device(peer), Payload.message(${s('"on my way"')}))`,
      java: `node.send(Destination.device(peer), Payload.message(${s('"on my way"')}));`,
    },
  },
  {
    id: 'send-internet',
    title: 'Reach the internet from offline',
    desc: 'Egress is a hops:// service request addressed to an endpoint node by its key: it fetches the URL and the sealed response routes back to your key. You still pick no route or bearer.',
    samples: {
      rust: `node.send_service_request(endpoint, ${s('"http"')}, ${s('"get"')}, ${s('b"hops://example.com/status"')})?;`,
      swift: `${k('try')} node.sendServiceRequest(to: endpoint, service: ${s('"http"')}, method: ${s('"get"')}, args: ${s('"hops://example.com/status"')})`,
      objc: `[node sendServiceRequestTo:endpoint service:${s('@"http"')} method:${s('@"get"')} args:${s('@"hops://example.com/status"')} error:&err];`,
      kotlin: `node.sendServiceRequest(endpoint, ${s('"http"')}, ${s('"get"')}, ${s('"hops://example.com/status"')})`,
      java: `node.sendServiceRequest(endpoint, ${s('"http"')}, ${s('"get"')}, ${s('"hops://example.com/status"')});`,
    },
  },
  {
    id: 'receive',
    title: 'Receive',
    desc: 'Drain your inbox of sealed bundles addressed to you, and open them. Delivery acknowledgements and dedup are handled for you.',
    samples: {
      rust: `${k('for')} msg ${k('in')} node.receive()? { handle(msg.open()?); }`,
      swift: `${k('for')} msg ${k('in')} ${k('try')} node.receive() { handle(${k('try')} msg.open()) }`,
      objc: `${k('for')} (Message *msg ${k('in')} [node receiveAndReturnError:&err]) handle([msg openAndReturnError:&err]);`,
      kotlin: `${k('for')} (msg ${k('in')} node.receive()) handle(msg.open())`,
      java: `${k('for')} (Message msg : node.receive()) handle(msg.open());`,
    },
  },
  {
    id: 'subscribe',
    title: 'Subscribe to a topic',
    desc: 'Join a pub/sub topic and receive whatever is published to it across the mesh, one-to-many, region-aware, the same on every platform.',
    samples: {
      rust: `node.subscribe(${s('"alerts/region-4"')})?;`,
      swift: `${k('try')} node.subscribe(${s('"alerts/region-4"')})`,
      objc: `[node subscribe:${s('@"alerts/region-4"')} error:&err];`,
      kotlin: `node.subscribe(${s('"alerts/region-4"')})`,
      java: `node.subscribe(${s('"alerts/region-4"')});`,
    },
  },
];
