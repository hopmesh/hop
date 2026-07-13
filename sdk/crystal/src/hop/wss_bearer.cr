require "http/server"
require "http/web_socket"
require "openssl"
require "uri"
require "./discovery"

module Hop
  # The WSS Internet bearer for a Crystal endpoint, on Crystal's stdlib HTTP::WebSocket (server +
  # client) + HTTP::Server. The server also answers GET /.well-known/hop on the same port, so attach
  # wires both. core does the Noise + crypto over the frame payloads; one drained packet is one binary
  # WS message. No third-party shards.
  module WssBearer
    @@seq = 60_000_u64
    @@seq_mutex = Mutex.new

    def self.next_link : UInt64
      @@seq_mutex.synchronize { @@seq += 1 }
    end

    # Wire a live WS (server- or client-side) into the endpoint as a bearer link.
    def self.attach_ws(endpoint : Endpoint, ws : HTTP::WebSocket, role : Symbol) : UInt64
      link = next_link
      ws.on_binary { |bytes| endpoint.deliver(link, bytes) }
      ws.on_close { |_code, _msg| endpoint.link_down(link) }
      endpoint.register_link(link, role, ->(buf : Bytes) { ws.send(buf) rescue nil })
      link
    end

    # Start the HTTPS server: WS at /_hop (a bearer link) + GET /.well-known/hop (the reach record).
    def self.serve(endpoint : Endpoint, port : Int32, tls : OpenSSL::SSL::Context::Server,
                   public_url : String, ttl_secs : UInt32 = 3600_u32, host : String = "0.0.0.0") : HTTP::Server
      ws_handler = HTTP::WebSocketHandler.new do |ws, ctx|
        attach_ws(endpoint, ws, :acceptor) if ctx.request.path == "/_hop"
      end
      server = HTTP::Server.new([ws_handler.as(HTTP::Handler)]) do |ctx|
        if ctx.request.path == Hop::Discovery::WELL_KNOWN_PATH
          ctx.response.content_type = "application/json"
          ctx.response.print(Hop::Discovery.well_known_body(endpoint, public_url, ttl_secs))
        else
          ctx.response.status = HTTP::Status::NOT_FOUND
        end
      end
      server.bind_tls(host, port, tls)
      endpoint.register_closer { server.close rescue nil }
      spawn server.listen
      server
    end

    def self.dial(endpoint : Endpoint, wss_url : String, insecure_tls : Bool = false) : HTTP::WebSocket
      uri = URI.parse(wss_url)
      tls : HTTP::Client::TLSContext = if uri.scheme == "wss"
        ctx = OpenSSL::SSL::Context::Client.new
        ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE if insecure_tls
        ctx
      else
        false
      end
      path = uri.path.presence || "/_hop"
      ws = HTTP::WebSocket.new(uri.host.not_nil!, path, uri.port, tls)
      link = attach_ws(endpoint, ws, :dialer)
      endpoint.register_closer { ws.close rescue nil }
      spawn do
        ws.run # reads frames (driving on_binary/on_close) until the socket closes
        endpoint.link_down(link)
      end
      ws
    end
  end
end
