// The full reachable-by-name chain: an endpoint publishes /.well-known/hop over
// HTTPS, a client resolves + verifies the signed reach record, dials the WSS
// bearer, and completes a hops:// round trip. Uses a throwaway self-signed cert
// (dev only; production uses a real WebPKI cert). Run against a built libhop:
//   HOP_LIBDIR=../../target/debug dart run example/discovery.dart
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:hop_endpoint/hop_endpoint.dart';

SecurityContext _devCert() {
  final dir = Directory.systemTemp.createTempSync('hop-dev-tls-');
  final cert = '${dir.path}/cert.pem';
  final key = '${dir.path}/key.pem';
  final r = Process.runSync('openssl', [
    'req',
    '-x509',
    '-newkey',
    'ec',
    '-pkeyopt',
    'ec_paramgen_curve:prime256v1',
    '-nodes',
    '-keyout',
    key,
    '-out',
    cert,
    '-days',
    '1',
    '-subj',
    '/CN=localhost',
    '-addext',
    'subjectAltName=DNS:localhost',
  ]);
  if (r.exitCode != 0) {
    throw StateError('openssl failed: ${r.stderr}');
  }
  return SecurityContext()
    ..useCertificateChain(cert)
    ..usePrivateKey(key);
}

Future<void> main() async {
  final server = HopEndpoint();
  server.on('acme/orders', (req, reply) => reply(200, 'echo: ${req.text}'));
  final http = await server.attach(
    port: 0,
    context: _devCert(),
    publicUrl: 'wss://localhost/_hop',
    host: '127.0.0.1',
  );
  print('endpoint ${server.address} serving on https://localhost:${http.port}');

  final client = HopEndpoint();
  try {
    // TLS proves the domain, the signed reach record proves the address, the
    // Noise handshake confirms it. insecureTls is only for this self-signed dev
    // cert; real deployments verify via WebPKI.
    final resolved = await resolve(client, 'https://localhost:${http.port}',
        insecureTls: true);
    print('resolved + verified address ${resolved.address}');
    await dialWss(client, 'wss://localhost:${http.port}/_hop',
        insecureTls: true);
    final resp = await client.request(resolved.address, 'acme/orders', 'create',
        args: 'hi');
    print('client received ${resp.status}: ${resp.text}');
  } finally {
    server.close();
    client.close();
  }
}
