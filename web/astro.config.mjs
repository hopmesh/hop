// @ts-check
import { defineConfig } from 'astro/config';

// Static marketing site. File-based routing in src/pages/, output to dist/.
// `site` is the canonical production URL (used for absolute URLs / sitemaps).
export default defineConfig({
  site: 'https://hopme.sh',
  build: {
    // Pretty URLs: src/pages/developers.astro -> /developers/ . Most static
    // hosts and CDNs resolve the directory index; switch to 'file' for plain
    // bucket hosting that serves *.html literally.
    format: 'directory',
  },
});
