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
use crate::domain::{Invite, Membership, Permission, Role};
use crate::email::{invite_email, invite_link_url, EmailSender};
use crate::store::{Store, StoreError};

/// How long a team invite is valid.
pub const INVITE_TTL_MS: u64 = 7 * 24 * 60 * 60 * 1000;

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

/// POST /console/team/invite {tenant,email,role}. Invite someone by email (Resend link). ManageTeam,
/// and can_assign_role bounds the invited role (an Admin can only invite Users). A re-invite replaces
/// any pending invite for the same email with a fresh token.
#[allow(clippy::too_many_arguments)]
pub fn handle_invite(
    store: &dyn Store,
    sender: &dyn EmailSender,
    console_base: &str,
    cookie: Option<&str>,
    body: &str,
    now_ms: u64,
) -> AuthResponse {
    let Some(tenant) = json_field(body, "tenant") else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    let (Some(email_raw), Some(role_str)) = (json_field(body, "email"), json_field(body, "role"))
    else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    let Some(role) = Role::parse(&role_str) else {
        return AuthResponse::json(400, r#"{"error":"invalid_role"}"#);
    };
    let email = crate::session::normalize_email(&email_raw);
    if !crate::session::is_valid_email(&email) {
        return AuthResponse::json(400, r#"{"error":"invalid_email"}"#);
    }
    let (user, org) = match authorize_tenant(store, cookie, &tenant, Permission::ManageTeam, now_ms)
    {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    let Some(caller) = caller_role(store, &user.id, &org.id) else {
        return AuthResponse::json(500, r#"{"error":"internal"}"#);
    };
    // An Admin cannot invite an Admin/Owner (no privilege escalation via invitation).
    if !caller.can_assign_role(role) {
        return AuthResponse::json(403, r#"{"error":"forbidden"}"#);
    }
    // A fresh invite replaces any pending one for this email (a new token supersedes the old).
    let _ = store.delete_invite(&org.id, &email);
    let raw = crate::auth::generate_token();
    let invite = Invite {
        org_id: org.id.clone(),
        email: email.clone(),
        role,
        token_hash: crate::session::hash_token(&raw),
        invited_by: user.id.clone(),
        expires_ms: now_ms + INVITE_TTL_MS,
    };
    if store.create_invite(&invite).is_err() {
        return AuthResponse::json(500, r#"{"error":"internal"}"#);
    }
    let url = invite_link_url(console_base, &raw);
    let msg = invite_email(&email, &org.name, &user.email, &url);
    if sender.send(&msg).is_err() {
        // The invite row persists; the admin can re-invite to resend. Surface the failure.
        return AuthResponse::json(502, r#"{"error":"email_failed"}"#);
    }
    AuthResponse::json(200, r#"{"ok":true}"#)
}

/// POST /console/team/accept {token}. The signed-in invitee joins the workspace the invite named. The
/// invite must be unexpired and issued to THIS user's email (so a leaked token can't add a different
/// account). Idempotent: already-a-member just clears the invite.
pub fn handle_accept(
    store: &dyn Store,
    cookie: Option<&str>,
    body: &str,
    now_ms: u64,
) -> AuthResponse {
    let Some(token) = json_field(body, "token") else {
        return AuthResponse::json(400, r#"{"error":"bad_request"}"#);
    };
    let raw = match crate::auth_api::session_from_cookie_header(cookie) {
        Some(r) => r,
        None => return AuthResponse::json(401, r#"{"error":"unauthenticated"}"#),
    };
    let user = match crate::session::validate_session(store, &raw, now_ms) {
        Ok(Some(u)) => u,
        _ => return AuthResponse::json(401, r#"{"error":"unauthenticated"}"#),
    };
    let invite = match store.invite_by_token_hash(&crate::session::hash_token(&token)) {
        Ok(Some(i)) => i,
        Ok(None) => return AuthResponse::json(410, r#"{"error":"invite_invalid"}"#),
        Err(_) => return AuthResponse::json(500, r#"{"error":"internal"}"#),
    };
    if now_ms >= invite.expires_ms {
        let _ = store.delete_invite(&invite.org_id, &invite.email);
        return AuthResponse::json(410, r#"{"error":"invite_expired"}"#);
    }
    // The invite is for a specific email; only that account may accept it.
    if crate::session::normalize_email(&user.email) != invite.email {
        return AuthResponse::json(403, r#"{"error":"wrong_account"}"#);
    }
    match store.add_membership(&Membership {
        user_id: user.id.clone(),
        org_id: invite.org_id.clone(),
        role: invite.role,
    }) {
        // Already a member: the invite is spent, treat as success (idempotent).
        Ok(()) | Err(StoreError::Conflict(_)) => {}
        Err(_) => return AuthResponse::json(500, r#"{"error":"internal"}"#),
    }
    let _ = store.delete_invite(&invite.org_id, &invite.email);
    let tenant = store
        .org_by_id(&invite.org_id)
        .ok()
        .flatten()
        .map(|o| o.tenant_hex)
        .unwrap_or_default();
    AuthResponse::json(
        200,
        &format!(
            r#"{{"ok":true,"tenant":{}}}"#,
            serde_json::Value::String(tenant)
        ),
    )
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

    struct FakeSender(std::sync::Mutex<Option<crate::email::OutboundEmail>>);
    impl EmailSender for FakeSender {
        fn send(&self, msg: &crate::email::OutboundEmail) -> Result<(), String> {
            *self.0.lock().unwrap() = Some(msg.clone());
            Ok(())
        }
    }
    fn token_from(msg: &crate::email::OutboundEmail) -> String {
        // the accept URL is {base}/invite#token={raw}
        msg.text
            .split("#token=")
            .nth(1)
            .unwrap()
            .split_whitespace()
            .next()
            .unwrap()
            .to_string()
    }

    #[test]
    fn invite_then_accept_joins_the_workspace() {
        let (s, owner_c, tenant, _oid) = org_with_owner();
        let sender = FakeSender(std::sync::Mutex::new(None));
        let base = "https://dashboard.hopme.sh";
        // owner invites a new person as a User
        let body = format!(r#"{{"tenant":"{tenant}","email":"New@X.co","role":"user"}}"#);
        assert_eq!(
            handle_invite(&s, &sender, base, Some(&owner_c), &body, T0).status,
            200
        );
        let msg = sender.0.lock().unwrap().clone().unwrap();
        assert!(msg.to == "new@x.co" && msg.subject.contains("workspace"));
        let token = token_from(&msg);
        // the invitee signs in with the invited email, then accepts
        let invitee = login_or_create(&s, "new@x.co", T0).unwrap();
        let ic = {
            let c = set_cookie(&invitee.session_raw, 3600);
            let raw = c.split(['=', ';']).nth(1).unwrap().to_string();
            format!("__Host-hop_session={raw}")
        };
        let abody = format!(r#"{{"token":"{token}"}}"#);
        let r = handle_accept(&s, Some(&ic), &abody, T0);
        assert_eq!(r.status, 200);
        assert!(r.body.contains(&tenant));
        let org = s.org_by_tenant(&tenant).unwrap().unwrap();
        assert_eq!(
            s.membership(&invitee.user.id, &org.id)
                .unwrap()
                .unwrap()
                .role,
            Role::User
        );
        // the invite is spent
        assert!(s
            .invite_by_token_hash(&crate::session::hash_token(&token))
            .unwrap()
            .is_none());
    }

    #[test]
    fn admin_cannot_invite_an_admin_and_wrong_account_cannot_accept() {
        let (s, _oc, tenant, _oid) = org_with_owner();
        let (_admin_uid, admin_c) = add(&s, &tenant, "admin@x.co", Role::Admin);
        let sender = FakeSender(std::sync::Mutex::new(None));
        // an Admin inviting an Admin is refused
        let body = format!(r#"{{"tenant":"{tenant}","email":"x@x.co","role":"admin"}}"#);
        assert_eq!(
            handle_invite(&s, &sender, "https://d", Some(&admin_c), &body, T0).status,
            403
        );
        // owner invites x@x.co as user; a DIFFERENT signed-in account cannot accept it
        let (_owner2, owner_c, _t2, _o2) = org_with_owner();
        let _ = owner_c;
        let sender2 = FakeSender(std::sync::Mutex::new(None));
        let ib = format!(r#"{{"tenant":"{tenant}","email":"x@x.co","role":"user"}}"#);
        // re-authorize as the real owner of `tenant`
        let owner = s.user_by_email("owner@x.co").unwrap().unwrap();
        let osess = crate::session::login_or_create(&s, &owner.email, T0).unwrap();
        let oc = {
            let c = set_cookie(&osess.session_raw, 3600);
            format!("__Host-hop_session={}", c.split(['=', ';']).nth(1).unwrap())
        };
        assert_eq!(
            handle_invite(&s, &sender2, "https://d", Some(&oc), &ib, T0).status,
            200
        );
        let token = token_from(&sender2.0.lock().unwrap().clone().unwrap());
        // a different account (wrong email) tries to accept -> 403
        let (_uid, wrong_c) = add(&s, &tenant, "someoneelse@x.co", Role::User);
        let abody = format!(r#"{{"token":"{token}"}}"#);
        assert_eq!(handle_accept(&s, Some(&wrong_c), &abody, T0).status, 403);
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
