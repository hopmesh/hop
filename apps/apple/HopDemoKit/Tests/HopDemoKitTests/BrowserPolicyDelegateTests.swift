#if canImport(WebKit)
import XCTest
import WebKit
@testable import HopDemoKit

final class BrowserPolicyDelegateTests: XCTestCase {
    func testRealWebKitDelegateSeamIsFailClosedWithoutLoadingANetworkURL() {
        let delegate = BrowserPolicyDelegate()
        let webView = WKWebView(frame: .zero)
        let hops = URL(string: "hops://example.hop/page")!
        XCTAssertEqual(delegate.actionPolicy(for: webView, url: hops), .cancel)
        XCTAssertEqual(delegate.responsePolicy(for: webView, url: nil), .cancel)

        delegate.allowsURL = { candidate, url in
            candidate === webView && DemoFormat.browserAllowsURL(url.absoluteString)
        }
        XCTAssertEqual(delegate.actionPolicy(for: webView, url: hops), .allow)
        XCTAssertEqual(delegate.responsePolicy(for: webView, url: URL(string: "https://example.test")), .cancel)
    }
}
#endif
