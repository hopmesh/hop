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
}
