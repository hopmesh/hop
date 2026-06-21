// A WebView backed entirely by the Hop network (DESIGN.md §30).
//
// A WKWebView with a custom `hops` URL-scheme handler: every request the page makes — the
// document itself and every sub-resource (CSS, JS, images) plus relative/same-origin links,
// which resolve against the `hops://` base — is routed through HopBearer.hopsFetch, i.e. HNS
// resolution + a sealed request to the domain's own endpoint over the mesh. No traffic
// touches the normal HTTPS stack; there is no third party terminating TLS.

import SwiftUI
import WebKit

/// Routes WKWebView's `hops://` requests through the Hop mesh. The page's content-type comes
/// back from the endpoint, so HTML renders as HTML and sub-resources load with the right MIME.
final class HopSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var bearer: HopBearer?
    private var active = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let bearer else {
            task.didFailWithError(URLError(.badURL)); return
        }
        let domain = url.host ?? ""
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query, !q.isEmpty { path += "?\(q)" }

        let key = ObjectIdentifier(task)
        active.insert(key)
        bearer.hopsFetch(domain: domain, path: path) { [weak self] resp in
            // Only touch the task if it hasn't been stopped (WebKit may cancel mid-flight).
            guard let self, self.active.remove(key) != nil else { return }
            let mime = resp.contentType.split(separator: ";").first.map(String.init) ?? "application/octet-stream"
            let response = HTTPURLResponse(
                url: url,
                statusCode: resp.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": resp.contentType.isEmpty ? mime : resp.contentType]
            )!
            task.didReceive(response)
            task.didReceive(resp.body)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(task))
    }
}

/// Lets SwiftUI drive a WKWebView (load / back / forward / reload) and observe its state.
final class HopWebController: ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentURL: String = ""
    fileprivate weak var webView: WKWebView?

    func load(_ hopsURL: String) {
        guard let url = URL(string: hopsURL) else { return }
        webView?.load(URLRequest(url: url))
    }
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
}

/// The WKWebView, with the `hops` scheme handler installed and bound to a controller.
struct HopWebView: UIViewRepresentable {
    let bearer: HopBearer
    @ObservedObject var controller: HopWebController
    let initialURL: String

    func makeCoordinator() -> Coordinator { Coordinator(bearer: bearer, controller: controller) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(context.coordinator.handler, forURLScheme: "hops")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        controller.webView = wv
        if let url = URL(string: initialURL) { wv.load(URLRequest(url: url)) }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let handler = HopSchemeHandler()
        let controller: HopWebController
        init(bearer: HopBearer, controller: HopWebController) {
            self.handler.bearer = bearer
            self.controller = controller
        }
        private func sync(_ wv: WKWebView) {
            controller.canGoBack = wv.canGoBack
            controller.canGoForward = wv.canGoForward
            controller.currentURL = wv.url?.absoluteString ?? ""
        }
        func webView(_ wv: WKWebView, didCommit nav: WKNavigation!) { sync(wv) }
        func webView(_ wv: WKWebView, didFinish nav: WKNavigation!) { sync(wv) }
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
        let d = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = d.hasPrefix("hops://") ? d : "hops://\(d.isEmpty ? "example.hopme.sh" : d)"
        self.initialURL = url
        _address = State(initialValue: url)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { controller.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!controller.canGoBack)
                Button { controller.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!controller.canGoForward)
                TextField("hops://example.hopme.sh", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .onSubmit { go() }
                Button { controller.reload() } label: { Image(systemName: "arrow.clockwise") }
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
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("hops://") { s = "hops://\(s)" }
        address = s
        controller.load(s)
    }
}
