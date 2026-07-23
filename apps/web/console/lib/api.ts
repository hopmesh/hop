// The console talks to hop-accountd through the same-origin /api proxy (see next.config.mjs), so the
// __Host- session cookie stays first-party. These wrap the auth + console surfaces.

export type Me = { id: string; email: string };
export type Role = "owner" | "admin" | "user";
export type Workspace = {
  tenant: string;
  name: string;
  role: Role;
  hasCarriageKey: boolean;
  hasOtlp: boolean;
};
export type Overview = { user: Me; workspaces: Workspace[] };
export type Usage = {
  reach: { deliveries: number; included: number };
  telemetry: { events: number; included: number };
  windowDays: number;
};
export type Subscription = {
  plan: "developer" | "usage" | "scale";
  status: string;
  currentPeriodEnd: number | null;
  active: boolean;
};
export type Invoice = {
  id: string;
  number: string | null;
  status: string;
  amount_due: number;
  currency: string;
  created: number;
  hosted_invoice_url: string | null;
  invoice_pdf: string | null;
};
export type Card = { brand: string; last4: string; exp_month: number; exp_year: number } | null;
export type Member = { userId: string; email: string; role: Role };

async function jget<T>(path: string): Promise<T> {
  const r = await fetch(path, { headers: { accept: "application/json" } });
  if (!r.ok) throw new Error(`${r.status}`);
  return (await r.json()) as T;
}
async function jpost<T>(path: string, body: unknown): Promise<T> {
  const r = await fetch(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!r.ok) {
    let msg = `${r.status}`;
    try {
      msg = ((await r.json()) as { error?: string }).error ?? msg;
    } catch {
      /* keep the status */
    }
    throw new Error(msg);
  }
  return (await r.json().catch(() => ({}))) as T;
}

// ---- auth ----------------------------------------------------------------

/** Ask for a sign-in link. Resolves the same way whether or not the account exists (no enumeration). */
export async function requestLink(email: string): Promise<void> {
  const r = await fetch("/api/auth/request-link", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email }),
  });
  if (r.status === 429) throw new Error("Too many requests. Give it a moment and try again.");
  if (!r.ok && r.status !== 202) throw new Error("Something went wrong. Try again.");
}
export async function redeem(token: string): Promise<void> {
  await jpost("/api/auth/redeem", { token });
}
export async function me(): Promise<Me | null> {
  try {
    return await jget<Me>("/api/auth/me");
  } catch {
    return null;
  }
}
export async function logout(): Promise<void> {
  await fetch("/api/auth/logout", { method: "POST" });
}
export const githubStartUrl = "/api/auth/github/start";

// ---- console reads -------------------------------------------------------

export const overview = () => jget<Overview>("/api/console/overview");
// Create a new workspace the caller owns; returns it in the same shape as an overview workspace.
export const createOrg = (name: string) => jpost<Workspace>("/api/console/orgs", { name });
export const usage = (t: string) => jget<Usage>(`/api/console/usage?tenant=${t}`);
export const subscription = (t: string) => jget<Subscription>(`/api/console/subscription?tenant=${t}`);
export const invoices = (t: string) => jget<{ invoices: Invoice[] }>(`/api/console/invoices?tenant=${t}`);
export const card = (t: string) => jget<{ card: Card }>(`/api/console/card?tenant=${t}`);
export const team = (t: string) => jget<{ members: Member[] }>(`/api/console/team?tenant=${t}`);

// ---- console writes ------------------------------------------------------

export const setRole = (tenant: string, userId: string, role: Role) =>
  jpost("/api/console/team/role", { tenant, userId, role });
export const removeMember = (tenant: string, userId: string) =>
  jpost("/api/console/team/remove", { tenant, userId });
export const transferOwnership = (tenant: string, userId: string) =>
  jpost("/api/console/team/transfer", { tenant, userId });
export const inviteMember = (tenant: string, email: string, role: Role) =>
  jpost("/api/console/team/invite", { tenant, email, role });
export const acceptInvite = (token: string) =>
  jpost<{ ok: boolean; tenant: string }>("/api/console/team/accept", { token });
export const registerCarriageKey = (tenant: string, pubkey: string) =>
  jpost("/api/keys/carriage", { tenant, pubkey });
export const setOtlp = (tenant: string, endpoint: string) =>
  jpost("/api/settings/otlp", { tenant, endpoint });
export const checkout = (tenant: string, plan: "usage" | "scale") =>
  jpost<{ url?: string; free?: boolean }>("/api/billing/checkout", { tenant, plan });
export const openPortal = (tenant: string) => jpost<{ url: string }>("/api/billing/portal", { tenant });
