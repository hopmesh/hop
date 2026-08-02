// Dial the standalone server.dart and send it one hops:// request. Run against
// a built libhop:
//   HOP_LIBDIR=../../target/debug dart run example/client.dart <address> [host] [port]
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:hop_endpoint/hop_endpoint.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('usage: dart run example/client.dart <address> [host] [port]');
    exit(2);
  }
  final address = args[0];
  final host = args.length > 1 ? args[1] : 'localhost';
  final port = args.length > 2 ? int.parse(args[2]) : 9944;

  final hop = HopEndpoint();
  await dial(hop, host, port);
  try {
    final resp =
        await hop.request(address, 'acme/orders', 'create', args: 'widget x3');
    print('received ${resp.status}: ${resp.text}');
  } finally {
    hop.close();
  }
}
