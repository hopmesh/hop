require "spec"
require "openssl"
require "../src/hop"
require "../src/hop/dev_tls"

describe Hop do
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
    server.attach(port, tls, public_url) # WSS /_hop + /.well-known/hop in one call

    client = Hop::Endpoint.new
    begin
      address = client.dial_by_name("https://localhost:#{port}", insecure_tls: true)
      address.should eq server.address
      status, body = client.request(address, "acme/orders", "create", "widget")
      status.should eq 201
      String.new(body).should eq "widget"
    ensure
      server.close
      client.close
    end
  end
end
