# Hop Mesh Export Control & Sanctions Compliance Memorandum

**Document Version:** 1.0  
**Effective Date:** September 4, 2026  
**Entity:** Hop Mesh, LLC, a Delaware limited liability company  
**Classification Scope:** Hop cryptographic protocol software, client SDKs, hosted backbone services, and commercial defense / public safety licensing.

---

## 1. Regulatory Context

Hop Mesh, LLC develops software incorporating strong cryptographic algorithms (including X25519 key exchange, Ed25519 digital signatures, ChaCha20-Poly1305 authenticated encryption, and BLAKE3 hashing). The export, re-export, and in-country transfer of such software are subject to the Export Administration Regulations (EAR, 15 C.F.R. Parts 730-774) administered by the US Department of Commerce Bureau of Industry and Security (BIS), as well as economic sanctions regulations administered by the US Department of the Treasury Office of Foreign Assets Control (OFAC).

This memorandum provides the technical classification analysis and compliance determinations required prior to executing foreign commercial contracts, with particular emphasis on defense, public safety, and dual-use customer inquiries.

---

## 2. Publicly Available Open-Source Software Exemption

The baseline Hop protocol core (`core/hop-core`), language SDKs (`sdk/*`), platform bearers (`bearers/*`), and client drivers (`drivers/*`) are published publicly and freely available under the Apache License, Version 2.0.

- **Statutory Authority:** 15 C.F.R. § 734.7(a) and 15 C.F.R. § 742.15(b).
- **Analysis:** Under 15 C.F.R. § 734.7, software is "published" and not subject to the EAR when it has been made available to the public without restrictions upon its further dissemination. Furthermore, under Section 742.15(b), encryption source code that is publicly available is not subject to the EAR once the email notification or URL submission to BIS and the ENC Encryption Request Coordinator is completed.
- **Determination:** Publicly available Hop open-source components do not require an export license for international distribution to non-embargoed destinations.

---

## 3. Commercial and Proprietary Software ECCN Classification

Commercial software packages, managed cloud backbone components (`services/*`), proprietary enterprise extensions, and dedicated private fleet binaries licensed under commercial terms (e.g. FSL-1.1-ALv2 or enterprise master agreements) are evaluated against Category 5, Part 2 (Information Security) of the Commerce Control List (CCL):

### 3.1 Evaluation of ECCN 5D002 vs. 5D992.c vs. EAR99

1. **ECCN 5D002.a.1 (Information Security Software):**
   - Applies to software designed or modified for the "use" of equipment or software employing cryptographic techniques with symmetric key lengths exceeding 56 bits or asymmetric key algorithms based on factorization or discrete logarithms exceeding 512 bits.
   - Hop uses 256-bit ChaCha20 symmetric keys and 256-bit Curve25519 (X25519) asymmetric keys. Consequently, absent an applicable exception, proprietary Hop software falls under ECCN 5D002.a.1.

2. **License Exception ENC (§ 740.17(b)(1) & (b)(3)):**
   - Software eligible for License Exception ENC may be exported without an individual license to most destinations (excluding Country Group E:1 and E:2 embargoed nations), subject to self-classification and annual reporting requirements.
   - Relays and mesh transport software operating as network infrastructure components require formal classification or annual reporting under Section 740.17(b)(2) or (b)(3).

3. **ECCN 5D992.c (Mass Market Encryption Software):**
   - Software meeting the criteria of Note 3 to Category 5, Part 2 ("Cryptography Note", mass-market retail or developer availability) may be classified under 5D992.c, subject to submission of a self-classification report under Section 740.17(e).

4. **EAR99:**
   - Non-cryptographic client UI wrappers, developer documentation, design assets, and marketing sites are classified as EAR99.

### 3.2 Action Items for Commercial Defense Engagements
Prior to executing commercial contracts with foreign defense, tactical, or public safety entities:
- File the annual self-classification report with BIS and the ENC Encryption Request Coordinator pursuant to 15 C.F.R. § 740.17(e)(1).
- Ensure written customer contracts include explicit export control compliance representations (incorporated in Hop Terms of Service Section 11).

---

## 4. Economic Sanctions (OFAC) and Restricted Party Controls

Hop software and Hosted Services must not be provided, directly or indirectly, to:
1. **Embargoed Jurisdictions:** Any country or territory subject to comprehensive US territorial sanctions: currently Cuba, Iran, North Korea, Syria, and the Crimea, Donetsk, and Luhansk regions of Ukraine.
2. **Restricted Parties:** Any individual or entity listed on US government restricted party lists, including:
   - OFAC Specially Designated Nationals and Blocked Persons (SDN) List.
   - BIS Denied Persons List and Entity List.
   - US Department of State Nonproliferation Sanctions Lists.

Customer representations enforcing these restrictions are contractually mandated in Section 11 of the Hop Terms of Service.
