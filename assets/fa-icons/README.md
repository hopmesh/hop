# Font Awesome Pro icon sources: licensing (F-41)

The 27 SVGs in this directory (and the `ic_fa_*` drawables/assets derived from them in the iOS and
Android apps) are **Font Awesome Pro 7.3.0** icons, used under a **commercial Font Awesome Pro seat**.
Each source SVG carries the stamp:

> `Font Awesome Pro 7.3.0 by @fontawesome ... (Commercial License) Copyright 2026 Fonticons, Inc.`

## What the license allows / forbids

FA Pro permits embedding icons in a compiled app. It **forbids hosting the Pro icon _source_ files in
a publicly accessible repository or package**. This repo is **private today**, but note that:

- it is licensed FSL-1.1-ALv2 (source-available, with a future Apache-2.0 grant), and
- the bearer/SDK packages are designed to be independently publishable, and
- the marketing direction references the repo publicly.

## Pre-public / pre-publish checklist

Before making this repo public, or publishing any package that bundles these assets:

1. **Strip or swap the Pro-only icons.** Several used here exist in **Font Awesome Free** (e.g. `lock`,
   `camera`, `chevron-left`, `arrows-rotate`, `circle-info`, `wifi`, `bluetooth-b`), swap those to the
   Free equivalents (SIL OFL / MIT, redistributable).
2. **Remove any remaining Pro-only source SVGs** from the tree, or replace them with Free/other-licensed
   equivalents.
3. Keep this note with whatever remains, and confirm the FA Pro seat covers the shipping app usage.

Do not add new FA Pro source icons here without updating this checklist.
