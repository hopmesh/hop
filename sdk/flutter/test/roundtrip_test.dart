/// Round-trip proofs: the raw C ABI, `hops://` request/response in-process and
/// over real TCP + WSS bearers, base58 addressing, reach-record sign/verify, and
/// the full reachable-by-name discovery chain. Needs a built libhop
/// (`cargo build -p hop`, or `HOP_LIBDIR`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hop_endpoint/hop_endpoint.dart';
import 'package:test/test.dart';

import 'dev_tls.dart';

const _fastTick = Duration(milliseconds: 5);

void main() {
  group('raw C ABI', () {
    late HopFfi ffi;

    setUpAll(() => ffi = HopFfi.open());

    test('ABI version matches the header the wrapper was built against', () {
      // HopFfi.open() asserts it; reaching here means the assert passed.
      expect(hopAbiVersion, 7);
    });

    test('every fixed-width argument requires exactly 32 bytes', () {
      final node = ffi.nodeNew();
      try {
        ffi.tick(node, 1);
        final exact = ffi.address(node);
        for (final size in [0, 1, 31, 33]) {
          final bad = Uint8List(size);
          expect(() => ffi.acceptInbox(node, bad), throwsArgumentError);
          expect(() => ffi.clusterJoin(node, bad), throwsArgumentError);
          expect(
              () =>
                  ffi.sendServiceRequest(node, bad, 'svc', 'get', Uint8List(0)),
              throwsArgumentError);
          expect(
              () =>
                  ffi.sendServiceResponse(node, bad, exact, 200, Uint8List(0)),
              throwsArgumentError);
          expect(
              () =>
                  ffi.sendServiceResponse(node, exact, bad, 200, Uint8List(0)),
              throwsArgumentError);
          expect(() => ffi.toBase58(bad), throwsArgumentError);
        }
        expect(ffi.acceptInbox(node, exact), isFalse);
        ffi.clusterJoin(node, exact);
        expect(
            ffi
                .sendServiceRequest(node, exact, 'svc', 'get', Uint8List(0))
                .length,
            32);
        expect(ffi.sendServiceResponse(node, exact, exact, 200, Uint8List(0)),
            isTrue);
        expect(ffi.toBase58(exact), isNotEmpty);
      } finally {
        ffi.nodeFree(node);
      }
    });

    test('base58 round-trips an address', () {
      final node = ffi.nodeNew();
      try {
        final addr = ffi.address(node);
        final b58 = ffi.toBase58(addr);
        expect(ffi.fromBase58(b58), addr);
        expect(() => ffi.fromBase58('not-an-address!!'), throwsArgumentError);
      } finally {
        ffi.nodeFree(node);
      }
    });

    test('reach record signs and verifies against its own address', () {
      final node = ffi.nodeNew();
      try {
        ffi.tick(node, DateTime.now().millisecondsSinceEpoch);
        final record = ffi.signReach(node, 'wss://example.test/_hop', 3600);
        expect(record, isNotEmpty);
        final info = ffi.verifyReach(
            record, DateTime.now().millisecondsSinceEpoch ~/ 1000);
        expect(info, isNotNull);
        expect(info!.endpoint, 'wss://example.test/_hop');
        expect(info.address, ffi.address(node));
      } finally {
        ffi.nodeFree(node);
      }
    });
  });

  group('endpoint', () {
    test('rejects a non-32-byte identity key', () {
      expect(() => HopEndpoint(key: Uint8List(31)), throwsArgumentError);
    });

    test('in-process request/response round trip', () async {
      final server = HopEndpoint(tick: _fastTick);
      final client = HopEndpoint(tick: _fastTick);
      server.on('acme/orders', (req, reply) => reply(200, 'got:${req.text}'));
      connectInProcess(server, client);
      try {
        final resp = await client.request(
            server.addressBytes, 'acme/orders', 'create',
            args: 'temp=21', timeout: const Duration(seconds: 20));
        expect(resp.status, 200);
        expect(resp.text, 'got:temp=21');
      } finally {
        server.close();
        client.close();
      }
    });

    test('TCP bearer request/response round trip', () async {
      final server = HopEndpoint(tick: _fastTick);
      server.on('acme/orders', (req, reply) => reply(201, req.args));
      final listener = await listen(server, 0);
      final port = listener.port;
      final client = HopEndpoint(tick: _fastTick);
      await dial(client, '127.0.0.1', port);
      try {
        final resp = await client.request(
            server.address, 'acme/orders', 'create',
            args: 'widget', timeout: const Duration(seconds: 20));
        expect(resp.status, 201);
        expect(resp.text, 'widget');
      } finally {
        server.close();
        client.close();
      }
    });

    test('a throwing handler does not kill the pump', () async {
      final errors = <Object>[];
      final server =
          HopEndpoint(tick: _fastTick, onError: (e, _) => errors.add(e));
      server.on('svc/bad', (req, reply) => throw StateError('boom'));
      server.on('svc/good', (req, reply) => reply(200, 'ok'));
      final client = HopEndpoint(tick: _fastTick);
      connectInProcess(server, client);
      try {
        await expectLater(
          client.request(server.addressBytes, 'svc/bad', 'go',
              timeout: const Duration(seconds: 3)),
          throwsA(isA<TimeoutException>()),
        );
        // The pump survived the throw: a later request still completes.
        final resp = await client.request(server.addressBytes, 'svc/good', 'go',
            timeout: const Duration(seconds: 20));
        expect(resp.status, 200);
        expect(resp.text, 'ok');
        expect(errors.whereType<StateError>(), isNotEmpty);
      } finally {
        server.close();
        client.close();
      }
    });

    test('cluster join + quorum bindings resolve and chain', () {
      final e =
          HopEndpoint(tick: _fastTick, cluster: 'shared-passphrase', quorum: 3);
      try {
        expect(e.clusterMembers, 1);
        expect(identical(e.clusterQuorum(2), e), isTrue);
      } finally {
        e.close();
      }
    });

    test('public calls fail deterministically after close', () async {
      final e = HopEndpoint(tick: _fastTick);
      final addr = e.addressBytes;
      e.close();
      expect(() => e.address, throwsStateError);
      expect(() => e.addressBytes, throwsStateError);
      expect(() => e.on('svc', (_, __) {}), throwsStateError);
      expect(() => e.clusterMembers, throwsStateError);
      expect(() => e.signReach('wss://x.test/_hop'), throwsStateError);
      expect(
          () => e.request(addr, 'svc', 'get',
              timeout: const Duration(milliseconds: 10)),
          throwsStateError);
    });
  });

  group('WSS discovery', () {
    test('dial-by-name resolves, verifies, dials, and round-trips', () async {
      final context = devServerContext();
      if (context == null) {
        markTestSkipped(
            'openssl unavailable; skipping the TLS discovery proof');
        return;
      }
      final server = HopEndpoint(tick: _fastTick);
      server.on('acme/orders',
          (req, reply) => reply(200, jsonEncode({'echo': req.text})));
      final http = await server.attach(
        port: 0,
        context: context,
        publicUrl: 'wss://localhost/_hop',
        host: '127.0.0.1',
      );
      // The published reach record binds a hostless "wss://localhost/_hop"; dial
      // the real ephemeral port directly while resolving discovery over HTTPS.
      final port = http.port;
      final client = HopEndpoint(tick: _fastTick);
      try {
        final resolved =
            await resolve(client, 'https://localhost:$port', insecureTls: true);
        expect(resolved.address, server.address);
        await dialWss(client, 'wss://localhost:$port/_hop', insecureTls: true);
        final resp = await client.request(
            resolved.address, 'acme/orders', 'create',
            args: 'hi', timeout: const Duration(seconds: 20));
        expect(resp.status, 200);
        expect(jsonDecode(resp.text)['echo'], 'hi');
      } finally {
        server.close();
        client.close();
      }
    });
  });
}
