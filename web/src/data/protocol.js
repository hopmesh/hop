// The Hop protocol by layer. Each entry gets its own page at /docs/<id>/ and a
// row on the /docs/ overview. Grouped: Semantics (above the waist), Waist
// (the datagram substrate), Bearer (below). `ref` points into DESIGN.md.
export const DESIGN = 'https://github.com/hopmesh/hop/blob/main/DESIGN.md';

export const layers = [
  {
    id: 'hops', name: 'hops://', mono: true, group: 'Semantics', ref: '§30',
    tagline: 'HTTP over the mesh',
    body: "The same request/response semantics as HTTP, carried as sealed datagrams. An operator runs a <code>hop-endpoint</code> for their own domain — it <em>is</em> the origin, never an open proxy — so there's no man-in-the-middle.",
  },
  {
    id: 'hps', name: 'hps://', mono: true, group: 'Semantics', ref: '§32',
    tagline: 'Pub/sub — services and channels',
    body: "Topic-based broadcast and discovery over the same fabric, region-aware so a topic never ships to a region with no subscribers.",
  },
  {
    id: 'streams', name: 'Carrier transport &amp; streams', mono: false, group: 'Semantics', ref: '§31',
    tagline: 'Reliable, ordered, delay-tolerant delivery',
    body: "Large payloads split into ordered sealed chunks and reassemble into one bundle; genuinely open-ended data rides progressive streams, resumable after a gap. Also the home of the set-reconciliation (anti-entropy) primitive.",
  },
  {
    id: 'hns', name: 'HNS', mono: false, group: 'Semantics', ref: '§30',
    tagline: 'The Hop Name System',
    body: "Resolve a domain to an address via a DNSSEC-signed TXT record. No central resolver: a query walks the mesh until a node can answer, and the client verifies the DNSSEC chain itself — any node may resolve, none can lie.",
  },
  {
    id: 'hdp', name: 'hdp://', mono: true, group: 'Waist', ref: '§30 · §31',
    tagline: 'The datagram substrate — all traffic rides this',
    body: "The Hop Datagram Protocol. A connectionless, end-to-end encrypted, addressed datagram that's store-and-forwarded across the mesh: held when there's no onward path, never dropped. Everything above is built on it.",
  },
  {
    id: 'ble', name: 'Bluetooth LE', mono: false, group: 'Bearer', ref: '§11 · §22',
    tagline: 'The primary bearer',
    body: "GATT carries control; the link layer handles background discovery and beaconing within the platform's constraints. Each bundle is fragmented to the BLE MTU and reassembled at the next hop.",
  },
  {
    id: 'l2cap', name: 'L2CAP CoC', mono: false, group: 'Bearer', ref: '§11',
    tagline: 'Connection-oriented channels for bulk transfer',
    body: "Large payloads ride L2CAP CoC rather than GATT notifications, with bounded SDU sizes handled by the carrier transport.",
  },
  {
    id: 'tcp', name: 'TCP / WebSocket', mono: false, group: 'Bearer', ref: '§21 · §26',
    tagline: 'The internet bearer',
    body: "Devices reach the cloud backbone over WebSocket at a single anycast name that routes to the nearest region; relays peer over the internet to bridge Bluetooth islands across the world.",
  },
  {
    id: 'bearers', name: 'Pluggable bearers', mono: false, group: 'Bearer', ref: '§26',
    tagline: 'The bearer is the only thing that changes',
    body: "Bluetooth LE ships first; Wi-Fi Aware, MultipeerConnectivity, and LoRa fit the same interface — the core above is unchanged.",
  },
];

export const groups = ['Semantics', 'Waist', 'Bearer'];
