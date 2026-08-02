/// The WSS Internet bearer for a Dart/Flutter endpoint, on `dart:io`'s built-in
/// TLS + WebSocket stack (no third-party WebSocket library). core does the Noise
/// handshake and all crypto over the frame payloads; one drained packet is one
/// binary WebSocket message (no length prefix, unlike the TCP bearer). The
/// server also answers GET `/.well-known/hop` on the same port, so [HopEndpoint.attach]
/// wires the bearer and discovery in one call.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'discovery.dart';
import 'endpoint.dart';

int _linkSeq = 60000;

/// WebSocket messages larger than this are refused by `dart:io`'s decoder.
const int maxMessageBytes = 1 << 20;

void _runLink(HopEndpoint endpoint, WebSocket ws, String role) {
  final link = _linkSeq++;
  endpoint.registerCloser(() {
    try {
      ws.close();
    } catch (_) {}
  });
  endpoint.registerLink(link, role, (buf) {
    try {
      ws.add(buf);
    } catch (_) {
      // socket already closing; a pump send racing teardown is expected.
    }
  });
  ws.listen(
    (message) {
      if (message is Uint8List) {
        endpoint.deliver(link, message);
      } else if (message is List<int>) {
        endpoint.deliver(link, Uint8List.fromList(message));
      }
      // text frames are not part of the bearer wire; ignore them.
    },
    onError: (_) {},
    onDone: () => endpoint.linkDown(link),
    cancelOnError: true,
  );
}

/// Start an HTTPS/WSS server: `/_hop` upgrades to the bearer, `/.well-known/hop`
/// serves the discovery record. Returns the [HttpServer]. Admission stays held
/// for each link because this bearer cannot observe Noise completion.
Future<HttpServer> serve(
  HopEndpoint endpoint, {
  required String host,
  required int port,
  required SecurityContext context,
  required String publicUrl,
  int ttlSecs = 3600,
}) async {
  final server = await HttpServer.bindSecure(host, port, context);
  server.idleTimeout = const Duration(seconds: 15);
  endpoint.registerCloser(() {
    try {
      server.close(force: true);
    } catch (_) {}
  });
  server.listen(
    (request) async {
      try {
        if (request.uri.path == wellKnownPath) {
          final body = wellKnownBody(endpoint, publicUrl, ttlSecs: ttlSecs);
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(body);
          await request.response.close();
          return;
        }
        if (request.uri.path == '/_hop' &&
            WebSocketTransformer.isUpgradeRequest(request)) {
          final ws = await WebSocketTransformer.upgrade(request);
          _runLink(endpoint, ws, 'acceptor');
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      } catch (_) {
        // a malformed or half-open client must not take the listener down.
      }
    },
    onError: (_) {},
  );
  return server;
}

/// Dial a reachable endpoint over WSS (we are the Noise initiator). Returns the
/// [WebSocket]. Set [insecureTls] for a dev/self-signed cert only.
Future<WebSocket> dialWss(HopEndpoint endpoint, String wssUrl,
    {bool insecureTls = false}) async {
  HttpClient? client;
  if (insecureTls) {
    client = HttpClient()..badCertificateCallback = (cert, host, port) => true;
  }
  final ws = await WebSocket.connect(wssUrl, customClient: client);
  _runLink(endpoint, ws, 'dialer');
  return ws;
}

/// Reachable-by-name convenience on [HopEndpoint], mirroring the aligned surface
/// (`hop.attach(...)`, `client.dialByName(...)`) of the sibling SDKs.
extension HopWssDiscovery on HopEndpoint {
  /// Wire this endpoint into a threaded HTTPS server in one call: the WSS bearer
  /// at `/_hop` and the `/.well-known/hop` discovery responder. Returns the
  /// [HttpServer]. [publicUrl] is where senders reach it (e.g.
  /// `wss://myaddress.com/_hop`). Serve on 443 or behind a reverse proxy.
  Future<HttpServer> attach({
    required int port,
    required SecurityContext context,
    required String publicUrl,
    String host = '0.0.0.0',
    int ttlSecs = 3600,
  }) {
    return serve(this,
        host: host,
        port: port,
        context: context,
        publicUrl: publicUrl,
        ttlSecs: ttlSecs);
  }

  /// Resolve a base HTTPS URL to a verified endpoint, dial its WSS, and return
  /// the reachable address (then use [request]). Set [insecureTls] only for a
  /// dev/self-signed cert.
  Future<String> dialByName(String baseUrl, {bool insecureTls = false}) async {
    final info = await resolve(this, baseUrl, insecureTls: insecureTls);
    await dialWss(this, info.wssUrl, insecureTls: insecureTls);
    return info.address;
  }
}
