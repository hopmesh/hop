"use client";

import { useEffect, useState } from "react";
import { me, requestLink, githubStartUrl } from "@/lib/api";

// The console entry: one email field, or GitHub. Passwordless and frictionless by design,
// no password, no org, no "email taken", no "already have an account". Signing up and signing in
// are the same act (the link creates the account on first click, signs in after).
export default function SignIn() {
  const [email, setEmail] = useState("");
  const [state, setState] = useState<"idle" | "sending" | "sent">("idle");
  const [error, setError] = useState<string | null>(null);
  // An already-authenticated visitor (a live session cookie, or one just set by the GitHub
  // callback that lands here) skips the form and goes straight to the dashboard. Checked client
  // side so the static page still serves instantly; the flash is one frame.
  const [checking, setChecking] = useState(true);
  useEffect(() => {
    let live = true;
    me()
      .then((u) => {
        if (live && u) window.location.replace("/dashboard");
        else if (live) setChecking(false);
      })
      .catch(() => live && setChecking(false));
    return () => {
      live = false;
    };
  }, []);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setState("sending");
    try {
      await requestLink(email.trim());
      setState("sent");
    } catch (err) {
      setError(err instanceof Error ? err.message : "Something went wrong.");
      setState("idle");
    }
  }

  // Hold the paint until the session check resolves, so an authenticated visitor never sees the
  // sign-in form blink before the redirect.
  if (checking) return <main className="auth-wrap" aria-busy="true" />;

  return (
    <main className="auth-wrap">
      <div className="auth-card">
        <div className="brand">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img className="mark" src="/hop-mark.svg" alt="Hop" width={132} height={76} />
          <h1>Build on the mesh</h1>
          <p>Your keys, usage, and billing for Hop, the delay-tolerant, untraceable-by-default mesh.</p>
        </div>

        {state === "sent" ? (
          <div className="panel">
            <div className="sent">
              <div className="ring" aria-hidden="true">
                <i className="fa-regular fa-envelope-open" />
              </div>
              <h2>Check your inbox</h2>
              <p>
                We sent a sign-in link to <span className="email">{email.trim()}</span>. Click it to
                finish, on this device or another.
              </p>
              <button className="again" onClick={() => setState("idle")}>
                Use a different email
              </button>
            </div>
          </div>
        ) : (
          <div className="panel">
            <form className="field" onSubmit={submit}>
              <label htmlFor="email">Email</label>
              <input
                id="email"
                type="email"
                name="email"
                inputMode="email"
                autoComplete="email"
                autoFocus
                required
                placeholder="you@company.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
              />
              <div style={{ height: 6 }} />
              <button className="btn btn-primary" type="submit" disabled={state === "sending"}>
                {state === "sending" ? (
                  <>
                    <i className="fa-solid fa-circle-notch spin" aria-hidden="true" /> Sending…
                  </>
                ) : (
                  <>
                    <i className="fa-solid fa-paper-plane" aria-hidden="true" /> Send me a sign-in link
                  </>
                )}
              </button>
            </form>

            {error && <div className="err">{error}</div>}

            <div className="divider">or</div>

            <a className="btn btn-ghost" href={githubStartUrl}>
              <i className="fa-brands fa-github" aria-hidden="true" /> Continue with GitHub
            </a>

            <p className="hint">
              No password. We email you a one-time link that signs you in and creates your workspace on
              first use.
            </p>
          </div>
        )}

        <p className="foot">
          New to Hop? <a href="https://hopme.sh">See what it does →</a>
        </p>
      </div>
    </main>
  );
}
