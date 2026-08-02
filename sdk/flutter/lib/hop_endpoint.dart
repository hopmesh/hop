/// Receive Hop messages in Dart and Flutter: an embeddable endpoint over the
/// `libhop` C ABI (via `dart:ffi`).
///
/// ```dart
/// import 'package:hop_endpoint/hop_endpoint.dart';
///
/// final hop = HopEndpoint();
/// hop.on('acme/orders', (req, reply) => reply(201, 'got: ${req.text}'));
/// await listen(hop, 9944); // reachable over TCP
/// print(hop.address);      // publish this; senders reach you by it
/// ```
///
/// The DX looks like HTTP; the delivery is a durable, store-and-forward,
/// forward-secret mesh. See the README and docs/endpoint-sdk.md.
library;

export 'src/endpoint.dart'
    show
        HopEndpoint,
        HopRequest,
        HopResponse,
        HopReply,
        HopHandler,
        connectInProcess;
export 'src/ffi.dart' show HopFfi, ReachInfo, hopAbiVersion;
export 'src/tcp_bearer.dart' show listen, dial, maxFrameBytes;
export 'src/wss_bearer.dart'
    show serve, dialWss, maxMessageBytes, HopWssDiscovery;
export 'src/discovery.dart'
    show resolve, wellKnownBody, wellKnownPath, ResolvedEndpoint;
