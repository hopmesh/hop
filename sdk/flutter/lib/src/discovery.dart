/// Discovery: bind a name to a Hop address using the domain's TLS cert (WebPKI)
/// plus a self-certifying reachability record served at `/.well-known/hop`.
/// See docs/endpoint-sdk.md.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'endpoint.dart';

/// The path the discovery record is served at.
const String wellKnownPath = '/.well-known/hop';

/// The `/.well-known/hop` JSON body: the endpoint's address + a signed reach
/// record for [publicUrl].
String wellKnownBody(HopEndpoint endpoint, String publicUrl,
    {int ttlSecs = 3600}) {
  final record = endpoint.signReach(publicUrl, ttlSecs: ttlSecs);
  return jsonEncode({
    'address': endpoint.address,
    'endpoint': publicUrl,
    'reach': base64Encode(record),
  });
}

/// A verified, name-resolved endpoint.
class ResolvedEndpoint {
  ResolvedEndpoint({
    required this.address,
    required this.addressBytes,
    required this.wssUrl,
  });

  /// The verified address, base58.
  final String address;

  /// The verified address, raw 32 bytes.
  final Uint8List addressBytes;

  /// The endpoint URL the reach record binds (e.g. `wss://host/_hop`).
  final String wssUrl;
}

/// Fetch and verify [baseUrl]'s well-known record. [verifier] is any open
/// [HopEndpoint] (verification is self-certifying and needs only the library).
/// Set [insecureTls] for a dev/self-signed cert only. Throws on a
/// missing/malformed/unverified record.
Future<ResolvedEndpoint> resolve(HopEndpoint verifier, String baseUrl,
    {bool insecureTls = false}) async {
  final base = Uri.parse(baseUrl);
  final client = HttpClient();
  if (insecureTls) {
    client.badCertificateCallback = (cert, host, port) => true;
  }
  try {
    final request = await client.getUrl(base.replace(path: wellKnownPath));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException(
          'well-known fetch failed: HTTP ${response.statusCode}');
    }
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    final record = base64Decode(body['reach'] as String);
    final info = verifier.verifyReach(record);
    if (info == null) {
      throw const HttpException(
          'reach record failed verification (bad signature or expired)');
    }
    return ResolvedEndpoint(
      address: info.addressBase58,
      addressBytes: info.address,
      wssUrl: info.endpoint,
    );
  } finally {
    client.close(force: true);
  }
}
