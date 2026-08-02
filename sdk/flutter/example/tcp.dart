// The same hop.on / reply round trip over a real TCP bearer. Run against a
// built libhop:
//   HOP_LIBDIR=../../target/debug dart run example/tcp.dart
// ignore_for_file: avoid_print
import 'package:hop_endpoint/hop_endpoint.dart';

Future<void> main() async {
  final server = HopEndpoint();
  server.on('acme/orders', (req, reply) => reply(201, req.args));
  final listener = await listen(server, 0); // ephemeral port
  print('server listening on tcp://127.0.0.1:${listener.port}');

  final client = HopEndpoint();
  await dial(client, '127.0.0.1', listener.port);
  try {
    final resp = await client.request(server.address, 'acme/orders', 'create',
        args: 'widget');
    print('client received ${resp.status}: ${resp.text}');
  } finally {
    server.close();
    client.close();
  }
}
