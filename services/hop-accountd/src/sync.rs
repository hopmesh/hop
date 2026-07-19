//! The tenant-registry fleet projection: push the account service's Postgres `Org` rows into the
//! shared Firestore `tenants` collection, so relays and collectors read tenant carriage keys + OTLP
//! endpoints from one live source instead of operator-provisioned flat files (`access.rs` anticipates
//! exactly this: "the fleet syncs this from the account service").
//!
//! The projection (`tenant_record_for`) is pure and tested. `run_projection` does one full pass, and
//! `spawn_sync` runs it on an interval in a background thread. Both are behind `--features firestore`,
//! which pulls in the shared [`hop_store_firestore::TenantRegistry`]; a default/live build has no
//! Firestore dependency at all.

use crate::domain::Org;
use hop_store_firestore::TenantRecord;

/// Project one org into its fleet-facing tenant record. An org that exists is `active` (there is no
/// suspension mechanism yet; when there is, it sets `active=false` and the fleet drops the tenant
/// without a delete). `carriage_pubkey`/`otlp_endpoint` pass through as-is (already validated at the
/// registration endpoints), so an unissued key stays `None`.
pub fn tenant_record_for(org: &Org) -> TenantRecord {
    TenantRecord {
        tenant_hex: org.tenant_hex.clone(),
        carriage_pubkey: org.carriage_pubkey.clone(),
        otlp_endpoint: org.otlp_endpoint.clone(),
        active: true,
    }
}

/// Run one full projection pass: upsert every org into the Firestore tenant registry. Returns the
/// count synced. A per-tenant upsert error is logged and skipped (one bad row must not abort the
/// pass), so the next org still syncs and the next pass retries the failure.
pub fn run_projection(
    store: &dyn crate::store::Store,
    registry: &hop_store_firestore::TenantRegistry,
) -> Result<usize, crate::store::StoreError> {
    let orgs = store.all_orgs()?;
    let mut synced = 0usize;
    for org in &orgs {
        let record = tenant_record_for(org);
        match registry.upsert(&record) {
            Ok(()) => synced += 1,
            Err(e) => eprintln!(
                "hop-accountd: tenant sync upsert failed for {}: {e}",
                org.tenant_hex
            ),
        }
    }
    Ok(synced)
}

/// Spawn the periodic projection in a background thread. Each pass reprojects the whole registry (it
/// is small, and a full pass is self-healing: it repairs any doc the fleet or a prior partial pass
/// left stale). A pass that cannot read the store is logged and retried next tick.
pub fn spawn_sync<S>(
    store: S,
    registry: hop_store_firestore::TenantRegistry,
    interval: std::time::Duration,
) where
    S: crate::store::Store + 'static,
{
    std::thread::spawn(move || loop {
        match run_projection(&store, &registry) {
            Ok(n) => println!("hop-accountd: tenant registry synced ({n} tenants)"),
            Err(e) => eprintln!("hop-accountd: tenant sync read failed: {e}"),
        }
        std::thread::sleep(interval);
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::Org;

    fn org(tenant: &str, pk: Option<&str>, otlp: Option<&str>) -> Org {
        Org {
            id: "o1".into(),
            name: "w".into(),
            tenant_hex: tenant.into(),
            stripe_customer: None,
            carriage_pubkey: pk.map(str::to_string),
            otlp_endpoint: otlp.map(str::to_string),
            created_ms: 0,
        }
    }

    #[test]
    fn projects_org_fields_into_the_tenant_record() {
        let o = org(
            "a3f1c0d2e4b6a8091122334455667788",
            Some("aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44"),
            Some("https://otlp.example.com"),
        );
        let r = tenant_record_for(&o);
        assert_eq!(r.tenant_hex, o.tenant_hex);
        assert_eq!(r.carriage_pubkey, o.carriage_pubkey);
        assert_eq!(r.otlp_endpoint, o.otlp_endpoint);
        assert!(r.active, "an existing org projects as active");
    }

    #[test]
    fn unissued_key_and_no_otlp_stay_none() {
        let r = tenant_record_for(&org("00112233445566778899aabbccddeeff", None, None));
        assert!(r.carriage_pubkey.is_none() && r.otlp_endpoint.is_none());
    }
}
