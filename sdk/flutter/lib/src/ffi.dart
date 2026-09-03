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
const int hopAbiVersion = 6;

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
typedef _HpsMsgSinkC = Bool Function(Pointer<Void>, Pointer<Uint8>,
    Pointer<Utf8>, Pointer<Uint8>, Pointer<Uint8>, Size);
typedef _HpsInviteSinkC = Void Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Utf8>, Uint32);
typedef _Addr32SinkC = Void Function(Pointer<Void>, Pointer<Uint8>);
typedef _HpsTopicSinkC = Void Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Utf8>, Uint32, Bool, Uint32);
typedef _HpsBrowseSinkC = Void Function(Pointer<Void>, Pointer<Uint8>,
    Pointer<Utf8>, Uint32, Pointer<Utf8>, Pointer<Utf8>, Uint32);

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
// ---- hps:// pub/sub (DESIGN.md section 32) ----
//
// A Hop group message is NOT one-to-one fan-out and NOT a multicast bundle:
// it is a single content-key-encrypted, per-writer-signed publication, flooded
// once. Membership, invites and revocation are properties of the topic's key
// handoff, which is why invite / approve / rekey sit in the messaging surface.
// kind / access / visibility cross as plain uint32_t; an out-of-range
// discriminant makes the call FAIL and is never coerced or defaulted, because
// reading a garbage int as open would hand a topic's keys to anyone who asks.
//
// These are DECLARED and deliberately NOT yet wrapped in a public Dart API:
// the thin methods below exist so every lookup resolves against libhop for
// real, not because the package exposes a channel surface today.
typedef _HpsRegisterC = Bool Function(Pointer<Void>, Pointer<Utf8>, Uint32,
    Uint32, Uint32, Pointer<Uint8>, Size, Pointer<Size>);
typedef _HpsRegisterDart = bool Function(Pointer<Void>, Pointer<Utf8>, int, int,
    int, Pointer<Uint8>, int, Pointer<Size>);
typedef _HpsSubscribeC = Bool Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Utf8>, Pointer<Uint8>);
typedef _HpsSubscribeDart = bool Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Utf8>, Pointer<Uint8>);
typedef _HpsPublishC = Bool Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, Size, Pointer<Uint8>);
typedef _HpsPublishDart = bool Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, int, Pointer<Uint8>);
typedef _PollHpsMessagesC = Void Function(
    Pointer<Void>, Pointer<NativeFunction<_HpsMsgSinkC>>, Pointer<Void>);
typedef _PollHpsMessagesDart = void Function(
    Pointer<Void>, Pointer<NativeFunction<_HpsMsgSinkC>>, Pointer<Void>);
typedef _AcceptHpsMessageC = Bool Function(Pointer<Void>, Pointer<Uint8>);
typedef _AcceptHpsMessageDart = bool Function(Pointer<Void>, Pointer<Uint8>);
typedef _HpsInviteC = Bool Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _HpsInviteDart = bool Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _HpsAcceptInviteC = Bool Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Utf8>, Pointer<Uint8>);
typedef _HpsAcceptInviteDart = bool Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Utf8>, Pointer<Uint8>);
typedef _HpsDeclineInviteC = Bool Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Utf8>);
typedef _HpsDeclineInviteDart = bool Function(
    Pointer<Void>, Pointer<Uint8>, Pointer<Utf8>);
typedef _PollHpsInvitesC = Void Function(
    Pointer<Void>, Pointer<NativeFunction<_HpsInviteSinkC>>, Pointer<Void>);
typedef _PollHpsInvitesDart = void Function(
    Pointer<Void>, Pointer<NativeFunction<_HpsInviteSinkC>>, Pointer<Void>);
typedef _HpsLeaveC = Bool Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, Pointer<Bool>);
typedef _HpsLeaveDart = bool Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, Pointer<Bool>);
typedef _HpsPendingC = Size Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<NativeFunction<_Addr32SinkC>>, Pointer<Void>);
typedef _HpsPendingDart = int Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<NativeFunction<_Addr32SinkC>>, Pointer<Void>);
typedef _HpsApproveC = Bool Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _HpsApproveDart = bool Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _HpsDenyC = Bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>);
typedef _HpsDenyDart = bool Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>);
typedef _HpsRekeyC = Size Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Uint8>, Size, Pointer<NativeFunction<_Addr32SinkC>>, Pointer<Void>);
typedef _HpsRekeyDart = int Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Uint8>,
    int,
    Pointer<NativeFunction<_Addr32SinkC>>,
    Pointer<Void>);
typedef _HpsReachC = Uint32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _HpsReachDart = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _HpsMembersC = Size Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<NativeFunction<_Addr32SinkC>>, Pointer<Void>);
typedef _HpsMembersDart = int Function(Pointer<Void>, Pointer<Utf8>,
    Pointer<NativeFunction<_Addr32SinkC>>, Pointer<Void>);
typedef _HpsMyTopicsC = Size Function(
    Pointer<Void>, Pointer<NativeFunction<_HpsTopicSinkC>>, Pointer<Void>);
typedef _HpsMyTopicsDart = int Function(
    Pointer<Void>, Pointer<NativeFunction<_HpsTopicSinkC>>, Pointer<Void>);
typedef _HpsBrowseC = Size Function(
    Pointer<Void>, Pointer<NativeFunction<_HpsBrowseSinkC>>, Pointer<Void>);
typedef _HpsBrowseDart = int Function(
    Pointer<Void>, Pointer<NativeFunction<_HpsBrowseSinkC>>, Pointer<Void>);

/// The kind of `hps://` topic hosted at a path (DESIGN.md section 32).
const int hpsKindChannel = 0;
const int hpsKindService = 1;

/// Who may obtain a topic's keys.
const int hpsAccessOpen = 0;
const int hpsAccessRequestToJoin = 1;
const int hpsAccessInvite = 2;

/// Whether a topic announces itself for discovery.
const int hpsVisibilityPrivate = 0;
const int hpsVisibilityDiscoverable = 1;

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

/// One polled `hps://` publication, after decryption and sender verification.
typedef HpsMessageRow = (
  Uint8List id,
  String path,
  Uint8List sender,
  Uint8List body,
);

/// One drained `hps://` invite we received.
typedef HpsInviteRow = (
  Uint8List host,
  String path,
  int kind,
);

/// One topic this node hosts or follows, for rebuilding a channel list.
typedef HpsTopicRow = (
  Uint8List host,
  String path,
  int kind,
  bool hosting,
  int access,
);

/// One same-app discoverable topic visible on the mesh.
typedef HpsTopicInfoRow = (
  Uint8List host,
  String path,
  int kind,
  String title,
  String summary,
  int access,
);

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
  // ---- hps:// pub/sub (DESIGN.md section 32) ----
  late final _hpsRegister =
      _lib.lookupFunction<_HpsRegisterC, _HpsRegisterDart>('hop_hps_register');
  late final _hpsSubscribe = _lib
      .lookupFunction<_HpsSubscribeC, _HpsSubscribeDart>('hop_hps_subscribe');
  late final _hpsPublish =
      _lib.lookupFunction<_HpsPublishC, _HpsPublishDart>('hop_hps_publish');
  late final _pollHpsMessages =
      _lib.lookupFunction<_PollHpsMessagesC, _PollHpsMessagesDart>(
          'hop_poll_hps_messages');
  late final _acceptHpsMessage =
      _lib.lookupFunction<_AcceptHpsMessageC, _AcceptHpsMessageDart>(
          'hop_accept_hps_message');
  late final _hpsInvite =
      _lib.lookupFunction<_HpsInviteC, _HpsInviteDart>('hop_hps_invite');
  late final _hpsAcceptInvite =
      _lib.lookupFunction<_HpsAcceptInviteC, _HpsAcceptInviteDart>(
          'hop_hps_accept_invite');
  late final _hpsDeclineInvite =
      _lib.lookupFunction<_HpsDeclineInviteC, _HpsDeclineInviteDart>(
          'hop_hps_decline_invite');
  late final _pollHpsInvites =
      _lib.lookupFunction<_PollHpsInvitesC, _PollHpsInvitesDart>(
          'hop_poll_hps_invites');
  late final _hpsLeave =
      _lib.lookupFunction<_HpsLeaveC, _HpsLeaveDart>('hop_hps_leave');
  late final _hpsPending =
      _lib.lookupFunction<_HpsPendingC, _HpsPendingDart>('hop_hps_pending');
  late final _hpsApprove =
      _lib.lookupFunction<_HpsApproveC, _HpsApproveDart>('hop_hps_approve');
  late final _hpsDeny =
      _lib.lookupFunction<_HpsDenyC, _HpsDenyDart>('hop_hps_deny');
  late final _hpsRekey =
      _lib.lookupFunction<_HpsRekeyC, _HpsRekeyDart>('hop_hps_rekey');
  late final _hpsReach =
      _lib.lookupFunction<_HpsReachC, _HpsReachDart>('hop_hps_reach');
  late final _hpsMembers =
      _lib.lookupFunction<_HpsMembersC, _HpsMembersDart>('hop_hps_members');
  late final _hpsMyTopics =
      _lib.lookupFunction<_HpsMyTopicsC, _HpsMyTopicsDart>('hop_hps_my_topics');
  late final _hpsBrowse =
      _lib.lookupFunction<_HpsBrowseC, _HpsBrowseDart>('hop_hps_browse');

  // ---- hps:// pub/sub methods (section 32) ----

  /// Register (host) a topic at [path]. Returns the service public key for a
  /// `hpsKindService` topic, an EMPTY list for a channel, or null when the
  /// call failed: the empty key is a success, never conflate it with one.
  Uint8List? hpsRegister(
      Pointer<Void> node, String path, int kind, int access, int visibility) {
    final p = path.toNativeUtf8();
    final out = calloc<Uint8>(32);
    final outLen = calloc<Size>(1);
    try {
      final ok =
          _hpsRegister(node, p, kind, access, visibility, out, 32, outLen);
      if (!ok) return null;
      final n = outLen.value;
      return n == 0 ? Uint8List(0) : Uint8List.fromList(out.asTypedList(n));
    } finally {
      calloc.free(p);
      calloc.free(out);
      calloc.free(outLen);
    }
  }

  /// Subscribe to `hps://{host}/{path}`. Returns the subscribe bundle id, or
  /// null on error.
  Uint8List? hpsSubscribe(Pointer<Void> node, Uint8List host, String path) {
    final p = path.toNativeUtf8();
    final out = calloc<Uint8>(32);
    try {
      final ok = _withBytes(_require32(host, 'host'),
          (hostPtr, _) => _hpsSubscribe(node, hostPtr, p, out));
      return ok ? Uint8List.fromList(out.asTypedList(32)) : null;
    } finally {
      calloc.free(p);
      calloc.free(out);
    }
  }

  /// Publish [body] to a topic we host or (for a channel) belong to. Returns
  /// the bundle id, or null on error.
  Uint8List? hpsPublish(Pointer<Void> node, String path, Uint8List body) {
    final p = path.toNativeUtf8();
    final out = calloc<Uint8>(32);
    try {
      final ok = _withBytes(body,
          (bodyPtr, bodyLen) => _hpsPublish(node, p, bodyPtr, bodyLen, out));
      return ok ? Uint8List.fromList(out.asTypedList(32)) : null;
    } finally {
      calloc.free(p);
      calloc.free(out);
    }
  }

  /// Poll received publications WITHOUT accepting them; rows repeat until
  /// [acceptHpsMessage] succeeds, mirroring [takeServiceResponses].
  List<HpsMessageRow> takeHpsMessages(Pointer<Void> node) {
    final out = <HpsMessageRow>[];
    final cb = NativeCallable<_HpsMsgSinkC>.isolateLocal(
      (Pointer<Void> _, Pointer<Uint8> id, Pointer<Utf8> path,
          Pointer<Uint8> sender, Pointer<Uint8> body, int bodyLen) {
        out.add((
          _copy(id, 32),
          path.toDartString(),
          _copy(sender, 32),
          _copy(body, bodyLen)
        ));
        return false;
      },
      exceptionalReturn: false,
    );
    try {
      _pollHpsMessages(node, cb.nativeFunction, nullptr);
    } finally {
      cb.close();
    }
    return out;
  }

  /// Durably accept one publication returned by [takeHpsMessages].
  bool acceptHpsMessage(Pointer<Void> node, Uint8List id) => _withBytes(
      _require32(id, 'publication id'),
      (ptr, _) => _acceptHpsMessage(node, ptr));

  /// Host to destination: invite [dest] to a topic we host. Returns the
  /// invite bundle id, or null on error.
  Uint8List? hpsInvite(Pointer<Void> node, String path, Uint8List dest) {
    final p = path.toNativeUtf8();
    final out = calloc<Uint8>(32);
    try {
      final ok = _withBytes(_require32(dest, 'invite destination'),
          (destPtr, _) => _hpsInvite(node, p, destPtr, out));
      return ok ? Uint8List.fromList(out.asTypedList(32)) : null;
    } finally {
      calloc.free(p);
      calloc.free(out);
    }
  }

  /// Member to host: accept an invite we received. Returns the accept bundle
  /// id, or null on error.
  Uint8List? hpsAcceptInvite(Pointer<Void> node, Uint8List host, String path) {
    final p = path.toNativeUtf8();
    final out = calloc<Uint8>(32);
    try {
      final ok = _withBytes(_require32(host, 'invite host'),
          (hostPtr, _) => _hpsAcceptInvite(node, hostPtr, p, out));
      return ok ? Uint8List.fromList(out.asTypedList(32)) : null;
    } finally {
      calloc.free(p);
      calloc.free(out);
    }
  }

  /// Decline a received invite, durably, so it does not reappear on restart.
  bool hpsDeclineInvite(Pointer<Void> node, Uint8List host, String path) {
    final p = path.toNativeUtf8();
    try {
      return _withBytes(_require32(host, 'invite host'),
          (hostPtr, _) => _hpsDeclineInvite(node, hostPtr, p));
    } finally {
      calloc.free(p);
    }
  }

  /// Drain invites we have received, CLEARING them. Take-and-clear, unlike
  /// [takeHpsMessages]: a drained invite is gone, so persist what you surface.
  List<HpsInviteRow> takeHpsInvites(Pointer<Void> node) {
    final out = <HpsInviteRow>[];
    final cb = NativeCallable<_HpsInviteSinkC>.isolateLocal(
      (Pointer<Void> _, Pointer<Uint8> host, Pointer<Utf8> path, int kind) {
        out.add((_copy(host, 32), path.toDartString(), kind));
      },
    );
    try {
      _pollHpsInvites(node, cb.nativeFunction, nullptr);
    } finally {
      cb.close();
    }
    return out;
  }

  /// Leave a topic. `ok` is the C call's result; `id` is null when leaving a
  /// topic we HOST, because that sends no bundle and is a success, not a
  /// failure.
  ({bool ok, Uint8List? id}) hpsLeave(Pointer<Void> node, String path) {
    final p = path.toNativeUtf8();
    final out = calloc<Uint8>(32);
    final hasId = calloc<Bool>(1);
    try {
      final ok = _hpsLeave(node, p, out, hasId);
      return (
        ok: ok,
        id: hasId.value ? Uint8List.fromList(out.asTypedList(32)) : null,
      );
    } finally {
      calloc.free(p);
      calloc.free(out);
      calloc.free(hasId);
    }
  }

  /// Host: pending join requests on a request-to-join topic.
  List<Uint8List> hpsPending(Pointer<Void> node, String path) {
    final out = <Uint8List>[];
    final p = path.toNativeUtf8();
    final cb = NativeCallable<_Addr32SinkC>.isolateLocal(
      (Pointer<Void> _, Pointer<Uint8> addr) {
        out.add(_copy(addr, 32));
      },
    );
    try {
      _hpsPending(node, p, cb.nativeFunction, nullptr);
    } finally {
      cb.close();
      calloc.free(p);
    }
    return out;
  }

  /// Host: approve a pending requester. Returns the keys bundle id, or null.
  Uint8List? hpsApprove(Pointer<Void> node, String path, Uint8List requester) {
    final p = path.toNativeUtf8();
    final out = calloc<Uint8>(32);
    try {
      final ok = _withBytes(_require32(requester, 'requester'),
          (rPtr, _) => _hpsApprove(node, p, rPtr, out));
      return ok ? Uint8List.fromList(out.asTypedList(32)) : null;
    } finally {
      calloc.free(p);
      calloc.free(out);
    }
  }

  /// Host: deny a pending requester. No keys are sealed.
  bool hpsDeny(Pointer<Void> node, String path, Uint8List requester) {
    final p = path.toNativeUtf8();
    try {
      return _withBytes(_require32(requester, 'requester'),
          (rPtr, _) => _hpsDeny(node, p, rPtr));
    } finally {
      calloc.free(p);
    }
  }

  /// Host: selective forward rotation, which is how a member is REVOKED.
  /// [remove] is packed 32-byte addresses back to back; the count is computed
  /// from the byte length and must divide evenly. Returns the rekey bundle ids.
  List<Uint8List> hpsRekey(
      Pointer<Void> node, String path, String newPath, Uint8List remove) {
    if (remove.length % 32 != 0) {
      throw ArgumentError(
          'remove must be 32-byte addresses packed back to back, got ${remove.length} bytes');
    }
    final p = path.toNativeUtf8();
    final np = newPath.toNativeUtf8();
    final out = <Uint8List>[];
    final cb = NativeCallable<_Addr32SinkC>.isolateLocal(
      (Pointer<Void> _, Pointer<Uint8> id) {
        out.add(_copy(id, 32));
      },
    );
    try {
      _withBytes(
          remove,
          (rPtr, rLen) => _hpsRekey(
              node, p, np, rPtr, rLen ~/ 32, cb.nativeFunction, nullptr));
    } finally {
      cb.close();
      calloc.free(p);
      calloc.free(np);
    }
    return out;
  }

  /// Host: a topic's reach, the distinct addresses that have acked a
  /// publication on it. The only honest delivery number for a flood.
  int hpsReach(Pointer<Void> node, String path) {
    final p = path.toNativeUtf8();
    try {
      return _hpsReach(node, p);
    } finally {
      calloc.free(p);
    }
  }

  /// Host: the retained-member set for a topic.
  List<Uint8List> hpsMembers(Pointer<Void> node, String path) {
    final out = <Uint8List>[];
    final p = path.toNativeUtf8();
    final cb = NativeCallable<_Addr32SinkC>.isolateLocal(
      (Pointer<Void> _, Pointer<Uint8> addr) {
        out.add(_copy(addr, 32));
      },
    );
    try {
      _hpsMembers(node, p, cb.nativeFunction, nullptr);
    } finally {
      cb.close();
      calloc.free(p);
    }
    return out;
  }

  /// Every topic this node hosts or follows, for rebuilding a channel list
  /// after a restart.
  List<HpsTopicRow> hpsMyTopics(Pointer<Void> node) {
    final out = <HpsTopicRow>[];
    final cb = NativeCallable<_HpsTopicSinkC>.isolateLocal(
      (Pointer<Void> _, Pointer<Uint8> host, Pointer<Utf8> path, int kind,
          bool hosting, int access) {
        out.add((_copy(host, 32), path.toDartString(), kind, hosting, access));
      },
    );
    try {
      _hpsMyTopics(node, cb.nativeFunction, nullptr);
    } finally {
      cb.close();
    }
    return out;
  }

  /// Same-app discoverable topics visible on the mesh.
  List<HpsTopicInfoRow> hpsBrowse(Pointer<Void> node) {
    final out = <HpsTopicInfoRow>[];
    final cb = NativeCallable<_HpsBrowseSinkC>.isolateLocal(
      (Pointer<Void> _, Pointer<Uint8> host, Pointer<Utf8> path, int kind,
          Pointer<Utf8> title, Pointer<Utf8> summary, int access) {
        out.add((
          _copy(host, 32),
          path.toDartString(),
          kind,
          title.toDartString(),
          summary.toDartString(),
          access
        ));
      },
    );
    try {
      _hpsBrowse(node, cb.nativeFunction, nullptr);
    } finally {
      cb.close();
    }
    return out;
  }

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
