// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// Static marketing site. File-based routing in src/pages/, output to dist/.
// `site` is the canonical production URL (used for absolute URLs / sitemaps).
export default defineConfig({
  site: 'https://hopme.sh',
  integrations: [sitemap()],
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
