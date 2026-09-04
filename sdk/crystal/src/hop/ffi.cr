# Raw Crystal bindings to libhop (the C ABI, sdk/hop.h). Crystal binds C directly via `lib`, so this
# SDK needs no generated shim. Thin and one-to-one; ergonomics live in endpoint.cr. The library is
# located at link time via CRYSTAL_LIBRARY_PATH or HOP_LIBDIR; see shard.yml / CLAUDE.md.

# Link libhop. `#{__DIR__}` resolves at compile time to this file's dir, so the default `-L` points at
# the repo's target/debug without any env. libhop's install_name is an absolute path (cargo bakes it),
# so the binary finds the dylib at runtime with no rpath. To link a release or custom build, add its
# dir to CRYSTAL_LIBRARY_PATH (an extra `-L`); the linker searches all of them.
@[Link("hop", ldflags: "-L#{__DIR__}/../../../../target/debug")]
lib LibHop
  # `const struct HopNode *` is an opaque handle; a Void* is the honest binding.
  fun abi_version = hop_abi_version : UInt32 # the C ABI returns uint32_t; keep the binding's sign honest
  fun node_new = hop_node_new : Void*
  fun node_with_secret = hop_node_with_secret(secret : UInt8*, secret_len : LibC::SizeT) : Void*
  fun node_open = hop_node_open(db_path : LibC::Char*, secret : UInt8*, secret_len : LibC::SizeT, app_secret : UInt8*, app_secret_len : LibC::SizeT) : Void*
  fun node_open_keyed = hop_node_open_keyed(db_path : LibC::Char*, secret : UInt8*, secret_len : LibC::SizeT, app_secret : UInt8*, app_secret_len : LibC::SizeT, key : UInt8*, key_len : LibC::SizeT) : Void*
  fun node_is_persistent = hop_node_is_persistent(node : Void*) : Bool
  fun node_free = hop_node_free(node : Void*) : Void
  fun node_is_encrypted = hop_node_is_encrypted(node : Void*) : Bool
  fun node_address = hop_node_address(node : Void*, out_addr : UInt8*) : Bool
  fun node_tick = hop_node_tick(node : Void*, now_ms : UInt64) : Void
  fun link_up = hop_link_up(node : Void*, link : UInt64, role : UInt32) : Void
  fun bytes_received = hop_bytes_received(node : Void*, link : UInt64, data : UInt8*, len : LibC::SizeT) : Void
  fun link_down = hop_link_down(node : Void*, link : UInt64) : Void
  fun drain_outgoing = hop_drain_outgoing(node : Void*, sink : (Void*, UInt64, UInt8*, LibC::SizeT ->), ctx : Void*) : Void
  fun subscribe = hop_subscribe(node : Void*, topic : LibC::Char*) : Void
  fun publish_prekey = hop_publish_prekey(node : Void*) : Bool
  fun accept_inbox = hop_accept_inbox(node : Void*, inbox_id : UInt8*) : Bool
  fun accept_service_response = hop_accept_service_response(node : Void*, request_id : UInt8*) : Bool
  fun accept_service_request = hop_accept_service_request(node : Void*, request_id : UInt8*) : Bool
  fun reject_service_request = hop_reject_service_request(node : Void*, request_id : UInt8*) : Bool
  fun send_service_request = hop_send_service_request(node : Void*, dst : UInt8*, service : LibC::Char*, method : LibC::Char*, args : UInt8*, args_len : LibC::SizeT, out_id : UInt8*) : Bool
  fun send_service_response = hop_send_service_response(node : Void*, to : UInt8*, for_request_id : UInt8*, status : UInt16, body : UInt8*, body_len : LibC::SizeT) : Bool
  fun poll_service_requests = hop_poll_service_requests(node : Void*, sink : (Void*, UInt8*, UInt8*, LibC::Char*, LibC::Char*, UInt8*, LibC::SizeT -> Bool), ctx : Void*) : Void
  fun poll_service_responses = hop_poll_service_responses(node : Void*, sink : (Void*, UInt8*, UInt8*, UInt16, UInt8*, LibC::SizeT -> Bool), ctx : Void*) : Void
  fun address_to_base58 = hop_address_to_base58(addr : UInt8*, out_buf : LibC::Char*, out_cap : LibC::SizeT) : LibC::SizeT
  fun address_from_base58 = hop_address_from_base58(text : LibC::Char*, out32 : UInt8*) : Bool
  fun sign_reach_record = hop_sign_reach_record(node : Void*, endpoint : LibC::Char*, ttl_secs : UInt32, sink : (Void*, UInt8*, LibC::SizeT ->), ctx : Void*) : Void
  fun verify_reach_record = hop_verify_reach_record(bytes : UInt8*, len : LibC::SizeT, now_secs : UInt64, sink : (Void*, UInt8*, LibC::Char*, UInt64, UInt32 ->), ctx : Void*) : Bool
  # §19 relay pool. PLAT-003: the four calls the v4 -> v5 ABI bump this wrapper pins was taken for,
  # which no C-ABI wrapper bound, so a host on the published SDKs could not fail over off a dead relay.
  fun relay_add = hop_relay_add(node : Void*, url : LibC::Char*, configured : Bool) : Bool
  fun relay_next = hop_relay_next(node : Void*, out_buf : LibC::Char*, out_cap : LibC::SizeT) : LibC::SizeT
  fun relay_report = hop_relay_report(node : Void*, url : LibC::Char*, ok : Bool) : Void
  fun relay_pool_size = hop_relay_pool_size(node : Void*, out_available : LibC::SizeT*) : LibC::SizeT
  # Endpoint clustering (DESIGN.md §40).
  fun cluster_join = hop_cluster_join(node : Void*, secret : UInt8*) : Void
  fun cluster_join_passphrase = hop_cluster_join_passphrase(node : Void*, pass : UInt8*, pass_len : LibC::SizeT) : Void
  fun cluster_members = hop_cluster_members(node : Void*) : UInt32
  fun cluster_set_quorum = hop_cluster_set_quorum(node : Void*, min_live_members : UInt32) : Void
  fun cluster_mark_done = hop_cluster_mark_done(node : Void*, from : UInt8*, request_id : UInt8*) : Void
  fun cluster_would_drop = hop_cluster_would_drop(node : Void*, from : UInt8*, request_id : UInt8*) : Bool
  # §32 hps:// pub/sub: services and channels (group chat), the surface the v5 -> v6 ABI bump added.
  # PLAT-005: the C ABI exported NOTHING from hps:// before version 6 of the C ABI, so every wrapper that sits on it,
  # this one included, could not host, join, or post to a channel even though the protocol has shipped
  # in core and over UniFFI for as long as it has existed.
  #
  # A Hop group message is NOT one-to-one fan-out and NOT a multicast bundle: it is a single
  # content-key-encrypted, per-writer-signed publication, flooded once. Membership, invites and
  # revocation are properties of the topic's key handoff, which is why invite / approve / rekey belong
  # to this messaging surface rather than to a separate access-control API.
  #
  # Three distinctions the signatures carry that a caller must not flatten:
  #   * hps_register returns a bool AND writes the key length through a separate out-param, so a
  #     channel (zero-length key, because its writers sign with their own identity) stays
  #     distinguishable from a failure. The bool, never the length, is what says the topic was hosted.
  #   * hps_leave writes out_has_id: leaving a topic we HOST sends no bundle, which is a success with
  #     no id rather than a failure.
  #   * hps_rekey takes a COUNT of 32-byte addresses packed back to back, not a byte length.
  #
  # kind / access / visibility cross as plain uint32 discriminants (HopHpsKind, HopHpsAccess,
  # HopHpsVisibility in sdk/hop.h). An out-of-range value makes the call FAIL, and is never coerced or
  # defaulted, on purpose: reading a garbage int as Open would hand a topic's keys to anyone who asks.
  #
  # poll_hps_messages is accept-to-remove, the same shape as hop_poll_inbox: returning true from the
  # sink accepts the publication and core durably drops it, returning false leaves it queued for
  # redelivery until accept_hps_message succeeds. poll_hps_invites is take-and-clear instead, so a
  # drained invite is gone whether or not anyone acted on it and a host must persist what it surfaces.
  fun hps_register = hop_hps_register(node : Void*, path : LibC::Char*, kind : UInt32, access : UInt32, visibility : UInt32, out_pubkey : UInt8*, out_pubkey_cap : LibC::SizeT, out_pubkey_len : LibC::SizeT*) : Bool
  fun hps_subscribe = hop_hps_subscribe(node : Void*, host : UInt8*, path : LibC::Char*, out_id : UInt8*) : Bool
  fun hps_publish = hop_hps_publish(node : Void*, path : LibC::Char*, body : UInt8*, body_len : LibC::SizeT, out_id : UInt8*) : Bool
  fun poll_hps_messages = hop_poll_hps_messages(node : Void*, sink : (Void*, UInt8*, LibC::Char*, UInt8*, UInt8*, LibC::SizeT -> Bool), ctx : Void*) : Void
  fun accept_hps_message = hop_accept_hps_message(node : Void*, id : UInt8*) : Bool
  fun hps_invite = hop_hps_invite(node : Void*, path : LibC::Char*, dest : UInt8*, out_id : UInt8*) : Bool
  fun hps_accept_invite = hop_hps_accept_invite(node : Void*, host : UInt8*, path : LibC::Char*, out_id : UInt8*) : Bool
  fun hps_decline_invite = hop_hps_decline_invite(node : Void*, host : UInt8*, path : LibC::Char*) : Bool
  fun poll_hps_invites = hop_poll_hps_invites(node : Void*, sink : (Void*, UInt8*, LibC::Char*, UInt32 ->), ctx : Void*) : Void
  fun hps_leave = hop_hps_leave(node : Void*, path : LibC::Char*, out_id : UInt8*, out_has_id : Bool*) : Bool
  fun hps_pending = hop_hps_pending(node : Void*, path : LibC::Char*, sink : (Void*, UInt8* ->), ctx : Void*) : LibC::SizeT
  fun hps_approve = hop_hps_approve(node : Void*, path : LibC::Char*, requester : UInt8*, out_id : UInt8*) : Bool
  fun hps_deny = hop_hps_deny(node : Void*, path : LibC::Char*, requester : UInt8*) : Bool
  fun hps_rekey = hop_hps_rekey(node : Void*, path : LibC::Char*, new_path : LibC::Char*, remove : UInt8*, remove_count : LibC::SizeT, sink : (Void*, UInt8* ->), ctx : Void*) : LibC::SSizeT
  fun hps_reach = hop_hps_reach(node : Void*, path : LibC::Char*) : UInt32
  fun hps_members = hop_hps_members(node : Void*, path : LibC::Char*, sink : (Void*, UInt8* ->), ctx : Void*) : LibC::SizeT
  fun hps_my_topics = hop_hps_my_topics(node : Void*, sink : (Void*, UInt8*, LibC::Char*, UInt32, Bool, UInt32 ->), ctx : Void*) : LibC::SizeT
  fun hps_browse = hop_hps_browse(node : Void*, sink : (Void*, UInt8*, LibC::Char*, UInt32, LibC::Char*, LibC::Char*, UInt32 ->), ctx : Void*) : LibC::SizeT
end

module Hop
  # Thin, one-to-one helpers over LibHop: turn raw pointers + synchronous sink callbacks into Crystal
  # Bytes/String/arrays. Everything ergonomic lives in Hop::Endpoint.
  module FFI
    ABI_EXPECTED = 7_u32

    # Verified reach record fields (mirrors ReachInfo on the Rust side).
    record Reach, address : Bytes, endpoint : String, issued_at : UInt64, ttl_secs : UInt32

    def self.assert_abi!
      got = LibHop.abi_version
      raise "libhop ABI mismatch: wrapper expects #{ABI_EXPECTED}, library reports #{got}" if got != ABI_EXPECTED
    end

    private def self.require_32(bytes : Bytes, name : String) : Bytes
      raise ArgumentError.new("#{name} must be exactly 32 bytes, got #{bytes.size}") unless bytes.size == 32
      bytes
    end

    # ---- read C memory that is valid only during a call ----
    def self.read_bytes(ptr : UInt8*, len : LibC::SizeT) : Bytes
      return Bytes.new(0) if ptr.null? || len == 0
      Slice.new(ptr, len).dup
    end

    def self.read_cstr(ptr : LibC::Char*) : String
      ptr.null? ? "" : String.new(ptr)
    end

    # ---- thin wrappers ----
    def self.node_new : Void*
      LibHop.node_new
    end

    def self.node_with_secret(secret : Bytes) : Void*
      LibHop.node_with_secret(secret.to_unsafe, secret.size)
    end

    def self.node_free(node : Void*) : Nil
      LibHop.node_free(node)
    end

    def self.tick(node : Void*, now_ms : UInt64) : Nil
      LibHop.node_tick(node, now_ms)
    end

    # role: dialer/initiator = 0, acceptor = 1 (matches the other SDKs).
    def self.connected(node : Void*, link : UInt64, initiator : Bool) : Nil
      LibHop.link_up(node, link, initiator ? 0_u32 : 1_u32)
    end

    def self.disconnected(node : Void*, link : UInt64) : Nil
      LibHop.link_down(node, link)
    end

    def self.received(node : Void*, link : UInt64, data : Bytes) : Nil
      LibHop.bytes_received(node, link, data.to_unsafe, data.size)
    end

    def self.subscribe(node : Void*, topic : String) : Nil
      LibHop.subscribe(node, topic)
    end

    # ---- §19 relay pool ----

    def self.relay_add(node : Void*, url : String, configured : Bool = true) : Bool
      LibHop.relay_add(node, url, configured)
    end

    # The relay to dial right now, or nil when there is nothing dialable. nil with a non-zero
    # `relay_pool` total is the degraded "every candidate is backed off" state (wait and retry, this is
    # not offline); nil with a zero total is an empty pool. The 2 KiB buffer is far past any real
    # endpoint URL; the C call writes nothing and returns 0 if a URL would not fit.
    def self.relay_next(node : Void*) : String?
      buf = Bytes.new(2048)
      n = LibHop.relay_next(node, buf.to_unsafe.as(LibC::Char*), buf.size)
      n == 0 ? nil : String.new(buf.to_unsafe, n)
    end

    def self.relay_report(node : Void*, url : String, ok : Bool) : Nil
      LibHop.relay_report(node, url, ok)
    end

    # {total pooled endpoints, how many are dialable right now}.
    def self.relay_pool(node : Void*) : Tuple(Int32, Int32)
      available = uninitialized LibC::SizeT
      total = LibHop.relay_pool_size(node, pointerof(available))
      {total.to_i, available.to_i}
    end

    def self.cluster_join(node : Void*, secret : Bytes) : Nil
      LibHop.cluster_join(node, require_32(secret, "cluster secret").to_unsafe)
    end

    def self.cluster_join_passphrase(node : Void*, pass : Bytes) : Nil
      LibHop.cluster_join_passphrase(node, pass.to_unsafe, pass.size)
    end

    def self.cluster_members(node : Void*) : UInt32
      LibHop.cluster_members(node)
    end

    def self.cluster_set_quorum(node : Void*, min : UInt32) : Nil
      LibHop.cluster_set_quorum(node, min)
    end

    def self.publish_prekey(node : Void*) : Bool
      LibHop.publish_prekey(node)
    end

    def self.accept_inbox(node : Void*, inbox_id : Bytes) : Bool
      LibHop.accept_inbox(node, require_32(inbox_id, "inbox id").to_unsafe)
    end

    def self.accept_service_response(node : Void*, request_id : Bytes) : Bool
      LibHop.accept_service_response(node, require_32(request_id, "request id").to_unsafe)
    end

    def self.address(node : Void*) : Bytes
      buf = Bytes.new(32)
      LibHop.node_address(node, buf.to_unsafe)
      buf
    end

    def self.drain_outgoing(node : Void*) : Array({UInt64, Bytes})
      buf = [] of {UInt64, Bytes}
      boxed = Box.box(buf)
      LibHop.drain_outgoing(node, ->(ctx : Void*, link : UInt64, ptr : UInt8*, len : LibC::SizeT) {
        Box(Array({UInt64, Bytes})).unbox(ctx) << {link, Hop::FFI.read_bytes(ptr, len)}
        nil
      }, boxed)
      buf
    end

    def self.send_service_request(node : Void*, dst : Bytes, service : String, method : String, args : Bytes) : Bytes
      buf = Bytes.new(32)
      ok = LibHop.send_service_request(node, require_32(dst, "destination").to_unsafe, service, method, args.to_unsafe, args.size, buf.to_unsafe)
      raise "hop_send_service_request failed" unless ok
      buf
    end

    def self.send_service_response(node : Void*, to : Bytes, for_request_id : Bytes, status : UInt16, body : Bytes) : Bool
      LibHop.send_service_response(node, require_32(to, "response destination").to_unsafe,
        require_32(for_request_id, "request id").to_unsafe, status, body.to_unsafe, body.size)
    end

    def self.node_is_encrypted(node : Void*) : Bool
      LibHop.node_is_encrypted(node)
    end

    def self.node_open(db_path : String, secret : Bytes? = nil, app_secret : Bytes? = nil) : Void*
      sec_ptr = secret ? require_32(secret, "secret").to_unsafe : Pointer(UInt8).null
      sec_len = secret ? LibC::SizeT.new(secret.size) : LibC::SizeT.new(0)
      app_ptr = app_secret ? require_32(app_secret, "app secret").to_unsafe : Pointer(UInt8).null
      app_len = app_secret ? LibC::SizeT.new(app_secret.size) : LibC::SizeT.new(0)
      ptr = LibHop.node_open(db_path.to_unsafe, sec_ptr, sec_len, app_ptr, app_len)
      raise "hop_node_open returned NULL for path #{db_path}" if ptr.null?
      ptr
    end

    def self.node_open_keyed(db_path : String, secret : Bytes? = nil, app_secret : Bytes? = nil, key : Bytes? = nil) : Void*
      sec_ptr = secret ? require_32(secret, "secret").to_unsafe : Pointer(UInt8).null
      sec_len = secret ? LibC::SizeT.new(secret.size) : LibC::SizeT.new(0)
      app_ptr = app_secret ? require_32(app_secret, "app secret").to_unsafe : Pointer(UInt8).null
      app_len = app_secret ? LibC::SizeT.new(app_secret.size) : LibC::SizeT.new(0)
      key_ptr = key ? key.to_unsafe : Pointer(UInt8).null
      key_len = key ? LibC::SizeT.new(key.size) : LibC::SizeT.new(0)
      ptr = LibHop.node_open_keyed(db_path.to_unsafe, sec_ptr, sec_len, app_ptr, app_len, key_ptr, key_len)
      raise "hop_node_open_keyed returned NULL for path #{db_path}" if ptr.null?
      ptr
    end

    def self.node_is_persistent(node : Void*) : Bool
      LibHop.node_is_persistent(node)
    end

    def self.cluster_mark_done(node : Void*, from : Bytes, request_id : Bytes) : Nil
      LibHop.cluster_mark_done(node, require_32(from, "from").to_unsafe, require_32(request_id, "request id").to_unsafe)
    end

    def self.cluster_would_drop(node : Void*, from : Bytes, request_id : Bytes) : Bool
      LibHop.cluster_would_drop(node, require_32(from, "from").to_unsafe, require_32(request_id, "request id").to_unsafe)
    end

    def self.accept_service_request(node : Void*, request_id : Bytes) : Bool
      LibHop.accept_service_request(node, require_32(request_id, "request id").to_unsafe)
    end

    def self.reject_service_request(node : Void*, request_id : Bytes) : Bool
      LibHop.reject_service_request(node, require_32(request_id, "request id").to_unsafe)
    end

    # [{from32, request_id32, service, method, args}]
    def self.take_service_requests(node : Void*) : Array({Bytes, Bytes, String, String, Bytes})
      buf = [] of {Bytes, Bytes, String, String, Bytes}
      boxed = Box.box(buf)
      LibHop.poll_service_requests(node, ->(ctx : Void*, frm : UInt8*, rid : UInt8*, service : LibC::Char*, method : LibC::Char*, args : UInt8*, arglen : LibC::SizeT) {
        Box(Array({Bytes, Bytes, String, String, Bytes})).unbox(ctx) <<
        {Hop::FFI.read_bytes(frm, LibC::SizeT.new(32)), Hop::FFI.read_bytes(rid, LibC::SizeT.new(32)),
         Hop::FFI.read_cstr(service), Hop::FFI.read_cstr(method), Hop::FFI.read_bytes(args, arglen)}
        false
      }, boxed)
      buf
    end

    # [{from32, for_request_id32, status, body}]
    def self.take_service_responses(node : Void*) : Array({Bytes, Bytes, UInt16, Bytes})
      buf = [] of {Bytes, Bytes, UInt16, Bytes}
      boxed = Box.box(buf)
      LibHop.poll_service_responses(node, ->(ctx : Void*, frm : UInt8*, for_id : UInt8*, status : UInt16, body : UInt8*, body_len : LibC::SizeT) {
        Box(Array({Bytes, Bytes, UInt16, Bytes})).unbox(ctx) <<
        {Hop::FFI.read_bytes(frm, LibC::SizeT.new(32)), Hop::FFI.read_bytes(for_id, LibC::SizeT.new(32)), status, Hop::FFI.read_bytes(body, body_len)}
        false
      }, boxed)
      buf
    end

    def self.to_b58(addr32 : Bytes) : String
      buf = Bytes.new(64)
      n = LibHop.address_to_base58(require_32(addr32, "address").to_unsafe,
        buf.to_unsafe.as(LibC::Char*), 64)
      String.new(buf.to_unsafe, n)
    end

    def self.from_b58(text : String) : Bytes
      buf = Bytes.new(32)
      raise "not a valid Hop address: #{text}" unless LibHop.address_from_base58(text, buf.to_unsafe)
      buf
    end

    def self.sign_reach(node : Void*, endpoint : String, ttl_secs : UInt32) : Bytes
      result = Bytes.new(0)
      boxed = Box.box(->(b : Bytes) { result = b })
      LibHop.sign_reach_record(node, endpoint, ttl_secs, ->(ctx : Void*, ptr : UInt8*, len : LibC::SizeT) {
        Box(Proc(Bytes, Bytes)).unbox(ctx).call(Hop::FFI.read_bytes(ptr, len))
        nil
      }, boxed)
      result
    end

    def self.verify_reach(record : Bytes, now_secs : UInt64) : Reach?
      info = nil.as(Reach?)
      boxed = Box.box(->(r : Reach) { info = r })
      ok = LibHop.verify_reach_record(record.to_unsafe, record.size, now_secs, ->(ctx : Void*, addr : UInt8*, endpoint : LibC::Char*, issued_at : UInt64, ttl_secs : UInt32) {
        Box(Proc(Reach, Reach)).unbox(ctx).call(Reach.new(Hop::FFI.read_bytes(addr, LibC::SizeT.new(32)), Hop::FFI.read_cstr(endpoint), issued_at, ttl_secs))
        nil
      }, boxed)
      ok ? info : nil
    end
  end
end
