# Audit Vectors And Reviewer Lanes

Use this reference to build lanes from the current repository. Do not treat the lists as a substitute for live inventory.

## Component discovery

Inspect the root tree, workspace manifests, package manifests, workflow files, deployment roots, component catalogs, generated-artifact stamps, and nearest instruction files. Current HOP audits commonly include:

- Root protocol, security, governance, license, version, and contribution contracts.
- `.github` workflows, protected gates, release authority, sync, Pages, fuzzing, and automation.
- `core` protocol, C ABI, stores, WASM, simulation bindings, and endpoint primitives.
- `services` relay, endpoint, gateway, account, billing, telemetry, and future daemons.
- `sdk` C, Apple, Android, embedded, Node, Python, Go, Ruby, Crystal, Elixir, and new wrappers.
- `bearers` Apple and Android BLE, LAN, relay, and future transports.
- `drivers` app-facing Apple and Android clients.
- `apps` Apple, Android, web, embedded, labs, and new products.
- `sim`, `fuzz`, `testkit`, `examples`, `tools`, `infra`, `docs`, `learn`, `assets`, and `mockups`.
- `business` pricing, positioning, deck, GTM, fundraising, customer, operating, and legal evidence.

Split packages and services into separate inventory items when they have different trust, release, storage, platform, or business boundaries.

## Technical adversarial vectors

### Protocol and cryptography

- Wire parsing, canonical encoding, versioning, transcript binding, downgrade resistance.
- Double Ratchet lifecycle, skipped keys, replay, reordering, forward secrecy, post-compromise recovery.
- Identity, prekeys, key rotation, backup, restore, deletion, multi-device, and compromise recovery.
- Metadata privacy, unlinkability, traffic analysis, addressing, discovery, and untraceable-by-default claims.
- Static sealing boundaries versus ratcheted user content.

### State, storage, and durability

- Acceptance only after authenticated durable commit.
- Atomic multi-record mutation, crash consistency, fault injection, and restart rehydration.
- SQLCipher, SQLite, Firestore, in-memory, and optional backend parity.
- Expiry, clock anchoring, migration, corruption, quarantine, and retry behavior.
- Per-object and process-global limits by count, bytes, age, sender, tenant, and stream.

### Concurrency and lifecycle

- Call-versus-close, callback-versus-teardown, cancellation, retry, and ownership races.
- Lost wakeups, dropped first messages, timer independence, queue starvation, and deadlocks.
- Process-owner cleanup, background transitions, reconnect, and duplicate workers.

### Networking and transports

- Framing, partial reads, oversized materialization, backpressure, paging, retry, and liveness.
- BLE, LAN, relay, gateway, WebSocket, HTTP, TCP, L2CAP, and radio-specific trust boundaries.
- Discovery spoofing, peer authorization, route binding, bearer downgrade, and carrier abuse.
- Offline delivery semantics, deduplication, acknowledgement, and never-drop claims.

### APIs, ABI, and packages

- C ABI memory ownership, integer widths, panic containment, header drift, and consumer behavior.
- Wrapper parity, generated bindings, nullability, errors, async lifecycle, and resource release.
- Exact standalone exports, package metadata, native assets, clean package-manager consumers, and publication authority.

### Resource abuse and performance

- CPU, memory, disk, queue, worker, connection, key, message, media, and tenant exhaustion.
- Compression, decompression, parsing, retry, cardinality, and amplification attacks.
- Mobile battery, background budgets, embedded memory, browser main-thread, and fleet cost.

### Product security and privacy

- Authentication versus authorization, tenant binding, capability scope, and fail-open behavior.
- Secret handling, log classification, diagnostic output, crash reports, retention, and deletion.
- Abuse, spam, unwanted contact, safety reporting, block controls, and administrative access.

### Infrastructure and supply chain

- IAM least privilege, bootstrap/runtime separation, deploy authority, stale-deploy fencing, and rollback.
- Immutable actions, images, installers, lockfiles, provenance, signatures, attestations, and package producers.
- Cloud regions, data residency, backups, disaster recovery, monitoring, alerting, and incident response.
- Repository settings and protected environments must be verified live or marked unvalidated.

### Tests, docs, and claims

- Hostile regressions, boundaries, fuzzing, deterministic vectors, coverage exclusions, and flaky tests.
- Public copy, design docs, runbooks, pricing, privacy, release, and architecture claims against implementation.
- A green suite proves only the scenarios it exercises.

## Business and operating vectors

Use repository evidence first. Add external market evidence only when web access is authorized, cite the URL and retrieval date, and distinguish repository evidence, external facts, owner claims, assumptions, direct observations, and counsel-required conclusions.

### Business model and moat

- Free versus paid boundary, self-hosting, commercial licensing, managed network, support, and federation.
- What remains defensible if protocol and services are available to customers or competitors.
- Network effects, service quality, data, distribution, switching costs, contracts, and intellectual property.

### Product and market

- Sharp initial product and ICP versus an undifferentiated platform story.
- Urgency, budget, current workaround, buyer, user, integration owner, and procurement path.
- Market evidence, design partners, pilots, retained usage, willingness to pay, and falsification criteria.
- Competitive alternatives include internal builds, adjacent protocols, incumbents, and doing nothing.

### Positioning and claims

- One memorable category, buyer-specific value, proof, and differentiation.
- Consistency between messenger, transport layer, managed backbone, telemetry, public safety, and hardware narratives.
- Reliability, privacy, scale, availability, global, guarantee, and compliance claims must match evidence.

### Pricing and unit economics

- Canonical billable event, package structure, free allowances, overages, commits, suspension, and disputes.
- Infrastructure, payment, support, implementation, compliance, bad-debt, and idle-capacity costs.
- Margin under realistic utilization, abuse, regionality, delivery size, and support assumptions.
- Stripe catalog, billing services, public pricing, design docs, and forecasts must agree.

### Sales and GTM

- Lead capture, qualification, pipeline stages, design-partner contract, pilot exit, conversion, and expansion.
- Product-led activation from install to first value to retained project to paid use.
- Enterprise discovery, solution engineering, security review, procurement, support, and renewal.
- Channels, ecosystems, package distribution, developer relations, partners, and public-sector motion.

### Legal, privacy, and commercial readiness

- Entity, license rights, CLA, commercial trigger, Terms, AUP, DPA, MSA, SLA, order form, and subprocessors.
- Controller/processor roles, retention, deletion, residency, transfers, export controls, sanctions, and public-sector obligations.
- Legal readiness is owner/counsel evidence, never an inference from source.

### Operations and governance

- Fleet status, signup, billing, support, on-call, SLOs, capacity, recovery, incident communication, and second-operator risk.
- Hiring gaps, decision rights, roadmap governance, financial controls, runway, fundraising evidence, and board reporting.
- Process safety: worktree isolation, commits, scope control, evidence chronology, secret handling, and source/live separation.

## Reviewer topology

Start with independent roles, then adapt to inventory size:

- Protocol cryptographer and wire-format reviewer.
- Distributed-state, storage, and concurrency reviewer.
- Network and transport abuse reviewer.
- Platform reviewers for Apple, Android, web, embedded, and server environments.
- SDK, ABI, packaging, and supply-chain reviewer.
- Cloud IAM, deployment, observability, and incident-response reviewer.
- Test-strategy, fuzzing, and claims-drift reviewer.
- Product strategist and technical product marketer.
- Usage-pricing specialist and FinOps reviewer.
- Enterprise sales, developer GTM, and RevOps reviewer.
- Startup commercial, privacy, open-source, and public-sector legal issue spotter. Mark counsel-required conclusions.
- Fractional CFO, investor/operator, support, and governance reviewer.

Every Critical or High candidate needs a finder and a separate refuter. Use a final critic across all lanes to detect uncovered components and one-layer-above failures.
