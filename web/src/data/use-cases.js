// Use cases / case studies. Each entry gets its own page at /use-cases/<id>/
// and a card on the /use-cases/ overview. `body` is rendered as paragraphs
// (HTML allowed); `uses` are related-primitive chips linking into the docs.
export const cases = [
  {
    id: 'messaging', icon: '📨', title: 'Messaging',
    tagline: 'People to people, no infrastructure',
    description:
      'End-to-end encrypted, store-and-forward messaging that works with no tower, Wi-Fi, or server — hopping device to device until it reaches its destination.',
    body: [
      "End-to-end encrypted, store-and-forward messaging that works with no tower, Wi-Fi, or server. A message hops device to device across everyone in between until it reaches its destination — confidential the whole way, even across relays you don't trust.",
      "Binary spray-and-wait spreads a small copy budget across independent paths so the first to arrive delivers, and the cloud backbone holds messages for recipients who are offline. Built for events, field teams, remote communities, and response.",
    ],
    uses: [['hdp://', '/protocol/hdp/'], ['spray-and-wait', '/protocol/hdp/'], ['mailbox', '/protocol/hdp/']],
  },
  {
    id: 'sync', icon: '🔄', title: 'Data sync',
    tagline: 'Offline-first collections that converge',
    description:
      "Build a replicated store that converges across devices and the cloud without a live connection. Hop's set-reconciliation primitive transfers only the difference.",
    body: [
      "Build a replicated store — a CRDT collection, an event log, a shared dataset — that converges across devices and the cloud without a live connection. Hop's set-reconciliation primitive answers “what do you have that I don't?” efficiently, transferring only the difference.",
      "Hop provides the convergence transport — sealed, content-addressed items, delay-tolerant, backbone-assisted — and your app brings the merge logic. This is the layer a Ditto-class store builds on.",
    ],
    uses: [['anti-entropy', '/protocol/streams/'], ['hps://', '/protocol/hps/'], ['hdp://', '/protocol/hdp/']],
  },
  {
    id: 'files', icon: '🗂️', title: 'File &amp; media transfer',
    tagline: 'Any size, chunked and reassembled',
    description:
      'Move files, images, and media of any size across the mesh. The carrier transport splits a large payload into ordered, sealed chunks and reassembles it on the far side.',
    body: [
      "Move files, images, and media of any size across the mesh. The carrier transport transparently splits a large payload into ordered, individually-sealed chunks and reassembles it on the far side — id, order, acks, and dedup all preserved.",
      "The size cap is a sliding window, not a ceiling, so even video streams through, hop by hop, eventually.",
    ],
    uses: [['carrier transport', '/protocol/streams/'], ['hdp://', '/protocol/hdp/']],
  },
  {
    id: 'web', icon: '🌐', title: 'Offline web',
    tagline: 'Reach a service from no connection',
    description:
      "A device with no internet emits a sealed HTTP request; any gateway node fulfills it and relays the sealed response back to your device's key.",
    body: [
      "A device with no internet emits a sealed HTTP request. Any gateway node fulfills it and relays the sealed response back to your device's key — eventual, but guaranteed. Or reach a specific service over <code>hops://</code>: HTTP semantics carried as sealed datagrams, terminated by the origin's own endpoint, with no third party in the middle.",
    ],
    uses: [['hops://', '/protocol/hops/'], ['HNS', '/protocol/hns/'], ['internet egress', '/protocol/hops/']],
  },
  {
    id: 'telemetry', icon: '📡', title: 'Telemetry &amp; IoT',
    tagline: 'Data from past the edge',
    description:
      'Sensors, crews, and assets past coverage push readings that hop back to whichever node has a link, then bridge home the moment any carrier touches the internet.',
    body: [
      "Sensors, crews, and assets spread past coverage push readings that hop back to whichever node has a link, then bridge home the moment any carrier touches the internet. Topic-based pub/sub over <code>hps://</code> fans data only to regions with live subscribers — no wasted egress to empty regions.",
    ],
    uses: [['hps://', '/protocol/hps/'], ['hdp://', '/protocol/hdp/'], ['cloud backbone', '/protocol/tcp/']],
  },
];
