// Toggle macOS Bluetooth controller power WITHOUT sudo, the same way the menu bar does, via
// IOBluetooth's (private) power API resolved with dlsym. Used to un-wedge a degraded CoreBluetooth
// stack after many connections. Usage: btpower off | on | cycle
import Foundation

typealias SetPower = @convention(c) (Int32) -> Void
typealias GetPower = @convention(c) () -> Int32

let h = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)
guard let h,
      let setSym = dlsym(h, "IOBluetoothPreferenceSetControllerPowerState"),
      let getSym = dlsym(h, "IOBluetoothPreferenceGetControllerPowerState") else {
    print("could not resolve IOBluetooth power symbols"); exit(2)
}
let setPower = unsafeBitCast(setSym, to: SetPower.self)
let getPower = unsafeBitCast(getSym, to: GetPower.self)

func wait(_ s: Double) { Thread.sleep(forTimeInterval: s) }
let arg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "cycle"
print("power before = \(getPower())")
switch arg {
case "off": setPower(0)
case "on":  setPower(1)
default:
    setPower(0); print("→ off"); wait(3)
    setPower(1); print("→ on")
}
wait(2)
print("power after = \(getPower())")
