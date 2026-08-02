/// Raw `dart:ffi` bindings to `libhop` (the C ABI, `sdk/hop.h`), plus thin typed
/// wrappers. One-to-one with the `hop_*` exports; the ergonomics live in
/// `endpoint.dart`. The only third-party dependency is `package:ffi` (the
/// dart.dev allocator + UTF-8 helpers), which is to Dart what `ctypes` is to
/// Python: part of the FFI toolchain, not an app framework.
///
/// FFI discipline mirrored from the Kotlin/JNA + ctypes SDKs:
///   * C `_Bool` is a single byte; `Bool`/`ffi.Bool` reads exactly one byte, so
///     a dirty-upper-bit `false` cannot misread as `true` (the JNA footgun).
///   * Binary args pass an explicit length; hop-core reads exactly `len` bytes,
///     so embedded NUL bytes in Noise/wire data are fine.
///   * Sink callbacks fire SYNCHRONOUSLY during the drain/poll call. We use
///     `NativeCallable.isolateLocal` (same isolate, blocking) and copy every
///     pointer's bytes immediately, then close the callable.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'library.dart';

/// The ABI version this wrapper was written against (`HOP_ABI_VERSION` in
/// `sdk/hop.h`). Asserted at construction so a wrapper built against a newer
/// header fails loudly instead of drifting silently (F-28).
const int hopAbiVersion = 5;

// ---- native callback signatures (invoked synchronously during poll/drain) ----
typedef _DrainSinkC = Void Function(
    Pointer<Void>, Uint64, Pointer<Uint8>, Size);
typedef _SvcReqSinkC = Void Function(Pointer<Void>, Pointer<Uint8>,
    Pointer<Uint8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>, Size);
typedef _SvcRespSinkC = Bool Function(Pointer<Void>, Pointer<Uint8>,
    Pointer<Uint8>, Uint16, Pointer<Uint8>, Size);
typedef _ReachSignSinkC = Void Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _ReachVerifySinkC = Void Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Utf8>, Uint64, Uint32);

// ---- native function signatures ----
typedef _AbiVersionC = Uint32 Function();
typedef _AbiVersionDart = int Function();

typedef _NodeNewC = Pointer<Void> Function();
typedef _NodeWithSecretC = Pointer<Void> Function(Pointer<Uint8>, Size);
typedef _NodeWithSecretDart = Pointer<Void> Function(Pointer<Uint8>, int);
typedef _NodeFreeC = Void Function(Pointer<Void>);
typedef _NodeFreeDart = void Function(Pointer<Void>);
typedef _NodeAddressC = Bool Function(Pointer<Void>, Pointer<Uint8>);
typedef _NodeAddressDart = bool Function(Pointer<Void>, Pointer<Uint8>);
typedef _TickC = Void Function(Pointer<Void>, Uint64);
typedef _TickDart = void Function(Pointer<Void>, int);
typedef _LinkUpC = Void Function(Pointer<Void>, Uint64, Uint32);
typedef _LinkUpDart = void Function(Pointer<Void>, int, int);
typedef _LinkDownC = Void Function(Pointer<Void>, Uint64);
typedef _LinkDownDart = void Function(Pointer<Void>, int);
typedef _BytesReceivedC = Void Function(
    Pointer<Void>, Uint64, Pointer<Uint8>, Size);
typedef _BytesReceivedDart = void Function(
    Pointer<Void>, int, Pointer<Uint8>, int);
typedef _DrainC = Void Function(
    Pointer<Void>, Pointer<NativeFunction<_DrainSinkC>>, Pointer<Void>);
typedef _DrainDart = void Function(
    Pointer<Void>, Pointer<NativeFunction<_DrainSinkC>>, Pointer<Void>);
typedef _SubscribeC = Void Function(Pointer<Void>, Pointer<Utf8>);
typedef _SubscribeDart = void Function(Pointer<Void>, Pointer<Utf8>);
typedef _PublishPrekeyC = Bool Function(Pointer<Void>);
typedef _PublishPrekeyDart = bool Function(Pointer<Void>);
typedef _AcceptInboxC = Bool Function(Pointer<Void>, Pointer<Uint8>);
typedef _AcceptInboxDart = bool Function(Pointer<Void>, Pointer<Uint8>);
typedef _SendSvcReqC = Bool Function(Pointer<Void>, Pointer<Uint8>,
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>, Size, Pointer<Uint8>);
typedef _SendSvcReqDart = bool Function(Pointer<Void>, Pointer<Uint8>,
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>, int, Pointer<Uint8>);
typedef _SendSvcRespC = Bool Function(Pointer<Void>, Pointer<Uint8>,
    Pointer<Uint8>, Uint16, Pointer<Uint8>, Size);
typedef _SendSvcRespDart = bool Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef _PollSvcReqC = Void Function(
    Pointer<Void>, Pointer<NativeFunction<_SvcReqSinkC>>, Pointer<Void>);
typedef _PollSvcReqDart = void Function(
    Pointer<Void>, Pointer<NativeFunction<_SvcReqSinkC>>, Pointer<Void>);
typedef _PollSvcRespC = Void Function(
    Pointer<Void>, Pointer<NativeFunction<_SvcRespSinkC>>, Pointer<Void>);
typedef _PollSvcRespDart = void Function(
    Pointer<Void>, Pointer<NativeFunction<_SvcRespSinkC>>, Pointer<Void>);
typedef _AcceptSvcRespC = Bool Function(Pointer<Void>, Pointer<Uint8>);
typedef _AcceptSvcRespDart = bool Function(Pointer<Void>, Pointer<Uint8>);
typedef _ToB58C = Size Function(Pointer<Uint8>, Pointer<Utf8>, Size);
typedef _ToB58Dart = int Function(Pointer<Uint8>, Pointer<Utf8>, int);
typedef _FromB58C = Bool Function(Pointer<Utf8>, Pointer<Uint8>);
typedef _FromB58Dart = bool Function(Pointer<Utf8>, Pointer<Uint8>);
typedef _SignReachC = Void Function(Pointer<Void>, Pointer<Utf8>, Uint32,
    Pointer<NativeFunction<_ReachSignSinkC>>, Pointer<Void>);
typedef _SignReachDart = void Function(Pointer<Void>, Pointer<Utf8>, int,
    Pointer<NativeFunction<_ReachSignSinkC>>, Pointer<Void>);
typedef _VerifyReachC = Bool Function(Pointer<Uint8>, Size, Uint64,
    Pointer<NativeFunction<_ReachVerifySinkC>>, Pointer<Void>);
typedef _VerifyReachDart = bool Function(Pointer<Uint8>, int, int,
    Pointer<NativeFunction<_ReachVerifySinkC>>, Pointer<Void>);
typedef _ClusterJoinC = Void Function(Pointer<Void>, Pointer<Uint8>);
typedef _ClusterJoinDart = void Function(Pointer<Void>, Pointer<Uint8>);
typedef _ClusterJoinPassC = Void Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _ClusterJoinPassDart = void Function(
    Pointer<Void>, Pointer<Uint8>, int);
typedef _ClusterMembersC = Uint32 Function(Pointer<Void>);
typedef _ClusterMembersDart = int Function(Pointer<Void>);
typedef _ClusterSetQuorumC = Void Function(Pointer<Void>, Uint32);
typedef _ClusterSetQuorumDart = void Function(Pointer<Void>, int);

/// A drained outbound packet: `(link, bytes)`.
typedef OutgoingPacket = (int link, Uint8List bytes);

/// One polled `hops://` service request.
typedef ServiceRequestRow = (
  Uint8List from,
  Uint8List requestId,
  String service,
  String method,
  Uint8List args,
);

/// One polled `hops://` service response.
typedef ServiceResponseRow = (
  Uint8List from,
  Uint8List forRequestId,
  int status,
  Uint8List body,
);

/// A verified reachability record.
typedef ReachInfo = ({
  Uint8List address,
  String addressBase58,
  String endpoint,
  int issuedAt,
  int ttlSecs,
});

Uint8List _copy(Pointer<Uint8> ptr, int len) =>
    len == 0 ? Uint8List(0) : Uint8List.fromList(ptr.asTypedList(len));

/// The typed binding surface over one open `libhop`. Holds no node state; a
/// [Pointer] node handle is threaded through every call, exactly like the C ABI.
class HopFfi {
  HopFfi._(this._lib);

  final DynamicLibrary _lib;

  /// Open `libhop` and assert its ABI matches [hopAbiVersion].
  factory HopFfi.open() {
    final ffi = HopFfi._(openLibhop());
    final got = ffi._abiVersion();
    if (got != hopAbiVersion) {
      throw StateError(
        'libhop ABI mismatch: wrapper expects $hopAbiVersion, library reports $got',
      );
    }
    return ffi;
  }

  late final _abiVersion =
      _lib.lookupFunction<_AbiVersionC, _AbiVersionDart>('hop_abi_version');
  late final _nodeNew =
      _lib.lookupFunction<_NodeNewC, _NodeNewC>('hop_node_new');
  late final _nodeWithSecret =
      _lib.lookupFunction<_NodeWithSecretC, _NodeWithSecretDart>(
          'hop_node_with_secret');
  late final _nodeFree =
      _lib.lookupFunction<_NodeFreeC, _NodeFreeDart>('hop_node_free');
  late final _nodeAddress =
      _lib.lookupFunction<_NodeAddressC, _NodeAddressDart>('hop_node_address');
  late final _tick = _lib.lookupFunction<_TickC, _TickDart>('hop_node_tick');
  late final _linkUp =
      _lib.lookupFunction<_LinkUpC, _LinkUpDart>('hop_link_up');
  late final _linkDown =
      _lib.lookupFunction<_LinkDownC, _LinkDownDart>('hop_link_down');
  late final _bytesReceived =
      _lib.lookupFunction<_BytesReceivedC, _BytesReceivedDart>(
          'hop_bytes_received');
  late final _drain =
      _lib.lookupFunction<_DrainC, _DrainDart>('hop_drain_outgoing');
  late final _subscribe =
      _lib.lookupFunction<_SubscribeC, _SubscribeDart>('hop_subscribe');
  late final _publishPrekey =
      _lib.lookupFunction<_PublishPrekeyC, _PublishPrekeyDart>(
          'hop_publish_prekey');
  late final _acceptInbox =
      _lib.lookupFunction<_AcceptInboxC, _AcceptInboxDart>('hop_accept_inbox');
  late final _sendSvcReq = _lib.lookupFunction<_SendSvcReqC, _SendSvcReqDart>(
      'hop_send_service_request');
  late final _sendSvcResp =
      _lib.lookupFunction<_SendSvcRespC, _SendSvcRespDart>(
          'hop_send_service_response');
  late final _pollSvcReq = _lib.lookupFunction<_PollSvcReqC, _PollSvcReqDart>(
      'hop_poll_service_requests');
  late final _pollSvcResp =
      _lib.lookupFunction<_PollSvcRespC, _PollSvcRespDart>(
          'hop_poll_service_responses');
  late final _acceptSvcResp =
      _lib.lookupFunction<_AcceptSvcRespC, _AcceptSvcRespDart>(
          'hop_accept_service_response');
  late final _toB58 =
      _lib.lookupFunction<_ToB58C, _ToB58Dart>('hop_address_to_base58');
  late final _fromB58 =
      _lib.lookupFunction<_FromB58C, _FromB58Dart>('hop_address_from_base58');
  late final _signReach =
      _lib.lookupFunction<_SignReachC, _SignReachDart>('hop_sign_reach_record');
  late final _verifyReach =
      _lib.lookupFunction<_VerifyReachC, _VerifyReachDart>(
          'hop_verify_reach_record');
  late final _clusterJoin =
      _lib.lookupFunction<_ClusterJoinC, _ClusterJoinDart>('hop_cluster_join');
  late final _clusterJoinPass =
      _lib.lookupFunction<_ClusterJoinPassC, _ClusterJoinPassDart>(
          'hop_cluster_join_passphrase');
  late final _clusterMembers =
      _lib.lookupFunction<_ClusterMembersC, _ClusterMembersDart>(
          'hop_cluster_members');
  late final _clusterSetQuorum =
      _lib.lookupFunction<_ClusterSetQuorumC, _ClusterSetQuorumDart>(
          'hop_cluster_set_quorum');

  static Uint8List _require32(Uint8List value, String name) {
    if (value.length != 32) {
      throw ArgumentError(
          '$name must be exactly 32 bytes, got ${value.length}');
    }
    return value;
  }

  /// Run [body] with a freshly allocated, zero-filled native `uint8` buffer of
  /// [len] bytes preloaded from [data], freeing it afterward.
  R _withBytes<R>(Uint8List data, R Function(Pointer<Uint8>, int) body) {
    final len = data.length;
    final ptr = len == 0 ? nullptr : calloc<Uint8>(len);
    try {
      if (len != 0) ptr.asTypedList(len).setAll(0, data);
      return body(ptr, len);
    } finally {
      if (len != 0) calloc.free(ptr);
    }
  }

  // ---- node lifecycle ----
  Pointer<Void> nodeNew() => _nodeNew();

  Pointer<Void> nodeWithSecret(Uint8List secret) =>
      _withBytes(secret, (ptr, len) => _nodeWithSecret(ptr, len));

  void nodeFree(Pointer<Void> node) => _nodeFree(node);

  Uint8List address(Pointer<Void> node) {
    final out = calloc<Uint8>(32);
    try {
      _nodeAddress(node, out);
      return Uint8List.fromList(out.asTypedList(32));
    } finally {
      calloc.free(out);
    }
  }

  void tick(Pointer<Void> node, int nowMs) => _tick(node, nowMs);

  void connected(Pointer<Void> node, int link, bool initiator) =>
      _linkUp(node, link, initiator ? 0 : 1);

  void disconnected(Pointer<Void> node, int link) => _linkDown(node, link);

  void received(Pointer<Void> node, int link, Uint8List data) =>
      _withBytes(data, (ptr, len) => _bytesReceived(node, link, ptr, len));

  void subscribe(Pointer<Void> node, String topic) {
    final t = topic.toNativeUtf8();
    try {
      _subscribe(node, t);
    } finally {
      calloc.free(t);
    }
  }

  bool publishPrekey(Pointer<Void> node) => _publishPrekey(node);

  bool acceptInbox(Pointer<Void> node, Uint8List inboxId) => _withBytes(
      _require32(inboxId, 'inbox id'), (ptr, _) => _acceptInbox(node, ptr));

  // ---- drain (poll model) ----
  List<OutgoingPacket> drainOutgoing(Pointer<Void> node) {
    final out = <OutgoingPacket>[];
    final cb = NativeCallable<_DrainSinkC>.isolateLocal(
      (Pointer<Void> _, int link, Pointer<Uint8> ptr, int len) {
        out.add((link, _copy(ptr, len)));
      },
    );
    try {
      _drain(node, cb.nativeFunction, nullptr);
    } finally {
      cb.close();
    }
    return out;
  }

  // ---- hops:// service surface ----
  Uint8List sendServiceRequest(Pointer<Void> node, Uint8List dst,
      String service, String method, Uint8List args) {
    final s = service.toNativeUtf8();
    final m = method.toNativeUtf8();
    final out = calloc<Uint8>(32);
    try {
      final ok = _withBytes(
          _require32(dst, 'destination'),
          (dstPtr, _) => _withBytes(
              args,
              (argsPtr, argsLen) =>
                  _sendSvcReq(node, dstPtr, s, m, argsPtr, argsLen, out)));
      if (!ok) throw StateError('hop_send_service_request failed');
      return Uint8List.fromList(out.asTypedList(32));
    } finally {
      calloc.free(s);
      calloc.free(m);
      calloc.free(out);
    }
  }

  bool sendServiceResponse(Pointer<Void> node, Uint8List to,
      Uint8List forRequestId, int status, Uint8List body) {
    return _withBytes(
        _require32(to, 'response destination'),
        (toPtr, _) => _withBytes(
            _require32(forRequestId, 'request id'),
            (ridPtr, _) => _withBytes(
                body,
                (bodyPtr, bodyLen) => _sendSvcResp(
                    node, toPtr, ridPtr, status, bodyPtr, bodyLen))));
  }

  bool acceptServiceResponse(Pointer<Void> node, Uint8List requestId) =>
      _withBytes(_require32(requestId, 'request id'),
          (ptr, _) => _acceptSvcResp(node, ptr));

  List<ServiceRequestRow> takeServiceRequests(Pointer<Void> node) {
    final out = <ServiceRequestRow>[];
    final cb = NativeCallable<_SvcReqSinkC>.isolateLocal(
      (Pointer<Void> _,
          Pointer<Uint8> from,
          Pointer<Uint8> rid,
          Pointer<Utf8> service,
          Pointer<Utf8> method,
          Pointer<Uint8> args,
          int argsLen) {
        out.add((
          _copy(from, 32),
          _copy(rid, 32),
          service.toDartString(),
          method.toDartString(),
          _copy(args, argsLen),
        ));
      },
    );
    try {
      _pollSvcReq(node, cb.nativeFunction, nullptr);
    } finally {
      cb.close();
    }
    return out;
  }

  List<ServiceResponseRow> takeServiceResponses(Pointer<Void> node) {
    final out = <ServiceResponseRow>[];
    final cb = NativeCallable<_SvcRespSinkC>.isolateLocal(
      (Pointer<Void> _, Pointer<Uint8> from, Pointer<Uint8> forId, int status,
          Pointer<Uint8> body, int bodyLen) {
        out.add(
            (_copy(from, 32), _copy(forId, 32), status, _copy(body, bodyLen)));
        // False: the endpoint pump accepts durably via a later
        // hop_accept_service_response, mirroring the other SDKs.
        return false;
      },
      exceptionalReturn: false,
    );
    try {
      _pollSvcResp(node, cb.nativeFunction, nullptr);
    } finally {
      cb.close();
    }
    return out;
  }

  // ---- addressing ----
  String toBase58(Uint8List addr32) {
    final out = calloc<Uint8>(64);
    try {
      final n = _withBytes(_require32(addr32, 'address'),
          (ptr, _) => _toB58(ptr, out.cast<Utf8>(), 64));
      return utf8.decode(out.asTypedList(n));
    } finally {
      calloc.free(out);
    }
  }

  Uint8List fromBase58(String text) {
    final t = text.toNativeUtf8();
    final out = calloc<Uint8>(32);
    try {
      if (!_fromB58(t, out)) {
        throw ArgumentError('not a valid Hop address: $text');
      }
      return Uint8List.fromList(out.asTypedList(32));
    } finally {
      calloc.free(t);
      calloc.free(out);
    }
  }

  // ---- reachability records (discovery) ----
  Uint8List signReach(Pointer<Void> node, String endpoint, int ttlSecs) {
    Uint8List record = Uint8List(0);
    final ep = endpoint.toNativeUtf8();
    final cb = NativeCallable<_ReachSignSinkC>.isolateLocal(
      (Pointer<Void> _, Pointer<Uint8> ptr, int len) {
        record = _copy(ptr, len);
      },
    );
    try {
      _signReach(node, ep, ttlSecs, cb.nativeFunction, nullptr);
    } finally {
      cb.close();
      calloc.free(ep);
    }
    return record;
  }

  ReachInfo? verifyReach(Uint8List record, int nowSecs) {
    ReachInfo? info;
    final cb = NativeCallable<_ReachVerifySinkC>.isolateLocal(
      (Pointer<Void> _, Pointer<Uint8> addr, Pointer<Utf8> endpoint,
          int issuedAt, int ttlSecs) {
        final a = _copy(addr, 32);
        info = (
          address: a,
          addressBase58: toBase58(a),
          endpoint: endpoint.toDartString(),
          issuedAt: issuedAt,
          ttlSecs: ttlSecs,
        );
      },
    );
    try {
      final ok = _withBytes(
          record,
          (ptr, len) =>
              _verifyReach(ptr, len, nowSecs, cb.nativeFunction, nullptr));
      return ok ? info : null;
    } finally {
      cb.close();
    }
  }

  // ---- clustering (DESIGN.md §40) ----
  void clusterJoin(Pointer<Void> node, Uint8List secret) => _withBytes(
      _require32(secret, 'cluster secret'),
      (ptr, _) => _clusterJoin(node, ptr));

  void clusterJoinPassphrase(Pointer<Void> node, Uint8List passphrase) =>
      _withBytes(passphrase, (ptr, len) => _clusterJoinPass(node, ptr, len));

  int clusterMembers(Pointer<Void> node) => _clusterMembers(node);

  void clusterSetQuorum(Pointer<Void> node, int minLiveMembers) =>
      _clusterSetQuorum(node, minLiveMembers);
}
