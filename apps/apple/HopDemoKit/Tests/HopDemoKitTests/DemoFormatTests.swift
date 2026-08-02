import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import HopDemoKit

// Headless unit tests for the demo app's extracted non-UI logic. These run under macOS
// `swift test`; the SwiftUI/UIKit/WebKit/AVFoundation screens are excluded (see the CI gate note
// in .github/workflows/ci.yml). No em-dashes anywhere in this file.
final class DemoFormatTests: XCTestCase {

    // MARK: transportIcon

    func testTransportIconKnownTags() {
        XCTAssertEqual(DemoFormat.transportIcon("BT"), "ic_fa_bluetooth_b")
        XCTAssertEqual(DemoFormat.transportIcon("LAN"), "ic_fa_wifi")
        XCTAssertEqual(DemoFormat.transportIcon("P2P"), "ic_fa_circle_nodes")
        XCTAssertEqual(DemoFormat.transportIcon("Relay"), "ic_fa_cloud")
    }

    func testTransportIconUnknownFallsBackToNodes() {
        XCTAssertEqual(DemoFormat.transportIcon("wat"), "ic_fa_circle_nodes")
        XCTAssertEqual(DemoFormat.transportIcon(""), "ic_fa_circle_nodes")
    }

    // MARK: transportTag

    func testTransportTagMapsStatusIds() {
        XCTAssertEqual(DemoFormat.transportTag("Bluetooth"), "BT")
        XCTAssertEqual(DemoFormat.transportTag("Peer-to-Peer"), "P2P")
        XCTAssertEqual(DemoFormat.transportTag("Local Net"), "LAN")
    }

    func testTransportTagPassthroughForUnknown() {
        XCTAssertEqual(DemoFormat.transportTag("Relay"), "Relay")
        XCTAssertEqual(DemoFormat.transportTag("anything"), "anything")
    }

    // transportTag then transportIcon should compose the way the transport list expects.
    func testTagThenIconComposition() {
        XCTAssertEqual(DemoFormat.transportIcon(DemoFormat.transportTag("Local Net")), "ic_fa_wifi")
        XCTAssertEqual(DemoFormat.transportIcon(DemoFormat.transportTag("Bluetooth")), "ic_fa_bluetooth_b")
    }

    // MARK: platformLabel

    func testPlatformLabel() {
        XCTAssertEqual(DemoFormat.platformLabel("ios"), "iOS")
        XCTAssertEqual(DemoFormat.platformLabel("android"), "Android")
        XCTAssertEqual(DemoFormat.platformLabel(""), "")
        XCTAssertEqual(DemoFormat.platformLabel("linux"), "linux")
    }

    // MARK: isDirect

    func testIsDirect() {
        XCTAssertTrue(DemoFormat.isDirect(hops: 0))
        XCTAssertTrue(DemoFormat.isDirect(hops: 1))
        XCTAssertFalse(DemoFormat.isDirect(hops: 2))
        XCTAssertFalse(DemoFormat.isDirect(hops: 9))
    }

    // MARK: subline

    func testSublineAllFields() {
        XCTAssertEqual(
            DemoFormat.subline(shortAddress: "AbCd1234", platform: "ios", app: "Hop"),
            "AbCd1234 \u{00B7} iOS \u{00B7} Hop")
    }

    func testSublineOmitsEmptyFields() {
        XCTAssertEqual(DemoFormat.subline(shortAddress: "AbCd1234", platform: "", app: ""), "AbCd1234")
        XCTAssertEqual(
            DemoFormat.subline(shortAddress: "AbCd1234", platform: "android", app: ""),
            "AbCd1234 \u{00B7} Android")
        XCTAssertEqual(
            DemoFormat.subline(shortAddress: "AbCd1234", platform: "", app: "Demo"),
            "AbCd1234 \u{00B7} Demo")
    }

    func testSublineAllEmpty() {
        XCTAssertEqual(DemoFormat.subline(shortAddress: "", platform: "", app: ""), "")
    }

    // MARK: hopsLabel

    func testHopsLabel() {
        XCTAssertEqual(DemoFormat.hopsLabel(0), "direct")
        XCTAssertEqual(DemoFormat.hopsLabel(1), "direct")
        XCTAssertEqual(DemoFormat.hopsLabel(2), "2 hops")
        XCTAssertEqual(DemoFormat.hopsLabel(10), "10 hops")
    }

    // MARK: compactDuration

    func testCompactDurationSeconds() {
        XCTAssertEqual(DemoFormat.compactDuration(0), "0s")
        XCTAssertEqual(DemoFormat.compactDuration(3_000), "3s")
        XCTAssertEqual(DemoFormat.compactDuration(59_000), "59s")
    }

    func testCompactDurationMinutes() {
        XCTAssertEqual(DemoFormat.compactDuration(60_000), "1m")
        XCTAssertEqual(DemoFormat.compactDuration(5 * 60_000), "5m")
        XCTAssertEqual(DemoFormat.compactDuration(59 * 60_000), "59m")
    }

    func testCompactDurationHours() {
        XCTAssertEqual(DemoFormat.compactDuration(60 * 60_000), "1h")
        XCTAssertEqual(DemoFormat.compactDuration(2 * 60 * 60_000), "2h")
        XCTAssertEqual(DemoFormat.compactDuration(23 * 60 * 60_000), "23h")
    }

    func testCompactDurationDays() {
        XCTAssertEqual(DemoFormat.compactDuration(24 * 60 * 60_000), "1d")
        XCTAssertEqual(DemoFormat.compactDuration(4 * 24 * 60 * 60_000), "4d")
    }

    // MARK: messageMeta

    func testMessageMetaIncomingWithLatency() {
        let s = DemoFormat.messageMeta(incoming: true, hops: 2, latencyMs: 60_000,
                                       delivered: false, deliveryHops: 0, deliveryMs: 0,
                                       failed: false, relayed: 0)
        XCTAssertEqual(s, "2 hops, 1m")
    }

    func testMessageMetaIncomingDirectNoLatency() {
        let s = DemoFormat.messageMeta(incoming: true, hops: 1, latencyMs: nil,
                                       delivered: false, deliveryHops: 0, deliveryMs: 0,
                                       failed: false, relayed: 0)
        XCTAssertEqual(s, "direct")
    }

    func testMessageMetaDelivered() {
        let s = DemoFormat.messageMeta(incoming: false, hops: 0, latencyMs: nil,
                                       delivered: true, deliveryHops: 10, deliveryMs: 2 * 60 * 60_000,
                                       failed: false, relayed: 3)
        XCTAssertEqual(s, "Delivered, 10 hops, 2h")
    }

    func testMessageMetaDeliveredDirect() {
        let s = DemoFormat.messageMeta(incoming: false, hops: 0, latencyMs: nil,
                                       delivered: true, deliveryHops: 1, deliveryMs: 3_000,
                                       failed: false, relayed: 1)
        XCTAssertEqual(s, "Delivered, direct, 3s")
    }

    func testMessageMetaFailed() {
        let s = DemoFormat.messageMeta(incoming: false, hops: 0, latencyMs: nil,
                                       delivered: false, deliveryHops: 0, deliveryMs: 0,
                                       failed: true, relayed: 0)
        XCTAssertEqual(s, "Not sent")
    }

    func testMessageMetaSentPluralization() {
        let zero = DemoFormat.messageMeta(incoming: false, hops: 0, latencyMs: nil,
                                          delivered: false, deliveryHops: 0, deliveryMs: 0,
                                          failed: false, relayed: 0)
        XCTAssertEqual(zero, "Sent \u{00B7} 0 peers")
        let one = DemoFormat.messageMeta(incoming: false, hops: 0, latencyMs: nil,
                                         delivered: false, deliveryHops: 0, deliveryMs: 0,
                                         failed: false, relayed: 1)
        XCTAssertEqual(one, "Sent \u{00B7} 1 peer")
        let many = DemoFormat.messageMeta(incoming: false, hops: 0, latencyMs: nil,
                                          delivered: false, deliveryHops: 0, deliveryMs: 0,
                                          failed: false, relayed: 4)
        XCTAssertEqual(many, "Sent \u{00B7} 4 peers")
    }

    // MARK: normalizeHopsURL

    func testNormalizeHopsURLAddsScheme() {
        XCTAssertEqual(DemoFormat.normalizeHopsURL("example.hopme.sh"), "hops://example.hopme.sh")
    }

    func testNormalizeHopsURLKeepsExistingScheme() {
        XCTAssertEqual(DemoFormat.normalizeHopsURL("hops://foo.hopme.sh"), "hops://foo.hopme.sh")
        XCTAssertEqual(DemoFormat.normalizeHopsURL("HOPS://foo.hopme.sh"), "hops://foo.hopme.sh")
        XCTAssertEqual(DemoFormat.normalizeHopsURL("HTTPS://foo.hopme.sh"), "hops://foo.hopme.sh")
    }

    func testNormalizeHopsURLTrimsWhitespace() {
        XCTAssertEqual(DemoFormat.normalizeHopsURL("  example.hopme.sh \n"), "hops://example.hopme.sh")
        XCTAssertEqual(DemoFormat.normalizeHopsURL("  hops://foo \t"), "hops://foo")
    }

    func testNormalizeHopsURLEmptyWithDefaultHost() {
        XCTAssertEqual(DemoFormat.normalizeHopsURL("", defaultHost: "example.hopme.sh"),
                       "hops://example.hopme.sh")
        XCTAssertEqual(DemoFormat.normalizeHopsURL("   ", defaultHost: "example.hopme.sh"),
                       "hops://example.hopme.sh")
    }

    func testNormalizeHopsURLEmptyWithoutDefaultHost() {
        XCTAssertEqual(DemoFormat.normalizeHopsURL(""), "hops://")
    }

    func testBrowserPolicyAllowsHopsBootstrapAndRelativeResources() {
        XCTAssertTrue(DemoFormat.browserAllowsURL("hops://example.hop/page"))
        XCTAssertTrue(DemoFormat.browserAllowsURL("HOPS://EXAMPLE.HOP/page"))
        XCTAssertTrue(DemoFormat.browserAllowsURL("about:blank"))
        XCTAssertTrue(DemoFormat.browserAllowsURL("/image.png", relativeTo: "hops://example.hop/page"))
        XCTAssertTrue(DemoFormat.browserAllowsURL("//other.hop/frame", relativeTo: "hops://example.hop/page"))
    }

    func testBrowserPolicyDeniesTopLevelAndEveryActiveSubresourceScheme() {
        let blocked = [
            "http://evil.test/", "HTTPS://evil.test/script.js", "ws://evil.test/socket",
            "WSS://evil.test/socket", "data:text/html,boom", "blob:hops://example.hop/id",
            "file:///etc/passwd", "content://authority/item", "intent://evil/#Intent;scheme=https;end",
            "javascript:alert(1)", "custom://evil/path",
        ]
        for url in blocked { XCTAssertFalse(DemoFormat.browserAllowsURL(url), "must block \(url)") }
    }

    func testBrowserPolicyRejectsAmbiguousAuthoritiesAndSmuggling() {
        let blocked = [
            "hops://user@example.hop/", "hops://example.hop:443/", "hops:opaque",
            "hops://example.hop/#fragment", "hops://example.hop\\@evil.test/",
            "https:relative.js", "//evil.test/x",
        ]
        for url in blocked { XCTAssertFalse(DemoFormat.browserAllowsURL(url), "must block \(url)") }
    }

    func testBrowserPolicyCoversScriptImageFrameFetchAndWebSocketForms() {
        let base = "hops://site.hop/index.html"
        for relative in ["script.js", "./image.png", "../frame.html", "/api/fetch", "socket"] {
            XCTAssertTrue(DemoFormat.browserAllowsURL(relative, relativeTo: base))
        }
        for external in [
            "https://cdn.test/script.js", "http://img.test/a.png", "data:text/html,<iframe>",
            "https://api.test/fetch", "wss://socket.test/chat",
        ] {
            XCTAssertFalse(DemoFormat.browserAllowsURL(external, relativeTo: base))
        }
        XCTAssertTrue(DemoFormat.hopsContentSecurityPolicy.contains("script-src 'none'"))
        XCTAssertTrue(DemoFormat.hopsContentSecurityPolicy.contains("connect-src hops:"))
    }

    func testBrowserPolicyLifecycleRejectsStaleAttachmentCompletion() {
        var lifecycle = BrowserPolicyLifecycle()
        let generationA = lifecycle.attach(101)
        XCTAssertFalse(lifecycle.policyReady)
        XCTAssertFalse(lifecycle.allows("hops://a.hop", attachment: 101))

        lifecycle.detach(101)
        let generationB = lifecycle.attach(202)
        XCTAssertFalse(lifecycle.complete(attachment: 101, generation: generationA, installed: true))
        XCTAssertFalse(lifecycle.policyReady)

        XCTAssertFalse(lifecycle.complete(attachment: 202, generation: generationB, installed: false))
        XCTAssertFalse(lifecycle.allows("hops://b.hop", attachment: 202))
        XCTAssertTrue(lifecycle.complete(attachment: 202, generation: generationB, installed: true))
        XCTAssertTrue(lifecycle.allows("hops://b.hop", attachment: 202))
        XCTAssertFalse(lifecycle.allows("hops://a.hop", attachment: 101))
    }

    func testReadyLifecycleStillRejectsEveryNonHopsScheme() {
        var lifecycle = BrowserPolicyLifecycle()
        let generation = lifecycle.attach(7)
        XCTAssertTrue(lifecycle.complete(attachment: 7, generation: generation, installed: true))
        let blocked = [
            "http://x.test", "https://x.test", "ws://x.test", "wss://x.test",
            "ftp://x.test", "file:///tmp/x", "data:text/plain,x", "blob:hops://x.hop/id",
            "javascript:alert(1)", "about:srcdoc", "mailto:x@test", "tel:+15551212",
            "sms:+15551212", "facetime:x@test", "cid:x", "content://x/y", "intent://x",
            "webkit-fake-url://x", "x-apple-data-detectors://x", "custom://x",
        ]
        for url in blocked {
            XCTAssertFalse(lifecycle.allows(url, attachment: 7), "must block \(url)")
        }
    }

    // MARK: requestPath

    func testRequestPathEmptyBecomesRoot() {
        XCTAssertEqual(DemoFormat.requestPath(path: "", query: nil), "/")
    }

    func testRequestPathKeepsPath() {
        XCTAssertEqual(DemoFormat.requestPath(path: "/style.css", query: nil), "/style.css")
    }

    func testRequestPathAppendsQuery() {
        XCTAssertEqual(DemoFormat.requestPath(path: "/search", query: "q=hop&n=2"), "/search?q=hop&n=2")
        XCTAssertEqual(DemoFormat.requestPath(path: "", query: "a=1"), "/?a=1")
    }

    func testRequestPathIgnoresEmptyQuery() {
        XCTAssertEqual(DemoFormat.requestPath(path: "/x", query: ""), "/x")
    }

    // MARK: mimeType / contentTypeHeader

    func testMimeTypeStripsParameters() {
        XCTAssertEqual(DemoFormat.mimeType(fromContentType: "text/html; charset=utf-8"), "text/html")
        XCTAssertEqual(DemoFormat.mimeType(fromContentType: "image/png"), "image/png")
    }

    func testMimeTypeEmptyDefaults() {
        XCTAssertEqual(DemoFormat.mimeType(fromContentType: ""), "application/octet-stream")
    }

    func testContentTypeHeaderPrefersProvided() {
        XCTAssertEqual(DemoFormat.contentTypeHeader("text/html; charset=utf-8"),
                       "text/html; charset=utf-8")
    }

    func testContentTypeHeaderEmptyFallsBack() {
        XCTAssertEqual(DemoFormat.contentTypeHeader(""), "application/octet-stream")
    }

    // MARK: parseAutomationURL

    func testParseAutomationURLValid() {
        let r = DemoFormat.parseAutomationURL(scheme: "hopdemo", host: "send",
                                              queryItems: [("to", "AbC"), ("text", "hello")])
        XCTAssertEqual(r?.to, "AbC")
        XCTAssertEqual(r?.text, "hello")
    }

    func testParseAutomationURLRejectsWrongSchemeOrHost() {
        XCTAssertNil(DemoFormat.parseAutomationURL(scheme: "https", host: "send",
                                                   queryItems: [("to", "x"), ("text", "y")]))
        XCTAssertNil(DemoFormat.parseAutomationURL(scheme: "hopdemo", host: "recv",
                                                   queryItems: [("to", "x"), ("text", "y")]))
        XCTAssertNil(DemoFormat.parseAutomationURL(scheme: nil, host: nil, queryItems: []))
    }

    func testParseAutomationURLRejectsMissingParams() {
        XCTAssertNil(DemoFormat.parseAutomationURL(scheme: "hopdemo", host: "send",
                                                   queryItems: [("to", "x")]))
        XCTAssertNil(DemoFormat.parseAutomationURL(scheme: "hopdemo", host: "send",
                                                   queryItems: [("text", "y")]))
    }

    // MARK: parseAutomationEnv

    func testParseAutomationEnvValid() {
        let r = DemoFormat.parseAutomationEnv("send|AbC|hello world")
        XCTAssertEqual(r?.to, "AbC")
        XCTAssertEqual(r?.text, "hello world")
    }

    func testParseAutomationEnvRejoinsStrayPipes() {
        // Only the first two pipes are structural; the rest belong to the marker text.
        let r = DemoFormat.parseAutomationEnv("send|AbC|a|b|c")
        XCTAssertEqual(r?.to, "AbC")
        XCTAssertEqual(r?.text, "a|b|c")
    }

    func testParseAutomationEnvRejectsMalformed() {
        XCTAssertNil(DemoFormat.parseAutomationEnv(""))
        XCTAssertNil(DemoFormat.parseAutomationEnv("send|onlyaddr"))
        XCTAssertNil(DemoFormat.parseAutomationEnv("nope|a|b"))
    }

    // MARK: QR payload encode/decode

    func testHopQREncode() {
        XCTAssertEqual(HopQR.encode(address: "AbC", name: "Alice"), "AbC|Alice")
        XCTAssertEqual(HopQR.encode(address: "AbC", name: ""), "AbC|")
    }

    func testHopQRDecodeRoundTrip() {
        let payload = HopQR.encode(address: "AbC123", name: "Bob")
        let d = HopQR.decode(payload)
        XCTAssertEqual(d?.address, "AbC123")
        XCTAssertEqual(d?.name, "Bob")
    }

    func testHopQRDecodeNoName() {
        let d = HopQR.decode("AbC123")
        XCTAssertEqual(d?.address, "AbC123")
        XCTAssertEqual(d?.name, "")
    }

    func testHopQRDecodeEmptyName() {
        let d = HopQR.decode("AbC123|")
        XCTAssertEqual(d?.address, "AbC123")
        XCTAssertEqual(d?.name, "")
    }

    func testHopQRDecodeToleratesHopPrefix() {
        let d = HopQR.decode("hop:AbC123|Carol")
        XCTAssertEqual(d?.address, "AbC123")
        XCTAssertEqual(d?.name, "Carol")
    }

    func testHopQRDecodeNameWithPipe() {
        // maxSplits: 1 keeps a pipe inside the name intact.
        let d = HopQR.decode("AbC123|Da|ve")
        XCTAssertEqual(d?.address, "AbC123")
        XCTAssertEqual(d?.name, "Da|ve")
    }

    func testHopQRDecodeRejectsEmptyAddress() {
        XCTAssertNil(HopQR.decode(""))
        XCTAssertNil(HopQR.decode("|onlyname"))
        XCTAssertNil(HopQR.decode("hop:"))
    }

    // MARK: QR bitmap (CoreImage, headless)

    #if canImport(CoreGraphics) && canImport(CoreImage)
    func testQRCGImageProducesBitmap() {
        let cg = DemoFormat.qrCGImage(HopQR.encode(address: "AbC123", name: "Alice"))
        XCTAssertNotNil(cg)
        if let cg {
            // 10x scale over a QR module grid: comfortably larger than a single module.
            XCTAssertGreaterThan(cg.width, 20)
            XCTAssertEqual(cg.width, cg.height)   // QR codes are square
        }
    }

    func testQRCGImageLongerTextGrowsGrid() {
        let small = DemoFormat.qrCGImage("hi")
        let big = DemoFormat.qrCGImage(String(repeating: "A", count: 200))
        XCTAssertNotNil(small)
        XCTAssertNotNil(big)
        if let small, let big {
            // More payload needs more QR modules, hence a wider bitmap at the same 10x scale.
            XCTAssertGreaterThan(big.width, small.width)
        }
    }
    #endif

    // MARK: photo downscale (ImageIO, headless)

    #if canImport(CoreGraphics) && canImport(ImageIO)
    func testDownscaledCGImageShrinksLargeImage() throws {
        let big = try Self.makePNG(width: 2000, height: 1000)
        let cg = try XCTUnwrap(DemoFormat.downscaledCGImage(big, maxPixel: 256))
        XCTAssertLessThanOrEqual(cg.width, 256)
        XCTAssertLessThanOrEqual(cg.height, 256)
        // Longest edge should be driven to the cap; aspect ratio (2:1) is preserved.
        XCTAssertEqual(cg.width, 256)
        XCTAssertEqual(cg.height, 128)
    }

    func testDownscaledCGImageRejectsNonImage() {
        XCTAssertNil(DemoFormat.downscaledCGImage(Data([0x00, 0x01, 0x02, 0x03])))
    }

    /// Build an opaque PNG of the given size in memory for the downscale test.
    private static func makePNG(width: Int, height: Int) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = try XCTUnwrap(ctx.makeImage())
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(
            out as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }
    #endif

    // MARK: originStamp (when the ORIGINATING device sent it)

    /// A fixed UTC calendar, so these assert the format and never the runner's region.
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return utc.date(from: c)!
    }

    func testOriginStampIsBareTimeForToday() {
        let now = at(2026, 7, 26, 21, 40)
        XCTAssertEqual(DemoFormat.originStamp(at(2026, 7, 26, 9, 5), now: now, calendar: utc), "09:05",
                       "same day needs no date, and is zero-padded 24-hour")
    }

    /// The delay-tolerant case that makes this more than cosmetic: a bundle can arrive long after it
    /// was sent, so a bare time on an old message would read as recent.
    func testOriginStampNamesYesterdayAndOlderDays() {
        let now = at(2026, 7, 26, 21, 40)
        XCTAssertEqual(DemoFormat.originStamp(at(2026, 7, 25, 23, 59), now: now, calendar: utc), "Yesterday 23:59")
        XCTAssertEqual(DemoFormat.originStamp(at(2026, 7, 20, 8, 0), now: now, calendar: utc), "20 Jul 08:00")
        XCTAssertEqual(DemoFormat.originStamp(at(2025, 12, 31, 23, 15), now: now, calendar: utc), "31 Dec 2025 23:15",
                       "a different year has to say so")
    }

    /// Yesterday is a CALENDAR day, not "within 24 hours": 00:10 today and 23:50 yesterday are 20
    /// minutes apart but must not both render as a bare time.
    func testOriginStampYesterdayIsACalendarDayNotA24HourWindow() {
        let now = at(2026, 7, 26, 0, 10)
        XCTAssertEqual(DemoFormat.originStamp(at(2026, 7, 25, 23, 50), now: now, calendar: utc), "Yesterday 23:50")
        XCTAssertEqual(DemoFormat.originStamp(at(2026, 7, 26, 0, 0), now: now, calendar: utc), "00:00")
    }

    func testOriginStampNeverShowsSecondsBecauseThePrivatePathBucketsTo60s() {
        // Two sends 59s apart inside one private-path bucket are indistinguishable on the wire, so the
        // display must not imply otherwise.
        let now = at(2026, 7, 26, 12, 0)
        var c = DateComponents(); c.year = 2026; c.month = 7; c.day = 26; c.hour = 11; c.minute = 30; c.second = 59
        let withSeconds = utc.date(from: c)!
        XCTAssertEqual(DemoFormat.originStamp(withSeconds, now: now, calendar: utc), "11:30")
        XCTAssertFalse(DemoFormat.originStamp(withSeconds, now: now, calendar: utc).contains("59"))
    }

    // MARK: parseBearerURL

    func testBearerURLParsesATransportToggle() {
        let q = [(name: "tag", value: Optional("BT")), (name: "enabled", value: Optional("false"))]
        XCTAssertEqual(DemoFormat.parseBearerURL(scheme: "hopdemo", host: "bearer", queryItems: q),
                       .setEnabled(tag: "BT", enabled: false))
        let on = [(name: "tag", value: Optional("LAN")), (name: "enabled", value: Optional("true"))]
        XCTAssertEqual(DemoFormat.parseBearerURL(scheme: "hopdemo", host: "bearer", queryItems: on),
                       .setEnabled(tag: "LAN", enabled: true))
    }

    func testBearerStatesHostNeedsNoQuery() {
        XCTAssertEqual(DemoFormat.parseBearerURL(scheme: "hopdemo", host: "bearerstates", queryItems: []),
                       .queryStates)
    }

    /// The case that matters most for the device harness. A permissive bool parse would read a typo as
    /// `false`, the toggle would never run, and the test would then "prove" a control it never exercised.
    func testBearerURLRejectsAnythingButExactlyTrueOrFalse() {
        for bad in ["False", "TRUE", "0", "1", "yes", "no", "", "flase"] {
            let q = [(name: "tag", value: Optional("BT")), (name: "enabled", value: Optional(bad))]
            XCTAssertNil(DemoFormat.parseBearerURL(scheme: "hopdemo", host: "bearer", queryItems: q),
                         "enabled=\(bad) must not parse: a loose parse silently fakes a passing test")
        }
    }

    func testBearerURLRejectsWrongSchemeHostOrMissingItems() {
        let q = [(name: "tag", value: Optional("BT")), (name: "enabled", value: Optional("false"))]
        XCTAssertNil(DemoFormat.parseBearerURL(scheme: "https", host: "bearer", queryItems: q))
        XCTAssertNil(DemoFormat.parseBearerURL(scheme: "hopdemo", host: "send", queryItems: q))
        XCTAssertNil(DemoFormat.parseBearerURL(scheme: "hopdemo", host: "bearer",
                                               queryItems: [(name: "tag", value: Optional("BT"))]))
        XCTAssertNil(DemoFormat.parseBearerURL(scheme: "hopdemo", host: "bearer",
                                               queryItems: [(name: "enabled", value: Optional("false"))]))
        XCTAssertNil(DemoFormat.parseBearerURL(scheme: "hopdemo", host: "bearer",
                                               queryItems: [(name: "tag", value: Optional("")),
                                                            (name: "enabled", value: Optional("false"))]))
    }

    /// The bearer link must not be mistaken for a send, and vice versa: the send hook is a
    /// send-as-user primitive, so the two surfaces must stay disjoint.
    func testBearerAndSendParsersDoNotOverlap() {
        let bearerQ = [(name: "tag", value: Optional("BT")), (name: "enabled", value: Optional("false"))]
        XCTAssertNil(DemoFormat.parseAutomationURL(scheme: "hopdemo", host: "bearer", queryItems: bearerQ))
        let sendQ = [(name: "to", value: Optional("abc")), (name: "text", value: Optional("m"))]
        XCTAssertNil(DemoFormat.parseBearerURL(scheme: "hopdemo", host: "send", queryItems: sendQ))
    }
}
