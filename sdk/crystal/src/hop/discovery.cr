require "json"
require "base64"
require "http/client"
require "uri"
require "openssl"
require "./ffi"

module Hop
  # Discovery: bind a name to a Hop address without DNSSEC, using the domain's TLS cert (WebPKI) plus a
  # self-certifying reachability record served at /.well-known/hop. See docs/endpoint-sdk.md.
  module Discovery
    WELL_KNOWN_PATH = "/.well-known/hop"

    def self.well_known_body(endpoint : Endpoint, public_url : String, ttl_secs : UInt32 = 3600_u32) : String
      record = endpoint.sign_reach(public_url, ttl_secs)
      {address: endpoint.address, endpoint: public_url, reach: Base64.strict_encode(record)}.to_json
    end

    # Fetch + verify base_url's well-known. Returns {address, address_bytes, wss_url}. Raises on a
    # missing/malformed/unverified record.
    def self.resolve(base_url : String, insecure_tls : Bool = false)
      tls = OpenSSL::SSL::Context::Client.new
      tls.verify_mode = OpenSSL::SSL::VerifyMode::NONE if insecure_tls
      res = HTTP::Client.get("#{base_url}#{WELL_KNOWN_PATH}", tls: tls)
      raise "well-known fetch failed: HTTP #{res.status_code}" unless res.status_code == 200

      body = JSON.parse(res.body)
      record = Base64.decode(body["reach"].as_s)
      info = Hop::FFI.verify_reach(record, Time.utc.to_unix.to_u64)
      raise "reach record failed verification (bad signature or expired)" unless info

      {address: Hop::FFI.to_b58(info.address), address_bytes: info.address, wss_url: info.endpoint}
    end
  end
end
