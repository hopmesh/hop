/// DEV/TEST ONLY: a self-signed cert for the discovery example + test, generated
/// in a temp dir via the `openssl` CLI (universally present on CI and dev boxes).
/// Never use a self-signed cert in production; there a real WebPKI cert proves
/// the domain.
library;

import 'dart:io';

/// A [SecurityContext] backed by a fresh self-signed cert (EC P-256, CN=[cn]).
/// Returns null if `openssl` is unavailable, so a test can skip rather than fail.
SecurityContext? devServerContext({String cn = 'localhost'}) {
  final dir = Directory.systemTemp.createTempSync('hop-dev-tls-');
  final certPath = '${dir.path}/cert.pem';
  final keyPath = '${dir.path}/key.pem';
  final result = Process.runSync('openssl', [
    'req',
    '-x509',
    '-newkey',
    'ec',
    '-pkeyopt',
    'ec_paramgen_curve:prime256v1',
    '-nodes',
    '-keyout',
    keyPath,
    '-out',
    certPath,
    '-days',
    '1',
    '-subj',
    '/CN=$cn',
    '-addext',
    'subjectAltName=DNS:$cn',
  ]);
  if (result.exitCode != 0) return null;
  return SecurityContext()
    ..useCertificateChain(certPath)
    ..usePrivateKey(keyPath);
}
