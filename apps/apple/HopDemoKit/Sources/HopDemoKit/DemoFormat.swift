// DemoFormat - the deterministic, UI-independent logic behind the HopDemo screens.
//
// Everything here is a pure function (or a CoreImage/ImageIO bitmap builder that does not touch
// UIKit), so it runs and is covered under a headless macOS `swift test`. The SwiftUI View bodies,
// the AVFoundation camera scanner, the WKWebView glue, PhotosUI, and BackgroundTasks stay in the
// app target: they are UI/device-bound and cannot run without a running app. The app's Views call
// straight into these helpers so the extraction is behavior-preserving, not a parallel copy.
//
// Punctuation note: this file uses only ASCII plus the interpunct (U+00B7, the middle dot the app
// already renders between metadata fields). There are no em-dashes or en-dashes anywhere.

import Foundation
#if canImport(CoreImage)
import CoreImage
import CoreImage.CIFilterBuiltins
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Pure formatting + parsing helpers shared by the demo screens.
public enum DemoFormat {

    // MARK: - Transport glyph + tag mapping

    /// Font Awesome (Light) asset name for a transport tag. "LAN" (local network over shared
    /// Wi-Fi) and "P2P" (peer-to-peer Wi-Fi, AWDL) get distinct glyphs; "BT" is the Bluetooth
    /// brand glyph; anything unknown falls back to the mesh-nodes glyph.
    public static func transportIcon(_ tag: String) -> String {
        switch tag {
        case "BT": return "ic_fa_bluetooth_b"
        case "LAN": return "ic_fa_wifi"          // local network over a shared Wi-Fi/router
        case "P2P": return "ic_fa_circle_nodes"  // peer-to-peer WLAN (AWDL), no router
        case "Relay": return "ic_fa_cloud"
        default: return "ic_fa_circle_nodes"
        }
    }

    /// Map a TransportStatus id to the short tag used in `linkTransports`.
    public static func transportTag(_ id: String) -> String {
        switch id {
        case "Bluetooth": return "BT"
        case "Peer-to-Peer": return "P2P"
        case "Local Net": return "LAN"
        default: return id
        }
    }

    /// "iOS" / "Android" / passthrough from the raw platform tag.
    public static func platformLabel(_ p: String) -> String {
        switch p { case "ios": return "iOS"; case "android": return "Android"; default: return p }
    }

    /// A peer is "direct" (a 1-hop neighbour) when its hop count is <= 1. A live BT/Wi-Fi link is
    /// forced to 1 hop upstream, so this single rule covers both live links and direct adverts.
    public static func isDirect(hops: UInt8) -> Bool { hops <= 1 }

    // MARK: - Peer subtitle

    /// Peer subtitle: address . platform . app, joined by " \u{00B7} ", omitting empty fields.
    /// `shortAddress` is the already-shortened address string (the caller resolves it via the
    /// driver's base58 helper, which needs the FFI and so stays out of this pure layer).
    public static func subline(shortAddress: String, platform: String, app: String) -> String {
        [shortAddress, platformLabel(platform), app]
            .filter { !$0.isEmpty }
            .joined(separator: " \u{00B7} ")
    }

    // MARK: - Message metadata

    /// A single link to the destination is "direct" (0 relays); >= 2 shows the hop count.
    public static func hopsLabel(_ h: UInt8) -> String { h <= 1 ? "direct" : "\(h) hops" }

    /// Compact elapsed-time label: 3s / 5m / 2h / 4d.
    public static func compactDuration(_ ms: UInt64) -> String {
        let s = ms / 1000
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h" }
        return "\(h / 24)d"
    }

    /// One-line metadata under a chat bubble.
    /// Incoming: "2 hops, 1m" (path length + send->receive time; the time is omitted when unknown).
    /// Outgoing, acked: "Delivered, 10 hops, 2h" (forward A->B time and hop count the recipient
    /// reported). Outgoing, failed: "Not sent". Otherwise: "Sent \u{00B7} N peer(s)".
    ///
    /// Note: when the message is outgoing, not delivered, not failed, and `relayed == 0`, the app
    /// renders a live SendingIndicator view instead of this string; `messageMeta` still returns the
    /// "Sent \u{00B7} 0 peers" form for that case so the pure logic stays total.
    /// The ORIGINATING device's send time, for the message list.
    ///
    /// Two deliberate choices. **No seconds:** on the §39 private path (the default) the wire
    /// `created_at` is bucketed to 60s and rounded down, because at millisecond resolution it is a
    /// sender timing fingerprint. Rendering seconds would imply precision the protocol removes on
    /// purpose. **A date once it is not today:** hop is delay-tolerant, so a bundle can arrive hours
    /// or days after it was sent, and a bare "09:12" on a three-day-old message reads as recent.
    ///
    /// 24-hour and built from calendar components rather than a `DateFormatter`, so the output is
    /// locale-independent and the tests cannot flake on the runner's region settings.
    public static func originStamp(_ origin: Date, now: Date, calendar: Calendar = .current) -> String {
        let o = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: origin)
        guard let oy = o.year, let om = o.month, let od = o.day, let oh = o.hour, let omin = o.minute else { return "" }
        let hhmm = String(format: "%02d:%02d", oh, omin)
        if calendar.isDate(origin, inSameDayAs: now) { return hhmm }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(origin, inSameDayAs: y) {
            return "Yesterday \(hhmm)"
        }
        let nowYear = calendar.component(.year, from: now)
        let mon = monthAbbrev(om)
        return oy == nowYear ? "\(od) \(mon) \(hhmm)" : "\(od) \(mon) \(oy) \(hhmm)"
    }

    private static func monthAbbrev(_ m: Int) -> String {
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return (1...12).contains(m) ? names[m - 1] : "?"
    }

    public static func messageMeta(incoming: Bool,
                                   hops: UInt8,
                                   latencyMs: UInt64?,
                                   delivered: Bool,
                                   deliveryHops: UInt8,
                                   deliveryMs: UInt32,
                                   failed: Bool,
                                   relayed: UInt32) -> String {
        if incoming {
            var s = hopsLabel(hops)
            if let lat = latencyMs { s += ", \(compactDuration(lat))" }
            return s
        }
        if delivered {
            // The FORWARD (A->B) time the recipient reported, not the A->B->A round trip.
            let fwd = compactDuration(UInt64(deliveryMs))
            return "Delivered, \(hopsLabel(deliveryHops)), \(fwd)"
        }
        if failed { return "Not sent" }
        return "Sent \u{00B7} \(relayed) peer\(relayed == 1 ? "" : "s")"
    }

    // MARK: - hops:// URL normalization

    /// Normalize a user-entered hops:// address: trim whitespace, and prefix "hops://" if absent.
    /// When the trimmed input is empty, `defaultHost` (if given) is used as the host; with no
    /// default an empty input yields the bare scheme "hops://" (matching the browser's go() field).
    public static func normalizeHopsURL(_ raw: String, defaultHost: String? = nil) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower.hasPrefix("hops://") { return "hops://" + s.dropFirst(7) }
        if lower.hasPrefix("https://") { return "hops://" + s.dropFirst(8) }
        if lower.hasPrefix("http://") { return "hops://" + s.dropFirst(7) }
        let host = s.isEmpty ? (defaultHost ?? "") : s
        return "hops://\(host)"
    }

    /// The browser's complete URL policy. Only hierarchical, credential-free `hops` URLs and the
    /// explicit local `about:blank` bootstrap are allowed. Relative URLs inherit their supplied hops base.
    public static func browserAllowsURL(_ raw: String, relativeTo base: String? = nil) -> Bool {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.lowercased() == "about:blank" { return true }
        guard !input.isEmpty, !input.contains("\\") else { return false }
        let baseURL = base.flatMap(URL.init(string:))
        guard let url = URL(string: input, relativeTo: baseURL)?.absoluteURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "hops",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              let rawHost = components.host else { return false }
        let host = rawHost.lowercased()
        guard (1...253).contains(host.count), !host.hasSuffix("."), host.unicodeScalars.allSatisfy({
            (0x21...0x7e).contains(Int($0.value))
        }) else { return false }
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            (1...63).contains(label.count) && label.first != "-" && label.last != "-" &&
                label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    /// Defense in depth for active content and subresources that bypass navigation callbacks.
    public static let hopsContentSecurityPolicy =
        "default-src 'none'; img-src hops:; style-src hops:; font-src hops:; frame-src hops:; " +
        "media-src hops:; connect-src hops:; script-src 'none'; object-src 'none'; " +
        "base-uri 'none'; form-action 'none'"

    // MARK: - hops:// scheme-handler request shaping

    /// Build the request path a hops:// resource fetch uses: an empty path becomes "/", and a
    /// non-empty query string is appended as "?<query>".
    public static func requestPath(path: String, query: String?) -> String {
        var p = path.isEmpty ? "/" : path
        if let q = query, !q.isEmpty { p += "?\(q)" }
        return p
    }

    /// The bare MIME type from a Content-Type value: the part before the first ";", or
    /// "application/octet-stream" when the value is empty/parameter-only.
    public static func mimeType(fromContentType ct: String) -> String {
        ct.split(separator: ";").first.map(String.init) ?? "application/octet-stream"
    }

    /// The Content-Type header value to hand WebKit: the endpoint's own value when present,
    /// else the derived bare MIME type (so an empty content-type still yields a usable header).
    public static func contentTypeHeader(_ ct: String) -> String {
        ct.isEmpty ? mimeType(fromContentType: ct) : ct
    }

    // MARK: - Automation control surface parsing (TEST/AUTOMATION)

    /// Parse a `hopdemo://send?to=<base58>&text=<marker>` deep link into (to, text). Returns nil
    /// unless the scheme is "hopdemo", the host is "send", and both query items are present.
    /// `queryItems` is the URLComponents query list mapped to (name, value) pairs by the caller.
    public static func parseAutomationURL(scheme: String?,
                                          host: String?,
                                          queryItems: [(name: String, value: String?)]) -> (to: String, text: String)? {
        guard scheme == "hopdemo", host == "send" else { return nil }
        guard let to = queryItems.first(where: { $0.name == "to" })?.value,
              let text = queryItems.first(where: { $0.name == "text" })?.value else { return nil }
        return (to, text)
    }

    /// Parse `hopdemo://bearer?tag=<BT|LAN|Relay|P2P>&enabled=<true|false>` into (tag, enabled), and
    /// `hopdemo://bearerstates` into a state-query request. Returns nil for anything else.
    ///
    /// This exists so PLAT-001's closure contract can be driven by a SCRIPT. The contract is to assert,
    /// while a peer is dialing, that no `LINKFLOW SEAM UP xport=BT` follows the toggle and that
    /// `bearerStates()["BT"] == false` agrees with `activeTransports()`. Before this, the toggle was
    /// reachable only by tapping the UI, so the assertion could not be re-run or regressed. A control
    /// that cannot be exercised by the thing meant to verify it is exactly the defect class this audit
    /// keeps surfacing.
    ///
    /// `enabled` is parsed STRICTLY: only the exact strings "true" and "false". A permissive parse
    /// would silently read a typo as `false` and a test would then "prove" a toggle that never ran.
    public static func parseBearerURL(scheme: String?,
                                      host: String?,
                                      queryItems: [(name: String, value: String?)]) -> BearerAutomation? {
        guard scheme == "hopdemo" else { return nil }
        if host == "bearerstates" { return .queryStates }
        guard host == "bearer" else { return nil }
        guard let tag = queryItems.first(where: { $0.name == "tag" })?.value, !tag.isEmpty,
              let raw = queryItems.first(where: { $0.name == "enabled" })?.value else { return nil }
        switch raw {
        case "true": return .setEnabled(tag: tag, enabled: true)
        case "false": return .setEnabled(tag: tag, enabled: false)
        default: return nil
        }
    }

    /// What a `hopdemo://bearer*` link asked for.
    public enum BearerAutomation: Equatable {
        /// Flip one shared transport, the same call the UI switch makes.
        case setEnabled(tag: String, enabled: Bool)
        /// Report the manager's own view of transport states and live link counts.
        case queryStates
    }

    /// Parse a `HOP_AUTO=send|<base58>|<marker text>` launch-env spec into (to, text). Only the
    /// first two "|" are structural; any further pipes are rejoined into the marker text so a
    /// message body may itself contain "|". Returns nil unless there are >= 3 parts led by "send".
    public static func parseAutomationEnv(_ spec: String) -> (to: String, text: String)? {
        let parts = spec.components(separatedBy: "|")
        guard parts.count >= 3, parts[0] == "send" else { return nil }
        let text = parts[2...].joined(separator: "|")
        return (parts[1], text)
    }

    // MARK: - QR bitmap + photo downscale (CoreImage / ImageIO, no UIKit)

    #if canImport(CoreImage)
    /// Build a crisp QR code CGImage for `text` (correction level M, 10x nearest-neighbour scale).
    /// The app wraps the result in a UIImage; returning a CGImage keeps this testable off-device.
    public static func qrCGImage(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        let ctx = CIContext()
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = ctx.createCGImage(out, from: out.extent) else { return nil }
        return cg
    }
    #endif

    #if canImport(ImageIO)
    /// Downscale a picked photo to a thumbnail whose longest edge is at most `maxPixel`, decoding
    /// a reduced-size image directly via ImageIO (low memory/CPU) instead of loading the full
    /// image. The app JPEG-encodes the result; the decode+downscale is the bug-prone part and is
    /// what this covers. Returns nil when the data is not a decodable image.
    public static func downscaledCGImage(_ data: Data, maxPixel: CGFloat = 1280) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
    #endif
}

/// Fail-closed state for one currently attached browser view. The caller supplies an attachment token
/// and carries the returned generation into asynchronous rule-list completion.
public struct BrowserPolicyLifecycle {
    public private(set) var generation: UInt64 = 0
    public private(set) var attachment: UInt64?
    public private(set) var policyReady = false

    public init() {}

    @discardableResult
    public mutating func attach(_ token: UInt64) -> UInt64 {
        generation &+= 1
        attachment = token
        policyReady = false
        return generation
    }

    public mutating func detach(_ token: UInt64) {
        guard attachment == token else { return }
        generation &+= 1
        attachment = nil
        policyReady = false
    }

    public func isCurrent(attachment token: UInt64, generation expected: UInt64) -> Bool {
        attachment == token && generation == expected
    }

    /// Returns true only when this completion installed rules for the current attachment.
    @discardableResult
    public mutating func complete(attachment token: UInt64, generation expected: UInt64,
                                  installed: Bool) -> Bool {
        guard isCurrent(attachment: token, generation: expected) else { return false }
        policyReady = installed
        return installed
    }

    public func allows(_ rawURL: String, attachment token: UInt64) -> Bool {
        attachment == token && policyReady && DemoFormat.browserAllowsURL(rawURL)
    }
}

/// QR identity-exchange payload, shared with Android: "<base58 address>|<name>". The name is
/// optional. Pure string logic, so it lives in the testable layer.
public enum HopQR {
    /// Encode an address + name into the "<address>|<name>" payload.
    public static func encode(address base58: String, name: String) -> String { "\(base58)|\(name)" }

    /// Decode a scanned payload into (address, name). Tolerates a leading "hop:" prefix. Returns
    /// nil when there is no non-empty address. A missing name decodes as the empty string.
    public static func decode(_ s: String) -> (address: String, name: String)? {
        let body = s.hasPrefix("hop:") ? String(s.dropFirst(4)) : s   // tolerate a hop: prefix
        let parts = body.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let addr = parts.first, !addr.isEmpty else { return nil }
        let name = parts.count > 1 ? String(parts[1]) : ""
        return (String(addr), name)
    }
}

/// Screen and recents privacy policy (PLAT-011):
/// When an app becomes inactive or backgrounded, OS snapshots and casual screen capture must not
/// retain readable message bodies, media, identity addresses, or private endpoint configuration.
public struct ScreenPrivacyState: Equatable, Sendable {
    public enum Phase: Sendable {
        case active
        case inactive
        case background
    }

    /// Whether the privacy shield must cover the window. Starts true on launch so cold background
    /// launch, notification entry, and process restoration never flash sensitive UI before active.
    public private(set) var isObscured: Bool

    public init(initiallyObscured: Bool = true) {
        self.isObscured = initiallyObscured
    }

    /// Transition to a new scene phase. Only .active uncovers sensitive content.
    @discardableResult
    public mutating func transition(to phase: Phase) -> Bool {
        switch phase {
        case .active:
            isObscured = false
        case .inactive, .background:
            isObscured = true
        }
        return isObscured
    }
}
