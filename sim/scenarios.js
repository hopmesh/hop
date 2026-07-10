// Real-world scenarios, played by the REAL hop-core mesh on the city map.
//
// Ids match web/src/data/scenarios.js, the homepage mini player and the full simulator load the
// same scenario by id (sim/index.html?scenario=<id>[&mini=1]). Every scenario is mechanically
// honest: the infra toggles set which real components are up, the script sends real messages
// between real nodes, and delivery happens (or doesn't) by the same rules as always. The only
// theatrical liberty is TIME COMPRESSION (`speed` = sim-seconds per real second).
//
// Cast handles (deterministic, from cast()):
//   <route>A / <route>B     stationary people at a route's ends (geary, mission, vanness, market, northsouth)
//   <route>bus / <route>car vehicles bouncing along the route
//   at0..at5                anchored at their AP: 0 FiDi Café (Starlink+battery) · 1 Ferry Plaza ·
//                           2 Nob Hill Park · 3 SoMa Office (battery) · 4 Civic Home · 5 Mission Home (Starlink)
//   extras                  per-scenario additions (real nodes): {id,name,emoji,route,mode,off}
//
// Schema: { title, blurb, speed, infra:{power,cell,isp,sat?}, camera:{center,zoom},
//           extras?, script:[{at, send:{from,to,text}} | {at, narr}], maxReal }
//   at       sim-seconds since the scenario started
//   maxReal  REAL seconds before a mini loop restarts even if the run didn't complete
//            (a completed run, every scripted send ACKed, restarts a few seconds after the ack)

export const SCENARIOS = {
  p2p: {
    // San Francisco, the flagship city (also the free-play map): a downtown block meshes on its own.
    title: 'A neighborhood that talks to itself.',
    blurb: 'No tower, no plan, messages thread between whoever’s nearby.',
    speed: 32, maxReal: 150,
    infra: { power: true, cell: false, isp: false },
    camera: { center: [-122.3985, 37.7895], zoom: 14.2 },
    script: [
      { at: 2, send: { from: 'missionB', to: 'marketB', text: 'dinner at ours tonight?' } },
      { after: 0, at: 6, send: { from: 'marketB', to: 'missionB', text: 'yes! see you at 7' } },
    ],
  },

  disaster: {
    // Istanbul, Fatih, earthquake country; the fault runs right past the city.
    title: 'The tower is gone. The phones aren’t.',
    blurb: 'Istanbul after a quake: cell and internet down, the mesh carries word to the command post’s satellite uplink, and the answer rides back.',
    speed: 90, maxReal: 360,
    infra: { power: true, cell: false, isp: false },
    stage: {
      routes: { istanbul: null },   // baked: Divan Yolu / Ordu Cd corridor, 5.7 km
      aps: [ { pos: [28.935002, 41.016503], r: 40, name: 'Command post', pub: true, sat: true } ],
      cast: [
        { id: 'you',  name: 'Emre',  route: 'istanbul', frac: 0.04 },
        { id: 'post', name: 'AFAD',  ap: 0 },
        { id: 'r1', name: 'Rescue', emoji: '🚗', route: 'istanbul', mode: 'drive', off: 0.2, seg: [0.02, 0.55] },
        { id: 'r2', name: 'Rescue', emoji: '🚗', route: 'istanbul', mode: 'drive', off: 0.6, seg: [0.45, 1.0] },
        { id: 'r3', name: 'Volunteer', route: 'istanbul', mode: 'bike', off: 0.3, seg: [0.2, 0.6] },
        { id: 'r4', name: 'Volunteer', route: 'istanbul', mode: 'bike', off: 0.75, seg: [0.55, 0.95] },
        { id: 'n1', name: 'Deniz', route: 'istanbul', frac: 0.35 },
        { id: 'n2', name: 'Zeynep', route: 'istanbul', frac: 0.7 },
        { id: 'n3', name: 'Murat', route: 'istanbul', frac: 0.5 },
        { id: 'r5', name: 'Volunteer', route: 'istanbul', mode: 'bike', off: 0.4, seg: [0.25, 0.75] },
      ],
    },
    script: [
      { at: 2, send: { from: 'you', to: 'post', text: 'trapped near Beyazıt, building is cracked, we are 4' } },
      { after: 0, at: 8, send: { from: 'post', to: 'you', text: 'crews dispatched to you, stay where you are' } },
    ],
  },

  iot: {
    // Dutch polder farmland, a sensor GRID meshes across the field, sensor to sensor, until the
    // reading reaches the field edge; cars on the polder road carry it to the agronomist. No cell,
    // no LoRaWAN subscription, no field gateway: the road itself is the backhaul.
    title: 'Sensors where there’s no cell at all.',
    blurb: 'A polder field: readings hop sensor to sensor to the road’s edge, and passing cars carry them to the agronomist.',
    speed: 90, maxReal: 300,
    infra: { power: true, cell: false, isp: false },
    stage: {
      style: 'topo',
      routes: { polder: null },   // baked: a Flevoland polder road, 10.3 km
      aps: [],
      cast: [
        // the field chain, ~29 m spacing, BLE reaches the next sensor; s1 sits at the road's edge
        { id: 's1', name: 'Soil 1', emoji: 'router', pos: [5.50874, 52.52844] },
        { id: 's2', name: 'Soil 2', emoji: 'router', pos: [5.50862, 52.52819] },
        { id: 's3', name: 'Soil 3', emoji: 'router', pos: [5.50850, 52.52794] },
        { id: 's4', name: 'Soil 4', emoji: 'router', pos: [5.50838, 52.52769] },
        { id: 's5', name: 'Soil 5', emoji: 'router', pos: [5.50826, 52.52744] },
        { id: 's6', name: 'Soil 6', emoji: 'router', pos: [5.50814, 52.52719] },
        { id: 'agro', name: 'Agronomist', route: 'polder', frac: 0.55 },
        { id: 'c1', name: 'Car', emoji: '🚗', route: 'polder', mode: 'drive', off: 0.1, seg: [0.02, 0.4] },
        { id: 'c2', name: 'Car', emoji: '🚗', route: 'polder', mode: 'drive', off: 0.45, seg: [0.3, 0.7] },
        { id: 'c3', name: 'Tractor', emoji: '🚗', route: 'polder', mode: 'drive', off: 0.8, seg: [0.6, 0.98] },
        { id: 'c4', name: 'Cyclist', route: 'polder', mode: 'bike', off: 0.25, seg: [0.05, 0.55] },
      ],
    },
    script: [
      { at: 2,  send: { from: 's6', to: 'agro', text: 'soil probe 6: moisture 19%, dropping, irrigate block C' } },
      { at: 60, send: { from: 's6', to: 'agro', text: 'soil probe 6: moisture 18%, dropping' } },
    ],
  },

  offgrid: {
    // Rural Karnataka, India, where this literally happened (DakNet ran buses as the network).
    title: 'Between towns, there’s only the road.',
    blurb: 'Rural India: no link between villages, the clinic record rides the bus until it reaches the town that’s online.',
    speed: 90, maxReal: 300,
    infra: { power: true, cell: false, isp: false },
    camera: { center: [77.5040, 13.2590], zoom: 12.3 },
    stage: {
      style: 'topo',
      routes: { ogroad: null },   // baked: village → Doddaballapura road (12.6 km)
      aps: [
        { pos: [77.469843, 13.225807], r: 40, name: 'Village clinic', pub: true },              // Wi-Fi, no backhaul
        { pos: [77.53829, 13.291992],  r: 40, name: 'Town telecentre', pub: true, sat: true },  // the one online building
      ],
      cast: [
        { id: 'clinic', name: 'Asha',  ap: 0 },
        { id: 'townie', name: 'Ravi',  ap: 1 },
        { id: 'bus',    name: 'Bus',   emoji: '🚌', route: 'ogroad', mode: 'drive', off: 0.0, seg: [0.0, 0.55] },
        { id: 'truck',  name: 'Truck', emoji: '🚗', route: 'ogroad', mode: 'drive', off: 0.5, seg: [0.45, 1.0] },
        { id: 'moto',   name: 'Moto',  emoji: '🚗', route: 'ogroad', mode: 'drive', off: 0.3, seg: [0.2, 0.75] },
        { id: 'farmA',  name: 'Devi',  route: 'ogroad', frac: 0.3 },
        { id: 'farmB',  name: 'Kiran', route: 'ogroad', frac: 0.7 },
      ],
    },
    script: [
      { at: 2, send: { from: 'clinic', to: 'townie', text: 'clinic record: patient stable, needs transport' } },
      { after: 0, at: 8, send: { from: 'townie', to: 'clinic', text: 'received, ambulance booked for tomorrow morning' } },
    ],
  },

  traveler: {
    // Nepal hill villages, a footpath between Ghandruk and Landruk; messages walk with people.
    title: 'A message hitchhikes on a passerby.',
    blurb: 'Nepal foothills: neither village is connected, the message rides whoever is already walking the trail.',
    speed: 90, maxReal: 480,
    infra: { power: true, cell: false, isp: false },
    camera: { center: [83.8165, 28.3700], zoom: 13.4 },
    stage: {
      style: 'topo',
      routes: { ghtrail: null },   // baked: Ghandruk → Landruk footpath (4.7 km)
      aps: [],
      cast: [
        { id: 'townA', name: 'Pemba', route: 'ghtrail', frac: 0.02 },
        { id: 'townB', name: 'Maya',  route: 'ghtrail', frac: 0.98 },
        { id: 'w1', name: 'Traveler', route: 'ghtrail', mode: 'walk', off: 0.25, seg: [0.02, 0.4] },
        { id: 'w2', name: 'Traveler', route: 'ghtrail', mode: 'walk', off: 0.6, seg: [0.32, 0.7] },
        { id: 'w3', name: 'Porter',   route: 'ghtrail', mode: 'bike', off: 0.85, seg: [0.62, 1.0] },
        { id: 'w4', name: 'Traveler', route: 'ghtrail', mode: 'walk', off: 0.45, seg: [0.2, 0.55] },
        { id: 'tea1', name: 'Teahouse', route: 'ghtrail', frac: 0.35 },
        { id: 'tea2', name: 'Teahouse', route: 'ghtrail', frac: 0.65 },
      ],
    },
    script: [
      { at: 2, send: { from: 'townA', to: 'townB', text: 'trail is clear past the ridge, see you tonight' } },
      { after: 0, at: 6, send: { from: 'townB', to: 'townA', text: 'good news, dal bhat will be waiting' } },
    ],
  },

  nodata: {
    // Manila, prepaid-data country: running out of load is an everyday event, the mesh isn't.
    title: 'No plan? Borrow a path, not a phone.',
    blurb: 'Manila: a phone with no load still texts, sealed hops ride a neighbor’s connection, and the reply rides one back.',
    speed: 48, maxReal: 300,
    infra: { power: true, cell: true, isp: true },
    stage: {
      routes: { manila: null },   // baked: Quiapo → Sampaloc streets, 4.1 km
      towers: [ { pos: [120.985, 14.605], r: 1600 }, { pos: [121.001, 14.615], r: 1600 } ],
      aps: [],
      cast: [
        { id: 'you',    name: 'Jom',   route: 'manila', frac: 0.06 },               // no load (cell:false default)
        { id: 'friend', name: 'Bea',   route: 'manila', frac: 0.94, cell: true },
        { id: 'n1', name: 'Marco', route: 'manila', frac: 0.12, cell: true },       // neighbors WITH signal
        { id: 'n2', name: 'Luz',   route: 'manila', frac: 0.3,  cell: true },
        { id: 'j1', name: 'Jeepney', emoji: '🚌', route: 'manila', mode: 'drive', off: 0.2, cell: true, seg: [0.02, 0.55] },
        { id: 'j2', name: 'Jeepney', emoji: '🚌', route: 'manila', mode: 'drive', off: 0.7, seg: [0.45, 1.0] },
        { id: 'j3', name: 'Trike',   emoji: '🚗', route: 'manila', mode: 'drive', off: 0.4, seg: [0.25, 0.7] },
      ],
    },
    script: [
      { at: 2, send: { from: 'you', to: 'friend', text: 'walang load pero nakakatext pa rin, see you at 6?' } },
      { after: 0, at: 6, send: { from: 'friend', to: 'you', text: 'got it! topping you up later. 6 works' } },
    ],
  },

  blackout: {
    // San Juan, Puerto Rico, hurricane blackouts took the whole grid AND the internet down for months.
    title: 'The internet gets cut. Talk anyway.',
    blurb: 'San Juan after the storm: grid down, internet down, local messages keep flowing, and word gets out through the one generator-powered uplink.',
    speed: 90, maxReal: 360,
    infra: { power: false, cell: false, isp: false },
    stage: {
      routes: { sanjuan: null },   // baked: Santurce → Hato Rey, 6.9 km
      aps: [ { pos: [-66.048008, 18.444003], r: 40, name: 'Hotel on generator', pub: true, sat: true, bat: true } ],
      cast: [
        { id: 'you',    name: 'Carla', route: 'sanjuan', frac: 0.05 },
        { id: 'friend', name: 'Luis',  route: 'sanjuan', frac: 0.4 },
        { id: 'hotel',  name: 'Front desk', ap: 0 },
        { id: 'v1', name: 'Relief', emoji: '🚗', route: 'sanjuan', mode: 'drive', off: 0.25, seg: [0.02, 0.55] },
        { id: 'v2', name: 'Relief', emoji: '🚗', route: 'sanjuan', mode: 'drive', off: 0.65, seg: [0.45, 1.0] },
        { id: 'v3', name: 'Neighbor', route: 'sanjuan', mode: 'bike', off: 0.3, seg: [0.15, 0.6] },
        { id: 'n1', name: 'Ana', route: 'sanjuan', frac: 0.75 },
        { id: 'n2', name: 'Tito', route: 'sanjuan', frac: 0.5 },
        { id: 'v4', name: 'Neighbor', route: 'sanjuan', mode: 'bike', off: 0.55, seg: [0.35, 0.85] },
      ],
    },
    script: [
      { at: 2, send: { from: 'you', to: 'friend', text: 'you all OK over there?' } },
      { after: 0, at: 5, send: { from: 'friend', to: 'you', text: 'safe. water’s out though, you?' } },
      { after: 1, at: 6, send: { from: 'you', to: 'hotel', text: 'please tell the mainland we’re all OK on Calle Loíza' } },
    ],
  },

  expedition: {
    // The Khumbu trek, Nepal, Namche Bazaar to Tengboche; a party strung along a real trail.
    title: 'No bars for miles. Tell the group anyway.',
    blurb: 'The Khumbu trail: word passes hiker to hiker up the line until it reaches the lead.',
    speed: 120, maxReal: 480,
    infra: { power: false, cell: false, isp: false },
    camera: { center: [86.7390, 27.8210], zoom: 12.8 },
    stage: {
      style: 'topo',
      routes: { khumbu: null },   // baked: Namche Bazaar → Tengboche (9.1 km)
      channel: { host: 'lead', path: 'party', members: ['lead', 'you', 'h1', 'h2', 'h4'] },
      aps: [],
      cast: [
        { id: 'you',  name: 'You',  route: 'khumbu', frac: 0.05 },
        { id: 'lead', name: 'Lead', route: 'khumbu', frac: 0.95 },
        { id: 'h1', name: 'Hiker',  route: 'khumbu', mode: 'bike', off: 0.2, seg: [0.02, 0.4] },
        { id: 'h2', name: 'Hiker',  route: 'khumbu', mode: 'bike', off: 0.45, seg: [0.32, 0.7] },
        { id: 'h3', name: 'Porter', route: 'khumbu', mode: 'bike', off: 0.7, seg: [0.62, 1.0] },
        { id: 'h4', name: 'Guide',  route: 'khumbu', mode: 'bike', off: 0.5, seg: [0.25, 0.75] },
        { id: 'camp1', name: 'Teahouse', route: 'khumbu', frac: 0.33 },
        { id: 'camp2', name: 'Teahouse', route: 'khumbu', frac: 0.66 },
        { id: 'h5', name: 'Porter', route: 'khumbu', mode: 'bike', off: 0.8, seg: [0.45, 0.95] },
      ],
    },
    script: [
      { at: 2, publish: { from: 'you', path: 'party', text: 'stopping to filter water, 20 min behind' } },
      { after: 0, at: 6, send: { from: 'lead', to: 'you', text: 'copy, we hold at the ridge for you' } },
    ],
  },

  ski: {
    // Heavenly (Tahoe) back side, resorts really do have dead bowls; the message rides the crowd.
    title: 'Find your crew across the mountain.',
    blurb: 'No coverage in the back bowls, the message rides skiers down to your crew at the lodge.',
    speed: 60, maxReal: 360,
    infra: { power: true, cell: false, isp: false },
    camera: { center: [-119.9150, 38.9280], zoom: 13.6 },
    stage: {
      style: 'topo',
      routes: {
        run1: [[-119.9089,38.9199],[-119.9120,38.9235],[-119.9105,38.9262],[-119.9160,38.9300],[-119.9210,38.9350]],
        run2: [[-119.9089,38.9199],[-119.9040,38.9250],[-119.9080,38.9290],[-119.9150,38.9330],[-119.9210,38.9350]],
      },
      aps: [ { pos: [-119.9210, 38.9350], r: 40, name: 'Mid-lodge', pub: true } ],   // Wi-Fi, no backhaul out here
      channel: { host: 'crew', path: 'crew', members: ['crew', 'you', 's1', 's2'] },   // the crew's group channel (hps://)
      cast: [
        { id: 'you',  name: 'You',   route: 'run1', frac: 0.03 },
        { id: 'crew', name: 'Rowan', ap: 0 },   // a PERSON with the crew at the lodge (group channels = future sim work)
        { id: 's1', name: 'Skier', route: 'run1', mode: 'drive', off: 0.3, seg: [0.03, 0.65] },
        { id: 's2', name: 'Skier', route: 'run1', mode: 'drive', off: 0.7, seg: [0.35, 1.0] },
        { id: 's3', name: 'Skier', route: 'run2', mode: 'drive', off: 0.4, seg: [0.03, 0.65] },
        { id: 's4', name: 'Skier', route: 'run2', mode: 'drive', off: 0.8, seg: [0.35, 1.0] },
        { id: 'lift1', name: 'Lift line', route: 'run1', frac: 0.45 },
        { id: 's5', name: 'Skier', route: 'run1', mode: 'drive', off: 0.5, seg: [0.15, 0.85] },
      ],
    },
    script: [
      { at: 2, publish: { from: 'you', path: 'crew', text: 'last run, meet at the mid-lodge' } },
      { after: 0, at: 5, send: { from: 'crew', to: 'you', text: 'saving you a seat by the fire' } },
    ],
  },

  convoy: {
    // The Tanami Track, Australian outback, hundreds of km with no backhaul; units relay forward.
    title: 'Keep the picture on the move.',
    blurb: 'The Tanami Track: no backhaul for hours, status hops vehicle to vehicle up to the lead.',
    speed: 48, maxReal: 780,
    infra: { power: true, cell: false, isp: false },
    camera: { center: [131.7440, -22.7450], zoom: 11.4 },
    stage: {
      style: 'topo',
      routes: { tanami: null },   // baked: an outback stretch of the track
      channel: { host: 'lead', path: 'net', members: ['lead', 'rear', 'v1', 'v2', 'v3', 'v4', 'v5'] },
      aps: [],
      cast: [
        { id: 'rear', name: 'Rear', route: 'tanami', frac: 0.02 },
        { id: 'lead', name: 'Lead', route: 'tanami', frac: 0.98 },
        // UNEQUAL patrol spans: equal spans + equal speed phase-lock into a parade that never
        // meets (found the hard way), distinct periods make every pair drift through its overlap.
        { id: 'v1', name: 'Unit 1', emoji: '🚗', route: 'tanami', mode: 'bike', off: 0.15, seg: [0.0, 0.30] },
        { id: 'v2', name: 'Unit 2', emoji: '🚗', route: 'tanami', mode: 'bike', off: 0.35, seg: [0.20, 0.58] },
        { id: 'v3', name: 'Unit 3', emoji: '🚗', route: 'tanami', mode: 'bike', off: 0.55, seg: [0.44, 0.76] },
        { id: 'v4', name: 'Scout',  emoji: '🚗', route: 'tanami', mode: 'bike', off: 0.75, seg: [0.62, 0.96] },
        { id: 'v5', name: 'Scout',  emoji: '🚗', route: 'tanami', mode: 'bike', off: 0.9, seg: [0.80, 1.0] },
      ],
    },
    script: [
      { at: 2, publish: { from: 'rear', path: 'net', text: 'convoy check: all units up, moving north-west' } },
      { after: 0, at: 5, send: { from: 'lead', to: 'rear', text: 'copy all, next waypoint in 20 clicks' } },
    ],
  },

  clockin: {
    // A big job site (Toronto Port Lands): the company's new punch app needs a connection the crew
    // doesn't have, no SIM on the site phones, and the trailer Wi-Fi only covers the gate. Punches
    // hop worker to worker along the works to the trailer; the confirmation rides back.
    title: 'Clocked in, no SIM needed.',
    blurb: 'A job site: the punch app on a SIM-less phone reaches the company’s cloud timesheet through the crew and the trailer’s uplink, device to platform, not chat.',
    speed: 48, maxReal: 300,
    infra: { power: true, cell: false, isp: true },
    stage: {
      routes: { yard: null },   // baked: a real Port Lands street (~800 m), on land, not the Ship Channel
      aps: [ { pos: [-79.356505, 43.650722], r: 40, name: 'Site trailer', pub: true } ],
      cast: [
        { id: 'office', name: 'Timesheet API', emoji: 'router', ap: 0 },   // the customer's cloud platform, reached via the trailer's uplink (a system, not a person)
        { id: 'worker', name: 'Marta', route: 'yard', frac: 0.95 },
        { id: 'w1', name: 'Crew', route: 'yard', mode: 'walk', off: 0.1,  seg: [0.0, 0.35] },
        { id: 'w2', name: 'Crew', route: 'yard', mode: 'walk', off: 0.28, seg: [0.22, 0.58] },
        { id: 'w3', name: 'Crew', route: 'yard', mode: 'walk', off: 0.45, seg: [0.45, 0.8] },
        { id: 'w4', name: 'Foreman', route: 'yard', mode: 'walk', off: 0.65, seg: [0.68, 1.0] },
        { id: 'p1', name: 'Plant', emoji: 'router', route: 'yard', frac: 0.3 },
        { id: 'p2', name: 'Plant', emoji: 'router', route: 'yard', frac: 0.62 },
      ],
    },
    script: [
      { at: 2, send: { from: 'worker', to: 'office', text: 'PUNCH badge=4211 t=07:58' } },
      { after: 0, at: 4, send: { from: 'office', to: 'worker', text: 'ACCEPTED punch 07:58, shift 06:00-14:30' } },
    ],
  },

  mine: {
    // Kiruna, Sweden, no radio past the first bend, and a gas alert is for EVERYONE: it goes out
    // as a CHANNEL broadcast on the shift's group, hopping headlamp to headlamp until every member
    // has it, and control's instruction comes back the same way.
    title: 'No radio underground. The shift is the network.',
    blurb: 'A mine drift: the gas alert broadcasts to the whole shift, headlamp to headlamp, and control’s instruction rides back.',
    speed: 48, maxReal: 420,
    infra: { power: true, cell: false, isp: true },
    stage: {
      style: 'topo',
      routes: { drift: [[20.2050,67.8360],[20.1960,67.8385],[20.1870,67.8405],[20.1780,67.8420],[20.1700,67.8440]] },
      aps: [ { pos: [20.2050, 67.8360], r: 40, name: 'Portal office', pub: true } ],
      channel: { host: 'office', path: 'shift', members: ['office', 'boss', 'face', 'm1', 'm2', 'm5'] },
      cast: [
        { id: 'office', name: 'Control', ap: 0 },
        { id: 'boss', name: 'Shift boss', route: 'drift', frac: 0.06 },
        { id: 'face', name: 'Ines', route: 'drift', frac: 0.95 },
        { id: 'm1', name: 'Miner', route: 'drift', mode: 'walk', off: 0.12, seg: [0.0, 0.3] },
        { id: 'm2', name: 'Miner', route: 'drift', mode: 'walk', off: 0.3,  seg: [0.22, 0.5] },
        { id: 'm3', name: 'Loader', emoji: '🚗', route: 'drift', mode: 'drive', off: 0.5, seg: [0.4, 0.75] },
        { id: 'm4', name: 'Miner', route: 'drift', mode: 'walk', off: 0.8,  seg: [0.68, 0.97] },
        { id: 'ref1', name: 'Refuge 1', emoji: 'router', route: 'drift', frac: 0.35 },
        { id: 'ref2', name: 'Refuge 2', emoji: 'router', route: 'drift', frac: 0.66 },
        { id: 'm5', name: 'Miner', route: 'drift', mode: 'walk', off: 0.45, seg: [0.3, 0.62] },
      ],
    },
    script: [
      { at: 2, publish: { from: 'face', path: 'shift', text: 'CH4 at 1.8% at the face, pulling the crew back' } },
      { after: 0, at: 6, publish: { from: 'office', path: 'shift', text: 'ventilation ramped, all crews hold at refuge 2 until green' } },
    ],
  },

  event: {
    // A festival ground, modeled the way one actually MOVES: named areas (main stage, vendor row,
    // the ops tent, the entrance), a crowd that swarms between them and DWELLS (a stage set, a
    // food queue), stationary stallholders, staff shuttling ops↔stage↔vendors, plus a constant
    // slurry of real background messages. The tower is UP and jammed (`congested`): everyone
    // attached this morning; now nothing moves except through the crowd itself.
    title: 'Full bars. Nothing sends.',
    blurb: 'A big event: the cell network is up but oversubscribed. Payments and meet-ups ride the crowd instead.',
    speed: 48, maxReal: 360,
    congested: true, chatter: 80,
    infra: { power: true, cell: true, isp: true },
    stage: {
      style: 'topo',
      routes: {},
      areas: {
        entrance: [-2.5960, 51.1500],
        vendors:  [-2.5895, 51.1522],
        stage:    [-2.5845, 51.1538],
        ops:      [-2.58043, 51.15531],
      },
      towers: [ { pos: [-2.5860, 51.1560], r: 1800 } ],   // one saturated macro cell over the site
      aps: [ { pos: [-2.58043, 51.15531], r: 40, name: 'Ops tent', pub: false, sat: true, key: 'ops' } ],
      cast: [
        { id: 'ops',    name: 'Ops', ap: 0, cell: true },
        { id: 'pos1',   name: 'PoS - Stall 12', emoji: 'router', at: 'vendors', cell: true },
        { id: 'vend1',  name: 'Vendor', at: 'vendors', cell: true },
        { id: 'sound',  name: 'Sound desk', emoji: 'router', at: 'stage', cell: true },
        { id: 'front1', name: 'Crowd', at: 'stage', cell: true },
        { id: 'front2', name: 'Crowd', at: 'stage', cell: true },
        { id: 'you',    name: 'Sam', wander: ['stage', 'vendors'], cell: true },
        { id: 'friend', name: 'Kai', wander: ['vendors', 'stage'], cell: true },
        { id: 'c1', name: 'Crowd', wander: ['stage', 'vendors'], cell: true },
        { id: 'c2', name: 'Crowd', wander: ['vendors', 'stage', 'entrance'], cell: true },
        { id: 'c3', name: 'Crowd', wander: ['stage', 'entrance'], cell: true },
        { id: 'c4', name: 'Crowd', wander: ['stage', 'vendors'], dwell: [60, 140], cell: true },
        { id: 'c5', name: 'Crowd', wander: ['vendors', 'entrance', 'stage'], cell: true },
        { id: 'c6', name: 'Crowd', wander: ['stage', 'vendors'], dwell: [50, 120], cell: true },
        { id: 'staff1', name: 'Staff', wander: ['ops', 'stage', 'vendors'], dwell: [10, 30], mode: 'bike', cell: true },
        { id: 'staff2', name: 'Staff', wander: ['ops', 'vendors', 'stage'], dwell: [10, 30], mode: 'bike', cell: true },
        { id: 'staff3', name: 'Staff', wander: ['stage', 'ops'], dwell: [12, 35], mode: 'bike', cell: true },
      ],
    },
    script: [
      { at: 5, send: { from: 'pos1', to: 'ops', text: 'card batch: 47 sales, £612, please sync' } },
      { after: 0, at: 5, send: { from: 'ops', to: 'pos1', text: 'batch received, float topped up' } },
      { at: 15, send: { from: 'you', to: 'friend', text: 'meet left of the sound tower' } },
      { after: 2, at: 8, send: { from: 'friend', to: 'you', text: 'omw, grabbing food first' } },
    ],
  },

  lora: {
    // FUTURE BEARER (in development): the Hop Bridge, an ESP32 that speaks BLE to nearby phones and
    // sub-GHz LoRa across the valley. The bridges are REAL hop nodes here; their 900 MHz span is
    // modeled as a bearer link (bearers are opaque to the core, hop can't tell LoRa from BLE).
    comingSoon: true, minHops: 3,
    title: 'Across the valley on 900 MHz.',
    blurb: 'Hop Bridge (in development): phones reach it over BLE, and it spans the valley on LoRa, the same protocol on a new radio.',
    speed: 24, maxReal: 120,
    infra: { power: true, cell: false, isp: false },
    camera: { center: [-122.6830, 38.0690], zoom: 12.6 },
    stage: {
      style: 'topo',
      routes: {},
      aps: [],
      cast: [
        { id: 'ranchA',  name: 'Noa',          pos: [-122.70055, 38.06155] },
        { id: 'bridgeA', name: 'Hop Bridge A', emoji: 'router', pos: [-122.7003, 38.0617], lora: 'valley' },
        { id: 'bridgeB', name: 'Hop Bridge B', emoji: 'router', pos: [-122.6664, 38.0758], lora: 'valley' },
        { id: 'ranchB',  name: 'Eli',          pos: [-122.66615, 38.07595] },
      ],
      decor: [ { from: [-122.7003, 38.0617], to: [-122.6664, 38.0758], label: 'LoRa - 900 MHz - future bearer (modeled)' } ],
    },
    script: [
      { at: 2, send: { from: 'ranchA', to: 'ranchB', text: 'fence is down in the north paddock, can you check your side?' } },
      { after: 0, at: 6, send: { from: 'ranchB', to: 'ranchA', text: 'on it, cattle are all on my side, gate held' } },
    ],
  },

  collapse: {
    // Port-au-Prince, the 2010 earthquake took out virtually all communications at once.
    title: 'No tower, no satellite. Talk anyway.',
    blurb: 'Port-au-Prince: everything is down, power, cell, internet, satellite. The mesh turns inward, delivers, and carries the answer back.',
    speed: 60, maxReal: 240,
    infra: { power: false, cell: false, isp: false, sat: false },
    stage: {
      routes: { pap: null },   // baked: downtown corridor, 3.2 km
      aps: [],
      cast: [
        { id: 'you',  name: 'Wideline', route: 'pap', frac: 0.05 },
        { id: 'lead', name: 'Incident lead', route: 'pap', frac: 0.95 },
        { id: 'r1', name: 'Responder', route: 'pap', mode: 'bike', off: 0.25, seg: [0.02, 0.55] },
        { id: 'r2', name: 'Responder', route: 'pap', mode: 'bike', off: 0.6, seg: [0.45, 1.0] },
        { id: 'r3', name: 'Volunteer', route: 'pap', mode: 'walk', off: 0.35, seg: [0.2, 0.6] },
        { id: 'n1', name: 'Jean', route: 'pap', frac: 0.45 },
      ],
    },
    script: [
      { at: 2, send: { from: 'you', to: 'lead', text: 'two trapped, west stairwell, need hands' } },
      { after: 0, at: 6, send: { from: 'lead', to: 'you', text: 'team en route, keep talking to them' } },
    ],
  },
};
