# testkit/

The on-device / cross-platform test harness: drives real iOS + Android devices to prove end-to-end
delivery that CI cannot (BLE radios, L2CAP, background wake). `tk` is the CLI; `devices.sh`, `run-round.sh`,
`soak.workflow.js` orchestrate rounds; `addrs.env` + `refresh-addrs.sh` track device identities;
`results/` holds run output (gitignored).

## Device gotchas (from real sessions)

- A rogue `net.waldrip.blelab` install steals the BLE radio and looks like a "slow device"; uninstall it first.
- The app's `messages.json` export LAGS in-memory delivery by >90s, so polling it for "delivered" false-negatives. Trust the in-app `deliveryMs`, not the export.
- Space rapid Android deep-links out; back-to-back ones drop.
- `devicectl` error codes: -10814 = wrong bundle id, 12040 = device locked.
- Always `process launch` the HopDemo app right after installing to a device.

This is where the platform layers (bearers/, drivers/, apps/) get their real coverage: the radio + UI
code excluded from CI's coverage denominators is validated here on hardware.
