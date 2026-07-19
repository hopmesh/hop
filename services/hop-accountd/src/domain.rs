//! The console's identity + RBAC model, pure and storage-agnostic. Every authorization decision the
//! account service makes routes through [`Role::can`] and the member-management guards here, so the
//! policy is one small tested surface rather than scattered `if role == ...` checks across handlers.
//!
//! An organization IS a billing tenant: `Org.tenant` is the 16-byte `TenantId` used everywhere else
//! (carriage stamps, the reconciler, telemetry attribution). A user belongs to one or more orgs via a
//! [`Membership`] carrying a [`Role`]. Three roles, least-privilege by default.

use serde::{Deserialize, Serialize};

/// A member's role within one organization. Ordered by privilege (Owner > Admin > User).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    /// The account holder: full control, including billing changes, deletion, and ownership transfer.
    /// Financially and destructively privileged; there is always at least one Owner per org.
    Owner,
    /// Operates the account day to day: team, keys, and settings, and can see billing, but cannot make
    /// destructive or financial changes (payment method, cancellation, deletion, ownership).
    Admin,
    /// A regular member: sees the dashboard and their own keys, changes nothing about the account.
    User,
}

impl Role {
    pub fn as_str(self) -> &'static str {
        match self {
            Role::Owner => "owner",
            Role::Admin => "admin",
            Role::User => "user",
        }
    }

    /// Parse the stored lowercase form back into a [`Role`] (the inverse of [`Role::as_str`]). Used by
    /// the Postgres binding when reading the `role` column.
    pub fn parse(s: &str) -> Option<Role> {
        match s {
            "owner" => Some(Role::Owner),
            "admin" => Some(Role::Admin),
            "user" => Some(Role::User),
            _ => None,
        }
    }
}

/// A discrete capability a request may require. Handlers ask `role.can(Permission::X)` rather than
/// matching on the role, so adding a capability is one arm here, not a sweep of every handler.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Permission {
    /// See the dashboard: usage, observability, and one's own keys. Everyone in the org.
    ViewDashboard,
    /// See invoices and payment history.
    ViewInvoices,
    /// Change the plan, payment method, budget caps, or cancel. Owner only (financial/destructive).
    ManageBilling,
    /// Create or revoke the org's API / carriage-stamp keys.
    ManageKeys,
    /// Invite, remove, or re-role members (subject to the member-management guards below).
    ManageTeam,
    /// Change org settings (name, OTLP endpoint, alert recipients).
    ManageSettings,
    /// Permanently delete the organization. Owner only.
    DeleteOrg,
    /// Transfer the Owner role to another member. Owner only.
    TransferOwnership,
}

impl Role {
    /// Whether this role holds `perm`. This is the whole authorization matrix in one place.
    pub fn can(self, perm: Permission) -> bool {
        use Permission::*;
        use Role::*;
        match perm {
            // Everyone can view.
            ViewDashboard => true,
            // Owner + Admin: operate the account and see money, but not change it.
            ViewInvoices | ManageKeys | ManageTeam | ManageSettings => {
                matches!(self, Owner | Admin)
            }
            // Owner only: money and existential actions.
            ManageBilling | DeleteOrg | TransferOwnership => self == Owner,
        }
    }

    /// Whether an actor with this role may manage (remove / re-role) a member holding `target`. The
    /// guard that stops privilege escalation and admin lockouts: an Admin may manage Users but never
    /// another Admin or the Owner; an Owner may manage anyone; a User manages no one. (Managing
    /// oneself, e.g. leaving, is handled separately by the caller, not via this guard.)
    pub fn can_manage_member(self, target: Role) -> bool {
        match self {
            Role::Owner => true,
            Role::Admin => target == Role::User,
            Role::User => false,
        }
    }

    /// Whether an actor with this role may ASSIGN `new_role` when inviting or re-roling. An Admin can
    /// only ever grant User (no minting of Admins/Owners); assigning Owner is ownership transfer, an
    /// Owner-only action gated separately by [`Permission::TransferOwnership`].
    pub fn can_assign_role(self, new_role: Role) -> bool {
        match self {
            Role::Owner => true,
            Role::Admin => new_role == Role::User,
            Role::User => false,
        }
    }
}

/// A user identity. The password hash is an argon2 PHC string (see [`crate::auth`]); it is never
/// serialized to a client (`skip`). `email_verified` gates login until the address is confirmed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct User {
    pub id: String,
    pub email: String,
    #[serde(skip)]
    pub password_hash: String,
    pub email_verified: bool,
    pub created_ms: u64,
}

/// An organization, which IS a billing tenant. `tenant` is the 16-byte `TenantId` (hex) that keys the
/// carriage stamps, the reconciler, and telemetry attribution; `stripe_customer` is set once the
/// signup creates the customer.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Org {
    pub id: String,
    pub name: String,
    /// 32-char lowercase-hex TenantId, this org's billing/attribution identity fleet-wide.
    pub tenant_hex: String,
    pub stripe_customer: Option<String>,
    pub created_ms: u64,
}

/// A user's role in an org. The join between [`User`] and [`Org`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Membership {
    pub user_id: String,
    pub org_id: String,
    pub role: Role,
}

/// A pending invitation to join an org at a given role. Like a login token, the emailed secret is a
/// CSPRNG value (see [`crate::auth::generate_token`]) whose SHA-256 hash is all that rests here
/// (`token_hash`, via [`crate::session::hash_token`]); the raw token lives only in the invite link.
/// It is never listed back to clients.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Invite {
    pub org_id: String,
    pub email: String,
    pub role: Role,
    #[serde(skip)]
    pub token_hash: String,
    pub invited_by: String,
    pub expires_ms: u64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use Permission::*;

    #[test]
    fn user_can_only_view() {
        assert!(Role::User.can(ViewDashboard));
        for p in [
            ViewInvoices,
            ManageBilling,
            ManageKeys,
            ManageTeam,
            ManageSettings,
            DeleteOrg,
            TransferOwnership,
        ] {
            assert!(!Role::User.can(p), "user must not {p:?}");
        }
    }

    #[test]
    fn admin_operates_but_cannot_touch_money_or_existence() {
        for p in [
            ViewDashboard,
            ViewInvoices,
            ManageKeys,
            ManageTeam,
            ManageSettings,
        ] {
            assert!(Role::Admin.can(p), "admin should {p:?}");
        }
        for p in [ManageBilling, DeleteOrg, TransferOwnership] {
            assert!(!Role::Admin.can(p), "admin must NOT {p:?}");
        }
    }

    #[test]
    fn owner_can_do_everything() {
        for p in [
            ViewDashboard,
            ViewInvoices,
            ManageBilling,
            ManageKeys,
            ManageTeam,
            ManageSettings,
            DeleteOrg,
            TransferOwnership,
        ] {
            assert!(Role::Owner.can(p));
        }
    }

    #[test]
    fn member_management_prevents_escalation_and_admin_lockout() {
        // Admin manages Users only, never Admins or the Owner (no lockout, no escalation).
        assert!(Role::Admin.can_manage_member(Role::User));
        assert!(!Role::Admin.can_manage_member(Role::Admin));
        assert!(!Role::Admin.can_manage_member(Role::Owner));
        // Admin can only ever grant User; it cannot mint Admins or Owners.
        assert!(Role::Admin.can_assign_role(Role::User));
        assert!(!Role::Admin.can_assign_role(Role::Admin));
        assert!(!Role::Admin.can_assign_role(Role::Owner));
        // Owner manages and assigns anything; User manages/assigns nothing.
        assert!(Role::Owner.can_manage_member(Role::Owner));
        assert!(Role::Owner.can_assign_role(Role::Owner));
        assert!(!Role::User.can_manage_member(Role::User));
        assert!(!Role::User.can_assign_role(Role::User));
    }

    #[test]
    fn role_serdes_lowercase_and_orders_by_privilege() {
        assert_eq!(serde_json::to_string(&Role::Owner).unwrap(), "\"owner\"");
        assert!(Role::Owner < Role::Admin && Role::Admin < Role::User);
        assert_eq!(Role::Admin.as_str(), "admin");
    }
}
