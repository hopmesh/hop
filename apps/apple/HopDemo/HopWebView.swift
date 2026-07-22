// A WebView backed entirely by the Hop network (DESIGN.md §30).
//
// A WKWebView with a custom `hops` URL-scheme handler: every request the page makes, the
// document itself and every sub-resource (CSS, JS, images) plus relative/same-origin links,
// which resolve against the `hops://` base, is routed through HopBearer.hopsFetch, i.e. HNS
// resolution + a sealed request to the domain's own endpoint over the mesh. No traffic
// touches the normal HTTPS stack; there is no third party terminating TLS.

import SwiftUI
import WebKit
import HopDriver
import HopDemoKit

/// Routes WKWebView's `hops://` requests through the Hop mesh. The page's content-type comes
/// back from the endpoint, so HTML renders as HTML and sub-resources load with the right MIME.
final class HopSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var bearer: HopBearer?
    var allowsRequest: ((WKWebView, URL) -> Bool)?
    private var active = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              allowsRequest?(webView, url) == true,
              let bearer else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let domain = url.host ?? ""
        let path = DemoFormat.requestPath(path: url.path, query: url.query)

        let key = ObjectIdentifier(task)
        active.insert(key)
        bearer.hopsFetch(domain: domain, path: path) { [weak self] resp in
            // Only touch the task if it hasn't been stopped (WebKit may cancel mid-flight).
            guard let self, self.active.remove(key) != nil else { return }
            let response = HTTPURLResponse(
                url: url,
                statusCode: resp.status,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": DemoFormat.contentTypeHeader(resp.contentType),
                    "Content-Security-Policy": DemoFormat.hopsContentSecurityPolicy,
                    "X-Content-Type-Options": "nosniff",
                ]
            )!
            task.didReceive(response)
            task.didReceive(resp.body)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }

    func detach() { active.removeAll() }
}

/// Lets SwiftUI drive a WKWebView (load / back / forward / reload) and observe its state.
final class HopWebController: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentURL: String = ""
    fileprivate weak var webView: WKWebView?
    fileprivate var policyReady = false

    func load(_ hopsURL: String) {
        guard policyReady, DemoFormat.browserAllowsURL(hopsURL), let url = URL(string: hopsURL) else { return }
        webView?.load(URLRequest(url: url))
    }
    func goBack() { if policyReady { webView?.goBack() } }
    func goForward() { if policyReady { webView?.goForward() } }
    func reload() { if policyReady { webView?.reload() } }
}

/// The WKWebView, with the `hops` scheme handler installed and bound to a controller.
struct HopWebView: UIViewRepresentable {
    let bearer: HopBearer
    @ObservedObject var controller: HopWebController
    let initialURL: String

    func makeCoordinator() -> Coordinator { Coordinator(bearer: bearer, controller: controller) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.preferences.javaScriptEnabled = false
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.allowsAirPlayForMediaPlayback = false
        cfg.setURLSchemeHandler(context.coordinator.handler, forURLScheme: "hops")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator.navigationDelegate
        wv.uiDelegate = context.coordinator.navigationDelegate
        context.coordinator.attach(wv, initialURL: initialURL)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.detach(uiView)
    }

    final class Coordinator: NSObject {
        let handler = HopSchemeHandler()
        let navigationDelegate = BrowserPolicyDelegate()
        let controller: HopWebController
        private var lifecycle = BrowserPolicyLifecycle()
        private var nextAttachment: UInt64 = 0
        private var attachment: UInt64?
        private weak var attachedWebView: WKWebView?

        init(bearer: HopBearer, controller: HopWebController) {
            self.handler.bearer = bearer
            self.controller = controller
            super.init()
            navigationDelegate.allowsURL = { [weak self] webView, url in
                self?.allows(webView, url: url) == true
            }
            navigationDelegate.didCommitNavigation = { [weak self] in self?.sync($0) }
            navigationDelegate.didFinishNavigation = { [weak self] in self?.sync($0) }
        }
        private func sync(_ wv: WKWebView) {
            controller.canGoBack = wv.canGoBack
            controller.canGoForward = wv.canGoForward
            controller.currentURL = wv.url?.absoluteString ?? ""
        }
        func attach(_ webView: WKWebView, initialURL: String) {
            if let current = attachedWebView { detach(current) }
            nextAttachment &+= 1
            let token = nextAttachment
            let generation = lifecycle.attach(token)
            attachment = token
            attachedWebView = webView
            controller.webView = webView
            controller.policyReady = false
            installIsolationRules(in: webView, initialURL: initialURL,
                                  attachment: token, generation: generation)
        }

        func detach(_ webView: WKWebView) {
            guard webView === attachedWebView, let token = attachment else { return }
            lifecycle.detach(token)
            attachment = nil
            attachedWebView = nil
            controller.policyReady = false
            controller.canGoBack = false
            controller.canGoForward = false
            controller.currentURL = ""
            if controller.webView === webView { controller.webView = nil }
            handler.detach()
            webView.stopLoading()
            if webView.navigationDelegate === navigationDelegate { webView.navigationDelegate = nil }
            if webView.uiDelegate === navigationDelegate { webView.uiDelegate = nil }
            webView.configuration.userContentController.removeAllContentRuleLists()
        }

        private func installIsolationRules(in webView: WKWebView, initialURL: String,
                                           attachment token: UInt64, generation: UInt64) {
            let rules = """
            [
              {"trigger":{"url-filter":".*"},"action":{"type":"block"}},
              {"trigger":{"url-filter":"^hops:"},"action":{"type":"ignore-previous-rules"}},
              {"trigger":{"url-filter":"^about:blank$"},"action":{"type":"ignore-previous-rules"}}
            ]
            """
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "sh.hopme.hops-only.v1", encodedContentRuleList: rules
            ) { [weak self, weak webView] list, _ in
                DispatchQueue.main.async {
                    guard let self, let webView,
                          self.lifecycle.isCurrent(attachment: token, generation: generation),
                          webView === self.attachedWebView else { return }
                    guard let list else {
                        _ = self.lifecycle.complete(attachment: token, generation: generation,
                                                    installed: false)
                        self.controller.policyReady = false
                        return
                    }
                    webView.configuration.userContentController.add(list)
                    guard self.lifecycle.complete(attachment: token, generation: generation,
                                                  installed: true) else { return }
                    self.controller.policyReady = true
                    if self.lifecycle.allows(initialURL, attachment: token),
                       let url = URL(string: initialURL) {
                        webView.load(URLRequest(url: url))
                    }
                }
            }
        }

        private func allows(_ webView: WKWebView, url: URL) -> Bool {
            guard webView === attachedWebView, let token = attachment else { return false }
            return lifecycle.allows(url.absoluteString, attachment: token)
        }
    }
}

/// A minimal hops:// browser: address bar + back/forward/reload + the mesh-backed WebView.
struct HopBrowserView: View {
    let bearer: HopBearer
    @StateObject private var controller = HopWebController()
    @State private var address: String
    private let initialURL: String

    init(bearer: HopBearer, start domain: String) {
        self.bearer = bearer
        let url = DemoFormat.normalizeHopsURL(domain, defaultHost: "example.hopme.sh")
        self.initialURL = url
        _address = State(initialValue: url)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { controller.goBack() } label: { FaIcon(name: "ic_fa_chevron_left", size: 16) }
                    .disabled(!controller.canGoBack)
                Button { controller.goForward() } label: { FaIcon(name: "ic_fa_chevron_right", size: 16) }
                    .disabled(!controller.canGoForward)
                TextField("hops://example.hopme.sh", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .onSubmit { go() }
                Button { controller.reload() } label: { FaIcon(name: "ic_fa_arrows_rotate", size: 16) }
            }
            .padding(8)
            Divider()
            HopWebView(bearer: bearer, controller: controller, initialURL: initialURL)
        }
        .navigationTitle("hops:// browser")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: controller.currentURL) { new in
            if !new.isEmpty { address = new }   // reflect link navigations in the bar
        }
    }

    private func go() {
        let s = DemoFormat.normalizeHopsURL(address)
        address = s
        controller.load(s)
    }
}
