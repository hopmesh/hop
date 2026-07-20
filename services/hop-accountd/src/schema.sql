-- Console account schema. Applied idempotently on startup (init_schema); every statement is
-- CREATE ... IF NOT EXISTS so a fresh DB and an already-migrated DB converge to the same shape.
-- Timestamps are epoch-millis stored as BIGINT (the domain uses u64; the binding casts u64<->i64).
-- Secret tokens (login links, session ids, invites) are stored ONLY as their SHA-256 hash, keyed by
-- that hash; the raw value never reaches this table (see session.rs / store.rs).

CREATE TABLE IF NOT EXISTS users (
  id             TEXT PRIMARY KEY,
  email          TEXT NOT NULL UNIQUE,      -- normalized (trimmed, lowercased); the account identity
  password_hash  TEXT NOT NULL DEFAULT '',  -- argon2 PHC for the optional password fallback; empty = passwordless
  email_verified BOOLEAN NOT NULL DEFAULT FALSE,
  created_ms     BIGINT NOT NULL
);

-- An org IS a billing tenant: tenant_hex is the 16-byte TenantId (hex) used fleet-wide.
CREATE TABLE IF NOT EXISTS orgs (
  id              TEXT PRIMARY KEY,
  name            TEXT NOT NULL,
  tenant_hex      TEXT NOT NULL UNIQUE,
  stripe_customer TEXT,                      -- set once signup creates the Stripe customer
  carriage_pubkey TEXT,                      -- the tenant's carriage-stamp signing pubkey (hex), set on first key issue
  otlp_endpoint   TEXT,                      -- the tenant's managed-OTLP forwarding endpoint, set when configured
  plan            TEXT,                      -- durable entitlement: plan ('developer'|'usage'|'scale'), set from the Stripe webhook
  subscription_status TEXT,                  -- durable entitlement: Stripe subscription status, set from the Stripe webhook
  created_ms      BIGINT NOT NULL
);
-- Migration for already-provisioned DBs (the CREATE TABLE above already carries these on a fresh DB;
-- ADD COLUMN IF NOT EXISTS makes both paths converge, idempotent on every boot).
ALTER TABLE orgs ADD COLUMN IF NOT EXISTS plan TEXT;
ALTER TABLE orgs ADD COLUMN IF NOT EXISTS subscription_status TEXT;

CREATE TABLE IF NOT EXISTS memberships (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  org_id  TEXT NOT NULL REFERENCES orgs(id)  ON DELETE CASCADE,
  role    TEXT NOT NULL,                      -- 'owner' | 'admin' | 'user'
  PRIMARY KEY (user_id, org_id)
);
CREATE INDEX IF NOT EXISTS idx_memberships_org ON memberships(org_id);

CREATE TABLE IF NOT EXISTS invites (
  token_hash TEXT PRIMARY KEY,               -- SHA-256 of the emailed invite secret
  org_id     TEXT NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
  email      TEXT NOT NULL,
  role       TEXT NOT NULL,
  invited_by TEXT NOT NULL,
  expires_ms BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_invites_org_email ON invites(org_id, email);

CREATE TABLE IF NOT EXISTS login_tokens (
  token_hash TEXT PRIMARY KEY,               -- SHA-256 of the emailed magic-link secret
  email      TEXT NOT NULL,
  created_ms BIGINT NOT NULL,
  expires_ms BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_login_tokens_expires ON login_tokens(expires_ms);

CREATE TABLE IF NOT EXISTS sessions (
  id_hash    TEXT PRIMARY KEY,               -- SHA-256 of the raw session id (the cookie value)
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_ms BIGINT NOT NULL,
  expires_ms BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_ms);
