// The Hop protocol by layer. Each entry gets its own page at /protocol/<id>/ and
// a row on the /protocol/ overview. Grouped: Semantics (above the waist), Waist
// (the datagram substrate), Bearer (below). `ref` points into DESIGN.md for the
// implementation detail. `viz` drives the per-layer diagram (see ProtocolDiagram).
export const DESIGN = 'https://github.com/hopmesh/hop/blob/main/DESIGN.md';

export const layers = [
  {
    id: 'hops', name: 'hops://', mono: true, group: 'Semantics', ref: '§30',
    tagline: 'HTTP over the mesh',
    body: "The same request/response semantics as HTTP, carried as sealed datagrams. An operator runs a <code>hop-endpoint</code> for their own domain — it <em>is</em> the origin, never an open proxy — so there's no man-in-the-middle.",
    viz: {
      caption: "An HTTP request is sealed and hops to the operator's own hop-endpoint — which is the origin, never an open proxy. It answers, and the sealed response returns the same way.",
      nodes: { c:{type:'you',x:90,y:150,label:'client'}, r:{type:'relay',x:320,y:150,label:'relay'}, e:{type:'endpoint',x:545,y:150,label:'hop-endpoint'} },
      edges: [['c','r'],['r','e']],
      routes: [['c','r','e']], return: true,
      notes: [{x:545,y:150,t:'the origin',tone:'deliv'}],
    },
  },
  {
    id: 'hps', name: 'hps://', mono: true, group: 'Semantics', ref: '§32',
    tagline: 'Pub/sub — services and channels',
    body: "Topic-based broadcast and discovery over the same fabric, region-aware so a topic never ships to a region with no subscribers.",
    viz: {
      caption: "A topic fans out only to regions with live subscribers. Empty regions are skipped — you never pay to ship where no one is listening.",
      nodes: { p:{type:'you',x:80,y:150,label:'publisher'}, h:{type:'relay',x:285,y:150,label:'topic'}, a:{type:'cloud',x:520,y:82,glyph:'region A'}, b:{type:'cloud',x:520,y:225,glyph:'region B',dim:true} },
      edges: [['p','h'],['h','a'],['h','b','dead']],
      routes: [['p','h','a']],
      notes: [{x:520,y:82,t:'subscribers ✓',tone:'deliv'},{x:520,y:225,t:'none — skipped',tone:'held'}],
    },
  },
  {
    id: 'streams', name: 'Carrier transport &amp; streams', mono: false, group: 'Semantics', ref: '§31',
    tagline: 'Reliable, ordered, delay-tolerant delivery',
    body: "Large payloads split into ordered sealed chunks and reassemble into one bundle; genuinely open-ended data rides progressive streams, resumable after a gap. Also the home of the set-reconciliation (anti-entropy) primitive.",
    viz: {
      caption: "A large payload is split into ordered, individually-sealed chunks and reassembled into one bundle on the far side — resumable after a gap.",
      nodes: { a:{type:'you',x:90,y:150,label:'sender'}, ch:{type:'chunks',x:320,y:150}, b:{type:'dest',x:545,y:150,label:'recipient'} },
      edges: [['a','ch'],['ch','b']],
      routes: [['a','ch','b']],
      notes: [{x:320,y:108,t:'ordered, sealed chunks',tone:'transit'}],
    },
  },
  {
    id: 'hns', name: 'HNS', mono: false, group: 'Semantics', ref: '§30',
    tagline: 'The Hop Name System',
    body: "Resolve a domain to an address via a DNSSEC-signed TXT record. No central resolver: a query walks the mesh until a node can answer, and the client verifies the DNSSEC chain itself — any node may resolve, none can lie.",
    viz: {
      caption: "A name query walks the mesh until a node can answer with a DNSSEC-signed record; the client verifies the chain itself. Any node may resolve — none can lie.",
      nodes: { c:{type:'you',x:90,y:150,label:'query'}, n1:{type:'relay',x:300,y:88,label:'node'}, n2:{type:'relay',x:300,y:212,label:'node'}, ans:{type:'dest',x:545,y:150,label:'answers'} },
      edges: [['c','n1'],['c','n2'],['n1','ans'],['n2','ans']],
      routes: [['c','n1','ans']],
      notes: [{x:545,y:150,t:'DNSSEC TXT ✓',tone:'deliv'}],
    },
  },
  {
    id: 'hdp', name: 'hdp://', mono: true, group: 'Waist', ref: '§30 · §31',
    tagline: 'The datagram substrate — all traffic rides this',
    body: "The Hop Datagram Protocol. A connectionless, end-to-end encrypted, addressed datagram that's store-and-forwarded across the mesh: held when there's no onward path, never dropped. Everything above is built on it.",
    viz: {
      caption: "A sealed, addressed datagram. When there's no onward path it's held at a relay, then forwarded the moment one appears. Held, never dropped.",
      nodes: { a:{type:'you',x:90,y:150,label:'sender'}, r:{type:'relay',x:320,y:150,label:'relay'}, b:{type:'dest',x:545,y:150,label:'recipient'} },
      edges: [['a','r'],['r','b']],
      routes: [['a','r','b']],
      notes: [{x:320,y:108,t:'◷ held',tone:'held'},{x:545,y:150,t:'✓ delivered',tone:'deliv'}],
    },
  },
  {
    id: 'ble', name: 'Bluetooth LE', mono: false, group: 'Bearer', ref: '§11 · §22',
    tagline: 'The primary bearer',
    body: "GATT carries control; the link layer handles background discovery and beaconing within the platform's constraints. Each bundle is fragmented to the BLE MTU and reassembled at the next hop.",
    viz: {
      caption: "Each bundle is fragmented to the Bluetooth LE MTU and reassembled at the next hop. GATT carries control; the link layer handles background discovery.",
      nodes: { a:{type:'you',x:90,y:150,label:'node'}, ch:{type:'chunks',x:320,y:150}, b:{type:'relay',x:545,y:150,label:'next hop'} },
      edges: [['a','ch'],['ch','b']],
      routes: [['a','ch','b']],
      notes: [{x:320,y:108,t:'MTU fragments',tone:'transit'}],
    },
  },
  {
    id: 'l2cap', name: 'L2CAP CoC', mono: false, group: 'Bearer', ref: '§11',
    tagline: 'Connection-oriented channels for bulk transfer',
    body: "Large payloads ride L2CAP CoC rather than GATT notifications, with bounded SDU sizes handled by the carrier transport.",
    viz: {
      caption: "Bulk transfer rides a connection-oriented L2CAP channel instead of GATT notifications, with bounded SDU sizes handled by the carrier transport.",
      nodes: { a:{type:'you',x:120,y:150,label:'sender'}, b:{type:'dest',x:520,y:150,label:'receiver'} },
      edges: [['a','b','pipe']],
      routes: [['a','b']],
      notes: [{x:320,y:108,t:'L2CAP CoC channel',tone:'deliv'}],
    },
  },
  {
    id: 'tcp', name: 'TCP / WebSocket', mono: false, group: 'Bearer', ref: '§21 · §26',
    tagline: 'The internet bearer',
    body: "Devices reach the cloud backbone over WebSocket at a single anycast name that routes to the nearest region; relays peer over the internet to bridge Bluetooth islands across the world.",
    viz: {
      caption: "Devices reach the backbone over WebSocket at one anycast name that routes to the nearest region; relays peer over the internet to bridge Bluetooth islands across the world.",
      nodes: { d:{type:'you',x:70,y:150,label:'device'}, up:{type:'uplink',x:245,y:150,label:'anycast'}, rgn:{type:'cloud',x:420,y:150,glyph:'region'}, far:{type:'dest',x:575,y:150,label:'far island'} },
      edges: [['d','up'],['up','rgn'],['rgn','far']],
      routes: [['d','up','rgn','far']],
      notes: [{x:245,y:108,t:'nearest region',tone:'transit'},{x:575,y:150,t:'bridged',tone:'deliv'}],
    },
  },
  {
    id: 'bearers', name: 'Pluggable bearers', mono: false, group: 'Bearer', ref: '§26',
    tagline: 'The bearer is the only thing that changes',
    body: "Bluetooth LE ships first; Wi-Fi Aware, MultipeerConnectivity, and more fit the same interface — the core above is unchanged.",
    viz: {
      caption: "The bearer is the only thing that changes. Bluetooth LE ships first; Wi-Fi Aware, MultipeerConnectivity, and more fit the same interface — the core above stays the same.",
      nodes: { core:{type:'endpoint',x:320,y:78,label:'hdp core'}, ble:{type:'relay',x:150,y:218,label:'Bluetooth LE'}, wifi:{type:'relay',x:320,y:218,label:'Wi-Fi Aware'}, mp:{type:'relay',x:500,y:218,label:'Multipeer'} },
      edges: [['core','ble'],['core','wifi','avail'],['core','mp','avail']],
      routes: [['core','ble']],
      notes: [{x:320,y:78,t:'unchanged',tone:'deliv'}],
    },
  },
];

export const groups = ['Semantics', 'Waist', 'Bearer'];
