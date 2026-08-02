// The hop.on / reply DX in-process (no sockets). Run against a built libhop:
//   HOP_LIBDIR=../../target/debug dart run example/echo.dart
// ignore_for_file: avoid_print
import 'package:hop_endpoint/hop_endpoint.dart';

Future<void> main() async {
  final server = HopEndpoint();
  final client = HopEndpoint();
  server.on('acme/orders', (req, reply) {
    // req.from is a VERIFIED identity (base58), not a spoofable header.
    print('order from ${req.from.substring(0, 8)}...: ${req.text}');
    reply(201, 'accepted: ${req.text}');
  });
  connectInProcess(server, client);
  try {
    final resp = await client.request(
        server.addressBytes, 'acme/orders', 'create',
        args: 'widget x3');
    print('client received ${resp.status}: ${resp.text}');
  } finally {
    server.close();
    client.close();
  }
}
