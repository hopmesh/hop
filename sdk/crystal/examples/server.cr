# A standalone, self-hostable Hop endpoint (the two-process deployment shape). Run this, then run
# client.cr with the address it prints. This one uses the idiomatic Crystal CHANNEL surface: the
# endpoint hands verified requests to a Channel and a fiber consumes them in a loop (equivalent to the
# hop.on block handler, just channels). In production HNS would resolve a name to this host/port/key,
# and you would persist the key so the address is stable across restarts.
require "json"
require "../src/hop"

port = (ENV["PORT"]? || "9944").to_i

server = Hop::Endpoint.new

# The channel surface: receive verified requests for the service, reply from your own fiber.
orders = server.channel("acme/orders")
spawn do
  loop do
    req, reply = orders.receive
    # req.from is the cryptographically VERIFIED sender, not a spoofable header. No auth middleware.
    puts "[server] #{req.service}/#{req.method} from #{req.from[0, 12]}: #{req.text}"
    reply.call(201, {ok: true, received: JSON.parse(req.text)}.to_json)
  end
end

Hop::TcpBearer.listen(server, port)
puts "hop endpoint listening on tcp://0.0.0.0:#{port}"
puts "address: #{server.address}"
puts "\ntry it:\n  crystal run examples/client.cr -- #{server.address} localhost #{port}"

sleep # keep the endpoint (and its pump fiber) alive
