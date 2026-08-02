/// The Internet bearer for a Dart/Flutter endpoint: opaque Hop frames over TCP,
/// core does the Noise. TCP is a stream, so each drained packet is
/// length-prefixed (4-byte big-endian) and reassembled on the far side. HNS
/// would resolve a name to host/port/key; here you pass them directly.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'endpoint.dart';

int _linkSeq = 40000;

/// Frames larger than this are refused (the link is dropped) before assembly.
const int maxFrameBytes = 1 << 20;

void _sendFramed(Socket socket, Uint8List buf) {
  final header = Uint8List(4);
  ByteData.view(header.buffer).setUint32(0, buf.length, Endian.big);
  try {
    socket.add(header);
    socket.add(buf);
  } on StateError {
    // socket already closed; a pump send racing teardown is expected.
  }
}

Uint8List _concat(Uint8List a, Uint8List b) {
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  final out = Uint8List(a.length + b.length)
    ..setAll(0, a)
    ..setAll(a.length, b);
  return out;
}

/// Reassembles the 4-byte length prefix on one link, delivering whole frames.
/// Returns false when a frame claims more than [maxFrameBytes] (the caller then
/// drops the link) so an oversized length can never drive an allocation.
class _FrameReader {
  _FrameReader(this._endpoint, this._link);

  final HopEndpoint _endpoint;
  final int _link;
  Uint8List _buf = Uint8List(0);

  bool add(Uint8List chunk) {
    _buf = _concat(_buf, chunk);
    var offset = 0;
    while (_buf.length - offset >= 4) {
      final n = ByteData.sublistView(_buf, offset, offset + 4)
          .getUint32(0, Endian.big);
      if (n > maxFrameBytes) return false; // oversized: drop the link
      if (_buf.length - offset < 4 + n) break;
      final frame = Uint8List.sublistView(_buf, offset + 4, offset + 4 + n);
      _endpoint.deliver(_link, Uint8List.fromList(frame));
      offset += 4 + n;
    }
    if (offset > 0) {
      _buf = Uint8List.fromList(Uint8List.sublistView(_buf, offset));
    }
    return true;
  }
}

void _pipe(HopEndpoint endpoint, Socket socket, int link) {
  final reader = _FrameReader(endpoint, link);
  socket.listen(
    (chunk) {
      if (!reader.add(chunk)) {
        socket.destroy();
      }
    },
    onError: (_) {},
    onDone: () => endpoint.linkDown(link),
    cancelOnError: true,
  );
}

/// Listen for inbound Hop connections; each accepted socket is one bearer link
/// (we are acceptor). Returns the listening [ServerSocket].
Future<ServerSocket> listen(HopEndpoint endpoint, int port,
    {String host = '0.0.0.0'}) async {
  final server = await ServerSocket.bind(host, port);
  endpoint.registerCloser(() {
    try {
      server.close();
    } catch (_) {}
  });
  server.listen(
    (socket) {
      final link = _linkSeq++;
      endpoint.registerCloser(() => socket.destroy());
      endpoint.registerLink(
          link, 'acceptor', (buf) => _sendFramed(socket, buf));
      _pipe(endpoint, socket, link);
    },
    onError: (_) {},
  );
  return server;
}

/// Dial a reachable endpoint (we are the Noise initiator). Returns the [Socket].
Future<Socket> dial(HopEndpoint endpoint, String host, int port) async {
  final socket = await Socket.connect(host, port);
  endpoint.registerCloser(() => socket.destroy());
  final link = _linkSeq++;
  endpoint.registerLink(link, 'dialer', (buf) => _sendFramed(socket, buf));
  _pipe(endpoint, socket, link);
  return socket;
}
