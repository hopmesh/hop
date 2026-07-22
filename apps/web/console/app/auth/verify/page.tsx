"use client";

import { useEffect, useState } from "react";
import { redeem } from "@/lib/api";

// The magic-link landing. The one-time token rides the URL FRAGMENT (#token=...), which the browser
// never sends to a server and a mail-scanner prefetch (a GET) cannot consume, only this client reads
// it and POSTs it to redeem, so a link preview can't burn the token. On success the account service
// has set the session cookie; we send them into the console.
export default function Verify() {
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const hash = window.location.hash.startsWith("#") ? window.location.hash.slice(1) : "";
    const token = new URLSearchParams(hash).get("token");
    if (!token) {
      setError("This sign-in link is incomplete. Request a fresh one from the sign-in page.");
      return;
    }
    // Clear the token from the address bar immediately so it isn't left in history/screenshots.
    history.replaceState(null, "", window.location.pathname);
    redeem(token)
      .then(() => {
        window.location.replace("/dashboard");
      })
      .catch((err) => setError(err instanceof Error ? err.message : "This link is invalid."));
  }, []);

  return (
    <main className="auth-wrap">
      <div className="auth-card">
        <div className="brand">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img className="mark" src="/hop-mark.svg" alt="Hop" width={132} height={76} />
        </div>
        <div className="panel">
          {error ? (
            <div className="sent">
              <div className="ring" aria-hidden="true" style={{ color: "var(--danger)" }}>
                <i className="fa-regular fa-circle-xmark" />
              </div>
              <h2>Link expired</h2>
              <p>{error}</p>
              <a className="again" href="/">
                Back to sign in
              </a>
            </div>
          ) : (
            <div className="sent">
              <div className="ring" aria-hidden="true">
                <i className="fa-solid fa-circle-notch spin" />
              </div>
              <h2>Signing you in…</h2>
              <p>One moment while we finish setting up your session.</p>
            </div>
          )}
        </div>
      </div>
    </main>
  );
}
