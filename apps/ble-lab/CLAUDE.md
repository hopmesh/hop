# apps/ble-lab

A from-scratch, minimal dual-role "proof of pipe" lab (macOS CLI + Android + iOS) used to prove
cross-platform BLE L2CAP before folding a design into the real `bearers/`. Self-contained: it does NOT
depend on `hop-core` or the shipping bearers, and it is not a shipped product. `SPEC.md` is the contract.

## Field gotchas (from real device sessions)

- Wait >= 8 seconds after enabling Android Bluetooth or the advertiser wedges.
- macOS `bluetoothd` degrades over a long session (discovery stalls); switch to a real iOS device once wedged, or reboot.
- Simultaneous mutual dial collides (Apple cannot advertise its id mid-dial); use a single initiator (Apple dials Android, Android defers).
- Tools inside: `btpower`, `scanonly`, `dialonly`; `setprop debug.blelab.noscan` on Android.

## Design lineage

The proven design here (GATT for the PSM handshake, L2CAP for data, unbiased random-id tiebreaker, no MAC
tracking) is what the real `bearers/apple/HopBearerBle` + `bearers/android/bearer-ble` implement. When you
change the shipping BLE bearer, this lab is where you prototype and validate on fresh hardware first.
