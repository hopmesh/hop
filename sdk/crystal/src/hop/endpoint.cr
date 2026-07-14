require "openssl"
require "./ffi"

module Hop
  # An inbound service request. `from` is the cryptographically verified sender identity (base58).
  record Request, from : String, from_bytes : Bytes, service : String, method : String, args : Bytes do
    def text : String
      String.new(args)
    end
  end

  # The callable handed to an `on` handler: `reply.call(status, body)`. Sealing a response is a new
  # addressed message back to the request's caller (it may arrive later, even after a restart).
  struct Reply
    def initialize(@endpoint : Endpoint, @to : Bytes, @request_id : Bytes)
    end

    def call(status : Int, body : String | Bytes = "") : Nil
      @endpoint.send_response(@to, @request_id, status.to_u16, body.is_a?(String) ? body.to_slice : body)
    end
  end

  # Receive Hop messages in Crystal with a Sinatra/Rails-shaped surface, over the libhop C ABI.
  #
  #   hop = Hop::Endpoint.new
  #   hop.on("acme/orders") { |req, reply| reply.call(201, "ok") } # req.from is VERIFIED
  #
  # Semantics: inbound is a durable store-and-forward consume; a reply is a new addressed message that
  # may arrive later. The DX is HTTP-shaped; delivery is delay-tolerant. core is poll-model, so the
  # endpoint runs a background pump FIBER (spawned; the node is thread-safe). Default runtime is single
  # fiber-scheduled thread; a reentrant Mutex still guards the node so #close can free it safely even
  # under `-Dpreview_mt`.
  class Endpoint
    @node : Void*

    def initialize(secret : Bytes? = nil, tick_ms : Int32 = 50, cluster : String | Bytes | Nil = nil)
      Hop::FFI.assert_abi!
      @node = secret ? Hop::FFI.node_with_secret(secret) : Hop::FFI.node_new
      Hop::FFI.tick(@node, now_ms)
      Hop::FFI.publish_prekey(@node)
      @handlers = {} of String => Proc(Request, Reply, Nil)
      @links = {} of UInt64 => Proc(Bytes, Nil)
      @pending = {} of Bytes => Channel({UInt16, Bytes})
      @closers = [] of Proc(Nil)
      @node_lock = Mutex.new(:reentrant) # serializes every libhop call on @node vs. #close
      @closed = false
      @tick = tick_ms.milliseconds
      cluster(cluster) if cluster # dedup across sibling replicas (same identity, no shared store)
      spawn pump_loop
    end

    def address : String
      Hop::FFI.to_b58(address_bytes)
    end

    def address_bytes : Bytes
      with_node { |n| Hop::FFI.address(n) } || raise "endpoint is closed"
    end

    # Join the endpoint cluster so sibling replicas (same identity, no shared datastore) each handle a
    # given request once. A String is a passphrase (interops with the standalone service's
    # HOP_CLUSTER_SECRET); a 32-byte Bytes is a raw secret. Dedup then applies transparently.
    def cluster(secret_or_passphrase : String | Bytes) : self
      case secret_or_passphrase
      in String
        with_node { |n| Hop::FFI.cluster_join_passphrase(n, secret_or_passphrase.to_slice) }
      in Bytes
        raise ArgumentError.new("cluster secret must be 32 bytes") unless secret_or_passphrase.size == 32
        with_node { |n| Hop::FFI.cluster_join(n, secret_or_passphrase) }
      end
      self
    end

    # Live replica count (self + peers within the membership TTL); 1 if not clustered.
    def cluster_members : UInt32
      with_node { |n| Hop::FFI.cluster_members(n) } || 0_u32
    end

    # Register a receiver for a hops:// service. The block gets (req, reply); reply is a callable
    # reply.call(status, body). This is the surface shared with every Hop SDK.
    def on(service : String, &block : Request, Reply -> Nil) : self
      with_node { |n| Hop::FFI.subscribe(n, service) }
      @handlers[service] = block
      self
    end

    # The idiomatic Crystal/Go alternative to a block handler: receive verified requests for `service`
    # on a Channel and reply from your own fiber (a long-running server usually reads it in a loop, or
    # `select`s over several services). Same delivery, just channels instead of a callback.
    #
    #   orders = hop.channel("acme/orders")
    #   spawn do
    #     loop do
    #       req, reply = orders.receive
    #       reply.call(201, req.text)
    #     end
    #   end
    def channel(service : String, buffer : Int32 = 32) : Channel({Request, Reply})
      ch = Channel({Request, Reply}).new(buffer)
      on(service) { |req, reply| ch.send({req, reply}) }
      ch
    end

    # Call a service on a remote endpoint. Blocks the calling fiber until the response returns
    # (delay-tolerant). `dst` is a base58 address String or the 32 raw bytes.
    def request(dst : String | Bytes, service : String, method : String,
                args : String | Bytes = "", timeout : Time::Span = 15.seconds) : {UInt16, Bytes}
      dst_bytes = dst.is_a?(String) ? Hop::FFI.from_b58(dst) : dst
      ch = Channel({UInt16, Bytes}).new(1)
      # Send + register the waiter under @node_lock so #pump (which also holds it) cannot deliver the
      # response before @pending knows to route it.
      req_id = with_node do |n|
        id = Hop::FFI.send_service_request(n, dst_bytes, service, method, to_bytes(args))
        @pending[id] = ch
        id
      end
      raise "endpoint is closed" unless req_id

      begin
        select
        when res = ch.receive
          res
        when timeout(timeout)
          @node_lock.synchronize { @pending.delete(req_id) } # under the node lock, like register + pump
          raise "hops://#{service}/#{method} timed out after #{timeout}"
        end
      rescue Channel::ClosedError
        # #close closed our waiter channel: fail fast instead of blocking the full timeout.
        raise "endpoint is closed"
      end
    end

    # Sign a self-certifying reachability record for this endpoint's address bound to `endpoint`.
    def sign_reach(endpoint : String, ttl_secs : UInt32 = 3600_u32) : Bytes
      with_node { |n| Hop::FFI.sign_reach(n, endpoint, ttl_secs) } || raise "endpoint is closed"
    end

    # Start an HTTPS server (WSS bearer at /_hop + /.well-known/hop) IN ONE CALL. `public_url` is where
    # senders reach it, e.g. "wss://myaddress.com/_hop". Returns the HTTP::Server (already listening).
    def attach(port : Int32, tls : OpenSSL::SSL::Context::Server, public_url : String,
               ttl_secs : UInt32 = 3600_u32, host : String = "0.0.0.0")
      Hop::WssBearer.serve(self, port, tls, public_url, ttl_secs, host)
    end

    # Resolve a base HTTPS URL to a verified endpoint, dial its WSS, and return the reachable address
    # (then use #request). Set insecure_tls: true only for a dev/self-signed cert.
    def dial_by_name(base_url : String, insecure_tls : Bool = false) : String
      info = Hop::Discovery.resolve(base_url, insecure_tls)
      Hop::WssBearer.dial(self, info[:wss_url], insecure_tls)
      info[:address]
    end

    # Register a teardown hook (e.g. a bearer's listening socket). #close runs these before freeing the
    # node so bearer fibers unblock and exit. If already closed, the hook fires immediately.
    def register_closer(&block : -> Nil) : Nil
      run_now = @node_lock.synchronize { @closed ? true : (@closers << block; false) }
      block.call if run_now
    end

    # ---- bearer seam (called from bearer fibers) ----
    def register_link(link : UInt64, role : Symbol, send_fn : Bytes -> Nil) : Nil
      with_node do |n|
        @links[link] = send_fn
        Hop::FFI.connected(n, link, role == :dialer)
      end
    end

    def deliver(link : UInt64, data : Bytes) : Nil
      with_node { |n| Hop::FFI.received(n, link, data) }
    end

    def link_down(link : UInt64) : Nil
      with_node do |n|
        @links.delete(link)
        Hop::FFI.disconnected(n, link)
      end
    end

    # Internal: seal a hops:// response (used by Reply).
    protected def send_response(to : Bytes, request_id : Bytes, status : UInt16, body : Bytes) : Nil
      with_node { |n| Hop::FFI.send_service_response(n, to, request_id, status, body) }
    end

    def close : Nil
      already = @node_lock.synchronize do
        next true if @closed
        @closed = true
        false
      end
      return if already

      @closers.each { |c| c.call rescue nil } # unblock bearer accept/read fibers so they exit
      # Wake any in-flight request waiters so they fail fast instead of blocking their full timeout:
      # closing the channel makes their `ch.receive` raise Channel::ClosedError (rescued in #request).
      @node_lock.synchronize do
        @pending.each_value(&.close)
        @pending.clear
      end
      # Free only after @closed is set: a late bearer-fiber call (a WSS run firing #link_down as its
      # socket closes) now short-circuits in #with_node instead of dereferencing a freed node.
      @node_lock.synchronize do
        return if @node.null?
        Hop::FFI.node_free(@node)
        @node = Pointer(Void).null
      end
    end

    private def now_ms : UInt64
      Time.utc.to_unix_ms.to_u64
    end

    private def to_bytes(v : String | Bytes) : Bytes
      v.is_a?(String) ? v.to_slice : v
    end

    # Run a libhop call on the node under the reentrant lock, unless the endpoint has been closed (in
    # which case @node may already be freed, so we must not touch it). Returns nil when closed.
    private def with_node(&)
      @node_lock.synchronize do
        return nil if @closed
        yield @node
      end
    end

    private def pump_loop : Nil
      until @closed
        begin
          pump
        rescue ex
          STDERR.puts "hop pump error: #{ex.message}"
        end
        sleep @tick
      end
    end

    private def pump : Nil
      # Collect under the lock (fast C calls, no IO); do bearer IO + user handlers OUTSIDE it so a
      # slow socket write or handler never blocks #close or another link.
      outgoing = with_node { |n| Hop::FFI.tick(n, now_ms); Hop::FFI.drain_outgoing(n) }
      return unless outgoing
      outgoing.each { |(link, data)| (fn = @links[link]?) && fn.call(data) }

      requests = with_node { |n| Hop::FFI.take_service_requests(n) }
      return unless requests
      requests.each do |(frm, rid, service, method, args)|
        handler = @handlers[service]?
        next unless handler
        handler.call(Request.new(Hop::FFI.to_b58(frm), frm, service, method, args), Reply.new(self, frm, rid))
      end

      responses = with_node { |n| Hop::FFI.take_service_responses(n) }
      return unless responses
      responses.each do |(_frm, for_id, status, body)|
        # audit LOW: mutate @pending under @node_lock (the reentrant node lock the register + timeout
        # paths use), so all three @pending accesses share one lock and cannot race under -Dpreview_mt.
        if ch = @node_lock.synchronize { @pending.delete(for_id) }
          ch.send({status, body})
        end
      end
    end
  end
end
