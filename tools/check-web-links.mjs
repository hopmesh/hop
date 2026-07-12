// Internal-link checker for the built marketing site (web-04 / quality-net-05).
//
// A broken internal link (a renamed page, a typo'd asset path, a moved anchor target) currently ships
// straight to hopme.sh with no gate. This walks every built HTML file under apps/web/dist, extracts local
// href/src references, and fails (exit 1) if any of them points at a path that does not exist in the
// build. It is deliberately dependency-free (plain Node + fs) so it runs in CI with no npm install.
//
// Scope + rules:
//   - Only INTERNAL links are checked (root-relative "/x" and document-relative "x/y"). External
//     (http/https/mailto/tel), protocol-relative "//", and in-page "#anchor" links are skipped:
//     validating those needs the network / is out of scope for a build-time gate.
//   - Astro's `format: 'directory'` means "/foo/" resolves to dist/foo/index.html. A path with no
//     extension is treated as a directory and must contain index.html (or exist as a literal file).
//   - Query strings and fragments are stripped before resolving ("/sim/index.html?x=1#y" -> that file).
//
// Usage: node tools/check-web-links.mjs [distDir]   (default: apps/web/dist)
import { readdirSync, readFileSync, statSync, existsSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join, resolve, posix } from 'path';

const here = dirname(fileURLToPath(import.meta.url));
const DIST = resolve(process.argv[2] || join(here, '..', 'apps', 'web', 'dist'));

if (!existsSync(DIST)) {
  console.error(`error: dist dir not found: ${DIST} (run \`npm run build\` in apps/web/ first)`);
  process.exit(2);
}

// Recursively list every *.html file under dist.
function htmlFiles(dir) {
  const out = [];
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, ent.name);
    if (ent.isDirectory()) out.push(...htmlFiles(p));
    else if (ent.name.endsWith('.html')) out.push(p);
  }
  return out;
}

// Does an internal reference resolve to something in the build?
function resolvesInDist(ref, fromFileDir) {
  // Strip query + fragment.
  let path = ref.split('#')[0].split('?')[0];
  if (path === '') return true; // pure "#anchor" or "?query" on the current page

  let abs;
  if (path.startsWith('/')) {
    abs = join(DIST, path);
  } else {
    abs = resolve(fromFileDir, path);
  }
  // Keep it inside dist (a "../.." escape is itself a bug).
  if (!abs.startsWith(DIST)) return false;

  if (existsSync(abs)) {
    const st = statSync(abs);
    if (st.isFile()) return true;
    // Directory: needs an index.html (directory-format pretty URL).
    if (st.isDirectory()) return existsSync(join(abs, 'index.html'));
  }
  // Extensionless path that wasn't an existing dir: try it as "<path>/index.html" and "<path>.html".
  if (!posix.basename(path).includes('.')) {
    if (existsSync(join(abs, 'index.html'))) return true;
    if (existsSync(`${abs}.html`)) return true;
  }
  return false;
}

const SKIP = /^(https?:|mailto:|tel:|data:|javascript:|\/\/|#)/i;
const ATTR_RE = /(?:href|src)\s*=\s*"([^"]*)"/gi;

let broken = 0;
let checked = 0;
const files = htmlFiles(DIST);

for (const file of files) {
  let html = readFileSync(file, 'utf8');
  // Drop <script> and <style> bodies: inline JS builds URLs dynamically (e.g. a template string
  // containing `href="..."+id`), which is not a real static link and would false-positive.
  html = html.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '')
             .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, '');
  const fromDir = dirname(file);
  let m;
  while ((m = ATTR_RE.exec(html)) !== null) {
    const ref = m[1].trim();
    if (ref === '' || SKIP.test(ref)) continue;
    // A ref carrying JS concatenation / template artifacts is not a static URL; skip it.
    if (/['`+]|\$\{/.test(ref)) continue;
    checked++;
    if (!resolvesInDist(ref, fromDir)) {
      broken++;
      const rel = file.slice(DIST.length + 1);
      console.error(`  BROKEN  ${rel}  ->  ${ref}`);
    }
  }
}

if (broken > 0) {
  console.error(`\n::error:: ${broken} broken internal link(s) across ${files.length} page(s).`);
  process.exit(1);
}
console.log(`OK: ${checked} internal link(s) across ${files.length} page(s) all resolve.`);
