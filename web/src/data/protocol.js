// The Hop protocol by layer. Each entry gets its own page at /protocol/<id>/ and
// a row on the /protocol/ overview. Grouped: Semantics (above the waist), Waist
// (the datagram substrate), Bearer (below). `viz` drives the per-layer diagram
// (see ProtocolDiagram): either a generic { nodes, edges, routes, notes } spec,
// or a hand-authored { vb, svg } for layers the generic engine can't express.

export const layers = [
  {
    id: 'hops', name: 'hops://', mono: true, group: 'Semantics', ref: '§30',
    tagline: 'HTTP over the mesh',
    how: [
      "Resolve the domain via <a href=\"/protocol/hns/\">HNS</a> to the endpoint's key — <span class=\"term\" tabindex=\"0\">DNSSEC<span class=\"tip\"><b>DNSSEC</b> — DNS Security Extensions: signed DNS records the client verifies itself, so a name can't be forged into the wrong key.</span></span>-verified, not an IP — or address the endpoint directly and skip the lookup.",
      "Sealed hop datagrams cross the mesh to the operator's own <code>hop-endpoint</code>. The only live hop is endpoint↔backend, on the operator's own wire; the client↔endpoint path stays delay-tolerant.",
      "The endpoint runs the request against its own origin and re-seals the response. It <em>is</em> the origin — bound to one domain, never an open proxy — so nothing on the mesh ever sees plaintext HTTP.",
    ],
    dev: "Send an HTTP request to <code>hops://host/path</code>. The request carries only a path plus a signed host; the endpoint refuses anything but its configured origin (no open-relay abuse). Finite responses auto-chunk; live ones (SSE, WebSocket) stream.",
    biz: "Expose your existing web service to devices with no internet — running on your own infrastructure, with no third-party proxy in the middle that could read your traffic or your users'.",
    viz: {
      vb: '0 0 700 380',
      caption: "Resolve the name via HNS (DNSSEC-verified, a hop address — not an IP), then spray sealed hop packets across the mesh to the hop-endpoint behind the operator's firewall. Only there are they translated to HTTP for the origin. The endpoint is the origin, not a proxy.",
      svg: `
        <rect class="pd-zone" x="446" y="26" width="232" height="330" rx="10"/>
        <text class="pd-zone-l" x="664" y="48" text-anchor="end">operator network</text>
        <text class="pd-zone-l dim" x="664" y="64" text-anchor="end">behind the firewall</text>
        <line class="pd-fw" x1="446" y1="46" x2="446" y2="334"/>
        <text class="pd-lbl" x="446" y="352" text-anchor="middle">firewall</text>

        <path class="pd-resolve" d="M64,250 Q92,124 250,104"/>
        <circle class="pd-node" cx="250" cy="104" r="12"/><circle class="pd-core" cx="250" cy="104" r="3.2"/>
        <text class="pd-lbl" x="250" y="132" text-anchor="middle">HNS</text>
        <g transform="translate(258,80)"><rect class="pd-note deliv" x="-86" y="-11" width="172" height="20" rx="5"/><text class="pd-note-t deliv" x="0" y="3.5" text-anchor="middle">DNSSEC ✓ → hop address</text></g>
        <text class="pd-step" x="86" y="166">1 · resolve</text>
        <text class="pd-step" x="86" y="324">2 · request</text>

        <line class="pd-edge" x1="64" y1="250" x2="196" y2="206"/>
        <line class="pd-edge" x1="64" y1="250" x2="200" y2="304"/>
        <line class="pd-edge" x1="196" y1="206" x2="330" y2="250"/>
        <line class="pd-edge" x1="200" y1="304" x2="330" y2="250"/>
        <line class="pd-edge" x1="330" y1="250" x2="540" y2="250"/>
        <line class="pd-edge http" x1="562" y1="250" x2="636" y2="250"/>
        <path class="pd-trail" d="M64,250 L196,206 L330,250 L540,250"/>

        <circle class="pd-node live" cx="64" cy="250" r="14"/><circle class="pd-core" cx="64" cy="250" r="4.5"/><text class="pd-lbl" x="64" y="280" text-anchor="middle">client</text>
        <circle class="pd-node" cx="196" cy="206" r="12"/><circle class="pd-core" cx="196" cy="206" r="3.2"/>
        <circle class="pd-node" cx="200" cy="304" r="12"/><circle class="pd-core" cx="200" cy="304" r="3.2"/>
        <text class="pd-lbl" x="198" y="332" text-anchor="middle">relays · mesh</text>
        <circle class="pd-node" cx="330" cy="250" r="12"/><circle class="pd-core" cx="330" cy="250" r="3.2"/>
        <rect class="pd-ep" x="518" y="228" width="44" height="44" rx="10"/><line class="pd-epl" x1="529" y1="244" x2="551" y2="244"/><line class="pd-epl" x1="529" y1="252" x2="551" y2="252"/><circle class="pd-core" cx="535" cy="262" r="2.4"/>
        <text class="pd-lbl" x="540" y="290" text-anchor="middle">hop-endpoint</text>
        <rect class="pd-origin" x="616" y="230" width="40" height="40" rx="9"/><circle class="pd-core" cx="636" cy="250" r="3"/>
        <text class="pd-lbl" x="636" y="288" text-anchor="middle">origin</text>

        <text class="pd-seg" x="236" y="238" text-anchor="middle">hop packets · sealed (hdp)</text>
        <text class="pd-seg http" x="599" y="238" text-anchor="middle">HTTP</text>
        <g transform="translate(540,210)"><rect class="pd-note deliv" x="-82" y="-11" width="164" height="20" rx="5"/><text class="pd-note-t deliv" x="0" y="3.5" text-anchor="middle">terminates hop → HTTP</text></g>

        <!-- one synced 7.2s loop: 1) public HNS query (a plain dot — not sealed), 2) DNSSEC answer back, 3) sealed request locks over the mesh, 4) unsealed HTTP to origin -->
        <circle class="pd-pkt" r="4.6"><animateMotion dur="7.2s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.02;0.18;1" calcMode="linear" path="M64,250 Q92,124 250,104"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.02;0.04;0.18;0.2;1" dur="7.2s" repeatCount="indefinite"/></circle>
        <circle class="pd-pkt resp" r="4.4"><animateMotion dur="7.2s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.2;0.36;1" calcMode="linear" path="M250,104 Q92,124 64,250"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.2;0.22;0.36;0.38;1" dur="7.2s" repeatCount="indefinite"/></circle>
        <use class="pd-lock" href="#pdlk"><animateMotion dur="7.2s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.42;0.64;1" calcMode="linear" path="M64,250 L196,206 L330,250 L540,250"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.42;0.44;0.64;0.66;1" dur="7.2s" repeatCount="indefinite"/></use>
        <use class="pd-lock alt" href="#pdlk"><animateMotion dur="7.2s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.44;0.66;1" calcMode="linear" path="M64,250 L200,304 L330,250 L540,250"/><animate attributeName="opacity" values="0;0;0.65;0.65;0;0" keyTimes="0;0.44;0.46;0.66;0.68;1" dur="7.2s" repeatCount="indefinite"/></use>
        <circle class="pd-pkt http" r="4.4"><animateMotion dur="7.2s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.70;0.86;1" calcMode="linear" path="M540,250 L636,250"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.70;0.72;0.86;0.88;1" dur="7.2s" repeatCount="indefinite"/></circle>
      `,
    },
  },
  {
    id: 'hps', name: 'hps://', mono: true, group: 'Semantics', ref: '§32',
    tagline: 'Pub/sub — services and channels',
    how: [
      "<strong>Channels</strong> — anyone with the shared key reads and writes (group chat); every post is signed by its author, so senders are always verified.",
      "<strong>Services</strong> — only the owner can broadcast (a service signing key), and many subscribers read with a shared content key.",
      "A post is sealed and floods the mesh; non-members carry it blind, members decrypt and ACK back — the host counts unique ACKs as its reach, with no subscriber registry.",
    ],
    dev: "Register a topic at a path on any node and that node becomes its host. Open / request-to-join / invite control who gets the keys; per-app secrets keep other apps' topics invisible and unjoinable.",
    biz: "Group messaging, fan-out alerts, and discoverable services with no broker to run — and on the cloud backbone a topic only ships to regions that actually have subscribers, so you never pay to flood empty ones.",
    viz: {
      vb: '0 0 720 330',
      caption: "A post is sealed and floods the mesh. Members (with the shared key) decrypt it and ACK back — the host counts unique ACKs as reach, with no subscriber registry; non-members carry it but can't read it. Every post is signed by its author. Channels let anyone read and write; services let only the owner broadcast.",
      svg: `
        <line class="pd-edge" x1="92" y1="165" x2="320" y2="92"/>
        <line class="pd-edge" x1="92" y1="165" x2="512" y2="168"/>
        <line class="pd-edge" x1="92" y1="165" x2="330" y2="262"/>
        <path class="pd-trail" d="M92,165 L320,92"/>

        <circle class="pd-node live" cx="92" cy="165" r="14"/><circle class="pd-core" cx="92" cy="165" r="4.5"/>
        <text class="pd-lbl" x="92" y="193" text-anchor="middle">publisher</text>
        <text class="pd-seg" x="92" y="209" text-anchor="middle">signs every post</text>

        <circle class="pd-node" cx="320" cy="92" r="12"/><circle class="pd-core" cx="320" cy="92" r="3.2"/><use href="#pdlko" transform="translate(346,80)"/><text class="pd-lbl" x="320" y="120" text-anchor="middle">member · reads</text>
        <circle class="pd-node" cx="512" cy="168" r="12"/><circle class="pd-core" cx="512" cy="168" r="3.2"/><use href="#pdlko" transform="translate(538,156)"/><text class="pd-lbl" x="512" y="196" text-anchor="middle">member · reads</text>
        <circle class="pd-node" cx="330" cy="262" r="12"/><circle class="pd-core" cx="330" cy="262" r="3.2"/><use href="#pdlk" transform="translate(356,250)"/><text class="pd-lbl" x="330" y="290" text-anchor="middle">non-member · carries blind</text>

        <text class="pd-seg" fill="#74b6ff" x="232" y="146" text-anchor="middle">ACK → reach</text>

        <use class="pd-lock" href="#pdlk"><animateMotion dur="4s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.05;0.4;1" calcMode="linear" path="M92,165 L320,92"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.05;0.08;0.4;0.44;1" dur="4s" repeatCount="indefinite"/></use>
        <use class="pd-lock" href="#pdlk"><animateMotion dur="4s" begin="0.2s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.05;0.4;1" calcMode="linear" path="M92,165 L512,168"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.05;0.08;0.4;0.44;1" dur="4s" begin="0.2s" repeatCount="indefinite"/></use>
        <use class="pd-lock alt" href="#pdlk"><animateMotion dur="4s" begin="0.35s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.05;0.4;1" calcMode="linear" path="M92,165 L330,262"/><animate attributeName="opacity" values="0;0;0.65;0.65;0;0" keyTimes="0;0.05;0.08;0.4;0.44;1" dur="4s" begin="0.35s" repeatCount="indefinite"/></use>
        <circle class="pd-pkt resp" r="3.8"><animateMotion dur="4s" begin="0.5s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.5;0.8;1" calcMode="linear" path="M320,92 L92,165"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.5;0.52;0.8;0.82;1" dur="4s" begin="0.5s" repeatCount="indefinite"/></circle>
        <circle class="pd-pkt resp" r="3.8"><animateMotion dur="4s" begin="0.7s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.5;0.8;1" calcMode="linear" path="M512,168 L92,165"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.5;0.52;0.8;0.82;1" dur="4s" begin="0.7s" repeatCount="indefinite"/></circle>
      `,
    },
  },
  {
    id: 'streams', name: 'Carrier transport &amp; streams', mono: false, group: 'Semantics', ref: '§31',
    tagline: 'Reliable, ordered, delay-tolerant delivery',
    how: [
      "A payload too big for one link is split into ordered chunks — each its own sealed, ACK-tracked datagram.",
      "Chunks take independent paths across the mesh and can arrive out of order; the destination reassembles the original bundle, with id, acks, and dedup preserved.",
      "Genuinely open-ended data (SSE, media) rides application streams instead — delivered in order, deduped, and resumable after a gap.",
    ],
    dev: "Carrier transport handles chunking and reassembly under one bundle id; the size cap is a sliding window, so a 5&nbsp;MB image — or video — just works without any chunking code.",
    biz: "Move files and media reliably across an intermittent network, not just short text messages.",
    viz: {
      vb: '0 0 700 360',
      caption: "A large payload is split into ordered, sealed chunks. Each takes its own path across the mesh and may arrive out of order; the far side reassembles them in order, deduplicated. Resumable after a gap.",
      svg: `
        <line class="pd-edge" x1="92" y1="180" x2="230" y2="84"/>
        <line class="pd-edge" x1="92" y1="180" x2="250" y2="180"/>
        <line class="pd-edge" x1="92" y1="180" x2="230" y2="290"/>
        <line class="pd-edge" x1="230" y1="84" x2="420" y2="120"/>
        <line class="pd-edge" x1="250" y1="180" x2="420" y2="120"/>
        <line class="pd-edge" x1="250" y1="180" x2="440" y2="250"/>
        <line class="pd-edge" x1="230" y1="290" x2="440" y2="250"/>
        <line class="pd-edge" x1="420" y1="120" x2="612" y2="180"/>
        <line class="pd-edge" x1="440" y1="250" x2="612" y2="180"/>

        <circle class="pd-node live" cx="70" cy="180" r="14"/><circle class="pd-core" cx="70" cy="180" r="4.5"/><text class="pd-lbl" x="70" y="210" text-anchor="middle">sender</text>
        <circle class="pd-node" cx="230" cy="84" r="11"/><circle class="pd-core" cx="230" cy="84" r="3"/>
        <circle class="pd-node" cx="250" cy="180" r="11"/><circle class="pd-core" cx="250" cy="180" r="3"/>
        <circle class="pd-node" cx="230" cy="290" r="11"/><circle class="pd-core" cx="230" cy="290" r="3"/>
        <circle class="pd-node" cx="420" cy="120" r="11"/><circle class="pd-core" cx="420" cy="120" r="3"/>
        <circle class="pd-node" cx="440" cy="250" r="11"/><circle class="pd-core" cx="440" cy="250" r="3"/>
        <text class="pd-lbl" x="335" y="330" text-anchor="middle">relays · independent paths</text>
        <circle class="pd-node live" cx="634" cy="180" r="14"/><circle class="pd-core" cx="634" cy="180" r="4.5"/><text class="pd-lbl" x="634" y="210" text-anchor="middle">recipient</text>

        <!-- disassembly: one payload splits into parts at the sender -->
        <rect class="pd-ep" x="104" y="150" width="28" height="60" rx="5"/><line class="pd-epl" x1="110" y1="165" x2="126" y2="165"/><line class="pd-epl" x1="110" y1="178" x2="126" y2="178"/><line class="pd-epl" x1="110" y1="191" x2="126" y2="191"/>
        <!-- reassembly: parts rebuild the bundle at the recipient -->
        <rect class="pd-ep" x="572" y="150" width="28" height="60" rx="5"/><line class="pd-epl" x1="578" y1="165" x2="594" y2="165"/><line class="pd-epl" x1="578" y1="178" x2="594" y2="178"/><line class="pd-epl" x1="578" y1="191" x2="594" y2="191"/>
        <text class="pd-seg" fill="#2bf0a0" x="586" y="144" text-anchor="middle">✓ bundle</text>

        <text class="pd-seg" x="120" y="144" text-anchor="middle">payload → parts</text>
        <g transform="translate(596,250)"><rect class="pd-note deliv" x="-80" y="-11" width="160" height="20" rx="5"/><text class="pd-note-t deliv" x="0" y="3.5" text-anchor="middle">reassembled in order ✓</text></g>

        <g><rect class="pd-chunkpkt" x="-8" y="-8" width="16" height="16" rx="3"/><text class="pd-pkt-n" y="3.5" text-anchor="middle">1</text><animateMotion dur="3.2s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.05;0.85;1" calcMode="linear" path="M70,180 L230,84 L420,120 L634,180"/><animate attributeName="opacity" values="0;1;1;1;0" keyTimes="0;0.05;0.5;0.85;1" dur="3.2s" repeatCount="indefinite"/></g>
        <g><rect class="pd-chunkpkt" x="-8" y="-8" width="16" height="16" rx="3"/><text class="pd-pkt-n" y="3.5" text-anchor="middle">2</text><animateMotion dur="4.6s" begin="0.3s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.05;0.85;1" calcMode="linear" path="M70,180 L250,180 L420,120 L634,180"/><animate attributeName="opacity" values="0;1;1;1;0" keyTimes="0;0.05;0.5;0.85;1" dur="4.6s" begin="0.3s" repeatCount="indefinite"/></g>
        <g><rect class="pd-chunkpkt" x="-8" y="-8" width="16" height="16" rx="3"/><text class="pd-pkt-n" y="3.5" text-anchor="middle">3</text><animateMotion dur="3.8s" begin="0.6s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.05;0.85;1" calcMode="linear" path="M70,180 L250,180 L440,250 L634,180"/><animate attributeName="opacity" values="0;1;1;1;0" keyTimes="0;0.05;0.5;0.85;1" dur="3.8s" begin="0.6s" repeatCount="indefinite"/></g>
        <g><rect class="pd-chunkpkt" x="-8" y="-8" width="16" height="16" rx="3"/><text class="pd-pkt-n" y="3.5" text-anchor="middle">4</text><animateMotion dur="5.2s" begin="0.2s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.05;0.85;1" calcMode="linear" path="M70,180 L230,290 L440,250 L634,180"/><animate attributeName="opacity" values="0;1;1;1;0" keyTimes="0;0.05;0.5;0.85;1" dur="5.2s" begin="0.2s" repeatCount="indefinite"/></g>
      `,
    },
  },
  {
    id: 'hns', name: 'HNS', mono: false, group: 'Semantics', ref: '§30',
    tagline: 'The Hop Name System',
    how: [
      "A query is forwarded peer to peer — each node answers if it holds a fresh record, otherwise hands it on — until it reaches one that can resolve. There's no central resolver to find first.",
      "Only a peer with internet does the actual DNS lookup, and just once: the signed answer is cached at every hop on the way back, so the next lookup is a <span class=\"term\" tabindex=\"0\">TTL<span class=\"tip\"><b>TTL</b> — Time To Live: how long a cached record stays valid. Within the TTL, a lookup is answered from a nearby cache on the mesh and never reaches DNS; once it expires, it's re-resolved.</span></span> cache hit on the mesh — no internet.",
      "The answer carries the full <span class=\"term\" tabindex=\"0\">DNSSEC<span class=\"tip\"><b>DNSSEC</b> — DNS Security Extensions: signed DNS records. The client verifies the chain against a baked-in root anchor, so any peer can answer but none can forge.</span></span> chain; the client verifies it itself, so a cached answer is just as trustworthy as a fresh one.",
    ],
    dev: "Names map to keys, not IPs. Resolution and DNSSEC validation live in <code>hop-core</code>; the host is a dumb byte-fetcher. Publish an endpoint by adding a <code>_hopaddress</code> TXT record (DNSSEC required).",
    biz: "Verifiable names that keep resolving from cache when the internet is down — and can't be spoofed by a malicious relay, because the client checks the signatures itself.",
    viz: {
      vb: '0 0 760 420',
      caption: "There's no central resolver. A cold query walks peer to peer — A misses, B misses, C is online and resolves it over DNS (just once). The signed answer routes back, seeding a cache at every hop. A later query hits A's cache while its TTL is still valid and stops there — it never reaches DNS again.",
      svg: `
        <text class="pd-step" x="60" y="96">1 · cold lookup</text>
        <text class="pd-seg" x="60" y="112">walk until a peer can resolve</text>
        <text class="pd-step" x="60" y="300">2 · later lookup</text>
        <text class="pd-seg" x="60" y="316">cache hit at A · no DNS</text>

        <!-- the walk chain -->
        <line class="pd-edge" x1="72" y1="150" x2="252" y2="150"/>
        <line class="pd-edge" x1="252" y1="150" x2="432" y2="150"/>
        <line class="pd-edge" x1="432" y1="150" x2="600" y2="150"/>
        <line class="pd-edge" x1="600" y1="138" x2="600" y2="86"/>
        <path class="pd-edge" d="M72,326 Q150,250 250,168" fill="none"/>

        <circle class="pd-node live" cx="72" cy="150" r="13"/><circle class="pd-core" cx="72" cy="150" r="4"/>
        <text class="pd-lbl" x="72" y="128" text-anchor="middle">query · cold</text>

        <circle class="pd-node" cx="252" cy="150" r="12"/><circle class="pd-core" cx="252" cy="150" r="3.2"/>
        <text class="pd-lbl" x="252" y="128" text-anchor="middle">peer A</text>
        <rect x="220" y="170" width="64" height="6" rx="3" fill="#1b2227"/>
        <rect x="220" y="170" width="64" height="6" rx="3" fill="#2bf0a0"><animate attributeName="width" values="0;0;64;52" keyTimes="0;0.62;0.66;1" dur="10s" repeatCount="indefinite"/></rect>
        <text class="pd-seg" x="252" y="194" text-anchor="middle"><animate attributeName="opacity" values="0;0;1;1" keyTimes="0;0.62;0.66;1" dur="10s" repeatCount="indefinite"/>cached · TTL</text>

        <circle class="pd-node" cx="432" cy="150" r="12"/><circle class="pd-core" cx="432" cy="150" r="3.2"/>
        <text class="pd-lbl" x="432" y="128" text-anchor="middle">peer B</text>
        <text class="pd-seg" fill="#2bf0a0" x="432" y="180" text-anchor="middle">✓ cached<animate attributeName="opacity" values="0;0;1;1" keyTimes="0;0.56;0.6;1" dur="10s" repeatCount="indefinite"/></text>

        <circle class="pd-ring" cx="600" cy="150" r="18"/><circle class="pd-node live" cx="600" cy="150" r="11"/><circle class="pd-core" cx="600" cy="150" r="3.4"/>
        <text class="pd-lbl" x="600" y="180" text-anchor="middle">peer C · online</text>
        <rect class="pd-cloud" x="552" y="48" width="96" height="36" rx="9"/><text class="pd-glyph" x="600" y="70" text-anchor="middle">public DNS</text>
        <text class="pd-seg" x="600" y="38" text-anchor="middle">queried once, on the cold miss</text>
        <text class="pd-seg" x="636" y="116" text-anchor="start">DoH</text>

        <circle class="pd-node live" cx="72" cy="326" r="13"/><circle class="pd-core" cx="72" cy="326" r="4"/>
        <text class="pd-lbl" x="72" y="350" text-anchor="middle">query · later</text>

        <g transform="translate(380,400)"><rect class="pd-result" x="-238" y="-16" width="476" height="32" rx="8"/><text class="pd-result-t" x="0" y="4" text-anchor="middle">acme.hop  →  hop:7f3a…9c2   ·   a key, not an IP   ·   DNSSEC ✓</text></g>

        <!-- cold: query walks A→B→C, then DoH, then signed answer seeds caches back -->
        <circle class="pd-pkt" r="4.6"><animateMotion dur="10s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.02;0.30;1" calcMode="linear" path="M72,150 L252,150 L432,150 L600,150"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.02;0.04;0.30;0.32;1" dur="10s" repeatCount="indefinite"/></circle>
        <circle class="pd-pkt" r="4.2"><animateMotion dur="10s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.32;0.40;1" calcMode="linear" path="M600,150 L600,86"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.32;0.34;0.40;0.42;1" dur="10s" repeatCount="indefinite"/></circle>
        <circle class="pd-pkt resp" r="4.2"><animateMotion dur="10s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.42;0.50;1" calcMode="linear" path="M600,86 L600,150"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.42;0.44;0.50;0.52;1" dur="10s" repeatCount="indefinite"/></circle>
        <circle class="pd-pkt resp" r="4.6"><animateMotion dur="10s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.52;0.70;1" calcMode="linear" path="M600,150 L432,150 L252,150 L72,150"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.52;0.54;0.70;0.72;1" dur="10s" repeatCount="indefinite"/></circle>

        <!-- later: query from a second source hits A's cache, stops there -->
        <circle class="pd-pkt" r="4.6"><animateMotion dur="10s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.76;0.84;1" calcMode="linear" path="M72,326 Q150,250 250,168"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.76;0.78;0.84;0.86;1" dur="10s" repeatCount="indefinite"/></circle>
        <circle class="pd-pkt resp" r="4.6"><animateMotion dur="10s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.86;0.94;1" calcMode="linear" path="M250,168 Q150,250 72,326"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.86;0.88;0.94;0.96;1" dur="10s" repeatCount="indefinite"/></circle>
      `,
    },
  },
  {
    id: 'hdp', name: 'hdp://', mono: true, group: 'Waist', ref: '§30 · §31',
    tagline: 'The datagram substrate — all traffic rides this',
    how: [
      "Each datagram is born with a small copy budget that binary-splits across peers — copies fan out on independent paths in parallel (spray-and-wait).",
      "Sealed and addressed to a key; relays carry ciphertext they can't read and keep <strong>custody</strong> of their copy until they've handed it onward.",
      "The recipient's acknowledgement travels back as a vaccine — every node it reaches drops its copy and refuses more, collapsing the flood. Held when there's no route, never dropped.",
    ],
    dev: "One connectionless send/receive primitive — a sealed, addressed bundle. The library handles spray-and-wait replication, custody, retransmit with backoff, dedup, and the delivery-ACK; you manage no connections or routes.",
    biz: "Messages get through across flaky or absent networks with nothing to operate. Delivery is eventual but guaranteed, with a default 24-hour lifetime everything above inherits.",
    viz: {
      vb: '0 0 720 340',
      caption: "Plaintext at the ends, garbled (sealed) in transit. Copies take more than one peer path; each relay holds its stored copy until an acknowledgement comes back, then releases it. Held, never dropped.",
      svg: `
        <line class="pd-edge" x1="80" y1="166" x2="345" y2="96"/>
        <line class="pd-edge" x1="80" y1="166" x2="345" y2="246"/>
        <line class="pd-edge" x1="345" y1="96" x2="640" y2="166"/>
        <line class="pd-edge" x1="345" y1="246" x2="640" y2="166"/>
        <path class="pd-trail" d="M80,166 L345,96 L640,166"/>

        <circle class="pd-node live" cx="80" cy="166" r="14"/><circle class="pd-core" cx="80" cy="166" r="4.5"/><text class="pd-lbl" x="80" y="150" text-anchor="middle">sender</text>
        <circle class="pd-node" cx="345" cy="96" r="12"/><circle class="pd-core" cx="345" cy="96" r="3.2"/>
        <circle class="pd-node" cx="345" cy="246" r="12"/><circle class="pd-core" cx="345" cy="246" r="3.2"/>
        <circle class="pd-pulse" cx="640" cy="166" r="15"><animate attributeName="r" values="15;30" dur="2.4s" repeatCount="indefinite"/><animate attributeName="opacity" values="0.45;0" dur="2.4s" repeatCount="indefinite"/></circle>
        <circle class="pd-node live" cx="640" cy="166" r="14"/><circle class="pd-core" cx="640" cy="166" r="4.5"/><text class="pd-lbl" x="640" y="150" text-anchor="middle">recipient</text>

        <g transform="translate(96,230)"><rect class="pd-msg" x="-46" y="-13" width="92" height="26" rx="6"/><use href="#pdlko" transform="translate(-30,0.5)"/><text class="pd-msg-p" x="12" y="3.6" text-anchor="middle">hello</text></g>
        <g transform="translate(626,230)"><rect class="pd-msg" x="-46" y="-13" width="92" height="26" rx="6"/><use href="#pdlko" transform="translate(-30,0.5)"/><text class="pd-msg-p" x="12" y="3.6" text-anchor="middle">hello</text></g>

        <!-- every relay stores its copy, then clears it as the ack passes back through -->
        <g transform="translate(345,70)"><use href="#pdlk"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.22;0.26;0.66;0.72;1" dur="7s" repeatCount="indefinite"/></g>
        <g transform="translate(345,272)"><use href="#pdlk"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.24;0.28;0.68;0.74;1" dur="7s" repeatCount="indefinite"/></g>

        <g><use href="#pdlk"/><text class="pd-msg-c" x="13" y="3.5">▚6@</text><animateMotion dur="7s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.05;0.42;1" calcMode="linear" path="M80,166 L345,96 L640,166"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.05;0.08;0.42;0.46;1" dur="7s" repeatCount="indefinite"/></g>
        <g><use href="#pdlk"/><animateMotion dur="7s" begin="0.4s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.05;0.42;1" calcMode="linear" path="M80,166 L345,246 L640,166"/><animate attributeName="opacity" values="0;0;0.6;0.6;0;0" keyTimes="0;0.05;0.08;0.42;0.46;1" dur="7s" begin="0.4s" repeatCount="indefinite"/></g>

        <!-- the blue ack travels back through the mesh, clearing every stored copy as it passes -->
        <circle class="pd-pkt resp" r="5"><animateMotion dur="7s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.5;0.84;1" calcMode="linear" path="M640,166 L345,96 L80,166"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.5;0.52;0.84;0.88;1" dur="7s" repeatCount="indefinite"/></circle>
        <circle class="pd-pkt resp" r="4.4"><animateMotion dur="7s" begin="0.25s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;0.5;0.84;1" calcMode="linear" path="M640,166 L345,246 L80,166"/><animate attributeName="opacity" values="0;0;1;1;0;0" keyTimes="0;0.5;0.52;0.84;0.88;1" dur="7s" begin="0.25s" repeatCount="indefinite"/></circle>
      `,
    },
  },
  {
    id: 'ble', name: 'BLE', mono: false, group: 'Bearer', ref: '§11 · §22',
    tagline: 'Passive, no pairing — the primary local bearer',
    how: [
      "BLE is <strong>passive</strong>: devices discover and relay through each other in the background — no pairing, no taps, no setup. That zero-friction meshing is exactly why it's the primary local bearer, and a deliberate trade-off (lower throughput for always-on, invisible reach).",
      "Every node is both BLE central and peripheral; GATT carries discovery, control, and small frames, with a fast L2CAP lane for bulk.",
      "Each bundle is fragmented to the <span class=\"term\" tabindex=\"0\">MTU<span class=\"tip\"><b>MTU</b> — Maximum Transmission Unit: the largest chunk a link carries in one frame. Bundles are split to fit it and reassembled at the next hop, so message size is never capped by the wire.</span></span> on the way out and reassembled at the next hop.",
      "BLE is the first bearer, not the only one — the same bundles ride Wi-Fi/LAN and the internet relay too. The network finds many ways.",
    ],
    dev: "Background operation within platform limits, fragmentation, and reassembly are handled for you behind the bearer trait — and because BLE needs no pairing, the mesh forms itself with nothing for users to approve. Choosing <em>which</em> neighbors to hop through is the network layer's job — see <a href=\"/protocol/hdp/\">hdp</a>.",
    biz: "Runs on the BLE radio already in every phone — no hardware to ship — and because BLE pairs with nothing, the mesh just forms. Nothing for people to configure, connect, or tap through.",
    viz: {
      caption: "On one BLE link, a bundle is fragmented to the MTU on the way out and reassembled into the whole bundle at the next hop.",
      nodes: { a:{type:'you',x:110,y:150,label:'node'}, ch:{type:'chunks',x:325,y:150}, b:{type:'dest',x:545,y:150,label:'next hop'} },
      edges: [['a','ch'],['ch','b']],
      routes: [['a','ch','b']],
      notes: [{x:325,y:108,t:'fragmented to MTU',tone:'transit'},{x:545,y:108,t:'reassembled',tone:'deliv'}],
    },
  },
  {
    id: 'l2cap', name: 'Direct data channel', mono: false, group: 'Bearer', ref: '§11',
    tagline: 'A fast lane for big transfers',
    how: [
      "A connection-oriented L2CAP channel (CoC) — a real byte stream, far faster than GATT notifications.",
      "Bulk traffic — HTTP responses, files, media — rides this lane; small control frames stay on GATT.",
      "It's one fast hop between two connected peers, inside the larger store-and-forward mesh.",
    ],
    dev: "Bulk automatically uses the CoC stream; you don't select it. (On BLE, this is an L2CAP connection-oriented channel.)",
    biz: "Large transfers move at usable throughput instead of trickling through a control channel.",
    viz: {
      caption: "A dedicated high-throughput lane between two connected devices for big transfers — one fast hop within a mesh that's still carrying ordinary peer traffic all around it.",
      nodes: { n1:{type:'relay',x:110,y:78,label:'peer'}, a:{type:'you',x:215,y:170,label:'device'}, b:{type:'dest',x:500,y:170,label:'device'}, n2:{type:'relay',x:600,y:258,label:'peer'} },
      edges: [['n1','a'],['a','b','pipe'],['b','n2']],
      routes: [['a','b'],['n1','a'],['b','n2']],
      notes: [{x:357,y:132,t:'fast lane for big transfers',tone:'deliv'}],
    },
  },
  {
    id: 'tcp', name: 'Internet relay', mono: false, group: 'Bearer', ref: '§21 · §26',
    tagline: 'Bridging peer-to-peer islands over the web',
    how: [
      "A device with internet links to the backbone over a TCP/WebSocket connection; cloud nodes peer with each other at near-zero cost.",
      "One hostname fronts the whole fleet via GeoDNS / <span class=\"term\" tabindex=\"0\">anycast<span class=\"tip\"><b>Anycast</b> — one address that routes you to the topologically-nearest server automatically. The device races the nearest relays and keeps the fastest.</span></span>, so it reaches the closest relay.",
      "Any two devices on the backbone are ~1 hop apart; a bundle exits at the relay the recipient is currently attached to, and a topic only fans to regions with live subscribers.",
    ],
    dev: "No special handling — when connectivity exists, the backbone extends reach automatically. The mailbox is an untrusted store of sealed ciphertext, so adding capacity is just adding nodes.",
    biz: "Local meshes anywhere on Earth reach each other and your services the moment any node gets online — region-aware, so you never pay to flood empty regions.",
    viz: {
      vb: '0 0 700 300',
      caption: "When any device touches the internet it joins the cloud relay; one anycast address finds the nearest region, and relays peer over the web to bridge far-apart peer-to-peer islands.",
      nodes: { a1:{type:'you',x:70,y:95,label:'phone'}, a2:{type:'relay',x:70,y:205,label:'phone'}, up:{type:'uplink',x:215,y:150,label:'gateway'}, rl:{type:'cloud',x:400,y:150,glyph:'cloud relay'}, up2:{type:'uplink',x:560,y:150,label:'gateway'}, far:{type:'dest',x:648,y:150,label:'far island'} },
      edges: [['a1','up'],['a2','up'],['up','rl'],['rl','up2'],['up2','far']],
      routes: [['a1','up','rl','up2','far'],['a2','up','rl','up2','far']],
      notes: [{x:400,y:108,t:'nearest region',tone:'transit'},{x:648,y:150,t:'bridged',tone:'deliv'}],
    },
  },
  {
    id: 'bearers', name: 'Any transport', mono: false, group: 'Bearer', ref: '§26',
    tagline: 'Hop rides anything that moves bytes',
    how: [
      "The bearer is a trait — <code>send_frame</code> / <code>recv_frame</code> / <code>peer_events</code>. BLE and Wi-Fi/LAN are the v1 implementations.",
      "Anything that moves bytes can carry Hop: Wi-Fi Aware, MultipeerConnectivity, a <a href=\"/lora/\">long-range sub-GHz radio</a>, a satellite link.",
      "Because the store-and-forward model is delay-tolerant, it even fits deep-space links where a continuous path never exists.",
    ],
    dev: "Implement the bearer trait and the entire core above runs unchanged — no protocol changes, no rewrites.",
    biz: "Never locked to one radio or vendor — Hop adapts to whatever connectivity you have, or add later. Have an unusual link or use case? <a href=\"mailto:hello@hopme.sh\">Tell us</a>.",
    viz: {
      vb: '0 0 660 270',
      caption: "The bearer is an abstract slot — anything that moves bytes can carry Hop. BLE and Wi-Fi today; the internet, long-range radio, satellite, and beyond. Have a special link in mind? Tell us.",
      svg: `
        <rect class="pd-ep" x="250" y="38" width="160" height="46" rx="11"/>
        <text class="pd-ct" x="330" y="66" text-anchor="middle">hdp core</text>
        <line class="pd-edge" x1="330" y1="84" x2="330" y2="150"/>
        <rect class="pd-slot" x="198" y="150" width="264" height="60" rx="12"/>
        <text class="pd-slot-t" x="330" y="176" text-anchor="middle">any bearer</text>
        <text class="pd-slot-s" x="330" y="196" text-anchor="middle">anything that moves bytes</text>
        <text class="pd-lbl" x="330" y="244" text-anchor="middle">BLE · Wi-Fi today · the internet · long-range radio · satellite · your transport?</text>
        <use class="pd-lock" href="#pdlk"><animateMotion dur="2.4s" repeatCount="indefinite" path="M330,84 L330,150"/><animate attributeName="opacity" values="0;1;1;0" keyTimes="0;0.15;0.8;1" dur="2.4s" repeatCount="indefinite"/></use>
      `,
    },
  },
];

export const groups = ['Semantics', 'Waist', 'Bearer'];
