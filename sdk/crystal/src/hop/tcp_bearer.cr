require "socket"
require "./endpoint"

module Hop
  # The raw-TCP Internet bearer: opaque Hop frames over TCP, core does the Noise. TCP is a stream, so
  # each drained packet is length-prefixed (4-byte big-endian) and reassembled on the far side.
  module TcpBearer
    @@seq = 40_000_u64
    @@seq_mutex = Mutex.new

    def self.next_link : UInt64
      @@seq_mutex.synchronize { @@seq += 1 }
    end

    def self.send_framed(sock : IO, buf : Bytes) : Nil
      sock.write_bytes(buf.size.to_u32, IO::ByteFormat::BigEndian)
      sock.write(buf)
      sock.flush
    rescue IO::Error
      nil
    end

    def self.recv_loop(endpoint : Endpoint, sock : TCPSocket, link : UInt64) : Nil
      loop do
        len = sock.read_bytes(UInt32, IO::ByteFormat::BigEndian)
        frame = Bytes.new(len)
        sock.read_fully(frame) if len > 0
        endpoint.deliver(link, frame)
      end
    rescue IO::Error
      nil
    ensure
      endpoint.link_down(link)
      sock.close rescue nil
    end

    def self.listen(endpoint : Endpoint, port : Int32, host : String = "0.0.0.0") : TCPServer
      server = TCPServer.new(host, port)
      endpoint.register_closer { server.close rescue nil }
      spawn do
        loop do
          sock = server.accept? || break
          link = next_link
          endpoint.register_link(link, :acceptor, ->(buf : Bytes) { send_framed(sock, buf) })
          spawn recv_loop(endpoint, sock, link)
        end
      end
      server
    end

    def self.dial(endpoint : Endpoint, host : String, port : Int32) : TCPSocket
      sock = TCPSocket.new(host, port)
      link = next_link
      endpoint.register_link(link, :dialer, ->(buf : Bytes) { send_framed(sock, buf) })
      endpoint.register_closer { sock.close rescue nil }
      spawn recv_loop(endpoint, sock, link)
      sock
    end
  end
end
