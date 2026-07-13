"""DEV/TEST ONLY: an in-process self-signed cert for the discovery example + test.

Uses the ``cryptography`` package (a dev/example dependency, NOT a runtime dependency, and not imported
by ``hop_endpoint/__init__``) to generate the cert in-process instead of shelling out to the openssl
CLI. Never use a self-signed cert in production; there a real WebPKI cert proves the domain.
"""
import datetime
import os
import ssl
import tempfile

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID


def server_context(cn: str = "localhost") -> ssl.SSLContext:
    """An SSLContext backed by a fresh in-process self-signed cert (EC P-256, CN=<cn>, 1h)."""
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, cn)])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)  # self-signed: issuer == subject
        .public_key(key.public_key())
        .serial_number(1)
        .not_valid_before(now - datetime.timedelta(minutes=1))
        .not_valid_after(now + datetime.timedelta(hours=1))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName(cn)]), critical=False)
        .sign(key, hashes.SHA256())
    )
    # ssl.SSLContext.load_cert_chain needs file paths, so write the in-process PEMs to a temp dir.
    d = tempfile.mkdtemp()
    cert_path, key_path = os.path.join(d, "cert.pem"), os.path.join(d, "key.pem")
    with open(cert_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))
    with open(key_path, "wb") as f:
        f.write(
            key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
        )
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert_path, key_path)
    return ctx
