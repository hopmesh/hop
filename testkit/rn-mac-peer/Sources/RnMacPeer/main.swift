import Darwin
import Foundation
import HopDriver

private func stamp() -> String {
    ISO8601DateFormatter().string(from: Date())
}

private func proofLog(_ message: String) {
    print("\(stamp()) RNMAC \(message)")
}

private func fail(_ message: String) -> Never {
    proofLog("fatal \(message)")
    exit(2)
}

let args = CommandLine.arguments
if args.count != 4 {
    fail("usage: RnMacPeer ble|lan <destination-base58> <nonce>")
}
let bearerName = args[1]
let destination = args[2]
let nonce = args[3]
guard bearerName == "ble" || bearerName == "lan" else {
    fail("bearer must be ble or lan")
}

setvbuf(stdout, nil, _IONBF, 0)
let role: HopBearer.Role = bearerName == "ble" ? .centralOnly : .full
let config = HopBearer.Config(
    dbPath: NSTemporaryDirectory() + "rn-mac-peer-\(bearerName)-\(UUID().uuidString).db",
    deviceSeed: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
    appSecret: HopBearer.appSecret,
    displayName: "RN Mac \(bearerName.uppercased()) proof",
    defaultRelay: nil,
    role: role
)
let hop = HopBearer(config: config)
hop.start(name: config.displayName)

if bearerName == "ble" {
    _ = hop.setTransportEnabled("P2P", false)
} else {
    _ = hop.setTransportEnabled("BT", false)
    _ = hop.setTransportEnabled("P2P", false)
    _ = hop.setTransportEnabled("LoRa", false)
}

var sent = false
let started = Date()
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
    let states = hop.transportStates()
    let active = hop.activeTransportCounts()
    let isolated: Bool
    if bearerName == "ble" {
        isolated = states["BT"] == true && states["P2P"] == false && states["LAN"] == nil
    } else {
        isolated = states["BT"] == false && states["P2P"] == false && states["LoRa"] == false && states["LAN"] == true
    }

    if !sent && isolated {
        sent = true
        let result = hop.sendTo(addressBase58: destination, text: nonce)
        proofLog("send bearer=\(bearerName) nonce=\(nonce) to=\(destination) result=\(result) states=\(states) active=\(active)")
    }

    if let message = hop.messages.first(where: { !$0.incoming && $0.text == nonce && $0.delivered }) {
        proofLog("ack bearer=\(bearerName) nonce=\(nonce) delivered=true deliveryMs=\(message.deliveryMs) hops=\(message.deliveryHops)")
        timer.invalidate()
        exit(0)
    }

    if Date().timeIntervalSince(started) > 90 {
        proofLog("timeout bearer=\(bearerName) nonce=\(nonce) sent=\(sent) states=\(states) active=\(active)")
        timer.invalidate()
        exit(3)
    }
}
RunLoop.main.run()
