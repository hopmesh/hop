require "http/server"
require "http/web_socket"
require "openssl"
require "set"
require "uri"
require "./discovery"

module Hop
  # The WSS Internet bearer. Frame headers and cumulative fragments are bounded before payload
  # allocation because the stdlib HTTP::WebSocket runner otherwise grows an unbounded IO::Memory.
  module WssBearer
    MAX_MESSAGE_BYTES       = 1 << 20
    MAX_HEADER_BYTES        = 16 << 10
    MAX_PENDING_CONNECTIONS = 64
    HANDSHAKE_WORKERS       =  8
    HANDSHAKE_TIMEOUT       = 5.seconds
    READ_TIMEOUT            = 15.seconds

    @@seq = 60_000_u64
    @@seq_mutex = Mutex.new

    def self.next_link : UInt64
      @@seq_mutex.synchronize { @@seq += 1 }
    end

    class Admission
      class Lease
        def initialize(@admission : Admission, @token : UInt64)
        end

        def track(&block : -> Nil) : Nil
          @admission.track(@token, &block)
        end

        def release : Nil
          @admission.release(@token)
        end
      end

      def initialize(@limit : Int32)
        @mutex = Mutex.new
        @next_token = 0_u64
        @tokens = Set(UInt64).new
        @closers = Hash(UInt64, Proc(Nil)).new
        @closed = false
      end

      def try_acquire : Lease?
        @mutex.synchronize do
          return nil if @closed || @tokens.size >= @limit

          @next_token += 1
          @tokens.add(@next_token)
          Lease.new(self, @next_token)
        end
      end

      def release(token : UInt64) : Nil
        @mutex.synchronize do
          @tokens.delete(token)
          @closers.delete(token)
        end
      end

      def track(token : UInt64, &block : -> Nil) : Nil
        run_now = @mutex.synchronize do
          if @closed
            true
          else
            @closers[token] = block if @tokens.includes?(token)
            false
          end
        end
        block.call if run_now
      end

      def close_all : Nil
        closers = @mutex.synchronize do
          @closed = true
          values = @closers.values
          @closers.clear
          @tokens.clear
          values
        end
        closers.each { |closer| closer.call rescue nil }
      end

      def count : Int32
        @mutex.synchronize { @tokens.size }
      end
    end

    def self.apply_timeout(io : IO, timeout : Time::Span) : Nil
      io.read_timeout = timeout if io.responds_to?(:read_timeout=)
      io.write_timeout = timeout if io.responds_to?(:write_timeout=)
    rescue NotImplementedError
      nil
    end

    # Compatible with HTTP::WebSocket for callers, but owns the receive parser so a declared payload
    # is checked before Bytes.new and fragmented totals are checked before each continuation body.
    class BoundedWebSocket < HTTP::WebSocket
      @binary_handler : Proc(Bytes, Nil)?
      @close_handler : Proc(HTTP::WebSocket::CloseCode, String, Nil)?

      def initialize(@io : IO, masked_out : Bool, @expect_masked : Bool)
        super(HTTP::WebSocket::Protocol.new(@io, masked: masked_out, sync_close: false))
      end

      def on_binary(&block : Bytes ->)
        @binary_handler = block
      end

      def on_close(&block : HTTP::WebSocket::CloseCode, String ->)
        @close_handler = block
      end

      def send(message : Bytes) : Nil
        raise IO::Error.new("WebSocket message exceeds 1 MiB") if message.size > MAX_MESSAGE_BYTES
        super(message)
      end

      def run : Nil
        loop do
          opcode, payload = read_message
          case opcode
          when 0x2_u8
            @binary_handler.try &.call(payload)
          when 0x8_u8
            @close_handler.try &.call(HTTP::WebSocket::CloseCode::NormalClosure, "")
            break
          when 0x9_u8
            pong(String.new(payload))
          end
        end
      rescue
        @close_handler.try &.call(HTTP::WebSocket::CloseCode::AbnormalClosure, "")
      ensure
        @io.close rescue nil
      end

      def close(code : HTTP::WebSocket::CloseCode | Int? = nil, message = nil) : Nil
        super(code, message)
      ensure
        @io.close rescue nil
      end

      private def read_message : {UInt8, Bytes}
        final, opcode, payload = read_frame_part(MAX_MESSAGE_BYTES)
        return {opcode, payload} if opcode >= 0x8_u8
        raise IO::Error.new("expected a binary WebSocket message") unless opcode == 0x2_u8
        return {opcode, payload} if final

        message = IO::Memory.new
        message.write(payload)
        total = payload.size
        until final
          final, continuation, payload = read_frame_part(MAX_MESSAGE_BYTES - total)
          raise IO::Error.new("expected a WebSocket continuation frame") unless continuation == 0x0_u8
          total += payload.size
          message.write(payload)
        end
        {opcode, message.to_slice.dup}
      end

      private def read_frame_part(remaining : Int32) : {Bool, UInt8, Bytes}
        header = read_exact(2)
        raise IO::Error.new("WebSocket extensions are not supported") unless (header[0] & 0x70_u8) == 0

        final = (header[0] & 0x80_u8) != 0
        opcode = header[0] & 0x0f_u8
        masked = (header[1] & 0x80_u8) != 0
        raise IO::Error.new("invalid WebSocket masking") unless masked == @expect_masked

        len = (header[1] & 0x7f_u8).to_u64
        len = read_uint(2) if len == 126
        len = read_uint(8) if len == 127
        if len > remaining.to_u64 || len > MAX_MESSAGE_BYTES.to_u64
          raise IO::Error.new("WebSocket message exceeds 1 MiB")
        end
        if opcode >= 0x8_u8 && (!final || len > 125)
          raise IO::Error.new("invalid WebSocket control frame")
        end

        mask = masked ? read_exact(4) : nil
        payload = read_exact(len.to_i)
        if mask
          payload.each_index { |i| payload[i] = payload[i] ^ mask[i % 4] }
        end
        {final, opcode, payload}
      end

      private def read_uint(bytes : Int32) : UInt64
        read_exact(bytes).reduce(0_u64) { |value, byte| (value << 8) | byte.to_u64 }
      end

      private def read_exact(size : Int32) : Bytes
        return Bytes.empty if size == 0

        buf = Bytes.new(size)
        @io.read_fully(buf)
        buf
      end
    end

    class BoundedWebSocketHandler
      include HTTP::Handler

      def initialize(@path : String, @admission : Admission,
                     &@callback : BoundedWebSocket, HTTP::Server::Context ->)
      end

      def call(context : HTTP::Server::Context) : Nil
        request = context.request
        return call_next(context) unless request.path == @path
        return call_next(context) unless websocket_upgrade?(request)

        response = context.response
        unless request.headers["Sec-WebSocket-Version"]? == HTTP::WebSocket::Protocol::VERSION
          response.status = HTTP::Status::UPGRADE_REQUIRED
          response.headers["Sec-WebSocket-Version"] = HTTP::WebSocket::Protocol::VERSION
          return
        end
        key = request.headers["Sec-WebSocket-Key"]?
        unless key
          response.status = HTTP::Status::BAD_REQUEST
          return
        end
        lease = @admission.try_acquire
        unless lease
          response.status = HTTP::Status::SERVICE_UNAVAILABLE
          return
        end

        response.status = HTTP::Status::SWITCHING_PROTOCOLS
        response.headers["Upgrade"] = "websocket"
        response.headers["Connection"] = "Upgrade"
        response.headers["Sec-WebSocket-Accept"] = HTTP::WebSocket::Protocol.key_challenge(key)
        response.upgrade do |io|
          begin
            Hop::WssBearer.apply_timeout(io, READ_TIMEOUT)
            ws = BoundedWebSocket.new(io, masked_out: false, expect_masked: true)
            lease.track { ws.close rescue nil }
            @callback.call(ws, context)
            ws.run
          ensure
            lease.release
          end
        end
      end

      private def websocket_upgrade?(request : HTTP::Request) : Bool
        upgrade = request.headers["Upgrade"]?
        return false unless upgrade && upgrade.compare("websocket", case_insensitive: true) == 0
        request.headers.includes_word?("Connection", "Upgrade")
      end
    end

    class ClientLifetime
      def initialize(@io : IO, @lease : Admission::Lease)
        @mutex = Mutex.new
        @headers_complete = false
        @finished = false
      end

      def headers_complete : Nil
        apply = @mutex.synchronize do
          next false if @finished
          @headers_complete = true
          true
        end
        Hop::WssBearer.apply_timeout(@io, READ_TIMEOUT) if apply
      end

      def expire_handshake : Nil
        close = @mutex.synchronize { !@headers_complete && !@finished }
        @io.close rescue nil if close
      end

      def close : Nil
        @io.close rescue nil
      end

      def finish : Nil
        release = @mutex.synchronize do
          next false if @finished
          @finished = true
          true
        end
        @lease.release if release
      end
    end

    class HandshakeCompleteHandler
      include HTTP::Handler

      def call(context : HTTP::Server::Context) : Nil
        BoundedServer.complete_current_handshake
        call_next(context)
      end
    end

    # HTTP::Server normally spawns one fiber for every accepted TLS socket. This gate bounds sockets
    # before TLS/header parsing; active WebSockets are separately held by BoundedWebSocketHandler.
    class BoundedServer < HTTP::Server
      @@current_mutex = Mutex.new
      @@current = Hash(UInt64, ClientLifetime).new

      def initialize(handlers : Array(HTTP::Handler), @handshakes : Admission,
                     &handler : HTTP::Handler::HandlerProc)
        @clients_mutex = Mutex.new
        @clients = Hash(UInt64, ClientLifetime).new
        super(HTTP::Server.build_middleware(handlers, handler))
      end

      def self.complete_current_handshake : Nil
        lifetime = @@current_mutex.synchronize { @@current[Fiber.current.object_id]? }
        lifetime.try &.headers_complete
      end

      def pending_clients : Int32
        @handshakes.count
      end

      protected def dispatch(io)
        lease = @handshakes.try_acquire
        unless lease
          io.close rescue nil
          return
        end
        lifetime = ClientLifetime.new(io, lease)
        @clients_mutex.synchronize { @clients[io.object_id] = lifetime }
        lease.track { lifetime.close }
        Hop::WssBearer.apply_timeout(io, HANDSHAKE_TIMEOUT)
        spawn do
          sleep HANDSHAKE_TIMEOUT
          lifetime.expire_handshake
        end
        super(io)
      end

      private def handle_client(io : IO)
        lifetime = @clients_mutex.synchronize { @clients[io.object_id]? }
        @@current_mutex.synchronize { @@current[Fiber.current.object_id] = lifetime } if lifetime
        super(io)
      ensure
        @@current_mutex.synchronize { @@current.delete(Fiber.current.object_id) }
        @clients_mutex.synchronize { @clients.delete(io.object_id) }
        lifetime.try &.finish
      end
    end

    def self.attach_ws(endpoint : Endpoint, ws : HTTP::WebSocket, role : Symbol) : UInt64
      link = next_link
      ws.on_binary { |bytes| endpoint.deliver(link, bytes) }
      ws.on_close { |_code, _msg| endpoint.link_down(link) }
      endpoint.register_link(link, role, ->(buf : Bytes) {
        if buf.size <= MAX_MESSAGE_BYTES
          ws.send(buf)
        else
          ws.close rescue nil
        end
      })
      link
    end

    def self.serve(endpoint : Endpoint, port : Int32, tls : OpenSSL::SSL::Context::Server,
                   public_url : String, ttl_secs : UInt32 = 3600_u32,
                   host : String = "0.0.0.0") : HTTP::Server
      active = Admission.new(MAX_PENDING_CONNECTIONS)
      ws_handler = BoundedWebSocketHandler.new("/_hop", active) do |ws, _ctx|
        attach_ws(endpoint, ws, :acceptor)
      end
      handlers = [HandshakeCompleteHandler.new.as(HTTP::Handler), ws_handler.as(HTTP::Handler)]
      handshakes = Admission.new(HANDSHAKE_WORKERS)
      server = BoundedServer.new(handlers, handshakes) do |ctx|
        if ctx.request.path == Hop::Discovery::WELL_KNOWN_PATH
          ctx.response.content_type = "application/json"
          ctx.response.print(Hop::Discovery.well_known_body(endpoint, public_url, ttl_secs))
        else
          ctx.response.status = HTTP::Status::NOT_FOUND
        end
      end
      server.max_request_line_size = 4096
      server.max_headers_size = MAX_HEADER_BYTES
      tcp = TCPServer.new(host, port, MAX_PENDING_CONNECTIONS)
      ssl = OpenSSL::SSL::Server.new(tcp, tls)
      ssl.start_immediately = false
      server.bind(ssl)
      endpoint.register_closer do
        server.close rescue nil
        handshakes.close_all
        active.close_all
      end
      spawn server.listen
      server
    end

    def self.dial(endpoint : Endpoint, wss_url : String,
                  insecure_tls : Bool = false) : HTTP::WebSocket
      uri = URI.parse(wss_url)
      tls : HTTP::Client::TLSContext = if uri.scheme == "wss"
        ctx = OpenSSL::SSL::Context::Client.new
        ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE if insecure_tls
        ctx
      else
        false
      end
      ws = connect(uri, tls)
      link = attach_ws(endpoint, ws, :dialer)
      endpoint.register_closer { ws.close rescue nil }
      spawn do
        ws.run
        endpoint.link_down(link)
      end
      ws
    end

    def self.connect(uri : URI, tls : HTTP::Client::TLSContext) : BoundedWebSocket
      io = nil.as(IO?)
      host = uri.host.not_nil!
      port = uri.port || (tls ? 443 : 80)
      tcp = TCPSocket.new(host, port, connect_timeout: HANDSHAKE_TIMEOUT)
      apply_timeout(tcp, HANDSHAKE_TIMEOUT)
      io = tcp.as(IO)
      if tls
        context = tls.is_a?(Bool) ? OpenSSL::SSL::Context::Client.new : tls
        io = OpenSSL::SSL::Socket::Client.new(tcp, context: context, sync_close: true, hostname: host)
      end
      stream = io.not_nil!

      key = Base64.strict_encode(StaticArray(UInt8, 16).new { rand(256).to_u8 })
      headers = HTTP::Headers{
        "Host"                  => "#{host}:#{port}",
        "Connection"            => "Upgrade",
        "Upgrade"               => "websocket",
        "Sec-WebSocket-Version" => HTTP::WebSocket::Protocol::VERSION,
        "Sec-WebSocket-Key"     => key,
      }
      request = HTTP::Request.new("GET", uri.request_target.presence || "/_hop", headers)
      request.to_io(stream)
      stream.flush
      response = HTTP::Client::Response.from_io(stream, ignore_body: true)
      unless response.status.switching_protocols?
        raise Socket::Error.new("Handshake got denied. Status code was #{response.status.code}.")
      end
      unless response.headers["Sec-WebSocket-Accept"]? == HTTP::WebSocket::Protocol.key_challenge(key)
        raise Socket::Error.new("Handshake got denied. Server did not verify WebSocket challenge.")
      end
      apply_timeout(stream, READ_TIMEOUT)
      BoundedWebSocket.new(stream, masked_out: true, expect_masked: false)
    rescue exc
      io.try &.close rescue nil
      raise exc
    end
  end
end
