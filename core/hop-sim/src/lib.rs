//! # hop-sim
//!
//! A discrete-event simulator for Hop routing (DESIGN.md §6, §12). Field-testing a
//! mesh by hand is brutal, so routing policies are validated here first: delivery
//! ratio, latency, and copy overhead under churn and partition.
//!
//! The harness has three parts:
//! - a deterministic, seeded [`Rng`] so scenarios are reproducible;
//! - a [`ScenarioParams`]-driven generator that synthesizes a partitioned contact
//!   trace and a cross-partition message workload ([`build_scenario`]);
//! - a discrete-event [`Sim`] that replays contacts and injections in time order,
//!   performing real binary spray-and-wait, and reports [`Metrics`].

use std::collections::HashMap;

use hop_core::prelude::*;

/// A node in the simulation: an identity, a store, and a router.
pub struct SimNode {
    pub identity: Identity,
    pub store: MemoryStore,
    pub router: SprayAndWait,
}

impl SimNode {
    pub fn new() -> Self {
        Self {
            identity: Identity::generate(),
            store: MemoryStore::new(),
            router: SprayAndWait::new(),
        }
    }

    pub fn address(&self) -> PubKeyBytes {
        self.identity.address()
    }
}

impl Default for SimNode {
    fn default() -> Self {
        Self::new()
    }
}

/// A scheduled contact: at `at` ms, nodes `a` and `b` are in range.
#[derive(Clone, Copy, Debug)]
pub struct Contact {
    pub at: u64,
    pub a: usize,
    pub b: usize,
}

/// Aggregate results of a run.
#[derive(Clone, Debug, Default)]
pub struct Metrics {
    /// Messages scheduled via [`Sim::schedule_message`].
    pub injected: usize,
    /// Distinct messages that reached their destination at least once.
    pub delivered: usize,
    /// `delivered / injected`.
    pub delivery_ratio: f64,
    /// Mean end-to-end delay (delivery time − creation time) over delivered msgs.
    pub mean_latency_ms: f64,
    /// Total copies transferred across all links (the cost of delivery).
    pub transmissions: u64,
    /// `transmissions / delivered` — copies spent per successful delivery.
    pub overhead: f64,
}

/// The simulation world.
pub struct Sim {
    pub nodes: Vec<SimNode>,
    pub contacts: Vec<Contact>,
    /// Delivered bundle ids per destination node index.
    pub delivered: HashMap<usize, Vec<BundleId>>,
    /// Timed message injections (at, node, bundle) replayed by [`Sim::run`].
    pending: Vec<(u64, usize, Bundle)>,
    injected: usize,
    transmissions: u64,
    /// First-delivery time per delivered message id.
    delivered_at: HashMap<BundleId, u64>,
    latency_sum_ms: u128,
}

impl Sim {
    pub fn new(node_count: usize) -> Self {
        Self {
            nodes: (0..node_count).map(|_| SimNode::new()).collect(),
            contacts: Vec::new(),
            delivered: HashMap::new(),
            pending: Vec::new(),
            injected: 0,
            transmissions: 0,
            delivered_at: HashMap::new(),
            latency_sum_ms: 0,
        }
    }

    /// Inject a bundle into node `at_node`'s store immediately (pre-seed). Low-level;
    /// not counted in [`Metrics::injected`]. Prefer [`Sim::schedule_message`].
    pub fn inject(&mut self, at_node: usize, bundle: Bundle) {
        self.nodes[at_node].store.put(bundle, 0);
    }

    /// Schedule a sealed `PeerMessage` from `src` to `dst`, created and injected at
    /// time `at` with copy budget L. Counted in metrics. Returns the bundle id.
    pub fn schedule_message(
        &mut self,
        at: u64,
        src: usize,
        dst: usize,
        copies: u16,
        body: Vec<u8>,
    ) -> BundleId {
        let dst_addr = self.nodes[dst].address();
        let dst_x = self.nodes[dst].identity.address();
        let bundle = Bundle::create(
            &self.nodes[src].identity,
            Destination::Device(dst_addr),
            &dst_x,
            &Payload::PeerMessage { content_type: "application/octet-stream".into(), body },
            BundleOpts { created_at: at, copies, ..Default::default() },
        )
        .expect("bundle create");
        let id = bundle.id();
        self.injected += 1;
        self.pending.push((at, src, bundle));
        id
    }

    /// Replay all injections and contacts in time order (injections first at equal
    /// times), performing real binary spray-and-wait.
    pub fn run(&mut self) {
        enum Ev {
            Inject(usize, Box<Bundle>),
            Contact(usize, usize),
        }
        let mut events: Vec<(u64, u8, Ev)> = Vec::new();
        for (at, node, b) in self.pending.drain(..).collect::<Vec<_>>() {
            events.push((at, 0, Ev::Inject(node, Box::new(b))));
        }
        for c in self.contacts.drain(..).collect::<Vec<_>>() {
            events.push((c.at, 1, Ev::Contact(c.a, c.b)));
        }
        events.sort_by(|x, y| x.0.cmp(&y.0).then(x.1.cmp(&y.1)));

        for (t, _, ev) in events {
            match ev {
                Ev::Inject(node, b) => {
                    self.nodes[node].store.put(*b, t);
                }
                Ev::Contact(a, b) => {
                    self.exchange(a, b, t);
                    self.exchange(b, a, t);
                }
            }
        }
    }

    /// Compute aggregate metrics for the completed run.
    pub fn metrics(&self) -> Metrics {
        let delivered = self.delivered_at.len();
        let delivery_ratio =
            if self.injected > 0 { delivered as f64 / self.injected as f64 } else { 0.0 };
        let mean_latency_ms =
            if delivered > 0 { self.latency_sum_ms as f64 / delivered as f64 } else { 0.0 };
        let overhead =
            if delivered > 0 { self.transmissions as f64 / delivered as f64 } else { 0.0 };
        Metrics {
            injected: self.injected,
            delivered,
            delivery_ratio,
            mean_latency_ms,
            transmissions: self.transmissions,
            overhead,
        }
    }

    fn exchange(&mut self, from: usize, to: usize, now: u64) {
        let to_addr = self.nodes[to].address();
        let ids = self.nodes[from].store.have().ids;

        for id in ids {
            if self.nodes[to].store.seen(&id) {
                continue; // peer already has it (dedup)
            }
            let Some(b) = self.nodes[from].store.get(&id) else {
                continue;
            };
            let meta = BundleMeta::from(&b);
            let direct = is_direct(&b.inner.dst, &to_addr);

            match self.nodes[from].router.should_forward(&meta, &to_addr) {
                ForwardDecision::Drop => {
                    self.nodes[from].store.remove(&id);
                }
                ForwardDecision::Hold => {}
                ForwardDecision::Forward if direct => {
                    // Hand the whole remaining bundle to its destination.
                    let mut copy = b.clone();
                    if !copy.decrement_hop() {
                        continue;
                    }
                    self.transmissions += 1;
                    let created = copy.inner.created_at;
                    if self.nodes[to].store.put(copy, now) {
                        self.delivered.entry(to).or_default().push(id);
                    }
                    if let std::collections::hash_map::Entry::Vacant(e) =
                        self.delivered_at.entry(id)
                    {
                        e.insert(now);
                        self.latency_sum_ms += now.saturating_sub(created) as u128;
                    }
                    self.nodes[from].store.remove(&id); // delivered; release custody
                }
                ForwardDecision::Forward => {
                    // Spray: give the peer floor(n/2) copies, keep the rest.
                    let give = self.nodes[from].store.split_copies(&id);
                    if give == 0 {
                        continue; // wait phase: nothing to spray (or absent)
                    }
                    let mut copy = b.clone();
                    copy.env.copies = give;
                    if !copy.decrement_hop() {
                        continue;
                    }
                    self.transmissions += 1;
                    self.nodes[to].store.put(copy, now);
                }
            }
        }
    }
}

/// Does `dst` resolve to this peer's address (so a handoff is direct delivery)?
fn is_direct(dst: &Destination, addr: &PubKeyBytes) -> bool {
    match dst {
        Destination::Device(d) => d == addr,
        Destination::AckTo(d, _) => d == addr,
        Destination::Broadcast => false,
    }
}

/// Deterministic SplitMix64 PRNG — reproducible scenarios from a seed. (We avoid a
/// `rand` dependency and keep runs bit-for-bit repeatable for regression tests.)
pub struct Rng {
    state: u64,
}

impl Rng {
    pub fn new(seed: u64) -> Self {
        Self { state: seed }
    }

    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform integer in `[0, n)`.
    pub fn below(&mut self, n: usize) -> usize {
        (self.next_u64() % n as u64) as usize
    }

    /// Uniform float in `[0, 1)`.
    pub fn unit(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }

    /// Exponentially-distributed gap with the given mean (for Poisson contacts).
    pub fn exp(&mut self, mean: u64) -> u64 {
        let u = 1.0 - self.unit(); // (0, 1]
        ((-(mean as f64)) * u.ln()) as u64
    }
}

/// Parameters for a synthetic scenario.
#[derive(Clone, Copy, Debug)]
pub struct ScenarioParams {
    pub nodes: usize,
    pub duration_ms: u64,
    /// Mean gap between successive contacts anywhere in the network (Poisson).
    pub mean_contact_interval_ms: u64,
    /// Number of communities; nodes split round-robin across them.
    pub partitions: usize,
    /// Fraction of contacts that bridge two different partitions.
    pub bridge_fraction: f64,
    pub seed: u64,
}

fn partition_of(node: usize, partitions: usize) -> usize {
    node % partitions.max(1)
}

/// Build a [`Sim`] with a generated contact trace and a cross-partition message
/// workload of `messages` bundles, each with copy budget `copies`.
pub fn build_scenario(p: &ScenarioParams, messages: usize, copies: u16) -> Sim {
    let mut sim = Sim::new(p.nodes);
    let mut rng = Rng::new(p.seed);
    let parts = p.partitions.max(1);

    // Contact trace: a Poisson process; each contact is intra- or cross-partition.
    let mut t = 0u64;
    loop {
        t += rng.exp(p.mean_contact_interval_ms).max(1);
        if t >= p.duration_ms {
            break;
        }
        let a = rng.below(p.nodes);
        let cross = rng.unit() < p.bridge_fraction && parts > 1;
        let mut b = a;
        for _ in 0..32 {
            let cand = rng.below(p.nodes);
            if cand == a {
                continue;
            }
            let same_part = partition_of(cand, parts) == partition_of(a, parts);
            if same_part != cross {
                b = cand;
                break;
            }
        }
        if b == a {
            continue; // couldn't satisfy the constraint this draw; skip
        }
        sim.contacts.push(Contact { at: t, a, b });
    }

    // Workload: messages between nodes in different partitions, so they must be
    // relayed (and, without bridges, cannot arrive at all).
    let inject_window = (p.duration_ms / 2).max(1);
    for _ in 0..messages {
        let at = rng.below(inject_window as usize) as u64;
        let src = rng.below(p.nodes);
        let mut dst = src;
        for _ in 0..32 {
            let cand = rng.below(p.nodes);
            let cross_ok = parts == 1 || partition_of(cand, parts) != partition_of(src, parts);
            if cand != src && cross_ok {
                dst = cand;
                break;
            }
        }
        if dst == src {
            continue;
        }
        sim.schedule_message(at, src, dst, copies, vec![0u8; 32]);
    }

    sim
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_hop_delivery() {
        // 0 -> 1 -> 2, where 2 is the destination. 0 and 2 never meet directly.
        let mut sim = Sim::new(3);
        let dst_addr = sim.nodes[2].address();
        let dst_x = sim.nodes[2].identity.address();

        let bundle = Bundle::create(
            &sim.nodes[0].identity,
            Destination::Device(dst_addr),
            &dst_x,
            &Payload::PeerMessage { content_type: "t".into(), body: b"relayed".to_vec() },
            BundleOpts::default(),
        )
        .unwrap();

        sim.inject(0, bundle);
        sim.contacts.push(Contact { at: 10, a: 0, b: 1 });
        sim.contacts.push(Contact { at: 20, a: 1, b: 2 });
        sim.run();

        assert_eq!(sim.delivered.get(&2).map(|v| v.len()), Some(1));
    }

    #[test]
    fn binary_spray_splits_copies_then_delivers() {
        // Source (0) starts with 8 copies. It sprays to relays 1 and 2, halving
        // each handoff, then relay 1 delivers directly to the destination (4).
        let mut sim = Sim::new(5);
        let dst_addr = sim.nodes[4].address();
        let dst_x = sim.nodes[4].identity.address();

        let bundle = Bundle::create(
            &sim.nodes[0].identity,
            Destination::Device(dst_addr),
            &dst_x,
            &Payload::PeerMessage { content_type: "t".into(), body: b"hi".to_vec() },
            BundleOpts { copies: 8, ..Default::default() },
        )
        .unwrap();
        let id = bundle.id();

        sim.inject(0, bundle);
        sim.contacts.push(Contact { at: 10, a: 0, b: 1 }); // 0 sprays 4 to 1, keeps 4
        sim.contacts.push(Contact { at: 20, a: 0, b: 2 }); // 0 sprays 2 to 2, keeps 2
        sim.contacts.push(Contact { at: 30, a: 1, b: 4 }); // 1 delivers direct to dst
        sim.run();

        assert_eq!(sim.delivered.get(&4).map(|v| v.len()), Some(1));
        // Source kept ceil after two sprays: 8 -> 4 -> 2.
        assert_eq!(sim.nodes[0].store.get(&id).unwrap().env.copies, 2);
        // Relay 2 holds the 2 copies it was sprayed.
        assert_eq!(sim.nodes[2].store.get(&id).unwrap().env.copies, 2);
    }

    fn base_params() -> ScenarioParams {
        ScenarioParams {
            nodes: 24,
            duration_ms: 2_000_000,
            mean_contact_interval_ms: 2_000,
            partitions: 3,
            bridge_fraction: 0.15,
            seed: 0xC0FFEE,
        }
    }

    #[test]
    fn rng_is_deterministic() {
        let mut a = Rng::new(1);
        let mut b = Rng::new(1);
        for _ in 0..1000 {
            assert_eq!(a.next_u64(), b.next_u64());
        }
    }

    #[test]
    fn partitions_without_bridges_block_delivery() {
        // Every message is cross-partition; with no bridging contacts, none arrive.
        let mut p = base_params();
        p.bridge_fraction = 0.0;
        let mut sim = build_scenario(&p, 40, 16);
        sim.run();
        let m = sim.metrics();
        assert!(m.injected > 0);
        assert_eq!(m.delivered, 0);
        assert_eq!(m.delivery_ratio, 0.0);
    }

    #[test]
    fn bridges_enable_some_delivery() {
        let mut sim = build_scenario(&base_params(), 40, 16);
        sim.run();
        let m = sim.metrics();
        assert!(m.delivered > 0, "expected some cross-partition delivery via bridges");
        assert!(m.mean_latency_ms > 0.0);
    }

    #[test]
    fn more_copies_never_deliver_less() {
        // Same seed → identical contacts and workload; only the copy budget differs.
        // Spray (L=16) must deliver at least as much as direct-only (L=1).
        let p = base_params();
        let mut direct = build_scenario(&p, 60, 1);
        direct.run();
        let mut sprayed = build_scenario(&p, 60, 16);
        sprayed.run();

        let (md, ms) = (direct.metrics(), sprayed.metrics());
        assert_eq!(md.injected, ms.injected);
        assert!(
            ms.delivered >= md.delivered,
            "spray L=16 delivered {} < direct L=1 delivered {}",
            ms.delivered,
            md.delivered
        );
    }
}
