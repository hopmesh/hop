//! Storage-agnostic persistence for the console. Every handler depends on the [`Store`] trait, never
//! on a concrete database, so the domain + auth logic is exercised in CI against [`MemStore`] and the
//! real Postgres binding (the sync `postgres` crate, matching the no-tokio house style) drops in later
//! behind the same contract. Secret tokens are stored only as their SHA-256 hash (see
//! [`crate::session`]); this layer never sees a raw login link or session id.

use crate::domain::{Invite, Membership, Org, Role, User};
use crate::session::{LoginToken, Session};
use std::collections::HashMap;
use std::sync::Mutex;
use thiserror::Error;

pub type StoreResult<T> = Result<T, StoreError>;

/// Why a store operation failed. `Conflict` is the DB-level uniqueness guard (duplicate email); the
/// caller maps it to the right user-facing outcome (and, for enumeration-sensitive flows like login,
/// deliberately does *not* surface it). `Backend` wraps a driver/IO error from a real store.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum StoreError {
    #[error("not found")]
    NotFound,
    #[error("conflict: {0}")]
    Conflict(String),
    #[error("store backend: {0}")]
    Backend(String),
}

/// The persistence contract. Sync and thread-safe (`Send + Sync`) to match the std-thread, no-tokio
/// service style. Implementations must enforce: a unique user email, single-use login tokens (fetched
/// and consumed atomically), and idempotent deletes (deleting an absent row is `Ok`, not `NotFound`).
pub trait Store: Send + Sync {
    // ---- users ----
    /// Insert a user. `Conflict` if the (normalized) email already exists.
    fn create_user(&self, u: &User) -> StoreResult<()>;
    fn user_by_email(&self, email: &str) -> StoreResult<Option<User>>;
    fn user_by_id(&self, id: &str) -> StoreResult<Option<User>>;
    /// Mark the address confirmed. Redeeming a login link proves control of the inbox.
    fn mark_email_verified(&self, user_id: &str) -> StoreResult<()>;

    // ---- orgs (an org IS a billing tenant) ----
    fn create_org(&self, o: &Org) -> StoreResult<()>;
    fn org_by_id(&self, id: &str) -> StoreResult<Option<Org>>;
    fn org_by_tenant(&self, tenant_hex: &str) -> StoreResult<Option<Org>>;
    /// Every org (tenant registry row). The fleet-sync projection reads this to push the registry to
    /// Firestore. Ordering is unspecified.
    fn all_orgs(&self) -> StoreResult<Vec<Org>>;
    fn set_org_stripe_customer(&self, org_id: &str, customer: &str) -> StoreResult<()>;
    /// Bind a Stripe customer to the org ONLY if it has none yet, returning the customer id now
    /// persisted (the one already stored if a concurrent caller won the race). This is what billing
    /// must use so two racing first-checkouts converge on a single customer instead of overwriting
    /// each other. The default is read-then-write (fine for a mutex-guarded in-memory store); a store
    /// with real cross-connection concurrency (Postgres) overrides it with an atomic conditional write.
    fn set_org_stripe_customer_if_absent(
        &self,
        org_id: &str,
        customer: &str,
    ) -> StoreResult<String> {
        if let Some(existing) = self.org_by_id(org_id)?.and_then(|o| o.stripe_customer) {
            return Ok(existing);
        }
        self.set_org_stripe_customer(org_id, customer)?;
        Ok(customer.to_string())
    }
    /// Set the tenant's carriage-stamp signing pubkey (hex) once the first key is issued.
    fn set_org_carriage_pubkey(&self, org_id: &str, pubkey_hex: &str) -> StoreResult<()>;
    /// Set the tenant's managed-OTLP forwarding endpoint.
    fn set_org_otlp_endpoint(&self, org_id: &str, endpoint: &str) -> StoreResult<()>;
    /// The org owning a Stripe customer id, or `None` if none does. The Stripe webhook maps an
    /// event's `customer` back to its tenant with this. (A customer is bound to exactly one org.)
    fn org_by_stripe_customer(&self, customer_id: &str) -> StoreResult<Option<Org>>;
    /// Store the tenant's plan + Stripe subscription status as durable entitlement (the Stripe webhook
    /// writes this; the console can then read a plan without a live Stripe query). Idempotent and
    /// unconditional: it overwrites both columns with the latest projection every time. `NotFound` if
    /// the org does not exist.
    fn set_org_subscription(
        &self,
        org_id: &str,
        plan: Option<&str>,
        status: Option<&str>,
    ) -> StoreResult<()>;

    // ---- memberships ----
    fn add_membership(&self, m: &Membership) -> StoreResult<()>;
    fn membership(&self, user_id: &str, org_id: &str) -> StoreResult<Option<Membership>>;
    fn members_of_org(&self, org_id: &str) -> StoreResult<Vec<Membership>>;
    /// Every org this user belongs to (with their role in each). Powers the org switcher.
    fn memberships_for_user(&self, user_id: &str) -> StoreResult<Vec<Membership>>;
    fn set_role(&self, user_id: &str, org_id: &str, role: Role) -> StoreResult<()>;
    fn remove_membership(&self, user_id: &str, org_id: &str) -> StoreResult<()>;
    /// Set a member's role ATOMICALLY with the last-Owner floor: if this would demote the org's sole
    /// Owner (target is Owner, new role is not, and no other Owner exists) it makes NO change and
    /// returns `Ok(false)`; otherwise it sets the role and returns `Ok(true)`. The check + write are
    /// one indivisible operation (a mutex span for the in-memory store, a single conditional statement
    /// for Postgres), so two concurrent demotions can never both pass the floor and strand the org
    /// ownerless. This is the ONLY role-change path team management should use. `NotFound` if the
    /// target is not a member.
    fn try_set_role(&self, user_id: &str, org_id: &str, role: Role) -> StoreResult<bool>;
    /// Remove a member ATOMICALLY with the same last-Owner floor: `Ok(false)` (no change) if it would
    /// remove the sole Owner, else remove and `Ok(true)`. `NotFound` if the target is not a member.
    fn try_remove_member(&self, user_id: &str, org_id: &str) -> StoreResult<bool>;

    // ---- invites ----
    fn create_invite(&self, i: &Invite) -> StoreResult<()>;
    fn invite_by_token_hash(&self, token_hash: &str) -> StoreResult<Option<Invite>>;
    fn delete_invite(&self, org_id: &str, email: &str) -> StoreResult<()>;

    // ---- magic-link login tokens ----
    fn create_login_token(&self, t: &LoginToken) -> StoreResult<()>;
    /// Fetch AND delete a login token by its hash in one step, so a link is single-use even under a
    /// double click / concurrent redeem. Returns `None` if it was never issued or already consumed.
    fn take_login_token(&self, token_hash: &str) -> StoreResult<Option<LoginToken>>;

    // ---- sessions ----
    fn create_session(&self, s: &Session) -> StoreResult<()>;
    fn session_by_id_hash(&self, id_hash: &str) -> StoreResult<Option<Session>>;
    fn delete_session(&self, id_hash: &str) -> StoreResult<()>;

    /// Garbage-collect expired sessions and login tokens (`now_ms` is the wall clock). Returns the
    /// number of rows removed. A periodic sweep; expiry is always re-checked at read time regardless.
    fn delete_expired(&self, now_ms: u64) -> StoreResult<u64>;
}

/// In-memory [`Store`] for tests and local runs. A single `Mutex` around plain maps: correctness over
/// throughput, and it keeps the passwordless flow testable without a database.
#[derive(Default)]
pub struct MemStore {
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    users: HashMap<String, User>,                   // id -> user
    email_ix: HashMap<String, String>,              // normalized email -> user id
    orgs: HashMap<String, Org>,                     // id -> org
    tenant_ix: HashMap<String, String>,             // tenant_hex -> org id
    members: HashMap<(String, String), Membership>, // (user_id, org_id) -> membership
    invites: HashMap<String, Invite>,               // token_hash -> invite
    login_tokens: HashMap<String, LoginToken>,      // token_hash -> token
    sessions: HashMap<String, Session>,             // id_hash -> session
}

impl MemStore {
    pub fn new() -> Self {
        Self::default()
    }
}

impl Store for MemStore {
    fn create_user(&self, u: &User) -> StoreResult<()> {
        let mut g = self.inner.lock().unwrap();
        if g.email_ix.contains_key(&u.email) {
            return Err(StoreError::Conflict(format!("email {} exists", u.email)));
        }
        g.email_ix.insert(u.email.clone(), u.id.clone());
        g.users.insert(u.id.clone(), u.clone());
        Ok(())
    }
    fn user_by_email(&self, email: &str) -> StoreResult<Option<User>> {
        let g = self.inner.lock().unwrap();
        Ok(g.email_ix
            .get(email)
            .and_then(|id| g.users.get(id))
            .cloned())
    }
    fn user_by_id(&self, id: &str) -> StoreResult<Option<User>> {
        Ok(self.inner.lock().unwrap().users.get(id).cloned())
    }
    fn mark_email_verified(&self, user_id: &str) -> StoreResult<()> {
        let mut g = self.inner.lock().unwrap();
        let u = g.users.get_mut(user_id).ok_or(StoreError::NotFound)?;
        u.email_verified = true;
        Ok(())
    }

    fn create_org(&self, o: &Org) -> StoreResult<()> {
        let mut g = self.inner.lock().unwrap();
        if g.tenant_ix.contains_key(&o.tenant_hex) {
            return Err(StoreError::Conflict(format!(
                "tenant {} exists",
                o.tenant_hex
            )));
        }
        g.tenant_ix.insert(o.tenant_hex.clone(), o.id.clone());
        g.orgs.insert(o.id.clone(), o.clone());
        Ok(())
    }
    fn org_by_id(&self, id: &str) -> StoreResult<Option<Org>> {
        Ok(self.inner.lock().unwrap().orgs.get(id).cloned())
    }
    fn org_by_tenant(&self, tenant_hex: &str) -> StoreResult<Option<Org>> {
        let g = self.inner.lock().unwrap();
        Ok(g.tenant_ix
            .get(tenant_hex)
            .and_then(|id| g.orgs.get(id))
            .cloned())
    }
    fn all_orgs(&self) -> StoreResult<Vec<Org>> {
        Ok(self.inner.lock().unwrap().orgs.values().cloned().collect())
    }
    fn set_org_stripe_customer(&self, org_id: &str, customer: &str) -> StoreResult<()> {
        let mut g = self.inner.lock().unwrap();
        let o = g.orgs.get_mut(org_id).ok_or(StoreError::NotFound)?;
        o.stripe_customer = Some(customer.to_string());
        Ok(())
    }
    fn set_org_carriage_pubkey(&self, org_id: &str, pubkey_hex: &str) -> StoreResult<()> {
        let mut g = self.inner.lock().unwrap();
        let o = g.orgs.get_mut(org_id).ok_or(StoreError::NotFound)?;
        o.carriage_pubkey = Some(pubkey_hex.to_string());
        Ok(())
    }
    fn set_org_otlp_endpoint(&self, org_id: &str, endpoint: &str) -> StoreResult<()> {
        let mut g = self.inner.lock().unwrap();
        let o = g.orgs.get_mut(org_id).ok_or(StoreError::NotFound)?;
        o.otlp_endpoint = Some(endpoint.to_string());
        Ok(())
    }
    fn org_by_stripe_customer(&self, customer_id: &str) -> StoreResult<Option<Org>> {
        let g = self.inner.lock().unwrap();
        Ok(g.orgs
            .values()
            .find(|o| o.stripe_customer.as_deref() == Some(customer_id))
            .cloned())
    }
    fn set_org_subscription(
        &self,
        org_id: &str,
        plan: Option<&str>,
        status: Option<&str>,
    ) -> StoreResult<()> {
        let mut g = self.inner.lock().unwrap();
        let o = g.orgs.get_mut(org_id).ok_or(StoreError::NotFound)?;
        o.plan = plan.map(str::to_string);
        o.subscription_status = status.map(str::to_string);
        Ok(())
    }

    fn add_membership(&self, m: &Membership) -> StoreResult<()> {
        let mut g = self.inner.lock().unwrap();
        let key = (m.user_id.clone(), m.org_id.clone());
        if g.members.contains_key(&key) {
            return Err(StoreError::Conflict("membership exists".into()));
        }
        g.members.insert(key, m.clone());
        Ok(())
    }
    fn membership(&self, user_id: &str, org_id: &str) -> StoreResult<Option<Membership>> {
        let g = self.inner.lock().unwrap();
        Ok(g.members
            .get(&(user_id.to_string(), org_id.to_string()))
            .cloned())
    }
    fn members_of_org(&self, org_id: &str) -> StoreResult<Vec<Membership>> {
        let g = self.inner.lock().unwrap();
        Ok(g.members
            .values()
            .filter(|m| m.org_id == org_id)
            .cloned()
            .collect())
    }
    fn memberships_for_user(&self, user_id: &str) -> StoreResult<Vec<Membership>> {
        let g = self.inner.lock().unwrap();
        Ok(g.members
            .values()
            .filter(|m| m.user_id == user_id)
            .cloned()
            .collect())
    }
    fn set_role(&self, user_id: &str, org_id: &str, role: Role) -> StoreResult<()> {
        let mut g = self.inner.lock().unwrap();
        let m = g
            .members
            .get_mut(&(user_id.to_string(), org_id.to_string()))
            .ok_or(StoreError::NotFound)?;
        m.role = role;
        Ok(())
    }
    fn remove_membership(&self, user_id: &str, org_id: &str) -> StoreResult<()> {
        self.inner
            .lock()
            .unwrap()
            .members
            .remove(&(user_id.to_string(), org_id.to_string()));
        Ok(())
    }
    fn try_set_role(&self, user_id: &str, org_id: &str, role: Role) -> StoreResult<bool> {
        // One lock span covers the count + the write, so it is atomic against concurrent demotions.
        let mut g = self.inner.lock().unwrap();
        let key = (user_id.to_string(), org_id.to_string());
        let cur = g.members.get(&key).ok_or(StoreError::NotFound)?.role;
        if cur == Role::Owner && role != Role::Owner {
            let owners = g
                .members
                .values()
                .filter(|m| m.org_id == org_id && m.role == Role::Owner)
                .count();
            if owners <= 1 {
                return Ok(false);
            }
        }
        g.members.get_mut(&key).expect("checked above").role = role;
        Ok(true)
    }
    fn try_remove_member(&self, user_id: &str, org_id: &str) -> StoreResult<bool> {
        let mut g = self.inner.lock().unwrap();
        let key = (user_id.to_string(), org_id.to_string());
        let cur = g.members.get(&key).ok_or(StoreError::NotFound)?.role;
        if cur == Role::Owner {
            let owners = g
                .members
                .values()
                .filter(|m| m.org_id == org_id && m.role == Role::Owner)
                .count();
            if owners <= 1 {
                return Ok(false);
            }
        }
        g.members.remove(&key);
        Ok(true)
    }

    fn create_invite(&self, i: &Invite) -> StoreResult<()> {
        self.inner
            .lock()
            .unwrap()
            .invites
            .insert(i.token_hash.clone(), i.clone());
        Ok(())
    }
    fn invite_by_token_hash(&self, token_hash: &str) -> StoreResult<Option<Invite>> {
        Ok(self.inner.lock().unwrap().invites.get(token_hash).cloned())
    }
    fn delete_invite(&self, org_id: &str, email: &str) -> StoreResult<()> {
        let mut g = self.inner.lock().unwrap();
        g.invites
            .retain(|_, i| !(i.org_id == org_id && i.email == email));
        Ok(())
    }

    fn create_login_token(&self, t: &LoginToken) -> StoreResult<()> {
        self.inner
            .lock()
            .unwrap()
            .login_tokens
            .insert(t.token_hash.clone(), t.clone());
        Ok(())
    }
    fn take_login_token(&self, token_hash: &str) -> StoreResult<Option<LoginToken>> {
        Ok(self.inner.lock().unwrap().login_tokens.remove(token_hash))
    }

    fn create_session(&self, s: &Session) -> StoreResult<()> {
        self.inner
            .lock()
            .unwrap()
            .sessions
            .insert(s.id_hash.clone(), s.clone());
        Ok(())
    }
    fn session_by_id_hash(&self, id_hash: &str) -> StoreResult<Option<Session>> {
        Ok(self.inner.lock().unwrap().sessions.get(id_hash).cloned())
    }
    fn delete_session(&self, id_hash: &str) -> StoreResult<()> {
        self.inner.lock().unwrap().sessions.remove(id_hash);
        Ok(())
    }

    fn delete_expired(&self, now_ms: u64) -> StoreResult<u64> {
        let mut g = self.inner.lock().unwrap();
        let before = g.sessions.len() + g.login_tokens.len();
        g.sessions.retain(|_, s| s.expires_ms > now_ms);
        g.login_tokens.retain(|_, t| t.expires_ms > now_ms);
        let after = g.sessions.len() + g.login_tokens.len();
        Ok((before - after) as u64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::Role;

    fn user(id: &str, email: &str) -> User {
        User {
            id: id.into(),
            email: email.into(),
            password_hash: String::new(),
            email_verified: false,
            created_ms: 0,
        }
    }

    #[test]
    fn unique_email_is_enforced() {
        let s = MemStore::new();
        s.create_user(&user("u1", "a@x.co")).unwrap();
        // Same email, different id: rejected by the uniqueness guard.
        assert!(matches!(
            s.create_user(&user("u2", "a@x.co")),
            Err(StoreError::Conflict(_))
        ));
        assert_eq!(s.user_by_email("a@x.co").unwrap().unwrap().id, "u1");
        assert!(s.user_by_email("missing@x.co").unwrap().is_none());
    }

    #[test]
    fn login_token_is_single_use() {
        let s = MemStore::new();
        let t = LoginToken {
            token_hash: "h1".into(),
            email: "a@x.co".into(),
            created_ms: 0,
            expires_ms: 1000,
        };
        s.create_login_token(&t).unwrap();
        assert!(s.take_login_token("h1").unwrap().is_some());
        // Second take returns nothing: the row was consumed.
        assert!(s.take_login_token("h1").unwrap().is_none());
    }

    #[test]
    fn membership_roles_update_and_delete_is_idempotent() {
        let s = MemStore::new();
        s.add_membership(&Membership {
            user_id: "u1".into(),
            org_id: "o1".into(),
            role: Role::User,
        })
        .unwrap();
        s.set_role("u1", "o1", Role::Admin).unwrap();
        assert_eq!(s.membership("u1", "o1").unwrap().unwrap().role, Role::Admin);
        assert_eq!(s.members_of_org("o1").unwrap().len(), 1);
        s.remove_membership("u1", "o1").unwrap();
        s.remove_membership("u1", "o1").unwrap(); // idempotent
        assert!(s.membership("u1", "o1").unwrap().is_none());
    }

    #[test]
    fn gc_removes_only_expired() {
        let s = MemStore::new();
        s.create_session(&Session {
            id_hash: "live".into(),
            user_id: "u1".into(),
            created_ms: 0,
            expires_ms: 5000,
        })
        .unwrap();
        s.create_session(&Session {
            id_hash: "dead".into(),
            user_id: "u1".into(),
            created_ms: 0,
            expires_ms: 100,
        })
        .unwrap();
        assert_eq!(s.delete_expired(1000).unwrap(), 1);
        assert!(s.session_by_id_hash("live").unwrap().is_some());
        assert!(s.session_by_id_hash("dead").unwrap().is_none());
    }
}
