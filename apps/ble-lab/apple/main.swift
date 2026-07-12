// main.swift — macOS CLI entry point for HopBleLab (ble-lab/SPEC.md §8).
//
// This is the ONLY file that must NOT be compiled into the iOS app target (top-level executable
// statements are legal only in a file named main.swift). All BLE logic lives in HopBleLab.swift,
// which compiles unchanged into both the CLI and a future iOS app target.
//
// The CLI keeps the SPEC defaults: bleQueue = .main, bleRunLoop = .main, bleAppInBackground = false
// (no UI contends for the main thread — SPEC R8). It runs the symmetric dual role and logs every
// state transition (prefix HOPLAB) plus the per-second proof-of-pipe counter in both directions.

import Foundation

setbuf(stdout, nil)                    // unbuffered logs so `timeout`/piping flush immediately
log("STATE", "HopBleLab macOS CLI starting (service=\(SERVICE_UUID.uuidString))")
let node = Node()
RunLoop.main.run()
