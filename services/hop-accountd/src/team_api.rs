//! Console team-management endpoints. All are tenant-scoped and gated: viewing + role changes +
//! removal need `ManageTeam` (Owner+Admin), transfer needs `TransferOwnership` (Owner). On top of the
//! permission gate, the domain escalation guards bound every action so an Admin can never manage
//! another Admin/Owner nor grant a role above their own, and the org can never be left without an
//! Owner.
//!
//!   GET  /console/team?tenant=..                 -> {members:[{userId,email,role}]}
//!   POST /console/team/role     {tenant,userId,role}  -> {ok}
//!   POST /console/team/remove   {tenant,userId}       -> {ok}
//!   POST /console/team/transfer {tenant,userId}       -> {ok}   (Owner only)

use crate::auth_api::{authorize_tenant, json_field, AuthResponse};
use crate::domain::{Permission, Role};
use crate::store::Store;

/// The caller's role in `org_id`. They are already a confirmed member (authorize_tenant passed), so a
/// missing membership here is an internal inconsistency, surfaced as `None` and refused fail-closed.
fn caller_role(store: &dyn Store, user_id: &str, org_id: &str) -> Option<Role> {
    store
        .membership(user_id, org_id)
        .ok()
        .flatten()
        .map(|m| m.role)
}

/// GET /console/team?tenant=.. The org roster (Owner/Admin). Each entry resolves the member's email.
pub fn handle_list(
    store: &dyn Store,
    cookie: Option<&str>,
    tenant: &str,
    now_ms: u64,
) -> AuthResponse {
    let (_user, org) = match authorize_tenant(store, cookie, tenant, Permission::ManageTeam, now_ms)
    {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    let members = match store.members_of_org(&org.id) {
        Ok(m) => m,
        Err(_) => return AuthResponse::json(500, r#"{"error":"internal"}"#),
    };
    let mut out = Vec::new();
    for m in members {
        // A membership whose user vanished is skipped rather than failing the whole roster.
        if let Ok(Some(u)) = store.user_by_id(&m.user_id) {
            out.push(serde_json::json!({
                "userId": m.user_id,
                "email": u.email,
                "role": m.role.as_str(),
            }));
        }
    }
    AuthResponse::json(200, &serde_json::json!({ "members": out }).to_string())
}

/// Resolve (caller_role, target current role) for a mutation, or the ready error response: the target
/// must be a member (404 otherwise), and the caller's role must be known.
fn mutation_ctx(
    store: &dyn Store,
    caller_id: &str,
    org_id: &str,
    target_id: &str,
) -> Result<(Role, Role), AuthResponse> {
    let caller = caller_role(store, caller_id, org_id)
        .ok_or_else(|| AuthResponse::json(500, r#"{"error":"internal"}"#))?;
    let target = store
        .membership(target_id, org_id)
        .ok()
        .flatten()
        .map(|m| m.role)
        .ok_or_else(|| AuthResponse::json(404, r#"{"error":"not_a_member"}"#))?;
    Ok((caller, target))
}

/// POST /console/team/role {tenant,userId,role}. Change a member's role. Bounded by can_manage_member
/// (who you may touch) + can_assign_role (what you may grant), and refuses to demote the last Owner.
pub fn handle_set_role(
    store: &dyn Store,
    cookie: Option<&str>,
    body: &str,
    now_ms: u64,
) -> AuthResponse {
    let Some(tenant) = json_field(body, "tenant") else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    let (Some(target_id), Some(role_str)) = (json_field(body, "userId"), json_field(body, "role"))
    else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    let Some(new_role) = Role::parse(&role_str) else {
        return AuthResponse::json(400, r#"{"error":"invalid_role"}"#);
    };
    let (user, org) = match authorize_tenant(store, cookie, &tenant, Permission::ManageTeam, now_ms)
    {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    let (caller, target_role) = match mutation_ctx(store, &user.id, &org.id, &target_id) {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    if !caller.can_manage_member(target_role) || !caller.can_assign_role(new_role) {
        return AuthResponse::json(403, r#"{"error":"forbidden"}"#);
    }
    // The last-Owner floor is enforced ATOMICALLY in the store (try_set_role), so two concurrent
    // demotions cannot both pass a check-then-write and strand the org ownerless. Ok(false) = the
    // floor blocked it (would remove the last Owner).
    match store.try_set_role(&target_id, &org.id, new_role) {
        Ok(true) => AuthResponse::json(200, r#"{"ok":true}"#),
        Ok(false) => AuthResponse::json(409, r#"{"error":"last_owner"}"#),
        Err(_) => AuthResponse::json(500, r#"{"error":"internal"}"#),
    }
}

/// POST /console/team/remove {tenant,userId}. Remove a member. Bounded by can_manage_member and the
/// last-Owner guard.
pub fn handle_remove(
    store: &dyn Store,
    cookie: Option<&str>,
    body: &str,
    now_ms: u64,
) -> AuthResponse {
    let Some(tenant) = json_field(body, "tenant") else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    let Some(target_id) = json_field(body, "userId") else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    let (user, org) = match authorize_tenant(store, cookie, &tenant, Permission::ManageTeam, now_ms)
    {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    let (caller, target_role) = match mutation_ctx(store, &user.id, &org.id, &target_id) {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    if !caller.can_manage_member(target_role) {
        return AuthResponse::json(403, r#"{"error":"forbidden"}"#);
    }
    // Atomic last-Owner floor (see try_set_role): Ok(false) = removing this member would strand the
    // org ownerless, refused.
    match store.try_remove_member(&target_id, &org.id) {
        Ok(true) => AuthResponse::json(200, r#"{"ok":true}"#),
        Ok(false) => AuthResponse::json(409, r#"{"error":"last_owner"}"#),
        Err(_) => AuthResponse::json(500, r#"{"error":"internal"}"#),
    }
}

/// POST /console/team/transfer {tenant,userId}. Hand the Owner role to an existing member and step the
/// current Owner down to Admin. Owner-only (TransferOwnership).
pub fn handle_transfer(
    store: &dyn Store,
    cookie: Option<&str>,
    body: &str,
    now_ms: u64,
) -> AuthResponse {
    let Some(tenant) = json_field(body, "tenant") else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    let Some(target_id) = json_field(body, "userId") else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    let (user, org) = match authorize_tenant(
        store,
        cookie,
        &tenant,
        Permission::TransferOwnership,
        now_ms,
    ) {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    if target_id == user.id {
        return AuthResponse::json(400, r#"{"error":"already_owner"}"#);
    }
    // The target must already be a member.
    if store
        .membership(&target_id, &org.id)
        .ok()
        .flatten()
        .is_none()
    {
        return AuthResponse::json(404, r#"{"error":"not_a_member"}"#);
    }
    // Promote the target (now two Owners), then step the caller down through the ATOMIC guarded path.
    // If a concurrent removal left the caller the sole Owner, the guarded step-down returns Ok(false)
    // and the caller stays Owner: the org always keeps at least one Owner, never zero.
    if store.set_role(&target_id, &org.id, Role::Owner).is_err() {
        return AuthResponse::json(500, r#"{"error":"internal"}"#);
    }
    match store.try_set_role(&user.id, &org.id, Role::Admin) {
        Ok(_) => AuthResponse::json(200, r#"{"ok":true}"#),
        Err(_) => AuthResponse::json(500, r#"{"error":"internal"}"#),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::Membership;
    use crate::orgs::ensure_personal_workspace;
    use crate::session::{login_or_create, set_cookie};
    use crate::store::MemStore;

    const T0: u64 = 1_000_000;

    /// An owner + the org, plus a helper to add members and get their cookie.
    fn org_with_owner() -> (MemStore, String, String, String) {
        let s = MemStore::new();
        let out = login_or_create(&s, "owner@x.co", T0).unwrap();
        let c = set_cookie(&out.session_raw, 3600);
        let raw = c.split(['=', ';']).nth(1).unwrap().to_string();
        let cookie = format!("__Host-hop_session={raw}");
        let org = ensure_personal_workspace(&s, &out.user.id, "owner@x.co", T0).unwrap();
        (s, cookie, org.tenant_hex, out.user.id)
    }

    fn add(s: &MemStore, tenant: &str, email: &str, role: Role) -> (String, String) {
        let m = login_or_create(s, email, T0).unwrap();
        let org = s.org_by_tenant(tenant).unwrap().unwrap();
        s.add_membership(&Membership {
            user_id: m.user.id.clone(),
            org_id: org.id,
            role,
        })
        .unwrap();
        let c = set_cookie(&m.session_raw, 3600);
        let raw = c.split(['=', ';']).nth(1).unwrap().to_string();
        (m.user.id, format!("__Host-hop_session={raw}"))
    }

    #[test]
    fn list_shows_the_roster_for_owner_admin_only() {
        let (s, owner_c, tenant, _oid) = org_with_owner();
        let (_uid, user_c) = add(&s, &tenant, "u@x.co", Role::User);
        let r = handle_list(&s, Some(&owner_c), &tenant, T0);
        assert_eq!(r.status, 200);
        let v: serde_json::Value = serde_json::from_str(&r.body).unwrap();
        assert_eq!(v["members"].as_array().unwrap().len(), 2);
        // a plain User lacks ManageTeam
        assert_eq!(handle_list(&s, Some(&user_c), &tenant, T0).status, 403);
    }

    #[test]
    fn admin_can_manage_a_user_but_not_another_admin() {
        let (s, _owner_c, tenant, _oid) = org_with_owner();
        let (_admin_uid, admin_c) = add(&s, &tenant, "admin@x.co", Role::Admin);
        let (user_uid, _uc) = add(&s, &tenant, "u@x.co", Role::User);
        let (admin2_uid, _a2) = add(&s, &tenant, "admin2@x.co", Role::Admin);
        // admin promotes a User to... Admin? can_assign_role(Admin) is Owner-only -> 403
        let body = format!(r#"{{"tenant":"{tenant}","userId":"{user_uid}","role":"admin"}}"#);
        assert_eq!(handle_set_role(&s, Some(&admin_c), &body, T0).status, 403);
        // admin can't touch another admin
        let body2 = format!(r#"{{"tenant":"{tenant}","userId":"{admin2_uid}","role":"user"}}"#);
        assert_eq!(handle_set_role(&s, Some(&admin_c), &body2, T0).status, 403);
        // admin removing a User is fine
        let rbody = format!(r#"{{"tenant":"{tenant}","userId":"{user_uid}"}}"#);
        assert_eq!(handle_remove(&s, Some(&admin_c), &rbody, T0).status, 200);
    }

    #[test]
    fn cannot_demote_or_remove_the_last_owner() {
        let (s, owner_c, tenant, owner_id) = org_with_owner();
        let demote = format!(r#"{{"tenant":"{tenant}","userId":"{owner_id}","role":"admin"}}"#);
        assert_eq!(handle_set_role(&s, Some(&owner_c), &demote, T0).status, 409);
        let remove = format!(r#"{{"tenant":"{tenant}","userId":"{owner_id}"}}"#);
        assert_eq!(handle_remove(&s, Some(&owner_c), &remove, T0).status, 409);
    }

    #[test]
    fn atomic_owner_floor_tracks_the_count() {
        // With two Owners, demoting one is allowed; demoting the now-sole Owner is refused. This is the
        // primitive the TOCTOU fix relies on (the floor sees the CURRENT owner count, atomically).
        let (s, _c, tenant, owner_a) = org_with_owner();
        let (owner_b, _cb) = add(&s, &tenant, "b@x.co", Role::Owner);
        let org = s.org_by_tenant(&tenant).unwrap().unwrap();
        assert!(s.try_set_role(&owner_b, &org.id, Role::Admin).unwrap()); // 2 owners -> ok
        assert!(!s.try_set_role(&owner_a, &org.id, Role::Admin).unwrap()); // last owner -> refused
        assert_eq!(
            s.membership(&owner_a, &org.id).unwrap().unwrap().role,
            Role::Owner
        );
        assert!(!s.try_remove_member(&owner_a, &org.id).unwrap()); // still the last owner
                                                                   // a non-member -> NotFound, never a silent success
        assert!(s.try_set_role("ghost", &org.id, Role::User).is_err());
    }

    #[test]
    fn transfer_promotes_target_and_steps_owner_down() {
        let (s, owner_c, tenant, owner_id) = org_with_owner();
        let (new_owner, _c) = add(&s, &tenant, "next@x.co", Role::Admin);
        let body = format!(r#"{{"tenant":"{tenant}","userId":"{new_owner}"}}"#);
        assert_eq!(handle_transfer(&s, Some(&owner_c), &body, T0).status, 200);
        let org = s.org_by_tenant(&tenant).unwrap().unwrap();
        assert_eq!(
            s.membership(&new_owner, &org.id).unwrap().unwrap().role,
            Role::Owner
        );
        assert_eq!(
            s.membership(&owner_id, &org.id).unwrap().unwrap().role,
            Role::Admin
        );
        // a non-Owner cannot transfer
        let (_admin_uid, admin_c) = add(&s, &tenant, "adm@x.co", Role::Admin);
        assert_eq!(handle_transfer(&s, Some(&admin_c), &body, T0).status, 403);
    }
}
