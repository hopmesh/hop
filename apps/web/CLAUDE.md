# apps/web

The Astro marketing site for hopme.sh.

## Build

- `npm ci && npm run build`. `prebuild` runs `npm run sync`, which copies `../../sim` into `public/sim`
  and `../../learn` into `public/learn` (the interactive sim + learn pages ship inside the site). Those
  relative paths are 2 levels up because the site is at `apps/web`; fix them if it moves.
- Astro 7, requires Node 22 (CI + `pages.yml` pin Node 22). `output: static`, deployed to `dist/`.
- Deploy: `.github/workflows/pages.yml` rebuilds the sim wasm from `core/hop-wasm` at HEAD, runs the
  build, and publishes `apps/web/dist` to GitHub Pages. The custom domain is carried by `public/CNAME`.

## Rules

- **No em-dashes, en-dashes, or lookalike dashes anywhere in `src/`.** `tools/docs-token-guard.sh` scans
  `web/src` in CI and rejects literal, HTML-entity (`&mdash;`, `&#8212`, with or without the semicolon),
  `\u`/CSS escapes, and the lookalikes U+2015 / U+2012. Markdown smartypants is off in `astro.config.mjs`
  so a typed `--` cannot render as a dash behind the scanner's back.
- Internal links must resolve: `node tools/check-web-links.mjs apps/web/dist` runs in CI.
- The site positions Hop as **BLE** (not "Bluetooth") and rides many transports; the guard also bans the
  removed terms (InternetEgress, Wi-Fi Direct) and bare "Bluetooth" in user-facing copy.
