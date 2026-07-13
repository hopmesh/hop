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
  fun abi_version = hop_abi_version : Int32
  fun node_new = hop_node_new : Void*
  fun node_with_secret = hop_node_with_secret(secret : UInt8*, secret_len : LibC::SizeT) : Void*
  fun node_free = hop_node_free(node : Void*) : Void
  fun node_address = hop_node_address(node : Void*, out_addr : UInt8*) : Bool
  fun node_tick = hop_node_tick(node : Void*, now_ms : UInt64) : Void
  fun link_up = hop_link_up(node : Void*, link : UInt64, role : UInt32) : Void
  fun bytes_received = hop_bytes_received(node : Void*, link : UInt64, data : UInt8*, len : LibC::SizeT) : Void
  fun link_down = hop_link_down(node : Void*, link : UInt64) : Void
  fun drain_outgoing = hop_drain_outgoing(node : Void*, sink : (Void*, UInt64, UInt8*, LibC::SizeT ->), ctx : Void*) : Void
  fun subscribe = hop_subscribe(node : Void*, topic : LibC::Char*) : Void
  fun publish_prekey = hop_publish_prekey(node : Void*) : Bool
  fun send_service_request = hop_send_service_request(node : Void*, dst : UInt8*, service : LibC::Char*, method : LibC::Char*, args : UInt8*, args_len : LibC::SizeT, out_id : UInt8*) : Bool
  fun send_service_response = hop_send_service_response(node : Void*, to : UInt8*, for_request_id : UInt8*, status : UInt16, body : UInt8*, body_len : LibC::SizeT) : Bool
  fun poll_service_requests = hop_poll_service_requests(node : Void*, sink : (Void*, UInt8*, UInt8*, LibC::Char*, LibC::Char*, UInt8*, LibC::SizeT ->), ctx : Void*) : Void
  fun poll_service_responses = hop_poll_service_responses(node : Void*, sink : (Void*, UInt8*, UInt8*, UInt16, UInt8*, LibC::SizeT ->), ctx : Void*) : Void
  fun address_to_base58 = hop_address_to_base58(addr : UInt8*, out_buf : LibC::Char*, out_cap : LibC::SizeT) : LibC::SizeT
  fun address_from_base58 = hop_address_from_base58(text : LibC::Char*, out32 : UInt8*) : Bool
  fun sign_reach_record = hop_sign_reach_record(node : Void*, endpoint : LibC::Char*, ttl_secs : UInt32, sink : (Void*, UInt8*, LibC::SizeT ->), ctx : Void*) : Void
  fun verify_reach_record = hop_verify_reach_record(bytes : UInt8*, len : LibC::SizeT, now_secs : UInt64, sink : (Void*, UInt8*, LibC::Char*, UInt64, UInt32 ->), ctx : Void*) : Bool
end

module Hop
  # Thin, one-to-one helpers over LibHop: turn raw pointers + synchronous sink callbacks into Crystal
  # Bytes/String/arrays. Everything ergonomic lives in Hop::Endpoint.
  module FFI
    ABI_EXPECTED = 3

    # Verified reach record fields (mirrors ReachInfo on the Rust side).
    record Reach, address : Bytes, endpoint : String, issued_at : UInt64, ttl_secs : UInt32

    def self.assert_abi!
      got = LibHop.abi_version
      raise "libhop ABI mismatch: wrapper expects #{ABI_EXPECTED}, library reports #{got}" if got != ABI_EXPECTED
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

    def self.publish_prekey(node : Void*) : Bool
      LibHop.publish_prekey(node)
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
      ok = LibHop.send_service_request(node, dst.to_unsafe, service, method, args.to_unsafe, args.size, buf.to_unsafe)
      raise "hop_send_service_request failed" unless ok
      buf
    end

    def self.send_service_response(node : Void*, to : Bytes, for_request_id : Bytes, status : UInt16, body : Bytes) : Bool
      LibHop.send_service_response(node, to.to_unsafe, for_request_id.to_unsafe, status, body.to_unsafe, body.size)
    end

    # [{from32, request_id32, service, method, args}]
    def self.take_service_requests(node : Void*) : Array({Bytes, Bytes, String, String, Bytes})
      buf = [] of {Bytes, Bytes, String, String, Bytes}
      boxed = Box.box(buf)
      LibHop.poll_service_requests(node, ->(ctx : Void*, frm : UInt8*, rid : UInt8*, service : LibC::Char*, method : LibC::Char*, args : UInt8*, arglen : LibC::SizeT) {
        Box(Array({Bytes, Bytes, String, String, Bytes})).unbox(ctx) <<
        {Hop::FFI.read_bytes(frm, LibC::SizeT.new(32)), Hop::FFI.read_bytes(rid, LibC::SizeT.new(32)),
         Hop::FFI.read_cstr(service), Hop::FFI.read_cstr(method), Hop::FFI.read_bytes(args, arglen)}
        nil
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
        nil
      }, boxed)
      buf
    end

    def self.to_b58(addr32 : Bytes) : String
      buf = Bytes.new(64)
      n = LibHop.address_to_base58(addr32.to_unsafe, buf.to_unsafe.as(LibC::Char*), 64)
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
