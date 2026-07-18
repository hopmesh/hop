// Drivers, the per-platform hosts that embed hop-core and drive the actual
// radios. hop-core has no bearer system of its own; it only moves bytes. A driver
// implements the bearer trait (send_frame / recv_frame / peer_events) for its
// platform and owns discovery, connections, background operation, and power.
//
// This is the start of the docs; each entry gets a page at /docs/drivers/<id>/.
export const drivers = [
  {
    id: 'ios', name: 'iOS', icon: '<i class="fa-duotone fa-solid fa-mobile-screen"></i>',
    status: 'Available', tagline: 'Swift host over CoreBluetooth',
    summary:
      'Embeds hop-core through UniFFI and drives BLE via CoreBluetooth, central and peripheral at once, with an L2CAP channel for bulk and background operation within iOS limits.',
    bearers: ['BLE, GATT + L2CAP CoC', 'LAN, Wi-Fi'],
    notes: [
      'UniFFI Swift bindings wrap the Rust core: hand it a key, address bundles, poll the durable inbox.',
      'CoreBluetooth runs as both central and peripheral so any two devices can relay through each other.',
      'Background BLE within iOS constraints, beaconing, state restoration, wake on connection events. Designing around iOS background is the hardest platform constraint in the project.',
      'L2CAP connection-oriented channel carries bulk; GATT carries control and small frames.',
    ],
    refs: [['BLE bearer', '/protocol/ble/'], ['Direct channel', '/protocol/l2cap/']],
  },
  {
    id: 'android', name: 'Android', icon: '<i class="fa-duotone fa-solid fa-robot"></i>',
    status: 'Available', tagline: 'Kotlin host over the Android BLE + LAN stack',
    summary:
      'Embeds hop-core through UniFFI and drives BLE (GATT + L2CAP) plus LAN, with a foreground service for sustained background meshing.',
    bearers: ['BLE, GATT + L2CAP CoC', 'LAN, mDNS + TCP'],
    notes: [
      'UniFFI Kotlin bindings, the same core API as iOS.',
      'A foreground service keeps the mesh alive in the background.',
      'The LAN bearer (mDNS + TCP) adds high-bandwidth local transfer where available. (Wi-Fi Direct was removed: its per-device approval dialog breaks the passive, no-pairing principle.)',
    ],
    refs: [['BLE bearer', '/protocol/ble/'], ['Any transport', '/protocol/bearers/']],
  },
  {
    id: 'macos', name: 'macOS', icon: '<i class="fa-duotone fa-solid fa-laptop"></i>',
    status: 'Available', tagline: 'A desktop node and rendezvous',
    summary:
      'The same Swift / CoreBluetooth driver as iOS, on the desktop, a plugged-in, always-on Mac makes an ideal rendezvous and local bridge.',
    bearers: ['BLE, GATT + L2CAP CoC', 'LAN, Wi-Fi / Ethernet'],
    notes: [
      'Shares the iOS Swift binding, with fewer background restrictions.',
      'An always-on Mac is a natural carry-and-forward rendezvous on a local network.',
    ],
    refs: [['BLE bearer', '/protocol/ble/']],
  },
  {
    id: 'esp32', name: 'ESP32', icon: '<i class="fa-duotone fa-solid fa-microchip"></i>',
    status: 'In development', tagline: 'Embedded host for the long-range bridge',
    summary:
      'A bare-metal host that runs hop-core on an ESP32 and drives BLE on one side and a long-range 900 MHz radio on the other, the Hop Bridge.',
    bearers: ['BLE', '900 MHz, LoRa + other sub-GHz firmware'],
    notes: [
      'Runs the core in a no-std embedded context and drives a sub-GHz radio module.',
      'Bridges a local BLE cluster to a long-range link, see the <a href="/lora/">Hop Bridge</a>.',
      'The 900 MHz radio is multi-firmware: LoRa is one waveform of several on the same chipset.',
    ],
    refs: [['Any transport', '/protocol/bearers/'], ['Hop Bridge', '/lora/']],
  },
  {
    id: 'linux', name: 'Linux / server', icon: '<i class="fa-duotone fa-solid fa-server"></i>',
    status: 'Available', tagline: 'The relay & backbone host',
    summary:
      'The host that runs the cloud backbone and private fleets, TCP/WebSocket bearers, durable mailboxes, and internet egress.',
    bearers: ['Internet relay, TCP / WebSocket', 'LAN'],
    notes: [
      'Runs the relay fleet (region-aware, anycast) and private or on-prem backbones.',
      'Bridges device meshes across the world and terminates internet egress for hops://.',
    ],
    refs: [['Internet relay', '/protocol/tcp/'], ['For business', '/business/']],
  },
];

export const driversById = Object.fromEntries(drivers.map((h) => [h.id, h]));
