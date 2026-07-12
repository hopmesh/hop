import XCTest

final class GrantBTPermissionTests: XCTestCase {
    func testGrantBluetoothPermission() throws {
        let app = XCUIApplication()
        app.launch()

        // Handle the Bluetooth system alert that appears when the app starts.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Give the app 6 seconds to trigger the alert.
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 6) {
            // Try "OK" first (iOS 13 style), then "Allow" (iOS 14+ style)
            let ok = alert.buttons["OK"]
            let allow = alert.buttons["Allow"]
            if ok.exists { ok.tap() }
            else if allow.exists { allow.tap() }
        }

        // Let BT come up and log the initial state.
        Thread.sleep(forTimeInterval: 8)
    }
}
