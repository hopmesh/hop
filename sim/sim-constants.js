// Single source of truth for the sim's transport + geography constants and the pure movement helpers.
//
// Before this module existed, the headless validator (scenario-check.mjs) hand-copied RANGE/SOAK from
// sim-worker.js and SPEED/TOWERS/APS/RKEYS + djb/rnd01/areaSpot/hav from index.html — a third copy that
// could silently drift and let the checker pass while the site failed (or vice versa). Now the worker
// and the checker both import from here, so there is exactly ONE definition. index.html still inlines
// its copies (it's a single monolithic file), so scenario-check.mjs runs a DRIFT TEST that greps the
// key literals out of index.html and fails if they no longer match these values. Change a constant here
// and either the imports pick it up automatically (worker, checker) or the drift test flags index.html.

// ---- transport model (shared with sim-worker.js linkInfo) ----
// Realistic radio ranges: BLE phone-to-phone ~10-35m; Wi-Fi Direct ~50-100m.
export const RANGE = { ble: 35, wifi: 90 };
// SOAK = dwell time (sim-ms ≈ simulated real seconds) a pair must stay in range before the link is
// usable. Real connection setup: BLE discovery+GATT ~4s, Wi-Fi Direct group negotiation ~8s, AP
// association ~2s, cell/relay attach ~3s, LoRa bond ~1.5s. A fast passer-by that doesn't dwell this long
// never links (physically honest).
export const SOAK = { ble: 4000, wifi: 8000, ap: 2000, relay: 3000, lora: 1500 };
export const RELAY_ID = 'relay';

// ---- geography + movement (shared with index.html cast/movement) ----
export const SPEED = { walk: 1.5, drive: 8, bike: 4.5 };   // m/s of sim time

// Full cross-town carrier routes (endpoints; the site fetches the OSRM geometry, the checker uses
// routes.json). RKEYS is derived so the two never disagree on the route set.
export const ROUTES = {
  geary: [[-122.4470, 37.7845], [-122.3945, 37.7905]],
  mission: [[-122.4225, 37.7575], [-122.3960, 37.7915]],
  vanness: [[-122.4210, 37.7680], [-122.4235, 37.8020]],
  market: [[-122.4200, 37.7770], [-122.3945, 37.7925]],
  northsouth: [[-122.4090, 37.8010], [-122.3980, 37.7770]],
};
export const RKEYS = Object.keys(ROUTES);

// SF-style cellular grid — overlapping macro + small cells give near-blanket coverage. radius in meters.
export const TOWERS = [
  { pos: [-122.4001, 37.7936], r: 850 }, { pos: [-122.4045, 37.7855], r: 820 },
  { pos: [-122.3958, 37.7952], r: 820 }, { pos: [-122.3945, 37.7828], r: 850 },
  { pos: [-122.4130, 37.7925], r: 950 }, { pos: [-122.4180, 37.8005], r: 950 },
  { pos: [-122.4235, 37.7815], r: 1050 }, { pos: [-122.4300, 37.7908], r: 1100 },
  { pos: [-122.4270, 37.7695], r: 1100 }, { pos: [-122.4130, 37.7625], r: 1100 },
  { pos: [-122.4030, 37.7660], r: 1050 }, { pos: [-122.4430, 37.7850], r: 1200 },
  { pos: [-122.4452, 37.7640], r: 1650 },
];

// Wi-Fi access points in the gaps between towers. pub = anyone joins; else key-gated. sat = Starlink
// (internet independent of the terrestrial ISP). bat = battery backup (radio survives a power cut).
export const APS = [
  { pos: [-122.3975, 37.7902], r: 35, name: 'FiDi Café', pub: true, sat: true, bat: true },
  { pos: [-122.394416, 37.792435], r: 42, name: 'Ferry Plaza', pub: true },
  { pos: [-122.421766, 37.795856], r: 40, name: 'Nob Hill Park', pub: true },
  { pos: [-122.4002, 37.7812], r: 40, name: 'SoMa Office', pub: false, bat: true, key: 'office' },
  { pos: [-122.419341, 37.775964], r: 22, name: 'Civic Home', pub: false, key: 'home1' },
  { pos: [-122.419568, 37.763818], r: 26, name: 'Mission Home', pub: false, sat: true, key: 'home2' },
];

// ---- pure helpers (identical in the app and the harness) ----

// Deterministic per-person randomness: id-salted counter hash.
export function djb(id) { let h = 5381; for (const c of id) h = (h * 33 + c.charCodeAt(0)) >>> 0; return h; }
export function rnd01(salt, n) { return ((((salt + n * 2654435761) ^ (salt << 7)) >>> 0) % 10000) / 10000; }

// A scattered spot around an area's centre (≤15 m) so a dwelling crowd forms a BLE-connected hub without
// stacking on one pixel.
export function areaSpot(centre, id, visit) {
  const salt = djb(id);
  const ang = rnd01(salt, visit * 2 + 1) * 6.283, rad = 4 + rnd01(salt, visit * 2 + 2) * 11;
  return [
    centre[0] + (rad * Math.sin(ang)) / (111320 * Math.cos(centre[1] * Math.PI / 180)),
    centre[1] + (rad * Math.cos(ang)) / 111320,
  ];
}

// Haversine distance in meters.
const _R = 6371000, _D2R = Math.PI / 180;
export function hav(a, b) {
  const dLa = (b[1] - a[1]) * _D2R, dLo = (b[0] - a[0]) * _D2R;
  const h = Math.sin(dLa / 2) ** 2 + Math.cos(a[1] * _D2R) * Math.cos(b[1] * _D2R) * Math.sin(dLo / 2) ** 2;
  return _R * 2 * Math.asin(Math.sqrt(h));
}
