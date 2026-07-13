# Calls a self-hosted Hop endpoint over TCP. The address would normally come from an HNS lookup; here
# you paste the one server.cr printed.
#   crystal run examples/client.cr -- <server-address> [host] [port]
require "json"
require "../src/hop"

address = ARGV[0]?
unless address
  STDERR.puts "usage: crystal run examples/client.cr -- <server-address> [host] [port]"
  exit(2)
end
host = ARGV[1]? || "localhost"
port = (ARGV[2]? || "9944").to_i

client = Hop::Endpoint.new
Hop::TcpBearer.dial(client, host, port)

begin
  status, body = client.request(address, "acme/orders", "create", {item: "widget", qty: 3}.to_json)
  puts "<- #{status} #{String.new(body)}"
rescue ex
  STDERR.puts "request failed: #{ex.message}"
  exit(1)
ensure
  client.close
end
