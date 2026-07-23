"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import * as api from "@/lib/api";
import type { Overview, Workspace, Role } from "@/lib/api";
import { generateCarriageKeypair, ed25519Supported, downloadText } from "@/lib/keygen";

type View = "overview" | "usage" | "keys" | "team" | "billing" | "observability" | "settings";

// hide-not-lock: which views each role sees. A plain User only ever sees the overview + usage; the
// management surfaces are Owner/Admin (matching the backend RBAC), and billing ACTIONS are Owner-only.
function navFor(role: Role): { view: View; label: string; icon: string }[] {
  const all: { view: View; label: string; icon: string; roles: Role[] }[] = [
    { view: "overview", label: "Overview", icon: "fa-gauge-high", roles: ["owner", "admin", "user"] },
    { view: "usage", label: "Usage", icon: "fa-wave-square", roles: ["owner", "admin"] },
    { view: "observability", label: "Observability", icon: "fa-satellite-dish", roles: ["owner", "admin"] },
    { view: "keys", label: "Keys", icon: "fa-key", roles: ["owner", "admin"] },
    { view: "team", label: "Team", icon: "fa-users", roles: ["owner", "admin"] },
    { view: "billing", label: "Billing", icon: "fa-credit-card", roles: ["owner", "admin"] },
    { view: "settings", label: "Settings", icon: "fa-sliders", roles: ["owner", "admin"] },
  ];
  return all.filter((n) => n.roles.includes(role));
}

// The last-selected workspace persists across reloads, keyed by tenant so it survives even as the
// workspace list changes (a stored tenant that no longer exists just falls back to the first).
const WS_KEY = "hop-console-ws";

export default function Dashboard() {
  const [data, setData] = useState<Overview | null | "loading">("loading");
  const [wsTenant, setWsTenant] = useState<string | null>(null);
  const [view, setView] = useState<View>("overview");

  // Load (or reload) the workspace list, then select `prefer` if given, else the persisted choice,
  // else the first. Used on mount and after creating a workspace (to pull the new one in and switch).
  const load = useCallback((prefer?: string) => {
    api.overview().then(
      (d) => {
        setData(d);
        let stored: string | null = prefer ?? null;
        if (!stored) {
          try {
            stored = localStorage.getItem(WS_KEY);
          } catch {
            stored = null;
          }
        }
        const pick = d.workspaces.find((w) => w.tenant === stored) ?? d.workspaces[0];
        if (pick) {
          setWsTenant(pick.tenant);
          try {
            localStorage.setItem(WS_KEY, pick.tenant);
          } catch {
            /* private mode: selection just won't persist */
          }
        }
      },
      () => window.location.replace("/"),
    );
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const switchTo = useCallback((tenant: string) => {
    setWsTenant(tenant);
    try {
      localStorage.setItem(WS_KEY, tenant);
    } catch {
      /* ignore */
    }
    setView("overview");
  }, []);

  if (data === "loading" || data === null) {
    return (
      <main className="auth-wrap">
        <div className="sent">
          <div className="ring" aria-hidden="true">
            <i className="fa-solid fa-circle-notch spin" />
          </div>
        </div>
      </main>
    );
  }

  const ws = data.workspaces.find((w) => w.tenant === wsTenant) ?? data.workspaces[0];
  if (!ws) {
    return (
      <main className="auth-wrap">
        <div className="auth-card">
          <div className="panel">
            <p className="hint">No workspace yet. Sign out and back in to provision one.</p>
            <button className="btn btn-ghost" onClick={() => api.logout().then(() => location.replace("/"))}>
              Sign out
            </button>
          </div>
        </div>
      </main>
    );
  }
  const nav = navFor(ws.role);
  const active = nav.some((n) => n.view === view) ? view : "overview";

  return (
    <div className="dash">
      <aside className="side">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img className="side-mark" src="/hop-mark.svg" alt="Hop" width={92} height={54} />
        <WorkspaceSwitcher
          workspaces={data.workspaces}
          current={ws}
          onSwitch={switchTo}
          onCreated={(w) => load(w.tenant)}
        />
        <nav className="nav">
          {nav.map((n) => (
            <button
              key={n.view}
              className={`nav-item${active === n.view ? " active" : ""}`}
              onClick={() => setView(n.view)}
            >
              <i className={`fa-solid ${n.icon}`} aria-hidden="true" /> {n.label}
            </button>
          ))}
        </nav>
        <div className="side-foot">
          <span className="who" title={data.user.email}>
            {data.user.email}
          </span>
          <button className="linkish" onClick={() => api.logout().then(() => location.replace("/"))}>
            Sign out
          </button>
        </div>
      </aside>
      <main className="content">
        <ViewBody view={active} ws={ws} />
      </main>
    </div>
  );
}

// The workspace picker + org creation, in the sidebar. Click to open a menu of every workspace the
// user belongs to (switch), or create a new one inline. Joining an existing org happens through the
// invite link a teammate sends (the /invite page); inviting others is in the Team view.
function WorkspaceSwitcher({
  workspaces,
  current,
  onSwitch,
  onCreated,
}: {
  workspaces: Workspace[];
  current: Workspace;
  onSwitch: (tenant: string) => void;
  onCreated: (w: Workspace) => void;
}) {
  const [open, setOpen] = useState(false);
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const boxRef = useRef<HTMLDivElement>(null);

  // Close on an outside click or Escape, the usual menu affordances.
  useEffect(() => {
    if (!open) return;
    const onDoc = (e: MouseEvent) => {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) {
        setOpen(false);
        setCreating(false);
      }
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        setOpen(false);
        setCreating(false);
      }
    };
    document.addEventListener("mousedown", onDoc);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDoc);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  async function create(e: React.FormEvent) {
    e.preventDefault();
    const n = name.trim();
    if (!n || busy) return;
    setBusy(true);
    setError(null);
    try {
      const w = await api.createOrg(n);
      setName("");
      setCreating(false);
      setOpen(false);
      onCreated(w);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not create the workspace.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="ws-switch-box" ref={boxRef}>
      <button
        type="button"
        className="ws-switch-btn"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
      >
        <span className="ws-switch-name">{current.name}</span>
        <i className="fa-solid fa-chevron-down ws-switch-caret" aria-hidden="true" />
      </button>

      {open && (
        <div className="ws-menu" role="menu">
          <div className="ws-menu-label">Workspaces</div>
          {workspaces.map((w) => (
            <button
              key={w.tenant}
              type="button"
              role="menuitem"
              className={`ws-menu-item${w.tenant === current.tenant ? " current" : ""}`}
              onClick={() => {
                onSwitch(w.tenant);
                setOpen(false);
              }}
            >
              <span className="ws-menu-item-name">{w.name}</span>
              <span className="ws-menu-item-role">{w.role}</span>
              {w.tenant === current.tenant && (
                <i className="fa-solid fa-check ws-menu-check" aria-hidden="true" />
              )}
            </button>
          ))}

          <div className="ws-menu-sep" />

          {creating ? (
            <form className="ws-create" onSubmit={create}>
              <input
                className="ws-create-input"
                type="text"
                value={name}
                onChange={(e) => setName(e.target.value)}
                placeholder="Organization name"
                maxLength={60}
                autoFocus
                aria-label="New organization name"
              />
              <div className="ws-create-row">
                <button type="submit" className="btn btn-primary btn-sm" disabled={busy || !name.trim()}>
                  {busy ? "Creating…" : "Create"}
                </button>
                <button
                  type="button"
                  className="btn btn-ghost btn-sm"
                  onClick={() => {
                    setCreating(false);
                    setError(null);
                  }}
                >
                  Cancel
                </button>
              </div>
              {error && <div className="ws-create-err">{error}</div>}
            </form>
          ) : (
            <button
              type="button"
              role="menuitem"
              className="ws-menu-item ws-menu-add"
              onClick={() => setCreating(true)}
            >
              <i className="fa-solid fa-plus" aria-hidden="true" /> Create organization
            </button>
          )}
        </div>
      )}
    </div>
  );
}

function ViewBody({ view, ws }: { view: View; ws: Workspace }) {
  switch (view) {
    case "usage":
      return <UsageView ws={ws} />;
    case "keys":
      return <KeysView ws={ws} />;
    case "team":
      return <TeamView ws={ws} />;
    case "billing":
      return <BillingView ws={ws} />;
    case "observability":
      return <ObservabilityView ws={ws} />;
    case "settings":
      return <SettingsView ws={ws} />;
    default:
      return <OverviewView ws={ws} />;
  }
}

function Header({ title, sub }: { title: string; sub?: string }) {
  return (
    <header className="view-head">
      <h1>{title}</h1>
      {sub && <p>{sub}</p>}
    </header>
  );
}

// --- views ------------------------------------------------------------------

function OverviewView({ ws }: { ws: Workspace }) {
  const [usage, setUsage] = useState<api.Usage | null>(null);
  const [sub, setSub] = useState<api.Subscription | null>(null);
  useEffect(() => {
    if (ws.role !== "user") {
      api.usage(ws.tenant).then(setUsage, () => {});
      api.subscription(ws.tenant).then(setSub, () => {});
    }
  }, [ws.tenant, ws.role]);
  return (
    <>
      <Header title={ws.name} sub={`Workspace ${ws.tenant.slice(0, 8)}… · you are ${ws.role}`} />
      <div className="grid">
        <div className="card">
          <div className="card-k">Plan</div>
          <div className="card-v">{sub ? cap(sub.plan) : "…"}</div>
          <div className="card-s">{sub?.active ? "Active" : "Free tier"}</div>
        </div>
        <div className="card">
          <div className="card-k">Reach · this window</div>
          <div className="card-v">{usage ? fmt(usage.reach.deliveries) : "…"}</div>
          <div className="card-s">
            of {usage ? fmt(usage.reach.included) : "…"} included deliveries
          </div>
        </div>
        <div className="card">
          <div className="card-k">Telemetry · this window</div>
          <div className="card-v">{usage ? fmt(usage.telemetry.events) : "…"}</div>
          <div className="card-s">of {usage ? fmt(usage.telemetry.included) : "…"} included events</div>
        </div>
        <div className="card">
          <div className="card-k">Carriage key</div>
          <div className="card-v">
            <i
              className={`fa-solid ${ws.hasCarriageKey ? "fa-circle-check ok" : "fa-circle-dot warn"}`}
            />
          </div>
          <div className="card-s">{ws.hasCarriageKey ? "Registered" : "Not set. Issue one in Keys"}</div>
        </div>
      </div>
    </>
  );
}

function UsageView({ ws }: { ws: Workspace }) {
  const [u, setU] = useState<api.Usage | null | "err">(null);
  useEffect(() => {
    api.usage(ws.tenant).then(setU, () => setU("err"));
  }, [ws.tenant]);
  if (u === "err") return <Empty msg="Usage is unavailable right now." />;
  return (
    <>
      <Header
        title="Usage"
        sub={u ? `Last ${u.windowDays} days · updates within ~30 seconds` : "Loading…"}
      />
      {u && (
        <div className="meters">
          <Meter label="Reach" unit="offline deliveries" used={u.reach.deliveries} included={u.reach.included} />
          <Meter label="Telemetry" unit="OTel events" used={u.telemetry.events} included={u.telemetry.included} />
        </div>
      )}
    </>
  );
}

function Meter({ label, unit, used, included }: { label: string; unit: string; used: number; included: number }) {
  const pct = included > 0 ? Math.min(100, (used / included) * 100) : 0;
  const over = used > included;
  return (
    <div className="meter">
      <div className="meter-top">
        <span className="meter-label">{label}</span>
        <span className="meter-num">
          {fmt(used)} <span className="dim">/ {fmt(included)} {unit}</span>
        </span>
      </div>
      <div className="bar">
        <div className={`fill${over ? " over" : ""}`} style={{ width: `${pct}%` }} />
      </div>
      <div className="meter-s">{over ? "Over the included amount, metered from here" : "Within the included amount"}</div>
    </div>
  );
}

function KeysView({ ws }: { ws: Workspace }) {
  const [busy, setBusy] = useState(false);
  const [minted, setMinted] = useState<{ pub: string } | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [supported, setSupported] = useState(true);
  useEffect(() => {
    ed25519Supported().then(setSupported);
  }, []);

  async function generate() {
    setErr(null);
    setBusy(true);
    try {
      const { pubkeyHex, privatePem } = await generateCarriageKeypair();
      downloadText(`hop-carriage-${ws.tenant.slice(0, 8)}.pem`, privatePem);
      await api.registerCarriageKey(ws.tenant, pubkeyHex);
      setMinted({ pub: pubkeyHex });
    } catch (e) {
      setErr(e instanceof Error ? e.message : "Key generation failed.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <Header
        title="Carriage key"
        sub="The Ed25519 key the paid relay fabric verifies your traffic against. Generated in your browser; we only ever store the public half."
      />
      <div className="panel wide">
        <p className="status-line">
          <i className={`fa-solid ${ws.hasCarriageKey || minted ? "fa-circle-check ok" : "fa-circle-dot warn"}`} />{" "}
          {ws.hasCarriageKey || minted ? "A carriage key is registered." : "No carriage key registered yet."}
        </p>
        {minted && (
          <div className="minted">
            <p>
              <strong>Saved.</strong> Your private key just downloaded. Keep it on your own
              infrastructure; we never see it. It won&rsquo;t be shown again.
            </p>
            <code className="pub">{minted.pub}</code>
          </div>
        )}
        {err && <div className="err">{err}</div>}
        {!supported ? (
          <p className="hint">
            This browser can&rsquo;t mint an Ed25519 key. Generate one with your SDK and register the
            public key instead.
          </p>
        ) : (
          <button className="btn btn-primary" onClick={generate} disabled={busy}>
            {busy ? (
              <>
                <i className="fa-solid fa-circle-notch spin" /> Generating…
              </>
            ) : (
              <>
                <i className="fa-solid fa-key" /> {ws.hasCarriageKey ? "Rotate key" : "Generate key"}
              </>
            )}
          </button>
        )}
      </div>
    </>
  );
}

function TeamView({ ws }: { ws: Workspace }) {
  const [members, setMembers] = useState<api.Member[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [invEmail, setInvEmail] = useState("");
  const [invRole, setInvRole] = useState<Role>("user");
  const [invMsg, setInvMsg] = useState<string | null>(null);
  const [inviting, setInviting] = useState(false);
  const load = useCallback(() => {
    api.team(ws.tenant).then((r) => setMembers(r.members), () => setErr("Couldn't load the team."));
  }, [ws.tenant]);
  useEffect(load, [load]);

  async function act(fn: () => Promise<unknown>) {
    setErr(null);
    try {
      await fn();
      load();
    } catch (e) {
      setErr(e instanceof Error ? niceErr(e.message) : "Action failed.");
    }
  }

  async function invite(e: React.FormEvent) {
    e.preventDefault();
    setInvMsg(null);
    setErr(null);
    setInviting(true);
    try {
      await api.inviteMember(ws.tenant, invEmail.trim(), invRole);
      setInvMsg(`Invite sent to ${invEmail.trim()}.`);
      setInvEmail("");
    } catch (e2) {
      setErr(e2 instanceof Error ? niceErr(e2.message) : "Couldn't send the invite.");
    } finally {
      setInviting(false);
    }
  }

  return (
    <>
      <Header title="Team" sub="Who can see and manage this workspace." />
      {err && <div className="err">{err}</div>}
      <div className="panel wide">
        <table className="tbl">
          <thead>
            <tr>
              <th>Member</th>
              <th>Role</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {members?.map((m) => (
              <tr key={m.userId}>
                <td>{m.email}</td>
                <td>
                  {ws.role === "owner" || (ws.role === "admin" && m.role === "user") ? (
                    <select
                      className="role-sel"
                      value={m.role}
                      onChange={(e) => act(() => api.setRole(ws.tenant, m.userId, e.target.value as Role))}
                    >
                      <option value="user">User</option>
                      <option value="admin" disabled={ws.role !== "owner"}>
                        Admin
                      </option>
                      <option value="owner" disabled={ws.role !== "owner"}>
                        Owner
                      </option>
                    </select>
                  ) : (
                    <span className="role-pill">{cap(m.role)}</span>
                  )}
                </td>
                <td className="row-actions">
                  {ws.role === "owner" && m.role !== "owner" && (
                    <button className="linkish" onClick={() => act(() => api.transferOwnership(ws.tenant, m.userId))}>
                      Make owner
                    </button>
                  )}
                  {(ws.role === "owner" || (ws.role === "admin" && m.role === "user")) && (
                    <button className="linkish danger" onClick={() => act(() => api.removeMember(ws.tenant, m.userId))}>
                      Remove
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="panel wide">
        <div className="card-k" style={{ marginBottom: 12 }}>
          Invite a teammate
        </div>
        <form className="invite-form" onSubmit={invite}>
          <input
            type="email"
            placeholder="teammate@company.com"
            value={invEmail}
            onChange={(e) => setInvEmail(e.target.value)}
            required
          />
          <select value={invRole} onChange={(e) => setInvRole(e.target.value as Role)}>
            <option value="user">User</option>
            <option value="admin" disabled={ws.role !== "owner"}>
              Admin
            </option>
          </select>
          <button className="btn btn-primary" disabled={inviting}>
            {inviting ? "Sending…" : "Send invite"}
          </button>
        </form>
        {invMsg && <p className="ok-line">{invMsg}</p>}
      </div>
    </>
  );
}

function BillingView({ ws }: { ws: Workspace }) {
  const [sub, setSub] = useState<api.Subscription | null>(null);
  const [inv, setInv] = useState<api.Invoice[]>([]);
  const [card, setCard] = useState<api.Card>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const isOwner = ws.role === "owner";
  useEffect(() => {
    api.subscription(ws.tenant).then(setSub, () => {});
    api.invoices(ws.tenant).then((r) => setInv(r.invoices), () => {});
    api.card(ws.tenant).then((r) => setCard(r.card), () => {});
  }, [ws.tenant]);

  async function upgrade(plan: "usage" | "scale") {
    setBusy(plan);
    try {
      const r = await api.checkout(ws.tenant, plan);
      if (r.url) window.location.href = r.url;
    } finally {
      setBusy(null);
    }
  }
  async function manage() {
    setBusy("portal");
    try {
      const r = await api.openPortal(ws.tenant);
      if (r.url) window.location.href = r.url;
    } finally {
      setBusy(null);
    }
  }

  return (
    <>
      <Header title="Billing" sub="Plan, payment, and invoices. Self-serve, no sales calls." />
      <div className="panel wide">
        <div className="plan-row">
          <div>
            <div className="card-k">Current plan</div>
            <div className="plan-name">{sub ? cap(sub.plan) : "…"}</div>
            <div className="card-s">
              {sub?.active
                ? `Active${sub.currentPeriodEnd ? ` · renews ${date(sub.currentPeriodEnd)}` : ""}`
                : "Free tier: 10K reach + 25M telemetry included"}
            </div>
          </div>
          {isOwner && (
            <div className="plan-actions">
              {sub?.active ? (
                <button className="btn btn-ghost" onClick={manage} disabled={!!busy}>
                  <i className="fa-solid fa-arrow-up-right-from-square" /> Manage billing
                </button>
              ) : (
                <>
                  <button className="btn btn-ghost" onClick={() => upgrade("usage")} disabled={!!busy}>
                    {busy === "usage" ? "…" : "Pay as you go"}
                  </button>
                  <button className="btn btn-primary" onClick={() => upgrade("scale")} disabled={!!busy}>
                    {busy === "scale" ? "…" : "Scale"}
                  </button>
                </>
              )}
            </div>
          )}
        </div>
        {card && (
          <div className="card-on-file">
            <i className="fa-regular fa-credit-card" /> {cap(card.brand)} ending {card.last4} · exp{" "}
            {card.exp_month}/{card.exp_year}
          </div>
        )}
      </div>
      <div className="panel wide">
        <div className="card-k" style={{ marginBottom: 10 }}>
          Invoices
        </div>
        {inv.length === 0 ? (
          <p className="hint">No invoices yet.</p>
        ) : (
          <table className="tbl">
            <tbody>
              {inv.map((i) => (
                <tr key={i.id}>
                  <td>{date(i.created)}</td>
                  <td>{money(i.amount_due, i.currency)}</td>
                  <td>
                    <span className={`inv-pill ${i.status}`}>{i.status}</span>
                  </td>
                  <td className="row-actions">
                    {i.hosted_invoice_url && (
                      <a className="linkish" href={i.hosted_invoice_url} target="_blank" rel="noreferrer">
                        View
                      </a>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}

function ObservabilityView({ ws }: { ws: Workspace }) {
  const [endpoint, setEndpoint] = useState("");
  const [saved, setSaved] = useState(ws.hasOtlp);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  async function save(e: React.FormEvent) {
    e.preventDefault();
    setErr(null);
    setBusy(true);
    try {
      await api.setOtlp(ws.tenant, endpoint.trim());
      setSaved(true);
    } catch (e2) {
      setErr(e2 instanceof Error ? niceErr(e2.message) : "Couldn't save the endpoint.");
    } finally {
      setBusy(false);
    }
  }
  return (
    <>
      <Header
        title="Observability"
        sub="Stream your device telemetry to your own OTel backend (Datadog, Grafana, Honeycomb…). It forwards on day one."
      />
      <div className="panel wide">
        <p className="status-line">
          <i className={`fa-solid ${saved ? "fa-circle-check ok" : "fa-circle-dot warn"}`} />{" "}
          {saved ? "An OTLP endpoint is configured." : "No OTLP endpoint yet, telemetry stays in Hop."}
        </p>
        <form className="field" onSubmit={save}>
          <label htmlFor="otlp">OTLP endpoint (https)</label>
          <input
            id="otlp"
            type="url"
            placeholder="https://otlp.datadoghq.com"
            value={endpoint}
            onChange={(e) => setEndpoint(e.target.value)}
            required
          />
          <div style={{ height: 8 }} />
          <button className="btn btn-primary" disabled={busy}>
            {busy ? "Saving…" : "Save endpoint"}
          </button>
        </form>
        {err && <div className="err">{err}</div>}
      </div>
    </>
  );
}

function SettingsView({ ws }: { ws: Workspace }) {
  const [copied, setCopied] = useState(false);
  return (
    <>
      <Header title="Settings" sub="Workspace details." />
      <div className="panel wide">
        <div className="kv">
          <span className="card-k">Workspace</span>
          <span>{ws.name}</span>
        </div>
        <div className="kv">
          <span className="card-k">Tenant ID</span>
          <button
            className="mono copy"
            onClick={() => {
              navigator.clipboard?.writeText(ws.tenant);
              setCopied(true);
              setTimeout(() => setCopied(false), 1200);
            }}
            title="Copy"
          >
            {ws.tenant} <i className={`fa-regular ${copied ? "fa-circle-check" : "fa-copy"}`} />
          </button>
        </div>
        <div className="kv">
          <span className="card-k">Your role</span>
          <span className="role-pill">{cap(ws.role)}</span>
        </div>
      </div>
    </>
  );
}

function Empty({ msg }: { msg: string }) {
  return (
    <div className="panel wide">
      <p className="hint">{msg}</p>
    </div>
  );
}

// --- helpers ----------------------------------------------------------------

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
const fmt = (n: number) => new Intl.NumberFormat().format(n);
const date = (unixSecs: number) => new Date(unixSecs * 1000).toLocaleDateString();
const money = (cents: number, cur: string) =>
  new Intl.NumberFormat(undefined, { style: "currency", currency: cur.toUpperCase() }).format(cents / 100);
function niceErr(code: string): string {
  const m: Record<string, string> = {
    forbidden: "You don't have permission for that.",
    last_owner: "An organization must keep at least one owner.",
    invalid_endpoint: "That doesn't look like a public https endpoint.",
    not_a_member: "That person isn't a member.",
  };
  return m[code] ?? "Action failed.";
}
