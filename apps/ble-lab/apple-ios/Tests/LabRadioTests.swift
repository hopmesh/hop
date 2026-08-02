// Tests for the BLE Lab dormant switch. The parse strictness is the point: this app is the
// coexistence fixture for the multi-app BLE defect, and a switch that silently reads a typo as
// "off" would park the fixture and let a later test "prove" a two-app scenario it never staged.
import XCTest
@testable import HopBleLab

final class LabRadioTests: XCTestCase {
    func testParsesTheTwoRealStates() {
        XCTAssertEqual(LabRadio.parse(url: URL(string: "blelab://radio?enabled=true")!), true)
        XCTAssertEqual(LabRadio.parse(url: URL(string: "blelab://radio?enabled=false")!), false)
    }

    /// The case that matters. A permissive bool would read any of these as false, park the fixture,
    /// and make a coexistence run silently meaningless.
    func testRejectsAnythingButExactlyTrueOrFalse() {
        for bad in ["True", "FALSE", "0", "1", "yes", "no", "on", "off", "", "flase", "true "] {
            let u = URL(string: "blelab://radio?enabled=\(bad.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? bad)")!
            XCTAssertNil(LabRadio.parse(url: u),
                         "enabled=\(bad) must not parse: a loose parse silently parks the fixture")
        }
    }

    func testRejectsAForeignSchemeOrHost() {
        XCTAssertNil(LabRadio.parse(url: URL(string: "hopdemo://radio?enabled=false")!))
        XCTAssertNil(LabRadio.parse(url: URL(string: "blelab://send?enabled=false")!))
        XCTAssertNil(LabRadio.parse(url: URL(string: "blelab://radio")!))
    }

    /// Default ON, so an existing install behaves exactly as it did before the switch existed. A
    /// fixture that went dormant on upgrade would be worse than no fixture, because the defect it
    /// reproduces would quietly stop reproducing.
    func testDefaultsToEnabledWhenUnset() {
        let key = "sh.hopme.blelab.radioEnabled"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(LabRadio.isEnabled)
    }

    /// Persistence is the whole mechanism: the app is relaunched by CoreBluetooth state restoration
    /// on any BLE event, so a switch that lived only in memory would be undone by the very thing it
    /// exists to survive.
    func testStatePersists() {
        let key = "sh.hopme.blelab.radioEnabled"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        LabRadio.isEnabled = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
        XCTAssertFalse(LabRadio.isEnabled)
        LabRadio.isEnabled = true
        XCTAssertTrue(LabRadio.isEnabled)
    }
}
