// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// Static marketing site. File-based routing in src/pages/, output to dist/.
// `site` is the canonical production URL (used for absolute URLs / sitemaps).
export default defineConfig({
  site: 'https://hopme.sh',
  integrations: [sitemap()],
  markdown: {
    // Landmine defused (F-8): Astro's smartypants (default true) rewrites a typed `--`/`---` in any
    // future Markdown/MDX page into a rendered en/em dash, which the byte-scan docs-token-guard never
    // sees (it scans source bytes, not rendered output). There are no markdown pages today, so this is
    // insurance: keep the no-dash rule enforceable if a markdown-driven page is ever added.
    smartypants: false,
  },
  // Quickstart moved into the docs site; keep the old URL working.
  redirects: {
    '/quickstart': '/docs/quickstart/',
  },
  build: {
    // Pretty URLs: src/pages/developers.astro -> /developers/ . Most static
    // hosts and CDNs resolve the directory index; switch to 'file' for plain
    // bucket hosting that serves *.html literally.
    format: 'directory',
  },
});
