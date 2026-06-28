// blepeer — the clean-room CLI host of the shared HopBearers transport (ble-lab/SPEC.md §8).
//
// It does nothing but BOOTSTRAP: build a BearerManager, register a BleBearer, wire the shared
// ProofSink (HopBearerProof) as the consumer, and run. The exact same shape the production app and the
// iOS clean-room app use — adding LAN/Wi-Fi later is one more register() call here. All the proof
// logic lives in HopBearerProof so it is shared verbatim with the iOS clean-room app (no fold-back).
//
// CLI defaults (HopBearers): bleQueue = .main, bleRunLoop = .main — no UI contends.

import Foundation
import HopBearers
import HopBearerProof

setbuf(stdout, nil)                    // unbuffered logs so `timeout`/piping flush immediately

log("STATE", "blepeer starting (HopBearers BearerManager + BleBearer + ProofSink)")
let manager = BearerManager()
manager.register(BleBearer(myId: BleBearer.randomNodeId()))
let sink = ProofSink()
sink.bearer = manager                  // proof pings route out through the manager (uniform Bearer)
manager.sink = sink                    // links from every registered bearer surface here, one id space
manager.start()
RunLoop.main.run()
