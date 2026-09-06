/// [HopEndpoint]: receive Hop messages in Dart/Flutter with a Flask/Express-shaped
/// surface, over the `libhop` C ABI. Sibling to the Node/Python/Go/Ruby/Crystal
/// endpoint SDKs; same C-ABI contract, idiomatic Dart surface.
///
/// ```dart
/// final hop = HopEndpoint();
/// hop.on('acme/orders', (req, reply) {
///   // req.from is a cryptographically VERIFIED identity, not a spoofable header
///   reply(201, jsonEncode({'ok': true}));
/// });
/// await listen(hop, 9944); // reachable by any device
/// ```
///
/// SEMANTICS: this is not synchronous HTTP. Inbound is a durable
/// store-and-forward consume; a reply is a new addressed message that may
/// arrive later, even across a restart. The DX is HTTP-shaped; delivery is
/// delay-tolerant. core is poll-model, so the endpoint runs a periodic pump on
/// the isolate's event loop (single-threaded, so no locking: unlike the
/// thread-per-pump SDKs, a Dart bearer's socket I/O is async on the same loop).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'ffi.dart';

/// A handler for an inbound `hops://` service request. Return type is
/// [FutureOr] so an `async` handler is fine; the pump does not await it (call
/// [HopReply] when the reply is ready, whenever that is).
typedef HopHandler = FutureOr<void> Function(HopRequest req, HopReply reply);

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

String _hex(Uint8List b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _asBytes(Object v) {
  if (v is Uint8List) return v;
  if (v is List<int>) return Uint8List.fromList(v);
  if (v is String) return Uint8List.fromList(utf8.encode(v));
  throw ArgumentError('body/args must be String, List<int>, or Uint8List');
}

/// A verified inbound request. [from] is the ratchet-verified sender identity
/// (base58), not a spoofable header.
class HopRequest {
  HopRequest({
    required this.from,
    required this.fromBytes,
    required this.service,
    required this.method,
    required this.args,
    this.requestId,
    this.accept,
    this.reject,
  });

  /// The verified sender address, base58 encoded.
  final String from;

  /// The verified sender address, raw 32 bytes.
  final Uint8List fromBytes;
  final String service;
  final String method;
  final Uint8List args;

  /// The 32-byte request id.
  final Uint8List? requestId;

  /// Explicitly accept this request.
  final bool Function()? accept;

  /// Explicitly reject this request so it remains queued for redelivery.
  final bool Function()? reject;

  /// The request body decoded as UTF-8 text.
  String get text => utf8.decode(args);

  /// The request body decoded as JSON.
  dynamic get json => jsonDecode(text);
}

/// The response to a [request]. The endpoint durably accepts it on delivery, so
/// a redelivery of the same response is ignored.
class HopResponse {
  HopResponse(this.status, this.body);

  /// The `uint16` status the peer replied with.
  final int status;

  /// The response body bytes.
  final Uint8List body;

  /// The response body decoded as UTF-8 text.
  String get text => utf8.decode(body);

  /// The response body decoded as JSON.
  dynamic get json => jsonDecode(text);
}

/// The `reply(status, body)` callable handed to a handler. Single-shot.
class HopReply {
  HopReply._(this._endpoint, this._to, this._for);

  final HopEndpoint _endpoint;
  final Uint8List _to;
  final Uint8List _for;
  bool _sent = false;

  /// Seal a `hops://` response back to the request's caller. [body] may be a
  /// [String], `List<int>`, or [Uint8List]. Returns whether the send succeeded.
  bool call(int status, [Object body = '']) {
    if (_sent) throw StateError('reply already sent');
    _sent = true;
    return _endpoint._replySend(_to, _for, status, _asBytes(body));
  }
}

/// An embeddable Hop endpoint. Construct one, register handlers with [on], make
/// it reachable with a bearer (`listen`, `dial`, `attach`, `dialByName`), and
/// call [request] to reach other endpoints.
class HopEndpoint {
  /// Open an endpoint. Pass a 32-byte [key] to restore a saved identity (else a
  /// fresh identity is generated). [tick] is the pump interval. [cluster] joins
  /// a sibling-replica cluster (a 32-byte secret or a passphrase [String]);
  /// [quorum] sets the failover visibility threshold.
  HopEndpoint({
    Uint8List? key,
    String? dbPath,
    Uint8List? dbKey,
    Uint8List? appSecret,
    Duration tick = const Duration(milliseconds: 50),
    Object? cluster,
    int? quorum,
    void Function(Object error, StackTrace stack)? onError,
    HopFfi? ffi,
  })  : _ffi = ffi ?? _sharedFfi(),
        _onError = onError {
    if (key != null && key.length != 32) {
      throw ArgumentError(
          'identity key must be exactly 32 bytes, got ${key.length}');
    }
    if (dbPath != null) {
      _node = dbKey != null
          ? _ffi.nodeOpenKeyed(dbPath,
              secret: key, appSecret: appSecret, key: dbKey)
          : _ffi.nodeOpen(dbPath, secret: key, appSecret: appSecret);
    } else {
      _node = key != null ? _ffi.nodeWithSecret(key) : _ffi.nodeNew();
    }
    if (cluster != null) this.cluster(cluster);
    if (quorum != null) clusterQuorum(quorum);
    _ffi.tick(_node, _nowMs());
    _ffi.publishPrekey(_node);
    _pump = Timer.periodic(tick, (_) => _runPump());
  }

  static HopFfi? _shared;
  static HopFfi _sharedFfi() => _shared ??= HopFfi.open();

  final HopFfi _ffi;
  final void Function(Object error, StackTrace stack)? _onError;
  late Pointer<Void> _node;
  bool _closed = false;
  Timer? _pump;
  final _handlers = <String, HopHandler>{};
  final _links = <int, void Function(Uint8List)>{};
  final _pending = <String, Completer<HopResponse>>{};
  final _inFlightRequests = <String>{};
  final _closers = <void Function()>[];
  void _ensureOpen() {
    if (_closed) throw StateError('endpoint is closed');
  }

  /// Whether the underlying node is backed by persistent storage.
  bool get isPersistent {
    _ensureOpen();
    return _ffi.nodeIsPersistent(_node);
  }

  /// Whether the underlying node storage is encrypted at rest.
  bool get isEncrypted {
    _ensureOpen();
    return _ffi.nodeIsEncrypted(_node);
  }

  /// Durably accept a service request after application processing completes.
  bool acceptServiceRequest(Uint8List requestId) {
    _ensureOpen();
    _inFlightRequests.remove(_hex(requestId));
    return _ffi.acceptServiceRequest(_node, requestId);
  }

  /// Reject a service request without ACK so it remains queued for redelivery.
  bool rejectServiceRequest(Uint8List requestId) {
    _ensureOpen();
    _inFlightRequests.remove(_hex(requestId));
    return _ffi.rejectServiceRequest(_node, requestId);
  }
  /// Mark a request handled in the replica cluster.
  void clusterMarkDone(Uint8List from, Uint8List requestId) {
    _ensureOpen();
    _ffi.clusterMarkDone(_node, from, requestId);
  }

  /// Whether a request would be dropped as already handled by a cluster replica.
  bool clusterWouldDrop(Uint8List from, Uint8List requestId) {
    _ensureOpen();
    return _ffi.clusterWouldDrop(_node, from, requestId);
  }

  /// The endpoint's address, base58 encoded. Publish this (or a name that maps
  /// to it); senders reach the endpoint by it.
  String get address {
    _ensureOpen();
    return _ffi.toBase58(_ffi.address(_node));
  }

  /// The endpoint's address as raw 32 bytes.
  Uint8List get addressBytes {
    _ensureOpen();
    return _ffi.address(_node);
  }

  /// Register a receiver for a `hops://` service. Replaces any prior handler for
  /// the same service.
  HopEndpoint on(String service, HopHandler handler) {
    _ensureOpen();
    _ffi.subscribe(_node, service);
    _handlers[service] = handler;
    return this;
  }

  /// Join a sibling-replica cluster (same identity, no shared datastore) so a
  /// given request is handled once across replicas. Pass a passphrase [String]
  /// (interops with the standalone service's `HOP_CLUSTER_SECRET`) or 32 raw
  /// bytes. Returns this.
  HopEndpoint cluster(Object secretOrPassphrase) {
    _ensureOpen();
    if (secretOrPassphrase is String) {
      _ffi.clusterJoinPassphrase(
          _node, Uint8List.fromList(utf8.encode(secretOrPassphrase)));
    } else if (secretOrPassphrase is Uint8List) {
      if (secretOrPassphrase.length != 32) {
        throw ArgumentError(
            'cluster secret must be 32 bytes or a passphrase String');
      }
      _ffi.clusterJoin(_node, secretOrPassphrase);
    } else {
      throw ArgumentError(
          'cluster secret must be 32 bytes or a passphrase String');
    }
    return this;
  }

  /// Live replica count (self + peers within the membership TTL); 1 if not clustered.
  int get clusterMembers {
    _ensureOpen();
    return _ffi.clusterMembers(_node);
  }

  /// Require at least [minLiveMembers] live cluster members visible before this
  /// replica processes a request (a conservative failover heuristic, not
  /// consensus). 0 or 1 disables the hold. Returns this.
  HopEndpoint clusterQuorum(int minLiveMembers) {
    _ensureOpen();
    _ffi.clusterSetQuorum(_node, minLiveMembers);
    return this;
  }

  /// Call a service on a remote endpoint. Completes when the response returns
  /// (delay-tolerant), or with a [TimeoutException] after [timeout].
  ///
  /// [dst] is a base58 [String] address or 32 raw bytes; [args] may be a
  /// [String], `List<int>`, or [Uint8List].
  Future<HopResponse> request(
    Object dst,
    String service,
    String method, {
    Object args = '',
    Duration timeout = const Duration(seconds: 15),
  }) {
    _ensureOpen();
    final dstBytes = _asAddress(dst);
    final reqId = _ffi.sendServiceRequest(
        _node, dstBytes, service, method, _asBytes(args));
    final key = _hex(reqId);
    final completer = Completer<HopResponse>();
    _pending[key] = completer;
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(key);
      throw TimeoutException('hops://$service/$method timed out', timeout);
    });
  }

  Uint8List _asAddress(Object dst) {
    if (dst is Uint8List && dst.length == 32) return dst;
    if (dst is String) return _ffi.fromBase58(dst);
    if (dst is List<int> && dst.length == 32) return Uint8List.fromList(dst);
    throw ArgumentError('destination must be a base58 String or 32 bytes');
  }

  /// Sign a self-certifying reachability record for this endpoint's address
  /// bound to [endpoint] (e.g. `wss://myaddress.com/_hop`) for [ttlSecs].
  Uint8List signReach(String endpoint, {int ttlSecs = 3600}) {
    _ensureOpen();
    return _ffi.signReach(_node, endpoint, ttlSecs);
  }

  /// Verify a reachability record (self-certifying; checked against the address
  /// it names). Returns the record's fields, or null if the signature is bad or
  /// it has expired. [nowSecs] defaults to the current Unix time; pass 0 to skip
  /// the expiry check. Needs no node state, only the loaded library.
  ReachInfo? verifyReach(Uint8List record, {int? nowSecs}) {
    _ensureOpen();
    return _ffi.verifyReach(
        record, nowSecs ?? DateTime.now().millisecondsSinceEpoch ~/ 1000);
  }

  bool _replySend(Uint8List to, Uint8List forId, int status, Uint8List body) {
    if (_closed) return false;
    return _ffi.sendServiceResponse(_node, to, forId, status, body);
  }

  // ---- bearer seam (internal; used by tcp_bearer / wss_bearer / connectInProcess) ----

  /// Bearer seam. Register an up link with a send function. Not a stable API.
  void registerLink(int link, String role, void Function(Uint8List) send) {
    if (_closed) return;
    _links[link] = send;
    _ffi.connected(_node, link, role == 'dialer');
  }

  /// Bearer seam. Feed an inbound frame. Not a stable API.
  void deliver(int link, Uint8List data) {
    if (_closed) return;
    _ffi.received(_node, link, data);
  }

  /// Bearer seam. A link dropped. Not a stable API.
  void linkDown(int link) {
    if (_closed) return;
    _links.remove(link);
    _ffi.disconnected(_node, link);
  }

  /// Bearer seam. Record a teardown hook (e.g. a listening socket); [close] runs
  /// it before freeing the node. Fires immediately if already closed.
  void registerCloser(void Function() closer) {
    if (_closed) {
      closer();
      return;
    }
    _closers.add(closer);
  }

  void _reportError(Object error, StackTrace stack) {
    final handler = _onError;
    if (handler != null) {
      try {
        handler(error, stack);
      } catch (_) {}
      return;
    }
    // Default: report and keep running (the pump must not die), like the other
    // SDKs' pumps. Pass an `onError` callback to route this elsewhere.
    stderr.writeln('HopEndpoint pump error: $error\n$stack');
  }

  void _runPump() {
    // Never let a throwing handler (or a transient native error) kill the pump
    // timer; the endpoint must keep draining. Mirrors the other SDKs' pumps.
    try {
      _pumpOnce();
    } catch (error, stack) {
      _reportError(error, stack);
    }
  }

  void _pumpOnce() {
    if (_closed) return;
    _ffi.tick(_node, _nowMs());
    for (final (link, data) in _ffi.drainOutgoing(_node)) {
      _links[link]?.call(data);
      if (_closed) return;
    }
    for (final (from, rid, service, method, args)
        in _ffi.takeServiceRequests(_node)) {
      final key = _hex(rid);
      if (_inFlightRequests.contains(key)) continue;
      final handler = _handlers[service];
      if (handler != null) {
        _inFlightRequests.add(key);
        final req = HopRequest(
          from: _ffi.toBase58(from),
          fromBytes: from,
          service: service,
          method: method,
          args: args,
          requestId: rid,
          accept: () => acceptServiceRequest(rid),
          reject: () => rejectServiceRequest(rid),
        );
        // A synchronous throw in one handler must not skip response routing or
        // stall the others; isolate it.
        try {
          final res = handler(req, HopReply._(this, from, rid));
          if (res is Future) {
            res.then((_) {
              _inFlightRequests.remove(key);
              if (!_closed) _ffi.acceptServiceRequest(_node, rid);
            }).catchError((Object error, StackTrace stack) {
              _inFlightRequests.remove(key);
              _reportError(error, stack);
            });
          } else {
            _inFlightRequests.remove(key);
            _ffi.acceptServiceRequest(_node, rid);
          }
        } catch (error, stack) {
          _inFlightRequests.remove(key);
          _reportError(error, stack);
        }
      }
      if (_closed) return;
    }
    for (final (_, forId, status, body) in _ffi.takeServiceResponses(_node)) {
      final completer = _pending.remove(_hex(forId));
      if (completer != null && !completer.isCompleted) {
        // Durably accept: the awaiting caller has the value, so a redelivery of
        // this exact response should be dropped rather than re-complete.
        _ffi.acceptServiceResponse(_node, forId);
        completer.complete(HopResponse(status, body));
      }
      if (_closed) return;
    }
  }

  /// Tear the endpoint down: stop the pump, close bearer sockets, fail any
  /// in-flight [request] callers, and free the node. Idempotent.
  void close() {
    if (_closed) return;
    _closed = true;
    _pump?.cancel();
    _pump = null;
    final closers = List<void Function()>.of(_closers);
    _inFlightRequests.clear();
    _closers.clear();
    for (final c in closers) {
      try {
        c();
      } catch (_) {}
    }
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('endpoint is closed'));
      }
    }
    _pending.clear();
    _ffi.nodeFree(_node);
    _node = nullptr;
  }
}

/// Wire two endpoints directly (in-process bearer). Proves the ergonomics end
/// to end without sockets; use `listen`/`dial` for a real, reachable endpoint.
void connectInProcess(HopEndpoint a, HopEndpoint b,
    {int la = 11, int lb = 22}) {
  a.registerLink(la, 'dialer', (buf) => b.deliver(lb, buf));
  b.registerLink(lb, 'acceptor', (buf) => a.deliver(la, buf));
}
