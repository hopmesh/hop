# Hop Mesh Transfer Impact Assessment (TIA)

**Document Version:** 1.0  
**Effective Date:** September 4, 2026  
**Entity:** Hop Mesh, LLC, a Delaware limited liability company  
**Scope:** Transfers of personal data from the European Economic Area (EEA), United Kingdom, and Switzerland to the United States in connection with the Hop Hosted Services.

---

## 1. Executive Summary

This Transfer Impact Assessment (TIA) evaluates the legal and technical safeguards governing cross-border transfers of personal data to the United States when utilizing the Hop Hosted Services. It has been prepared in accordance with the European Data Protection Board (EDPB) Recommendations 01/2020 on measures that supplement transfer tools to ensure compliance with the EU level of protection of personal data following the Court of Justice of the European Union (CJEU) *Schrems II* ruling (Case C-311/18).

**Primary Finding:** Because Hop employs client-side end-to-end encryption (E2EE) with zero-knowledge relays, user message payloads cannot be accessed, decrypted, or surrendered by Hop or its cloud subprocessors under any statutory authority. When combined with contractual safeguards under the 2021 EU Standard Contractual Clauses (SCCs) and transit encryption, these technical measures provide an essentially equivalent level of protection to that guaranteed within the European Union.

---

## 2. Architecture and Data Flows

Hop processes data under strict architectural constraints:
1. **Payload Ciphertext:** All user message bodies and media attachments are encrypted on device before leaving client custody, utilizing authenticated ciphers (ChaCha20-Poly1305) and cryptographic key agreements (X25519 and the Double Ratchet algorithm). Hop does not possess decryption keys and cannot decrypt payloads in transit or at rest.
2. **Envelope Routing Metadata:** Relays process sealed bundle envelopes consisting of pseudonymous destination public keys (Ed25519), hop counts, expiration timestamps (TTL), and byte lengths. No subscriber directories, phone numbers, or plain addresses exist at the protocol layer.
3. **Session and Device State:** Relay nodes maintain session state in Google Cloud Firestore (`relays/{node}/kv`), holding base58 public keys of connected devices and connection timestamps to manage rate limits and network routing.
4. **Developer Account Information:** Account registration data for console access (developer email, API tokens, and billing records) is processed by Google Cloud and Stripe in the United States.

---

## 3. Evaluation of United States Legal Framework

### 3.1 Foreign Intelligence Surveillance Act (FISA) Section 702
Section 702 of FISA allows US intelligence agencies to target non-US persons reasonably believed to be located outside the United States to acquire foreign intelligence information through electronic communication service providers (ECSPs).
- **Applicability to Hop:** Hop Mesh, LLC may be considered an ECSP under US law.
- **Impact on Hop Data:** Under FISA 702, government agencies may issue directives compelling disclosure of communications. However, because message payloads are end-to-end encrypted with endpoint-held keys, Hop cannot produce intelligible plaintext. The data in Hop's custody consists solely of unreadable ciphertext and pseudonymous routing envelopes.

### 3.2 Executive Order 14086
Executive Order 14086 ("Enhancing Safeguards for United States Signals Intelligence Activities") establishes binding limitations on US signals intelligence, mandating that activities be conducted only to pursue defined national security priorities and in a necessary and proportionate manner. It also establishes an independent Data Protection Review Court (DPRC) accessible to European individuals.

### 3.3 The CLOUD Act (18 U.S.C. § 2713)
The Clarifying Lawful Overseas Use of Data (CLOUD) Act allows US law enforcement to compel US-based service providers to produce data within their possession, custody, or control regardless of where stored.
- **Impact on Hop Data:** Hop complies with valid legal process. However, because Hop does not hold decryption keys, lawful orders directed to Hop can obtain only encrypted bytes and metadata.

---

## 4. Supplemental Technical and Organizational Safeguards

To satisfy the EDPB Recommendations 01/2020 (specifically Use Case 1: Data storage for backup and other neutral purposes, and Use Case 6: Transfer to service providers requiring access in the clear), Hop implements the following supplemental safeguards:

### 4.1 Cryptographic Impossibility of Plaintext Access
- **Client-Side Key Generation:** Private keys are generated on user endpoints (Secure Enclave, Android Keystore, or local hardware) and never leave the device.
- **Authenticated Encryption:** Payloads use ChaCha20-Poly1305 with unique per-message session keys established via Double Ratchet forward secrecy.
- **Mathematical Defense:** Even if an upstream cloud provider, subprocessor, or intelligence agency intercepts the ciphertext stream, the mathematical strength of the encryption prevents disclosure of personal communications.

### 4.2 Transit and Infrastructure Encryption
- Transport connections between devices and relays enforce TLS 1.3 or the Noise Protocol Framework (`Noise_XX_25519_ChaChaPoly_BLAKE2s`), preventing passive wiretapping.
- Persistent databases and held spools in Google Cloud multi-region facilities are protected by AES-256 encryption at rest.

### 4.3 Contractual and Procedural Safeguards
- **Challenge to Unlawful Demands:** Hop commits under Clause 15 of the SCCs to review the legality of any government request and to exhaust legal remedies if demands are overbroad or conflict with EU law.
- **Transparency and Notice:** Hop will notify data exporters of any public authority requests where legally permitted.

---

## 5. Conclusion and Assessment

Based on the objective technical architecture of the Hop protocol, the mathematical guarantees of endpoint-to-endpoint payload encryption, and the contractual commitments established in the Hop Data Processing Addendum and EU Standard Contractual Clauses, Hop Mesh, LLC concludes that:
1. The laws and practices of the United States do not undermine the level of protection guaranteed by GDPR for Hop message payload data.
2. The supplemental technical measures in place effectively mitigate risks related to foreign intelligence access to message communications.
3. European controllers and processors may lawfully transfer data to the Hop Hosted Services under GDPR Chapter V.
