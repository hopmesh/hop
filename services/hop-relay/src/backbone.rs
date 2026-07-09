//! The cloud backbone: region-aware distribution built on [`RegionRouter`] and the
//! [`Mailbox`]. See DESIGN.md §19, §21.
//!
//! This is where the zero-distance backbone earns its keep. Edges report which
//! devices and subscriptions they host; the backbone then:
//! - routes **topic adverts** only to regions with live subscribers for that topic
//!   (and drops them entirely when nobody, anywhere, wants them) — the
//!   "deprioritize regions without subscribers" rule;
//! - files **addressed bundles** in the mailbox and can point a fetch at the
//!   destination's current region instead of flooding all of them.

use std::collections::{HashMap, HashSet};

use hop_core::bundle::Bundle;
use hop_core::crypto::PubKeyBytes;
use hop_core::discover::{Advert, AdvertId};
use hop_core::AppId;

use crate::region::{Region, RegionRouter};
use crate::Mailbox;

/// Region-aware cloud backbone node.
pub struct Backbone {
    router: RegionRouter,
    mailbox: Mailbox,
    /// Minimum decayed demand for a region to receive a topic's adverts.
    threshold: f64,
    /// Per-region queue of adverts to hand that region's edge.
    advert_outbox: HashMap<Region, Vec<Advert>>,
    seen_adverts: HashSet<AdvertId>,
}

impl Backbone {
    pub fn new(router: RegionRouter, mailbox: Mailbox, threshold: f64) -> Self {
        Self {
            router,
            mailbox,
            threshold,
            advert_outbox: HashMap::new(),
            seen_adverts: HashSet::new(),
        }
    }

    /// An edge reports a device present in `region`, subscribed to `topics`.
    pub fn attach(
        &mut self,
        region: &Region,
        app: AppId,
        address: PubKeyBytes,
        topics: &[String],
        now_ms: u64,
    ) {
        self.router.observe_presence(address, region, now_ms);
        for topic in topics {
            self.router.observe_subscriber(app, topic, region, now_ms);
        }
    }

    /// Distribute a gossiped advert across the backbone: queue it only for regions
    /// with live demand for its topic. Returns the regions it was routed to —
    /// empty means nobody wants it anywhere, so it's dropped (not stored, not
    /// fanned out). Verifies and dedups first.
    pub fn distribute_advert(&mut self, advert: Advert, now_ms: u64) -> Vec<Region> {
        if advert.verify().is_err() || !self.seen_adverts.insert(advert.id) {
            return Vec::new();
        }
        let app = advert.body.app;
        let topic = advert.topic().to_string();
        let targets: Vec<Region> = self
            .router
            .target_regions(app, &topic, now_ms, self.threshold)
            .into_iter()
            .map(|(r, _)| r)
            .collect();
        for region in &targets {
            self.advert_outbox
                .entry(region.clone())
                .or_default()
                .push(advert.clone());
        }
        targets
    }

    /// Take the adverts queued for a region's edge (clears the queue).
    pub fn drain_region(&mut self, region: &Region) -> Vec<Advert> {
        self.advert_outbox.remove(region).unwrap_or_default()
    }

    /// File an addressed bundle for retrieval (delegates to the mailbox).
    pub fn deposit_bundle(&mut self, bundle: Bundle, now_ms: u64) -> bool {
        self.mailbox.deposit(bundle, now_ms)
    }

    /// The destination's current region, if known — so an addressed bundle can be
    /// steered to one region instead of flooded everywhere. `None` ⇒ fall back.
    pub fn region_of(&self, address: &PubKeyBytes, now_ms: u64, ttl_ms: u64) -> Option<Region> {
        self.router.region_of(address, now_ms, ttl_ms)
    }

    pub fn mailbox(&mut self) -> &mut Mailbox {
        &mut self.mailbox
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hop_core::discover::AdvertKind;
    use hop_core::prelude::*;

    fn listing(seller: &Identity, service: &str) -> Advert {
        Advert::publish(
            seller,
            AdvertKind::Service {
                service: service.into(),
                title: "Bike for sale".into(),
                summary: "blue".into(),
                tags: vec!["bicycle".into()],
            },
            0,
            600_000,
            1,
        )
        .unwrap()
    }

    fn backbone() -> Backbone {
        Backbone::new(RegionRouter::new(3_600_000), Mailbox::default(), 0.5)
    }

    #[test]
    fn advert_routed_only_to_regions_with_subscribers() {
        let mut bb = backbone();
        let seller = Identity::generate();
        let sub_a = Identity::generate();
        let sub_b = Identity::generate();
        let sub_c = Identity::generate();

        // us-east and eu-west have "market" subscribers; ap-south only "jobs".
        bb.attach(
            &"us-east".into(),
            FABRIC_APP,
            sub_a.address(),
            &["market".into()],
            0,
        );
        bb.attach(
            &"eu-west".into(),
            FABRIC_APP,
            sub_b.address(),
            &["market".into()],
            0,
        );
        bb.attach(
            &"ap-south".into(),
            FABRIC_APP,
            sub_c.address(),
            &["jobs".into()],
            0,
        );

        let mut targets = bb.distribute_advert(listing(&seller, "market"), 1);
        targets.sort();
        assert_eq!(targets, vec!["eu-west".to_string(), "us-east".to_string()]);

        assert_eq!(bb.drain_region(&"us-east".into()).len(), 1);
        assert_eq!(bb.drain_region(&"eu-west".into()).len(), 1);
        assert!(
            bb.drain_region(&"ap-south".into()).is_empty(),
            "no market subs there"
        );
    }

    #[test]
    fn advert_for_unwanted_topic_is_dropped() {
        let mut bb = backbone();
        let seller = Identity::generate();
        let sub = Identity::generate();
        bb.attach(
            &"us-east".into(),
            FABRIC_APP,
            sub.address(),
            &["market".into()],
            0,
        );

        // Nobody anywhere subscribes to "jobs".
        let targets = bb.distribute_advert(listing(&seller, "jobs"), 1);
        assert!(targets.is_empty(), "dropped — no demand anywhere");
        assert!(bb.drain_region(&"us-east".into()).is_empty());
    }

    #[test]
    fn addressed_bundle_steers_to_known_region() {
        let mut bb = backbone();
        let origin = Identity::generate();
        let dst = Identity::generate();

        bb.attach(&"eu-west".into(), FABRIC_APP, dst.address(), &[], 0);
        let b = Bundle::create(
            &origin,
            Destination::Device(dst.address()),
            &dst.address(),
            &Payload::PeerMessage {
                content_type: "t".into(),
                body: b"hi".to_vec(),
            },
            BundleOpts::default(),
        )
        .unwrap();
        assert!(bb.deposit_bundle(b, 0));

        assert_eq!(
            bb.region_of(&dst.address(), 1, 60_000).as_deref(),
            Some("eu-west")
        );
        // And it's fetchable from the mailbox by that address.
        assert_eq!(bb.mailbox().fetch(FABRIC_APP, &dst.address(), 1).len(), 1);
    }
}
