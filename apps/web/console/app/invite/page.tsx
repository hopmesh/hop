"use client";

import { useEffect, useState } from "react";
import * as api from "@/lib/api";

// The team-invite landing. The invite token rides the URL FRAGMENT (never sent to a server). If the
// visitor is already signed in with the invited email, we accept immediately and drop them into the
// workspace. If not, they sign in first (magic link) and come back to this same link to accept.
export default function Invite() {
  const [state, setState] = useState<"working" | "need-signin" | "sent" | "error">("working");
  const [token, setToken] = useState("");
  const [email, setEmail] = useState("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const hash = window.location.hash.startsWith("#") ? window.location.hash.slice(1) : "";
    const t = new URLSearchParams(hash).get("token");
    if (!t) {
      setError("This invite link is incomplete. Ask for a fresh one.");
      setState("error");
      return;
    }
    setToken(t);
    api.me().then((who) => {
      if (!who) {
        setState("need-signin");
        return;
      }
      api
        .acceptInvite(t)
        .then((r) => {
          window.location.replace(`/dashboard`);
          void r;
        })
        .catch((e) => {
          setError(mapErr(e instanceof Error ? e.message : ""));
          setState("error");
        });
    });
  }, []);

  async function signIn(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    try {
      await api.requestLink(email.trim());
      setState("sent");
    } catch (e2) {
      setError(e2 instanceof Error ? e2.message : "Something went wrong.");
    }
  }

  return (
    <main className="auth-wrap">
      <div className="auth-card">
        <div className="brand">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img className="mark" src="/hop-mark.svg" alt="Hop" width={132} height={76} />
        </div>
        <div className="panel">
          {state === "working" && (
            <div className="sent">
              <div className="ring" aria-hidden="true">
                <i className="fa-solid fa-circle-notch spin" />
              </div>
              <h2>Joining…</h2>
            </div>
          )}
          {state === "need-signin" && (
            <>
              <div className="sent" style={{ paddingBottom: 0 }}>
                <div className="ring" aria-hidden="true">
                  <i className="fa-regular fa-envelope" />
                </div>
                <h2>Accept your invite</h2>
                <p>Sign in with the email you were invited on, and you&rsquo;ll join automatically.</p>
              </div>
              <form className="field" onSubmit={signIn}>
                <label htmlFor="email">Email</label>
                <input
                  id="email"
                  type="email"
                  autoFocus
                  required
                  placeholder="you@company.com"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                />
                <div style={{ height: 6 }} />
                <button className="btn btn-primary" type="submit">
                  <i className="fa-solid fa-paper-plane" /> Send me a sign-in link
                </button>
              </form>
              <input type="hidden" value={token} readOnly />
            </>
          )}
          {state === "sent" && (
            <div className="sent">
              <div className="ring" aria-hidden="true">
                <i className="fa-regular fa-envelope-open" />
              </div>
              <h2>Check your inbox</h2>
              <p>
                Sign in from the link we just sent, then reopen this invite to finish joining.
              </p>
            </div>
          )}
          {state === "error" && (
            <div className="sent">
              <div className="ring" aria-hidden="true" style={{ color: "var(--danger)" }}>
                <i className="fa-regular fa-circle-xmark" />
              </div>
              <h2>Couldn&rsquo;t join</h2>
              <p>{error}</p>
              <a className="again" href="/">
                Go to sign in
              </a>
            </div>
          )}
        </div>
      </div>
    </main>
  );
}

function mapErr(code: string): string {
  const m: Record<string, string> = {
    invite_invalid: "This invite is no longer valid.",
    invite_expired: "This invite has expired. Ask for a fresh one.",
    wrong_account: "This invite was sent to a different email. Sign in with that address.",
  };
  return m[code] ?? "This invite couldn't be accepted.";
}
