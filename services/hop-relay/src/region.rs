//! Region-aware routing for the cloud backbone. See DESIGN.md §21.
//!
//! Cloud hop nodes are **zero-distance, high-capacity virtual peers**: any two
//! devices attached to the backbone are effectively one hop apart. That makes it
//! cheap to move a bundle *into* the cloud — but egress out to every region is not
//! free (backbone bandwidth + waking downstream devices). So the backbone routes
//! intelligently: it tracks where devices are and which regions actually have
//! subscribers for a topic, and **deprioritizes (or skips) regions with no demand.**
//!
//! Two signals, both recency-decayed so the picture tracks *current* reality:
//! - **presence** — which region a device address was last reachable through;
//! - **demand** — per `(app, topic)`, how much live subscriber interest each region
//!   has (the §18 demand idea, aggregated to regions).

use std::collections::HashMap;

use hop_core::crypto::PubKeyBytes;
use hop_core::AppId;

/// A coarse routing locale on the backbone (an edge/PoP id, a geo bucket, …).
pub type Region = String;

#[derive(Clone, Copy)]
struct Decaying {
    last_ms: u64,
    weight: f64,
}

impl Decaying {
    fn value(&self, now_ms: u64, half_life_ms: u64) -> f64 {
        if now_ms <= self.last_ms || half_life_ms == 0 {
            return self.weight;
        }
        let elapsed = (now_ms - self.last_ms) as f64;
        self.weight * 0.5f64.powf(elapsed / half_life_ms as f64)
    }
}

/// Backbone routing brain: device presence + per-region topic demand.
pub struct RegionRouter {
    half_life_ms: u64,
    /// Device address → (region, last seen there).
    presence: HashMap<PubKeyBytes, (Region, u64)>,
    /// (app, topic) → region → decayed subscriber demand.
    demand: HashMap<(AppId, String), HashMap<Region, Decaying>>,
}

impl RegionRouter {
    /// `half_life_ms` controls how fast stale presence/demand fades (e.g. an hour).
    pub fn new(half_life_ms: u64) -> Self {
        Self {
            half_life_ms,
            presence: HashMap::new(),
            demand: HashMap::new(),
        }
    }

    /// Record that `address` was just reachable through `region`.
    pub fn observe_presence(&mut self, address: PubKeyBytes, region: &Region, now_ms: u64) {
        self.presence.insert(address, (region.clone(), now_ms));
    }

    /// Record a live subscriber for `(app, topic)` in `region`.
    pub fn observe_subscriber(&mut self, app: AppId, topic: &str, region: &Region, now_ms: u64) {
        let entry = self
            .demand
            .entry((app, topic.to_string()))
            .or_default()
            .entry(region.clone())
            .or_insert(Decaying {
                last_ms: now_ms,
                weight: 0.0,
            });
        entry.weight = entry.value(now_ms, self.half_life_ms) + 1.0;
        entry.last_ms = now_ms;
    }

    /// Which region to send an **addressed** bundle to — the destination's last
    /// known region, if seen within `ttl_ms`. `None` ⇒ unknown, fall back to a
    /// broadcast/flood. This is the big win: one region instead of all of them.
    pub fn region_of(&self, address: &PubKeyBytes, now_ms: u64, ttl_ms: u64) -> Option<Region> {
        self.presence
            .get(address)
            .filter(|(_, last)| now_ms.saturating_sub(*last) <= ttl_ms)
            .map(|(r, _)| r.clone())
    }

    /// Decayed subscriber demand for `(app, topic)` in `region`.
    pub fn demand_score(&self, app: AppId, topic: &str, region: &Region, now_ms: u64) -> f64 {
        self.demand
            .get(&(app, topic.to_string()))
            .and_then(|m| m.get(region))
            .map(|d| d.value(now_ms, self.half_life_ms))
            .unwrap_or(0.0)
    }

    /// Should a topic's broadcasts be shipped to `region` at all? False when demand
    /// has decayed below `threshold` — the "don't ship to regions without
    /// subscribers" rule.
    pub fn should_route_topic_to(
        &self,
        app: AppId,
        topic: &str,
        region: &Region,
        now_ms: u64,
        threshold: f64,
    ) -> bool {
        self.demand_score(app, topic, region, now_ms) >= threshold
    }

    /// Regions worth fanning a topic broadcast to, highest demand first, excluding
    /// those below `threshold`. Empty ⇒ nobody wants it anywhere; don't send.
    pub fn target_regions(
        &self,
        app: AppId,
        topic: &str,
        now_ms: u64,
        threshold: f64,
    ) -> Vec<(Region, f64)> {
        let mut out: Vec<(Region, f64)> = self
            .demand
            .get(&(app, topic.to_string()))
            .map(|m| {
                m.iter()
                    .map(|(r, d)| (r.clone(), d.value(now_ms, self.half_life_ms)))
                    .filter(|(_, s)| *s >= threshold)
                    .collect()
            })
            .unwrap_or_default();
        out.sort_by(|a, b| b.1.total_cmp(&a.1));
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hop_core::FABRIC_APP;

    fn addr(n: u8) -> PubKeyBytes {
        [n; 32]
    }

    #[test]
    fn addressed_bundle_targets_the_devices_region() {
        let mut r = RegionRouter::new(3_600_000);
        r.observe_presence(addr(1), &"us-east".into(), 0);
        assert_eq!(
            r.region_of(&addr(1), 1_000, 60_000).as_deref(),
            Some("us-east")
        );
        // Unknown device → no region (caller falls back to flood).
        assert_eq!(r.region_of(&addr(2), 1_000, 60_000), None);
        // Stale presence beyond ttl → treated as unknown.
        assert_eq!(r.region_of(&addr(1), 1_000_000, 60_000), None);
    }

    #[test]
    fn topic_only_routed_to_regions_with_subscribers() {
        let mut r = RegionRouter::new(3_600_000);
        let now = 0;
        // "jobs" has subscribers in us-east and eu-west, none in ap-south.
        r.observe_subscriber(FABRIC_APP, "jobs", &"us-east".into(), now);
        r.observe_subscriber(FABRIC_APP, "jobs", &"us-east".into(), now);
        r.observe_subscriber(FABRIC_APP, "jobs", &"eu-west".into(), now);

        assert!(r.should_route_topic_to(FABRIC_APP, "jobs", &"us-east".into(), now, 0.5));
        assert!(r.should_route_topic_to(FABRIC_APP, "jobs", &"eu-west".into(), now, 0.5));
        assert!(
            !r.should_route_topic_to(FABRIC_APP, "jobs", &"ap-south".into(), now, 0.5),
            "no subscribers there → don't ship"
        );

        // Fan-out list is demand-ranked and excludes dead regions.
        let targets = r.target_regions(FABRIC_APP, "jobs", now, 0.5);
        assert_eq!(targets.len(), 2);
        assert_eq!(targets[0].0, "us-east"); // most demand first
    }

    #[test]
    fn demand_decays_so_emptied_regions_drop_off() {
        let mut r = RegionRouter::new(1_000); // fast 1s half-life
        r.observe_subscriber(FABRIC_APP, "jobs", &"us-east".into(), 0);
        assert!(r.should_route_topic_to(FABRIC_APP, "jobs", &"us-east".into(), 0, 0.5));
        // Long after, with no refresh, demand decays below threshold.
        assert!(!r.should_route_topic_to(FABRIC_APP, "jobs", &"us-east".into(), 20_000, 0.5));
        assert!(r.target_regions(FABRIC_APP, "jobs", 20_000, 0.5).is_empty());
    }
}
