require "spec"
require "openssl"
require "../src/hop"
require "../src/hop/dev_tls"

private def ws_header(final : Bool, opcode : UInt8, size : Int32) : Bytes
  io = IO::Memory.new
  io.write_byte((final ? 0x80_u8 : 0_u8) | opcode)
  if size < 126
    io.write_byte(size.to_u8)
  elsif size < 65_536
    io.write_byte(126_u8)
    io.write_bytes(size.to_u16, IO::ByteFormat::NetworkEndian)
  else
    io.write_byte(127_u8)
    io.write_bytes(size.to_u64, IO::ByteFormat::NetworkEndian)
  end
  io.to_slice.dup
end

private def ws_frame(final : Bool, opcode : UInt8, payload : Bytes) : Bytes
  ws_header(final, opcode, payload.size) + payload
end

private def insecure_tls_socket(port : Int32) : OpenSSL::SSL::Socket::Client
  tcp = TCPSocket.new("localhost", port, connect_timeout: Hop::WssBearer::HANDSHAKE_TIMEOUT)
  ctx = OpenSSL::SSL::Context::Client.new
  ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE
  OpenSSL::SSL::Socket::Client.new(tcp, context: ctx, sync_close: true, hostname: "localhost")
end

describe Hop do
  it "requires exact fixed-width buffers before every native call" do
    node = Hop::FFI.node_new
    begin
      Hop::FFI.tick(node, 1_u64)
      exact = Hop::FFI.address(node)
      [0, 1, 31, 33].each do |size|
        invalid = Bytes.new(size)
        expect_raises(ArgumentError, "exactly 32 bytes") { Hop::FFI.accept_inbox(node, invalid) }
        expect_raises(ArgumentError, "exactly 32 bytes") { Hop::FFI.cluster_join(node, invalid) }
        expect_raises(ArgumentError, "exactly 32 bytes") do
          Hop::FFI.send_service_request(node, invalid, "svc", "get", Bytes.new(0))
        end
        expect_raises(ArgumentError, "exactly 32 bytes") do
          Hop::FFI.send_service_response(node, invalid, exact, 200_u16, Bytes.new(0))
        end
        expect_raises(ArgumentError, "exactly 32 bytes") do
          Hop::FFI.send_service_response(node, exact, invalid, 200_u16, Bytes.new(0))
        end
        expect_raises(ArgumentError, "exactly 32 bytes") { Hop::FFI.to_b58(invalid) }
        expect_raises(ArgumentError, "exactly 32 bytes") { Hop::Endpoint.new(secret: invalid) }
      end
      Hop::FFI.accept_inbox(node, exact).should be_false
      Hop::FFI.cluster_join(node, exact)
      Hop::FFI.send_service_request(node, exact, "svc", "get", Bytes.new(0)).size.should eq 32
      Hop::FFI.send_service_response(node, exact, exact, 200_u16, Bytes.new(0)).should be_true
      Hop::FFI.to_b58(exact).should_not be_empty
      keyed = Hop::Endpoint.new(secret: exact)
      keyed.close
    ensure
      Hop::FFI.node_free(node)
    end
  end

  it "signs, verifies, and rejects a tampered reach record" do
    e = Hop::Endpoint.new
    begin
      rec = e.sign_reach("wss://myaddress.com/_hop", 3600_u32)
      info = Hop::FFI.verify_reach(rec, Time.utc.to_unix.to_u64)
      info.should_not be_nil
      info.not_nil!.endpoint.should eq "wss://myaddress.com/_hop"
      Hop::FFI.to_b58(info.not_nil!.address).should eq e.address

      bad = rec.dup
      bad[bad.size - 1] = bad[bad.size - 1] ^ 0xFF_u8
      Hop::FFI.verify_reach(bad, Time.utc.to_unix.to_u64).should be_nil
    ensure
      e.close
    end
  end

  it "bounds single and fragmented WebSocket messages before continuation allocation" do
    max = Hop::WssBearer::MAX_MESSAGE_BYTES

    delivered = [] of Bytes
    oversized = IO::Memory.new(ws_header(true, 0x2_u8, max + 1))
    ws = Hop::WssBearer::BoundedWebSocket.new(oversized, masked_out: false, expect_masked: false)
    ws.on_binary { |bytes| delivered << bytes.dup }
    ws.run
    delivered.should be_empty

    half = max // 2
    fragmented = IO::Memory.new(
      ws_frame(false, 0x2_u8, Bytes.new(half + 1, 0x41_u8)) + ws_header(true, 0x0_u8, half)
    )
    ws = Hop::WssBearer::BoundedWebSocket.new(fragmented, masked_out: false, expect_masked: false)
    ws.on_binary { |bytes| delivered << bytes.dup }
    ws.run
    delivered.should be_empty

    exact = IO::Memory.new(
      ws_frame(false, 0x2_u8, Bytes.new(half, 0x41_u8)) +
      ws_frame(true, 0x0_u8, Bytes.new(half, 0x42_u8))
    )
    ws = Hop::WssBearer::BoundedWebSocket.new(exact, masked_out: false, expect_masked: false)
    ws.on_binary { |bytes| delivered << bytes.dup }
    ws.run
    delivered.size.should eq 1
    delivered[0].size.should eq max
    delivered[0][0].should eq 0x41_u8
    delivered[0][-1].should eq 0x42_u8
  end

  it "caps pending WebSockets and restores one idempotent admission slot" do
    admission = Hop::WssBearer::Admission.new(Hop::WssBearer::MAX_PENDING_CONNECTIONS)
    leases = Array(Hop::WssBearer::Admission::Lease).new
    Hop::WssBearer::MAX_PENDING_CONNECTIONS.times do
      leases << admission.try_acquire.not_nil!
    end
    admission.try_acquire.should be_nil
    leases.first.release
    replacement = admission.try_acquire.not_nil!
    leases.first.release
    admission.count.should eq Hop::WssBearer::MAX_PENDING_CONNECTIONS
    closed = 0
    replacement.track { closed += 1 }
    admission.close_all
    admission.close_all
    closed.should eq 1
    admission.count.should eq 0
    admission.try_acquire.should be_nil
    replacement.release
    leases.each &.release
    admission.count.should eq 0

    late = Hop::WssBearer::Admission.new(1)
    late_lease = late.try_acquire.not_nil!
    late.close_all
    late_lease.track { closed += 1 }
    closed.should eq 2
  end

  it "holds client permits through slow trickle handling and recovers after the absolute deadline" do
    endpoint = Hop::Endpoint.new
    tls = Hop::DevTls.server_context
    server = endpoint.attach(0, tls, "wss://unused/_hop")
    port = server.addresses.first.as(Socket::IPAddress).port
    slow = Array(OpenSSL::SSL::Socket::Client).new

    begin
      Hop::WssBearer::HANDSHAKE_WORKERS.times do
        socket = insecure_tls_socket(port)
        socket << "GET /_hop HTTP/1.1\r\nHost: localhost\r\n"
        socket.flush
        slow << socket
      end
      server.as(Hop::WssBearer::BoundedServer).pending_clients.should eq Hop::WssBearer::HANDSHAKE_WORKERS

      6.times do
        sleep 900.milliseconds
        slow.each do |socket|
          begin
            socket << "X-Slow: x\r\n"
            socket.flush
          rescue
          end
        end
      end

      20.times do
        break if server.as(Hop::WssBearer::BoundedServer).pending_clients == 0
        sleep 50.milliseconds
      end
      server.as(Hop::WssBearer::BoundedServer).pending_clients.should eq 0

      client_tls = OpenSSL::SSL::Context::Client.new
      client_tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE
      recovered = Hop::WssBearer.connect(URI.parse("wss://localhost:#{port}/_hop"), client_tls)
      recovered.close
    ensure
      slow.each { |socket| socket.close rescue nil }
      endpoint.close
    end
  end

  it "round-trips a hops:// request in-process" do
    server = Hop::Endpoint.new
    server.on("acme/orders") { |req, reply| reply.call(200, "got:#{req.text}") }
    client = Hop::Endpoint.new
    begin
      Hop.connect_in_process(server, client)
      status, body = client.request(server.address_bytes, "acme/orders", "create", "temp=21")
      status.should eq 200
      String.new(body).should eq "got:temp=21"
    ensure
      server.close
      client.close
    end
  end

  it "resolves by name (WebPKI + self-certifying) and round-trips over WSS" do
    port = 8452
    public_url = "wss://localhost:#{port}/_hop"
    tls = Hop::DevTls.server_context # in-process self-signed cert, no openssl CLI

    server = Hop::Endpoint.new
    server.on("acme/orders") { |req, reply| reply.call(201, req.args) }
    http_server = server.attach(port, tls, public_url) # WSS /_hop + /.well-known/hop in one call
    http_server.max_headers_size.should eq Hop::WssBearer::MAX_HEADER_BYTES
    http_server.max_request_line_size.should eq 4096

    # One raw peer stalls before TLS. Separate workers still process malformed and oversized HTTP
    # handshakes, then the valid discovery + WSS client below.
    stalled = TCPSocket.new("localhost", port)
    malformed = insecure_tls_socket(port)
    malformed << "malformed\r\n\r\n"
    malformed.flush
    malformed.read_timeout = 1.second
    malformed.gets rescue nil
    malformed.close
    oversized = insecure_tls_socket(port)
    oversized << "GET /_hop HTTP/1.1\r\nHost: localhost\r\nX-Fill: "
    oversized << "x" * Hop::WssBearer::MAX_HEADER_BYTES
    oversized << "\r\n\r\n"
    oversized.flush rescue nil
    oversized.read_timeout = 1.second
    oversized.gets rescue nil
    oversized.close rescue nil

    client = Hop::Endpoint.new
    begin
      address = client.dial_by_name("https://localhost:#{port}", insecure_tls: true)
      address.should eq server.address
      status, body = client.request(address, "acme/orders", "create", "widget")
      status.should eq 201
      String.new(body).should eq "widget"
    ensure
      stalled.try &.close rescue nil
      malformed.try &.close rescue nil
      oversized.try &.close rescue nil
      server.close
      client.close
    end
  end

  it "joins a cluster and sets the TTL visibility threshold" do
    # cluster join + quorum bindings resolve against libhop and behave; the cross-replica dedup + hold
    # are proven in the Rust crate, here we exercise the Crystal surface.
    e = Hop::Endpoint.new(cluster: "shared-cluster-passphrase", quorum: 3)
    begin
      e.cluster_members.should eq 1_u32
      e.cluster_quorum(2).should be(e) # chainable
    ensure
      e.close
    end
  end

  # PLAT-003: sdk/hop.h justified the v4 -> v5 ABI bump with the §19 relay-pool calls, and this SDK
  # asserted that level at load while binding none of them, so an SDK-only host could not fail over:
  # the only reachable behavior was retrying one configured URL forever. It now pins ABI 7 and binds
  # the pool, so this drives the failover the header describes through the published Endpoint
  # surface, on ONE endpoint that is never restarted.
  it "fails the relay pool over to another endpoint without restarting the endpoint" do
    e = Hop::Endpoint.new(tick_ms: 1000)
    begin
      # An empty pool is distinguishable from a backed-off one: nothing to dial, nothing pooled.
      e.relay_next.should be_nil
      e.relay_pool.should eq({0, 0})

      a, b = "wss://relay-a.example/_hop", "wss://relay-b.example/_hop"
      e.relay_add(a).should be_true
      e.relay_add(b).should be_true
      e.relay_pool.should eq({2, 2})

      first = e.relay_next
      [a, b].should contain(first)

      # A working relay is kept: no needless churn between two healthy candidates.
      e.relay_report(first.not_nil!, true).should be(e) # chainable
      e.relay_next.should eq first

      # It goes dark. THIS is the case the header promised and the SDK could not reach: the same live
      # endpoint must hand back the other candidate, with no restart and no new node.
      e.relay_report(first.not_nil!, false)
      second = e.relay_next
      second.should_not be_nil
      second.should_not eq first

      # Everything down is WAIT, not offline, and the SDK can tell the two apart.
      [first, first, second, second].each { |url| e.relay_report(url.not_nil!, false) }
      e.relay_next.should be_nil
      e.relay_pool.should eq({2, 0})
    ensure
      e.close
    end
  end

  it "leaves service request queued for redelivery when handler fails (ABI-002)" do
    server = Hop::Endpoint.new(tick_ms: 10)
    client = Hop::Endpoint.new(tick_ms: 10)
    attempts = 0
    first_attempt_done = Channel(Nil).new

    server.on("flaky") do |req, reply|
      attempts += 1
      if attempts == 1
        first_attempt_done.send(nil)
        raise "handler failed attempt 1"
      end
      reply.call(200, "recovered")
    end

    Hop.connect_in_process(server, client)
    begin
      ch = Channel({UInt16, Bytes}).new
      spawn do
        res = client.request(server.address_bytes, "flaky", "call", "test", timeout: 3.seconds)
        ch.send(res)
      end

      first_attempt_done.receive
      attempts.should eq 1

      status, body = ch.receive
      attempts.should eq 2
      status.should eq 200_u16
      String.new(body).should eq "recovered"
    ensure
      server.close
      client.close
    end
  end

  it "persists state across restart when backed by db_path (ABI-003)" do
    db_path = File.tempfile("hop-cr-restart", ".db").path
    secret = Bytes.new(32) { |i| (i + 1).to_u8 }

    # Step 1: Open with db_path, verify persistence, mark state handled in cluster
    e1 = Hop::Endpoint.new(secret: secret, db_path: db_path, cluster: "shared-passphrase")
    e1.persistent?.should be_true

    from = Bytes.new(32)
    from[0] = 0xAA_u8
    req_id = Bytes.new(32)
    req_id[0] = 0xBB_u8

    e1.cluster_mark_done(from, req_id)
    e1.cluster_would_drop(from, req_id).should be_true
    e1.close

    # Step 2: Reopen same db_path, verify persistence and state recovery
    e2 = Hop::Endpoint.new(secret: secret, db_path: db_path, cluster: "shared-passphrase")
    begin
      e2.persistent?.should be_true
      e2.cluster_would_drop(from, req_id).should be_true
    ensure
      e2.close
      File.delete(db_path) if File.exists?(db_path)
    end
  end
end
