// Proves the dart:ffi bindings: a raw hops:// request/response through two
// nodes wired by hand over one in-memory link, with no HopEndpoint sugar. Run
// against a built libhop:
//   HOP_LIBDIR=../../target/debug dart run example/raw_roundtrip.dart
// ignore_for_file: avoid_print
import 'dart:typed_data';

import 'package:hop_endpoint/hop_endpoint.dart';

int _now() => DateTime.now().millisecondsSinceEpoch;

void main() {
  final ffi = HopFfi.open();
  final server = ffi.nodeNew();
  final client = ffi.nodeNew();
  try {
    for (final n in [server, client]) {
      ffi.tick(n, _now());
      ffi.publishPrekey(n);
    }
    ffi.subscribe(server, 'demo/echo');
    final serverAddr = ffi.address(server);

    // One bidirectional link, id 7: client dials, server accepts.
    ffi.connected(client, 7, true);
    ffi.connected(server, 7, false);
    ffi.sendServiceRequest(client, serverAddr, 'demo/echo', 'say',
        Uint8List.fromList('ping'.codeUnits));

    Uint8List? gotBody;
    for (var round = 0; round < 400 && gotBody == null; round++) {
      for (final (from, to) in [(client, server), (server, client)]) {
        ffi.tick(from, _now());
        for (final (_, bytes) in ffi.drainOutgoing(from)) {
          ffi.received(to, 7, bytes);
        }
      }
      for (final (fromAddr, rid, service, method, args)
          in ffi.takeServiceRequests(server)) {
        print('server got $service/$method: ${String.fromCharCodes(args)} '
            'from ${ffi.toBase58(fromAddr).substring(0, 8)}...');
        ffi.sendServiceResponse(
            server, fromAddr, rid, 200, Uint8List.fromList('pong'.codeUnits));
      }
      for (final (_, forId, status, body) in ffi.takeServiceResponses(client)) {
        print('client got status $status: ${String.fromCharCodes(body)}');
        ffi.acceptServiceResponse(client, forId);
        gotBody = body;
      }
    }
    print(
        gotBody != null ? 'round trip OK' : 'no response (handshake stalled)');
  } finally {
    ffi.nodeFree(server);
    ffi.nodeFree(client);
  }
}
