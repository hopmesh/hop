//! The Postgres [`Store`] implementation (Cloud SQL). Same contract as [`crate::store::MemStore`], so
//! the auth + domain logic is unchanged; only the backing store differs. Sync `postgres` client +
//! an r2d2 pool keep the std-thread, no-tokio server style (the client's internal runtime is an impl
//! detail). Timestamps are u64 epoch-millis stored as BIGINT (cast u64<->i64). Every secret is keyed
//! by its SHA-256 hash; raw tokens never reach this layer.
//!
//! `NoTls` is intentional: in production the Cloud SQL Auth Proxy (or a private-IP sidecar) terminates
//! TLS, so the app speaks plaintext to `127.0.0.1`. Never point this at a public Postgres over NoTls.

use crate::domain::{Invite, Membership, Org, Role, User};
use crate::session::{LoginToken, Session};
use crate::store::{Store, StoreError, StoreResult};
use postgres::{NoTls, Row};
use r2d2_postgres::PostgresConnectionManager;

type Mgr = PostgresConnectionManager<NoTls>;
type Conn = r2d2::PooledConnection<Mgr>;

const SCHEMA: &str = include_str!("schema.sql");

fn be<E: std::fmt::Display>(e: E) -> StoreError {
    StoreError::Backend(e.to_string())
}

/// A pooled Postgres-backed [`Store`].
pub struct PgStore {
    pool: r2d2::Pool<Mgr>,
}

impl PgStore {
    /// Connect (pooling) to `database_url` and apply the schema idempotently. `database_url` is a
    /// libpq/URI connection string, e.g. `postgres://user:pass@127.0.0.1:5432/hop_console`.
    pub fn connect(database_url: &str) -> StoreResult<PgStore> {
        let cfg = database_url.parse().map_err(be)?;
        let mgr = PostgresConnectionManager::new(cfg, NoTls);
        let pool = r2d2::Pool::builder().build(mgr).map_err(be)?;
        let store = PgStore { pool };
        store.init_schema()?;
        Ok(store)
    }

    /// Apply `schema.sql`. Every statement is `IF NOT EXISTS`, so this is safe to run on every boot.
    pub fn init_schema(&self) -> StoreResult<()> {
        self.conn()?.batch_execute(SCHEMA).map_err(be)
    }

    fn conn(&self) -> StoreResult<Conn> {
        self.pool.get().map_err(be)
    }
}

// ---- row mappers (column order must match the SELECT lists below) ----

const USER_COLS: &str = "id, email, password_hash, email_verified, created_ms";
fn row_user(r: &Row) -> User {
    User {
        id: r.get(0),
        email: r.get(1),
        password_hash: r.get(2),
        email_verified: r.get(3),
        created_ms: r.get::<_, i64>(4) as u64,
    }
}

const ORG_COLS: &str = "id, name, tenant_hex, stripe_customer, created_ms";
fn row_org(r: &Row) -> Org {
    Org {
        id: r.get(0),
        name: r.get(1),
        tenant_hex: r.get(2),
        stripe_customer: r.get(3),
        created_ms: r.get::<_, i64>(4) as u64,
    }
}

fn row_membership(r: &Row) -> Membership {
    Membership {
        user_id: r.get(0),
        org_id: r.get(1),
        role: Role::parse(&r.get::<_, String>(2)).unwrap_or(Role::User),
    }
}

impl Store for PgStore {
    fn create_user(&self, u: &User) -> StoreResult<()> {
        let created = u.created_ms as i64;
        let n = self
            .conn()?
            .execute(
                "INSERT INTO users (id, email, password_hash, email_verified, created_ms) \
                 VALUES ($1,$2,$3,$4,$5) ON CONFLICT (email) DO NOTHING",
                &[
                    &u.id,
                    &u.email,
                    &u.password_hash,
                    &u.email_verified,
                    &created,
                ],
            )
            .map_err(be)?;
        if n == 0 {
            return Err(StoreError::Conflict(format!("email {} exists", u.email)));
        }
        Ok(())
    }
    fn user_by_email(&self, email: &str) -> StoreResult<Option<User>> {
        let row = self
            .conn()?
            .query_opt(
                &format!("SELECT {USER_COLS} FROM users WHERE email=$1"),
                &[&email],
            )
            .map_err(be)?;
        Ok(row.as_ref().map(row_user))
    }
    fn user_by_id(&self, id: &str) -> StoreResult<Option<User>> {
        let row = self
            .conn()?
            .query_opt(
                &format!("SELECT {USER_COLS} FROM users WHERE id=$1"),
                &[&id],
            )
            .map_err(be)?;
        Ok(row.as_ref().map(row_user))
    }
    fn mark_email_verified(&self, user_id: &str) -> StoreResult<()> {
        let n = self
            .conn()?
            .execute(
                "UPDATE users SET email_verified=TRUE WHERE id=$1",
                &[&user_id],
            )
            .map_err(be)?;
        if n == 0 {
            return Err(StoreError::NotFound);
        }
        Ok(())
    }

    fn create_org(&self, o: &Org) -> StoreResult<()> {
        let created = o.created_ms as i64;
        let n = self
            .conn()?
            .execute(
                "INSERT INTO orgs (id, name, tenant_hex, stripe_customer, created_ms) \
                 VALUES ($1,$2,$3,$4,$5) ON CONFLICT (tenant_hex) DO NOTHING",
                &[&o.id, &o.name, &o.tenant_hex, &o.stripe_customer, &created],
            )
            .map_err(be)?;
        if n == 0 {
            return Err(StoreError::Conflict(format!(
                "tenant {} exists",
                o.tenant_hex
            )));
        }
        Ok(())
    }
    fn org_by_id(&self, id: &str) -> StoreResult<Option<Org>> {
        let row = self
            .conn()?
            .query_opt(&format!("SELECT {ORG_COLS} FROM orgs WHERE id=$1"), &[&id])
            .map_err(be)?;
        Ok(row.as_ref().map(row_org))
    }
    fn org_by_tenant(&self, tenant_hex: &str) -> StoreResult<Option<Org>> {
        let row = self
            .conn()?
            .query_opt(
                &format!("SELECT {ORG_COLS} FROM orgs WHERE tenant_hex=$1"),
                &[&tenant_hex],
            )
            .map_err(be)?;
        Ok(row.as_ref().map(row_org))
    }
    fn set_org_stripe_customer(&self, org_id: &str, customer: &str) -> StoreResult<()> {
        let n = self
            .conn()?
            .execute(
                "UPDATE orgs SET stripe_customer=$2 WHERE id=$1",
                &[&org_id, &customer],
            )
            .map_err(be)?;
        if n == 0 {
            return Err(StoreError::NotFound);
        }
        Ok(())
    }

    fn add_membership(&self, m: &Membership) -> StoreResult<()> {
        let n = self
            .conn()?
            .execute(
                "INSERT INTO memberships (user_id, org_id, role) VALUES ($1,$2,$3) \
                 ON CONFLICT (user_id, org_id) DO NOTHING",
                &[&m.user_id, &m.org_id, &m.role.as_str()],
            )
            .map_err(be)?;
        if n == 0 {
            return Err(StoreError::Conflict("membership exists".into()));
        }
        Ok(())
    }
    fn membership(&self, user_id: &str, org_id: &str) -> StoreResult<Option<Membership>> {
        let row = self
            .conn()?
            .query_opt(
                "SELECT user_id, org_id, role FROM memberships WHERE user_id=$1 AND org_id=$2",
                &[&user_id, &org_id],
            )
            .map_err(be)?;
        Ok(row.as_ref().map(row_membership))
    }
    fn members_of_org(&self, org_id: &str) -> StoreResult<Vec<Membership>> {
        let rows = self
            .conn()?
            .query(
                "SELECT user_id, org_id, role FROM memberships WHERE org_id=$1",
                &[&org_id],
            )
            .map_err(be)?;
        Ok(rows.iter().map(row_membership).collect())
    }
    fn set_role(&self, user_id: &str, org_id: &str, role: Role) -> StoreResult<()> {
        let n = self
            .conn()?
            .execute(
                "UPDATE memberships SET role=$3 WHERE user_id=$1 AND org_id=$2",
                &[&user_id, &org_id, &role.as_str()],
            )
            .map_err(be)?;
        if n == 0 {
            return Err(StoreError::NotFound);
        }
        Ok(())
    }
    fn remove_membership(&self, user_id: &str, org_id: &str) -> StoreResult<()> {
        self.conn()?
            .execute(
                "DELETE FROM memberships WHERE user_id=$1 AND org_id=$2",
                &[&user_id, &org_id],
            )
            .map_err(be)?;
        Ok(())
    }

    fn create_invite(&self, i: &Invite) -> StoreResult<()> {
        let expires = i.expires_ms as i64;
        self.conn()?
            .execute(
                "INSERT INTO invites (token_hash, org_id, email, role, invited_by, expires_ms) \
                 VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT (token_hash) DO NOTHING",
                &[
                    &i.token_hash,
                    &i.org_id,
                    &i.email,
                    &i.role.as_str(),
                    &i.invited_by,
                    &expires,
                ],
            )
            .map_err(be)?;
        Ok(())
    }
    fn invite_by_token_hash(&self, token_hash: &str) -> StoreResult<Option<Invite>> {
        let row = self
            .conn()?
            .query_opt(
                "SELECT token_hash, org_id, email, role, invited_by, expires_ms \
                 FROM invites WHERE token_hash=$1",
                &[&token_hash],
            )
            .map_err(be)?;
        Ok(row.map(|r| Invite {
            token_hash: r.get(0),
            org_id: r.get(1),
            email: r.get(2),
            role: Role::parse(&r.get::<_, String>(3)).unwrap_or(Role::User),
            invited_by: r.get(4),
            expires_ms: r.get::<_, i64>(5) as u64,
        }))
    }
    fn delete_invite(&self, org_id: &str, email: &str) -> StoreResult<()> {
        self.conn()?
            .execute(
                "DELETE FROM invites WHERE org_id=$1 AND email=$2",
                &[&org_id, &email],
            )
            .map_err(be)?;
        Ok(())
    }

    fn create_login_token(&self, t: &LoginToken) -> StoreResult<()> {
        let (created, expires) = (t.created_ms as i64, t.expires_ms as i64);
        self.conn()?
            .execute(
                "INSERT INTO login_tokens (token_hash, email, created_ms, expires_ms) \
                 VALUES ($1,$2,$3,$4) ON CONFLICT (token_hash) DO NOTHING",
                &[&t.token_hash, &t.email, &created, &expires],
            )
            .map_err(be)?;
        Ok(())
    }
    fn take_login_token(&self, token_hash: &str) -> StoreResult<Option<LoginToken>> {
        // Atomic single-use: delete and return in one statement.
        let row = self
            .conn()?
            .query_opt(
                "DELETE FROM login_tokens WHERE token_hash=$1 \
                 RETURNING token_hash, email, created_ms, expires_ms",
                &[&token_hash],
            )
            .map_err(be)?;
        Ok(row.map(|r| LoginToken {
            token_hash: r.get(0),
            email: r.get(1),
            created_ms: r.get::<_, i64>(2) as u64,
            expires_ms: r.get::<_, i64>(3) as u64,
        }))
    }

    fn create_session(&self, s: &Session) -> StoreResult<()> {
        let (created, expires) = (s.created_ms as i64, s.expires_ms as i64);
        self.conn()?
            .execute(
                "INSERT INTO sessions (id_hash, user_id, created_ms, expires_ms) \
                 VALUES ($1,$2,$3,$4) ON CONFLICT (id_hash) DO NOTHING",
                &[&s.id_hash, &s.user_id, &created, &expires],
            )
            .map_err(be)?;
        Ok(())
    }
    fn session_by_id_hash(&self, id_hash: &str) -> StoreResult<Option<Session>> {
        let row = self
            .conn()?
            .query_opt(
                "SELECT id_hash, user_id, created_ms, expires_ms FROM sessions WHERE id_hash=$1",
                &[&id_hash],
            )
            .map_err(be)?;
        Ok(row.map(|r| Session {
            id_hash: r.get(0),
            user_id: r.get(1),
            created_ms: r.get::<_, i64>(2) as u64,
            expires_ms: r.get::<_, i64>(3) as u64,
        }))
    }
    fn delete_session(&self, id_hash: &str) -> StoreResult<()> {
        self.conn()?
            .execute("DELETE FROM sessions WHERE id_hash=$1", &[&id_hash])
            .map_err(be)?;
        Ok(())
    }

    fn delete_expired(&self, now_ms: u64) -> StoreResult<u64> {
        let now = now_ms as i64;
        let mut c = self.conn()?;
        let a = c
            .execute("DELETE FROM sessions WHERE expires_ms<=$1", &[&now])
            .map_err(be)?;
        let b = c
            .execute("DELETE FROM login_tokens WHERE expires_ms<=$1", &[&now])
            .map_err(be)?;
        Ok(a + b)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{redeem_login, request_login, validate_session};

    /// Integration test against a REAL Postgres. Self-skips unless `HOP_TEST_DATABASE_URL` points at a
    /// throwaway database (never a prod one, it TRUNCATEs). CI leaves it unset, so it compiles there
    /// but does not run.
    fn test_store() -> Option<PgStore> {
        let url = std::env::var("HOP_TEST_DATABASE_URL").ok()?;
        let s = PgStore::connect(&url).expect("connect HOP_TEST_DATABASE_URL");
        s.conn()
            .unwrap()
            .batch_execute(
                "TRUNCATE sessions, login_tokens, invites, memberships, orgs, users CASCADE",
            )
            .unwrap();
        Some(s)
    }

    #[test]
    fn pg_upholds_the_store_and_passwordless_contract() {
        let Some(s) = test_store() else {
            eprintln!("pg test skipped: set HOP_TEST_DATABASE_URL to run it");
            return;
        };
        // unique email
        let u = User {
            id: "u1".into(),
            email: "a@x.co".into(),
            password_hash: String::new(),
            email_verified: false,
            created_ms: 1,
        };
        s.create_user(&u).unwrap();
        assert!(matches!(
            s.create_user(&User {
                id: "u2".into(),
                ..u.clone()
            }),
            Err(StoreError::Conflict(_))
        ));

        // magic-link create-or-signin against real Postgres
        let link = request_login(&s, "b@x.co", 1000).unwrap();
        let out = redeem_login(&s, &link.raw, 1000).unwrap().unwrap();
        assert!(out.created && out.user.email == "b@x.co");
        assert!(validate_session(&s, &out.session_raw, 2000)
            .unwrap()
            .is_some());
        // single-use link
        assert!(redeem_login(&s, &link.raw, 1000).unwrap().is_none());

        // gc removes only expired
        s.create_session(&Session {
            id_hash: "dead".into(),
            user_id: out.user.id.clone(),
            created_ms: 0,
            expires_ms: 100,
        })
        .unwrap();
        assert!(s.delete_expired(1000).unwrap() >= 1);
        assert!(s.session_by_id_hash("dead").unwrap().is_none());
    }
}
