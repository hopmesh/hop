import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const checker = path.resolve(here, "check-web-links.mjs");

function makeDist() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "hop-check-web-links-"));
  return {
    path: dir,
    write(relPath, content) {
      const full = path.join(dir, relPath);
      fs.mkdirSync(path.dirname(full), { recursive: true });
      fs.writeFileSync(full, content, "utf8");
    },
    cleanup() {
      fs.rmSync(dir, { recursive: true, force: true });
    },
  };
}

function runChecker(distDir) {
  const res = spawnSync(process.execPath, [checker, distDir], {
    encoding: "utf8",
  });
  return {
    status: res.status,
    stdout: res.stdout || "",
    stderr: res.stderr || "",
  };
}

test("passes on a clean site with varied valid link shapes", () => {
  const dist = makeDist();
  try {
    dist.write(
      "index.html",
      `<!doctype html>
<html>
  <head>
    <style>
      .hero { background: url('/assets/bg.png'); }
      /* style containing href-like string must not be treated as link */
      .fake { content: 'href="/nonexistent.html"'; }
    </style>
  </head>
  <body>
    <!-- root-relative with html extension -->
    <a href="/about.html">About</a>
    <!-- directory format pretty URL -->
    <a href="/docs/">Docs</a>
    <!-- extensionless path mapping to dir or html -->
    <a href="/docs/guide">Guide</a>
    <!-- document-relative child link -->
    <a href="blog/post.html">Post</a>
    <!-- query strings and fragments are stripped -->
    <a href="/about.html?source=nav#team">About Team</a>
    <!-- in-page anchor only -->
    <a href="#top">Back to top</a>
    <a href="?tab=details">Filter</a>
    <!-- asset src -->
    <img src="/assets/logo.svg" alt="logo">
    <!-- external links skipped -->
    <a href="https://example.com/external">External</a>
    <a href="http://example.com">Insecure</a>
    <a href="mailto:support@hopme.sh">Mail</a>
    <a href="tel:+1234567890">Tel</a>
    <a href="javascript:void(0)">JS</a>
    <a href="//cdn.example.com/script.js">Protocol-relative</a>
    <script>
      // inline script constructing dynamic url must not false-positive
      const dest = 'href="/missing-dynamic.html"';
    </script>
  </body>
</html>`
    );
    dist.write("about.html", "<h1>About</h1><a href=\"/\">Home</a>");
    dist.write("docs/index.html", "<h1>Docs</h1><a href=\"guide.html\">Guide</a>");
    dist.write("docs/guide.html", "<h1>Guide</h1>");
    dist.write("blog/post.html", "<h1>Post</h1><a href=\"../index.html\">Back</a>");
    dist.write("assets/logo.svg", "<svg></svg>");
    dist.write("assets/bg.png", "PNG");

    const res = runChecker(dist.path);
    assert.equal(res.status, 0, `checker should exit 0 on clean site:\n${res.stderr}\n${res.stdout}`);
    assert.match(res.stdout, /OK: \d+ internal link\(s\) across \d+ page\(s\) all resolve\./);
  } finally {
    dist.cleanup();
  }
});

test("fails loudly on broken root-relative link", () => {
  const dist = makeDist();
  try {
    dist.write("index.html", "<a href=\"/nonexistent.html\">Broken Link</a>");
    const res = runChecker(dist.path);
    assert.equal(res.status, 1, "checker should exit 1 on broken link");
    assert.match(res.stderr, /BROKEN\s+index\.html\s+->\s+\/nonexistent\.html/);
    assert.match(res.stderr, /::error:: 1 broken internal link\(s\)/);
  } finally {
    dist.cleanup();
  }
});

test("fails loudly on broken relative link from nested page", () => {
  const dist = makeDist();
  try {
    dist.write("nested/page.html", "<a href=\"missing-child.html\">Missing Child</a>");
    const res = runChecker(dist.path);
    assert.equal(res.status, 1, "checker should exit 1 on broken relative link");
    assert.match(res.stderr, /BROKEN\s+nested\/page\.html\s+->\s+missing-child\.html/);
  } finally {
    dist.cleanup();
  }
});

test("fails when directory link targets directory lacking index.html", () => {
  const dist = makeDist();
  try {
    dist.write("index.html", "<a href=\"/section/\">Empty section</a>");
    // create section directory with other file, but no index.html
    dist.write("section/other.txt", "not index");
    const res = runChecker(dist.path);
    assert.equal(res.status, 1, "checker should exit 1 when directory lacks index.html");
    assert.match(res.stderr, /BROKEN\s+index\.html\s+->\s+\/section\//);
  } finally {
    dist.cleanup();
  }
});

test("fails on path traversal escape outside dist directory", () => {
  const dist = makeDist();
  try {
    dist.write("index.html", "<a href=\"../../escaped.html\">Escape</a>");
    const res = runChecker(dist.path);
    assert.equal(res.status, 1, "checker should exit 1 on path traversal escape");
    assert.match(res.stderr, /BROKEN\s+index\.html\s+->\s+\.\.\/\.\.\/escaped\.html/);
  } finally {
    dist.cleanup();
  }
});

test("fails on broken image asset source", () => {
  const dist = makeDist();
  try {
    dist.write("index.html", "<img src=\"/images/missing.png\" alt=\"broken\">");
    const res = runChecker(dist.path);
    assert.equal(res.status, 1, "checker should exit 1 on broken img src");
    assert.match(res.stderr, /BROKEN\s+index\.html\s+->\s+\/images\/missing\.png/);
  } finally {
    dist.cleanup();
  }
});

test("exits with status 2 when dist directory is missing", () => {
  const nonexistent = path.join(os.tmpdir(), `nonexistent-dist-${Date.now()}`);
  const res = runChecker(nonexistent);
  assert.equal(res.status, 2, "checker should exit 2 when dist directory does not exist");
  assert.match(res.stderr, /dist dir not found/);
});
