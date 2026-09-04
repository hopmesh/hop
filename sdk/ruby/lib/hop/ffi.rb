# frozen_string_literal: true

# Raw Fiddle bindings to libhop (the C ABI, sdk/hop.h). Fiddle is Ruby's stdlib FFI (like ctypes), so
# this SDK has no native-gem build. Thin and one-to-one; ergonomics live in endpoint.rb.
require "fiddle"

module Hop
  module FFI
    P  = Fiddle::TYPE_VOIDP
    I  = Fiddle::TYPE_INT
    LL = Fiddle::TYPE_LONG_LONG
    SZ = Fiddle::TYPE_SIZE_T
    SSZ = Fiddle::TYPE_INTPTR_T
    CH = Fiddle::TYPE_CHAR
    V  = Fiddle::TYPE_VOID

    ABI_EXPECTED = 7

    def self.lib_path
      ext = case RbConfig::CONFIG["host_os"]
            when /darwin/ then "dylib"
            when /mswin|mingw/ then "dll"
            else "so"
            end
      repo = File.expand_path("../../../..", __dir__) # sdk/ruby/lib/hop -> repo root
      candidates = []
      candidates << File.join(ENV["HOP_LIBDIR"], "libhop.#{ext}") if ENV["HOP_LIBDIR"]
      candidates << File.join(repo, "target", "debug", "libhop.#{ext}")
      candidates << File.join(repo, "target", "release", "libhop.#{ext}")
      found = candidates.find { |c| File.exist?(c) }
      raise "libhop.#{ext} not found. Build it with `cargo build -p hop` or set HOP_LIBDIR.\n" \
            "Looked in:\n  #{candidates.join("\n  ")}" unless found

      found
    end

    LIB = Fiddle.dlopen(lib_path)
    private_class_method def self.fn(name, args, ret) = Fiddle::Function.new(LIB[name], args, ret)

    ABI_VERSION            = fn("hop_abi_version", [], I)
    NODE_NEW               = fn("hop_node_new", [], P)
    NODE_WITH_SECRET       = fn("hop_node_with_secret", [P, SZ], P)
    NODE_FREE              = fn("hop_node_free", [P], V)
    NODE_ADDRESS           = fn("hop_node_address", [P, P], CH)
    NODE_TICK              = fn("hop_node_tick", [P, LL], V)
    LINK_UP                = fn("hop_link_up", [P, LL, I], V)
    BYTES_RECEIVED         = fn("hop_bytes_received", [P, LL, P, SZ], V)
    LINK_DOWN              = fn("hop_link_down", [P, LL], V)
    DRAIN_OUTGOING         = fn("hop_drain_outgoing", [P, P, P], V)
    SUBSCRIBE              = fn("hop_subscribe", [P, P], V)
    PUBLISH_PREKEY         = fn("hop_publish_prekey", [P], CH)
    NODE_IS_ENCRYPTED      = fn("hop_node_is_encrypted", [P], CH)
    ACCEPT_INBOX           = fn("hop_accept_inbox", [P, P], CH)
    SEND_SERVICE_REQUEST   = fn("hop_send_service_request", [P, P, P, P, P, SZ, P], CH)
    SEND_SERVICE_RESPONSE  = fn("hop_send_service_response", [P, P, P, I, P, SZ], CH)
    POLL_SERVICE_REQUESTS  = fn("hop_poll_service_requests", [P, P, P], V)
    POLL_SERVICE_RESPONSES = fn("hop_poll_service_responses", [P, P, P], V)
    ACCEPT_SERVICE_RESPONSE = fn("hop_accept_service_response", [P, P], CH)
    ACCEPT_SERVICE_REQUEST = fn("hop_accept_service_request", [P, P], CH)
    REJECT_SERVICE_REQUEST = fn("hop_reject_service_request", [P, P], CH)
    ADDRESS_TO_BASE58      = fn("hop_address_to_base58", [P, P, SZ], SZ)
    ADDRESS_FROM_BASE58    = fn("hop_address_from_base58", [P, P], CH)
    SIGN_REACH_RECORD      = fn("hop_sign_reach_record", [P, P, I, P, P], V)
    VERIFY_REACH_RECORD    = fn("hop_verify_reach_record", [P, SZ, LL, P, P], CH)
    # §19 relay pool. PLAT-003: the four calls the v4 -> v5 ABI bump this wrapper pins was taken for,
    # which no C-ABI wrapper bound, so a host on the published SDKs could not fail over off a dead relay.
    RELAY_ADD              = fn("hop_relay_add", [P, P, CH], CH)
    RELAY_NEXT             = fn("hop_relay_next", [P, P, SZ], SZ)
    RELAY_REPORT           = fn("hop_relay_report", [P, P, CH], V)
    RELAY_POOL_SIZE        = fn("hop_relay_pool_size", [P, P], SZ)
    # Endpoint clustering (DESIGN.md §40).
    CLUSTER_JOIN            = fn("hop_cluster_join", [P, P], V)
    CLUSTER_JOIN_PASSPHRASE = fn("hop_cluster_join_passphrase", [P, P, SZ], V)
    CLUSTER_MEMBERS         = fn("hop_cluster_members", [P], I)
    CLUSTER_SET_QUORUM      = fn("hop_cluster_set_quorum", [P, I], V)
    # §32 hps:// pub/sub: services and channels, i.e. group chat. The eighteen exports the v5 -> v6 ABI
    # bump added, which the C ABI had none of before, so no wrapper sitting on it could reach channels
    # however completely the Rust core implemented them. Declared here because a Fiddle::Function
    # resolves its symbol at load, so a libhop missing any of them fails loudly at require time rather
    # than at the first publish.
    #
    # A publication is NOT one-to-one fan-out and NOT a multicast bundle: it is a single
    # content-key-encrypted, per-writer-signed publication, flooded once. Membership, invites and
    # revocation are properties of the topic's key handoff, not of a recipient list.
    #
    # POLL_HPS_MESSAGES is accept-to-remove like POLL_INBOX: its sink returns bool, true accepting the
    # publication so core durably removes it, false leaving it queued for redelivery until
    # ACCEPT_HPS_MESSAGE succeeds. POLL_HPS_INVITES is take-and-clear: a drained invite is GONE, so a
    # host must persist what it surfaces.
    #
    # HPS_REGISTER returns a bool AND writes the key length separately, so a channel (zero-length key,
    # its writers signing with their own identity) is distinguishable from a failure; the bool, never
    # the length, says whether registration happened. HPS_LEAVE writes out_has_id for the same reason:
    # leaving a topic we HOST sends no bundle, a success with no id. HPS_REKEY takes a COUNT of 32-byte
    # addresses packed back to back, not a byte length.
    HPS_REGISTER            = fn("hop_hps_register", [P, P, I, I, I, P, SZ, P], CH)
    HPS_SUBSCRIBE           = fn("hop_hps_subscribe", [P, P, P, P], CH)
    HPS_PUBLISH             = fn("hop_hps_publish", [P, P, P, SZ, P], CH)
    POLL_HPS_MESSAGES       = fn("hop_poll_hps_messages", [P, P, P], V)
    ACCEPT_HPS_MESSAGE      = fn("hop_accept_hps_message", [P, P], CH)
    HPS_INVITE              = fn("hop_hps_invite", [P, P, P, P], CH)
    HPS_ACCEPT_INVITE       = fn("hop_hps_accept_invite", [P, P, P, P], CH)
    HPS_DECLINE_INVITE      = fn("hop_hps_decline_invite", [P, P, P], CH)
    POLL_HPS_INVITES        = fn("hop_poll_hps_invites", [P, P, P], V)
    HPS_LEAVE               = fn("hop_hps_leave", [P, P, P, P], CH)
    HPS_PENDING             = fn("hop_hps_pending", [P, P, P, P], SZ)
    HPS_APPROVE             = fn("hop_hps_approve", [P, P, P, P], CH)
    HPS_DENY                = fn("hop_hps_deny", [P, P, P], CH)
    HPS_REKEY               = fn("hop_hps_rekey", [P, P, P, P, SZ, P, P], SSZ)
    HPS_REACH               = fn("hop_hps_reach", [P, P], I)
    HPS_MEMBERS             = fn("hop_hps_members", [P, P, P, P], SZ)
    HPS_MY_TOPICS           = fn("hop_hps_my_topics", [P, P, P], SZ)
    HPS_BROWSE              = fn("hop_hps_browse", [P, P, P], SZ)

    # The three §32 discriminants, which cross as plain uint32. An out-of-range value makes the call
    # FAIL rather than being defaulted, and a caller must never coerce one towards a member the library
    # would have rejected: reading a garbage int as Open would hand a topic's content key to anyone who
    # asks for it. So these are the only values to pass, and an unrecognized name is an error, not an
    # Open topic.
    HPS_KIND       = { channel: 0, service: 1 }.freeze
    HPS_ACCESS     = { open: 0, request_to_join: 1, invite: 2 }.freeze
    HPS_VISIBILITY = { private: 0, discoverable: 1 }.freeze

    Closure = Fiddle::Closure::BlockCaller

    def self.assert_abi!
      got = ABI_VERSION.call
      raise "libhop ABI mismatch: wrapper expects #{ABI_EXPECTED}, library reports #{got}" if got != ABI_EXPECTED
    end

    def self.require_32(value, name)
      raise ArgumentError, "#{name} must be exactly 32 bytes, got #{value.bytesize}" unless value.bytesize == 32

      value
    end
    private_class_method :require_32

    # ---- helpers: read C memory that is valid only during a call ----
    def self.read_bytes(ptr, len) = len.zero? ? "".b : Fiddle::Pointer.new(ptr)[0, len].b
    def self.read_cstr(ptr) = Fiddle::Pointer.new(ptr).to_s

    # ---- thin wrappers ----
    def self.node_new = NODE_NEW.call
    def self.node_with_secret(secret) = NODE_WITH_SECRET.call(secret, secret.bytesize)
    def self.node_free(node) = NODE_FREE.call(node)
    def self.tick(node, now_ms) = NODE_TICK.call(node, now_ms)
    def self.connected(node, link, initiator) = LINK_UP.call(node, link, initiator ? 0 : 1)
    def self.disconnected(node, link) = LINK_DOWN.call(node, link)
    def self.received(node, link, data) = BYTES_RECEIVED.call(node, link, data, data.bytesize)
    def self.subscribe(node, topic) = SUBSCRIBE.call(node, topic)
    def self.cluster_join(node, secret) = CLUSTER_JOIN.call(node, require_32(secret, "cluster secret"))
    def self.cluster_join_passphrase(node, pass) = CLUSTER_JOIN_PASSPHRASE.call(node, pass, pass.bytesize)
    def self.cluster_members(node) = CLUSTER_MEMBERS.call(node)
    def self.cluster_set_quorum(node, min) = CLUSTER_SET_QUORUM.call(node, min)
    def self.publish_prekey(node) = PUBLISH_PREKEY.call(node) != 0
    def self.accept_inbox(node, inbox_id)
      ACCEPT_INBOX.call(node, require_32(inbox_id, "inbox id")) != 0
    end

    def self.address(node)
      out = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
      NODE_ADDRESS.call(node, out)
      out[0, 32].b
    end

    def self.drain_outgoing(node)
      out = []
      sink = Closure.new(V, [P, LL, P, SZ]) { |_ctx, link, ptr, len| out << [link, read_bytes(ptr, len)] }
      DRAIN_OUTGOING.call(node, sink, nil)
      out
    end

    def self.send_service_request(node, dst, service, method, args)
      out = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
      ok = SEND_SERVICE_REQUEST.call(node, require_32(dst, "destination"), service, method, args, args.bytesize, out) != 0
      raise "hop_send_service_request failed" unless ok

      out[0, 32].b
    end

    def self.send_service_response(node, to, for_request_id, status, body)
      SEND_SERVICE_RESPONSE.call(node, require_32(to, "response destination"),
                                 require_32(for_request_id, "request id"), status, body, body.bytesize) != 0
    end

    def self.accept_service_response(node, request_id)
      ACCEPT_SERVICE_RESPONSE.call(node, require_32(request_id, "request id")) != 0
    end

    def self.node_is_encrypted(node)
      NODE_IS_ENCRYPTED.call(node) != 0
    end

    def self.accept_service_request(node, request_id)
      ACCEPT_SERVICE_REQUEST.call(node, require_32(request_id, "request id")) != 0
    end

    def self.reject_service_request(node, request_id)
      REJECT_SERVICE_REQUEST.call(node, require_32(request_id, "request id")) != 0
    end

    def self.take_service_requests(node)
      out = []
      sink = Closure.new(CH, [P, P, P, P, P, P, SZ]) do |_ctx, frm, rid, service, method, args, arglen|
        out << [read_bytes(frm, 32), read_bytes(rid, 32), read_cstr(service), read_cstr(method), read_bytes(args, arglen)]
        1
      end
      POLL_SERVICE_REQUESTS.call(node, sink, nil)
      out
    end

    def self.take_service_responses(node)
      out = []
      sink = Closure.new(CH, [P, P, P, I, P, SZ]) do |_ctx, frm, for_id, status, body, body_len|
        out << [read_bytes(frm, 32), read_bytes(for_id, 32), status & 0xFFFF, read_bytes(body, body_len)]
        0
      end
      POLL_SERVICE_RESPONSES.call(node, sink, nil)
      out
    end

    def self.to_b58(addr32)
      out = Fiddle::Pointer.malloc(64, Fiddle::RUBY_FREE)
      n = ADDRESS_TO_BASE58.call(require_32(addr32, "address"), out, 64)
      out[0, n]
    end

    def self.from_b58(text)
      out = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
      raise "not a valid Hop address: #{text}" if ADDRESS_FROM_BASE58.call(text, out).zero?

      out[0, 32].b
    end

    # ---- §19 relay pool ------------------------------------------------------------------------

    def self.relay_add(node, url, configured = true) = RELAY_ADD.call(node, url, configured ? 1 : 0) != 0
    def self.relay_report(node, url, ok) = RELAY_REPORT.call(node, url, ok ? 1 : 0)

    # The relay to dial right now, or nil when there is nothing dialable. nil with a non-zero
    # +relay_pool+ total is the degraded "every candidate is backed off" state (wait and retry, this
    # is not offline); nil with a zero total is an empty pool. The 2 KiB buffer is far past any real
    # endpoint URL; the C call writes nothing and returns 0 if a URL would not fit.
    def self.relay_next(node)
      out = Fiddle::Pointer.malloc(2048, Fiddle::RUBY_FREE)
      n = RELAY_NEXT.call(node, out, 2048)
      n.zero? ? nil : out[0, n]
    end

    # [total pooled endpoints, how many are dialable right now].
    def self.relay_pool(node)
      out = Fiddle::Pointer.malloc(Fiddle::SIZEOF_SIZE_T, Fiddle::RUBY_FREE)
      total = RELAY_POOL_SIZE.call(node, out)
      [total, out[0, Fiddle::SIZEOF_SIZE_T].unpack1(Fiddle::SIZEOF_SIZE_T == 8 ? "Q" : "L")]
    end

    def self.sign_reach(node, endpoint, ttl_secs)
      result = nil
      sink = Closure.new(V, [P, P, SZ]) { |_ctx, ptr, len| result = read_bytes(ptr, len) }
      SIGN_REACH_RECORD.call(node, endpoint, ttl_secs, sink, nil)
      result
    end

    def self.verify_reach(record, now_secs)
      info = nil
      sink = Closure.new(V, [P, P, P, LL, I]) do |_ctx, addr, endpoint, issued_at, ttl_secs|
        info = { address: read_bytes(addr, 32), endpoint: read_cstr(endpoint), issued_at: issued_at, ttl_secs: ttl_secs }
      end
      ok = VERIFY_REACH_RECORD.call(record, record.bytesize, now_secs, sink, nil) != 0
      ok ? info : nil
    end
  end
end
