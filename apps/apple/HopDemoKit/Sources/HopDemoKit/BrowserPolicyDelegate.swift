import Foundation

#if canImport(WebKit)
import WebKit

/// The production WebKit delegate seam. Policy stays injectable so the delegate can be exercised
/// headlessly without loading a URL or reaching an external network.
public final class BrowserPolicyDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    public var allowsURL: ((WKWebView, URL) -> Bool)?
    public var didCommitNavigation: ((WKWebView) -> Void)?
    public var didFinishNavigation: ((WKWebView) -> Void)?

    public override init() { super.init() }

    public func actionPolicy(for webView: WKWebView, url: URL?) -> WKNavigationActionPolicy {
        guard let url, allowsURL?(webView, url) == true else { return .cancel }
        return .allow
    }

    public func responsePolicy(for webView: WKWebView, url: URL?) -> WKNavigationResponsePolicy {
        guard let url, allowsURL?(webView, url) == true else { return .cancel }
        return .allow
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(actionPolicy(for: webView, url: navigationAction.request.url))
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(responsePolicy(for: webView, url: navigationResponse.response.url))
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                        for navigationAction: WKNavigationAction,
                        windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        didCommitNavigation?(webView)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishNavigation?(webView)
    }
}
#endif
