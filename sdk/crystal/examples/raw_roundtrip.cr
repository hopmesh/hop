# Derisking proof: the hops:// service round trip through the raw C ABI from Crystal, mirroring
# core/hop/src/cabi.rs. Two nodes, a byte-pipe bearer, a request in, 200 + body back out.
require "../src/hop/ffi"

F = Hop::FFI
F.assert_abi!
puts "ABI ok: #{LibHop.abi_version}"

LA = 11_u64
LB = 22_u64

def pump(a, b)
  1000.times do
    moved = false
    F.drain_outgoing(a).each { |(_l, buf)| moved = true; F.received(b, LB, buf) }
    F.drain_outgoing(b).each { |(_l, buf)| moved = true; F.received(a, LA, buf) }
    break unless moved
  end
end

a = F.node_new
b = F.node_new

F.tick(a, 1000_u64)
F.tick(b, 1000_u64)
F.connected(a, LA, true)
F.connected(b, LB, false)
pump(a, b)
F.publish_prekey(a)
F.publish_prekey(b)
pump(a, b)

b_addr = F.address(b)
req_id = F.send_service_request(a, b_addr, "weather", "report", "temp=21".to_slice)
puts "request fired, reqId: #{req_id[0, 6].hexstring}"
pump(a, b)

frm, rid, service, method, args = F.take_service_requests(b).first
puts "B received: #{service}/#{method} = #{String.new(args)} from #{F.to_b58(frm)[0, 12]}"

F.send_service_response(b, frm, rid, 200_u16, "stored".to_slice)
pump(a, b)

_rf, for_id, status, body = F.take_service_responses(a).first
puts "A got response: #{status} #{String.new(body)}  ties to reqId: #{for_id == req_id}"

passed = service == "weather" && status == 200 && String.new(body) == "stored" && for_id == req_id
F.node_free(a)
F.node_free(b)
puts(passed ? "\nPASS: full hops:// round trip through the C ABI from Crystal." : "\nFAIL")
exit(passed ? 0 : 1)
