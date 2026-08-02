// A standalone Hop endpoint over TCP. Prints its address (hand it to client.dart)
// and serves until interrupted. Run against a built libhop:
//   HOP_LIBDIR=../../target/debug dart run example/server.dart
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:hop_endpoint/hop_endpoint.dart';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args.first) : 9944;
  final hop = HopEndpoint();
  hop.on('acme/orders', (req, reply) {
    print('order from ${req.from.substring(0, 8)}...: ${req.text}');
    reply(201, 'accepted: ${req.text}');
  });
  await listen(hop, port);
  print('address: ${hop.address}');
  print('listening on tcp://0.0.0.0:$port  (Ctrl-C to stop)');
  await ProcessSignal.sigint.watch().first;
  hop.close();
}
