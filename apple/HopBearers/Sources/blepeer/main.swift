// blepeer — the clean-room CLI host of the shared HopBearers transports (ble-lab/SPEC.md §8).
//
// It does nothing but BOOTSTRAP: build a BearerManager, register the bearer(s) selected by env, wire
// the shared ProofSink (HopBearerProof) as the consumer, and run. This is the exact shape the
// production app uses — registering more transports is one more register() call. All proof logic lives
// in HopBearerProof so it is shared verbatim with the iOS clean-room app (no fold-back).
//
// One nodeId is shared across every bearer (a peer reached by BLE and by LAN is the same node).
//
// Env knobs (so one binary covers the BLE field test and a two-process LAN test on one machine):
//   HOPLAB_NO_BLE=1  → don't register the BLE bearer (avoid one-radio contention in a LAN-only test)
//   HOPLAB_LAN=1     → also register the LAN bearer (Bonjour _hoplan._tcp + TCP)
//
// CLI defaults (HopBearerBle): bleQueue = .main, bleRunLoop = .main — no UI contends.

import Foundation
import HopBearerCore    // BearerManager + the contract + randomNodeId
import HopBearerBle     // the BLE transport lib
import HopBearerLan     // the LAN transport lib
import HopBearerProof   // the clean-room proof consumer

setbuf(stdout, nil)                    // unbuffered logs so `timeout`/piping flush immediately

let env = ProcessInfo.processInfo.environment
let myId = randomNodeId()              // ONE identity, handed to every bearer
let manager = BearerManager()
if env["HOPLAB_NO_BLE"] == nil { manager.register(BleBearer(myId: myId)) }
if env["HOPLAB_LAN"] != nil     { manager.register(LanBearer(myId: myId)) }

let sink = ProofSink()
sink.bearer = manager                  // proof pings route out through the manager (uniform Bearer)
manager.sink = sink                    // links from every registered bearer surface here, one id space
log("STATE", "blepeer starting id=\(shortHex(myId)) ble=\(env["HOPLAB_NO_BLE"] == nil) lan=\(env["HOPLAB_LAN"] != nil)")
manager.start()
RunLoop.main.run()
