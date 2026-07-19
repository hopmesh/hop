//! Org (workspace) lifecycle + the tenant registry. An Org IS a billing tenant: its `tenant_hex` is
//! the fleet-wide TenantId, and the Org row IS the registry entry the fleet syncs from Postgres into
//! Firestore (tenant -> Stripe customer, carriage pubkey, OTLP endpoint). This replaces the old
//! operator-provisioned flat files with one writable source of truth.
//!
//! On first sign-in a user gets a personal workspace they OWN, so they land somewhere usable with zero
//! setup (the approachable, no-org-at-signup flow). Naming/converting to a team is a later action.

use crate::auth;
use crate::domain::{Membership, Org, Role};
use crate::store::{Store, StoreError, StoreResult};

/// A fresh 16-byte TenantId as 32 lowercase-hex chars, the fleet-wide tenant shape (matches
/// `api::valid_tenant_hex`). From the OS CSPRNG.
pub fn generate_tenant_hex() -> String {
    use rand::RngCore;
    let mut b = [0u8; 16];
    rand::rngs::OsRng.fill_bytes(&mut b);
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// A friendly default name for a personal workspace, from the email local-part (`dev@hopme.sh` ->
/// `dev's workspace`). Renamed later in settings.
pub fn default_workspace_name(email: &str) -> String {
    let local = email.split('@').next().unwrap_or("").trim();
    let local = if local.is_empty() { "my" } else { local };
    format!("{local}'s workspace")
}

/// Ensure the user has a workspace, returning one they own. Idempotent: if they already OWN an org
/// (the personal workspace from a prior login, or a team they founded), return it; otherwise create a
/// fresh personal Org (a new tenant) with the user as Owner. Retries on the astronomically unlikely
/// tenant-hex collision.
pub fn ensure_personal_workspace(
    store: &dyn Store,
    user_id: &str,
    email: &str,
    now_ms: u64,
) -> StoreResult<Org> {
    // Already own something? Reuse it (first-login creates once; re-login is a no-op).
    for m in store.memberships_for_user(user_id)? {
        if m.role == Role::Owner {
            if let Some(org) = store.org_by_id(&m.org_id)? {
                return Ok(org);
            }
        }
    }
    loop {
        let org = Org {
            id: auth::generate_token(),
            name: default_workspace_name(email),
            tenant_hex: generate_tenant_hex(),
            stripe_customer: None,
            carriage_pubkey: None,
            otlp_endpoint: None,
            created_ms: now_ms,
        };
        match store.create_org(&org) {
            Ok(()) => {
                store.add_membership(&Membership {
                    user_id: user_id.to_string(),
                    org_id: org.id.clone(),
                    role: Role::Owner,
                })?;
                return Ok(org);
            }
            // tenant_hex collided (1 in 2^128): mint a new one and retry.
            Err(StoreError::Conflict(_)) => continue,
            Err(e) => return Err(e),
        }
    }
}

/// The tenant-registry entry for `tenant_hex`, i.e. the Org row the fleet reads. `None` if no such
/// tenant. This is the read side of the registry the fleet-sync (later phase) pushes to Firestore.
pub fn registry_entry(store: &dyn Store, tenant_hex: &str) -> StoreResult<Option<Org>> {
    store.org_by_tenant(tenant_hex)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::MemStore;

    #[test]
    fn tenant_hex_is_32_hex_and_unique() {
        let t = generate_tenant_hex();
        assert_eq!(t.len(), 32);
        assert!(t.bytes().all(|b| b.is_ascii_hexdigit()));
        assert!(crate::api::valid_tenant_hex(&t));
        assert_ne!(generate_tenant_hex(), generate_tenant_hex());
    }

    #[test]
    fn default_name_from_email_local_part() {
        assert_eq!(default_workspace_name("Dev@hopme.sh"), "Dev's workspace");
        assert_eq!(default_workspace_name("@x.co"), "my's workspace");
    }

    #[test]
    fn first_login_creates_a_personal_workspace_reused_on_relogin() {
        let s = MemStore::new();
        let uid = "u1";
        let a = ensure_personal_workspace(&s, uid, "dev@hopme.sh", 100).unwrap();
        // owner of the fresh workspace, a real tenant, registry entry resolvable
        assert_eq!(s.membership(uid, &a.id).unwrap().unwrap().role, Role::Owner);
        assert!(crate::api::valid_tenant_hex(&a.tenant_hex));
        assert_eq!(registry_entry(&s, &a.tenant_hex).unwrap().unwrap().id, a.id);
        // second login: SAME workspace, not a duplicate
        let b = ensure_personal_workspace(&s, uid, "dev@hopme.sh", 200).unwrap();
        assert_eq!(a.id, b.id);
        assert_eq!(s.memberships_for_user(uid).unwrap().len(), 1);
    }

    #[test]
    fn registry_fields_start_empty_and_can_be_set() {
        let s = MemStore::new();
        let org = ensure_personal_workspace(&s, "u1", "a@x.co", 0).unwrap();
        assert!(
            org.stripe_customer.is_none()
                && org.carriage_pubkey.is_none()
                && org.otlp_endpoint.is_none()
        );
        s.set_org_stripe_customer(&org.id, "cus_123").unwrap();
        s.set_org_carriage_pubkey(&org.id, "aa11bb22").unwrap();
        s.set_org_otlp_endpoint(&org.id, "https://otlp.datadoghq.com")
            .unwrap();
        let e = registry_entry(&s, &org.tenant_hex).unwrap().unwrap();
        assert_eq!(e.stripe_customer.as_deref(), Some("cus_123"));
        assert_eq!(e.carriage_pubkey.as_deref(), Some("aa11bb22"));
        assert_eq!(
            e.otlp_endpoint.as_deref(),
            Some("https://otlp.datadoghq.com")
        );
    }
}
