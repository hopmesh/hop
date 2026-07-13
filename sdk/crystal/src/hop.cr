# Receive Hop messages in Crystal: an embeddable endpoint over the libhop C ABI (via Crystal's `lib`
# bindings, zero shards). See README.md and sdk/CLAUDE.md.
require "./hop/ffi"
require "./hop/endpoint"
require "./hop/tcp_bearer"
require "./hop/wss_bearer"
require "./hop/discovery"

module Hop
  VERSION = "0.1.0"

  # Wire two endpoints directly (in-process bearer), no sockets. Proves the ergonomics end to end.
  def self.connect_in_process(a : Endpoint, b : Endpoint, la : UInt64 = 11_u64, lb : UInt64 = 22_u64) : Nil
    a.register_link(la, :dialer, ->(buf : Bytes) { b.deliver(lb, buf) })
    b.register_link(lb, :acceptor, ->(buf : Bytes) { a.deliver(la, buf) })
  end
end
