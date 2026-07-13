require "openssl"

# DEV/TEST ONLY: generate an in-process self-signed cert (no `openssl` CLI, no shard) for the discovery
# example + spec. Crystal's stdlib OpenSSL parses certs but cannot create/sign them, so we reopen its
# `LibCrypto`/`LibSSL` bindings (reusing their pkg-config link + type aliases) and add the classic
# EC keygen + X509 build/sign functions (works on the OpenSSL 1.1 Crystal links here as well as 3.x).
# Never use a self-signed cert in production; there a real WebPKI cert proves the domain.

# X509/X509_NAME/EVP_MD/EC_KEY are already aliased to Void* by the stdlib, and x509_new / x509_free /
# x509_get_subject_name / x509_name_add_entry_by_txt / ec_key_new_by_curve_name / evp_sha256 already
# exist; add only the missing keygen + X509 build/sign functions.
lib LibCrypto
  fun evp_pkey_new = EVP_PKEY_new : Void*
  fun evp_pkey_free = EVP_PKEY_free(pkey : Void*) : Void
  fun evp_pkey_assign = EVP_PKEY_assign(pkey : Void*, type : Int, key : Void*) : Int
  fun ec_key_generate_key = EC_KEY_generate_key(ec : EC_KEY) : Int
  fun ec_key_set_asn1_flag = EC_KEY_set_asn1_flag(ec : EC_KEY, flag : Int)
  fun x509_set_version = X509_set_version(x : X509, v : Int64) : Int
  fun x509_get_serial_number = X509_get_serialNumber(x : X509) : Void*
  fun asn1_integer_set = ASN1_INTEGER_set(a : Void*, v : Int64) : Int
  fun x509_getm_not_before = X509_getm_notBefore(x : X509) : Void*
  fun x509_getm_not_after = X509_getm_notAfter(x : X509) : Void*
  fun x509_gmtime_adj = X509_gmtime_adj(t : Void*, adj : Int64) : Void*
  fun x509_set_pubkey = X509_set_pubkey(x : X509, pkey : Void*) : Int
  fun x509_set_issuer_name = X509_set_issuer_name(x : X509, name : X509_NAME) : Int
  fun x509_sign = X509_sign(x : X509, pkey : Void*, md : EVP_MD) : Int
end

lib LibSSL
  fun ssl_ctx_use_certificate = SSL_CTX_use_certificate(ctx : SSLContext, x : Void*) : Int
  fun ssl_ctx_use_private_key = SSL_CTX_use_PrivateKey(ctx : SSLContext, pkey : Void*) : Int
end

module Hop
  module DevTls
    MBSTRING_ASC           = 0x1001
    NID_PRIME256V1         =    415 # NID_X9_62_prime256v1 (P-256)
    EVP_PKEY_EC            =    408
    OPENSSL_EC_NAMED_CURVE =      1

    # A server SSL context backed by a fresh in-process self-signed cert (EC P-256, CN=<cn>, 1y).
    def self.server_context(cn : String = "localhost") : OpenSSL::SSL::Context::Server
      ec = LibCrypto.ec_key_new_by_curve_name(NID_PRIME256V1)
      raise "EC_KEY_new failed" if ec.null?
      LibCrypto.ec_key_set_asn1_flag(ec, OPENSSL_EC_NAMED_CURVE) # encode the curve by name, not params
      raise "EC keygen failed" if LibCrypto.ec_key_generate_key(ec) != 1
      pkey = LibCrypto.evp_pkey_new
      raise "EVP_PKEY_new failed" if pkey.null?
      raise "EVP_PKEY_assign failed" if LibCrypto.evp_pkey_assign(pkey, EVP_PKEY_EC, ec.as(Void*)) != 1

      x = LibCrypto.x509_new
      raise "X509_new failed" if x.null?
      LibCrypto.x509_set_version(x, 2_i64) # v3
      LibCrypto.asn1_integer_set(LibCrypto.x509_get_serial_number(x), 1_i64)
      LibCrypto.x509_gmtime_adj(LibCrypto.x509_getm_not_before(x), 0_i64)
      LibCrypto.x509_gmtime_adj(LibCrypto.x509_getm_not_after(x), 31_536_000_i64)
      LibCrypto.x509_set_pubkey(x, pkey)
      name = LibCrypto.x509_get_subject_name(x)
      LibCrypto.x509_name_add_entry_by_txt(name, "CN", MBSTRING_ASC, cn, -1, -1, 0)
      LibCrypto.x509_set_issuer_name(x, name) # self-signed: issuer == subject
      raise "X509_sign failed" if LibCrypto.x509_sign(x, pkey, LibCrypto.evp_sha256) == 0

      ctx = OpenSSL::SSL::Context::Server.new
      raise "SSL_CTX_use_certificate failed" if LibSSL.ssl_ctx_use_certificate(ctx.to_unsafe, x.as(Void*)) != 1
      raise "SSL_CTX_use_PrivateKey failed" if LibSSL.ssl_ctx_use_private_key(ctx.to_unsafe, pkey) != 1
      LibCrypto.x509_free(x) # the context holds its own refs now
      LibCrypto.evp_pkey_free(pkey)
      ctx
    end
  end
end
