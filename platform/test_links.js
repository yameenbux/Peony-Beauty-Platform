/* Every link in the built site, followed.
 *
 * This exists because of a bug that shipped: a relative link on the booking
 * page resolved correctly from /book/index.html and to the wrong place from
 * /studio-mila, where that same file is actually served. Nothing caught it,
 * because nothing had ever looked at where a link points as opposed to whether
 * the page containing it rendered.
 *
 * So every href, src, action and url() in dist/ is resolved and checked
 * against what the build actually produced - and the pages served under the
 * catch-all rewrite are checked twice, once from their real path and once from
 * a studio's, because those are different base URLs and a relative link can be
 * right from one and wrong from the other.
 *
 * External links are listed rather than fetched. A test that depends on
 * instagram.com being reachable fails for reasons that have nothing to do with
 * this site, and a flaky test gets ignored, which is worse than no test.
 *
 *   node test_links.js
 */
const fs = require("fs");
const path = require("path");

const DIST = path.join(__dirname, "..", "dist");
/* Served by the catch-all rewrite in render.yaml as well as at its own path,
   so its links have to work from a studio's URL too. */
const REWRITTEN = { "book/index.html": ["/studio-mila", "/a/b"] };

let fail = 0;
const ok = (m) => console.log("  ok   " + m);
const bad = (m) => { console.log("  FAIL " + m); fail = 1; };

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    e.isDirectory() ? walk(p, out) : out.push(p);
  }
  return out;
}

const files = walk(DIST);
const rel = (p) => path.relative(DIST, p).split(path.sep).join("/");
const onDisk = new Set(files.map(rel));

/* What the static host will actually serve for a given absolute path. A real
   file always wins; a directory means its index.html; anything left over is
   handed to the booking page by the rewrite. */
function served(urlPath) {
  const clean = urlPath.replace(/^\/+/, "");
  if (clean === "") return "index.html";
  if (onDisk.has(clean)) return clean;
  if (onDisk.has(clean + "/index.html")) return clean + "/index.html";
  if (onDisk.has(clean.replace(/\/$/, "") + "/index.html"))
    return clean.replace(/\/$/, "") + "/index.html";
  return null;
}

const REF = /(?:href|src|action)\s*=\s*["']([^"']+)["']/gi;
const CSSURL = /url\(\s*['"]?([^'")]+)['"]?\s*\)/gi;

const external = new Set();

function check(file, baseUrl) {
  const body = fs.readFileSync(file, "utf8");
  const isCss = file.endsWith(".css");
  const re = isCss ? CSSURL : REF;
  const ids = new Set([...body.matchAll(/\bid\s*=\s*["']([^"']+)["']/g)].map((m) => m[1]));
  re.lastIndex = 0;
  for (const m of body.matchAll(re)) {
    const raw = m[1].trim();
    if (!raw || raw.startsWith("data:") || raw.startsWith("mailto:") ||
        raw.startsWith("tel:") || raw.startsWith("javascript:")) continue;
    /* Our own absolute URLs - canonicals, og:url, the links in the footer -
       are internal, and resolving them here is how a mistyped canonical gets
       caught instead of quietly telling Google the wrong thing. */
    let abs = null;
    if (/^https?:\/\//i.test(raw)) {
      const u = new URL(raw);
      if (u.hostname !== "booked-in.co.uk") { external.add(raw.split("#")[0]); continue; }
      abs = u.pathname;
    }

    /* A bare fragment has to name something on this very page. */
    if (raw.startsWith("#")) {
      const id = decodeURIComponent(raw.slice(1));
      if (id && id !== "booked" && !ids.has(id))
        bad(`${rel(file)} → ${raw} (no element with that id)`);
      continue;
    }

    const url = abs ? { pathname: abs } : new URL(raw, "https://x" + baseUrl);
    const target = served(decodeURIComponent(url.pathname));
    if (!target) bad(`${rel(file)} (served at ${baseUrl}) → ${raw} → ${url.pathname} is not in the build`);
  }
}

console.log("-- every link resolves to something the build contains --");
const before = fail;
for (const f of files) {
  if (!/\.(html|css)$/.test(f)) continue;
  const r = rel(f);
  const own = "/" + (r.endsWith("/index.html") ? r.slice(0, -"index.html".length) : r);
  check(f, own);
  for (const alt of REWRITTEN[r] || []) check(f, alt);
}
if (fail === before) ok("all internal links and assets resolve, including under the rewrite");

console.log("\n-- pages the build must contain --");
for (const must of ["index.html", "404.html", "robots.txt", "sitemap.xml", "favicon.ico",
                    "privacy.html", "terms.html", "site/manifest.webmanifest",
                    "book/index.html", "app/index.html"]) {
  onDisk.has(must) ? ok(must) : bad(`${must} is missing from the build`);
}

console.log("\n-- robots and sitemap agree with each other --");
{
  const robots = fs.readFileSync(path.join(DIST, "robots.txt"), "utf8");
  const sitemap = fs.readFileSync(path.join(DIST, "sitemap.xml"), "utf8");
  const locs = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]);
  const disallow = [...robots.matchAll(/^Disallow:\s*(\S+)/gm)].map((m) => m[1]);

  locs.length ? ok(`the sitemap lists ${locs.length} pages`) : bad("the sitemap is empty");
  for (const loc of locs) {
    const p = new URL(loc).pathname;
    if (!served(p)) bad(`the sitemap lists ${p}, which the build does not contain`);
    if (disallow.some((d) => p.startsWith(d)))
      bad(`the sitemap lists ${p} and robots.txt disallows it`);
  }
  if (!/^Sitemap:\s*https:\/\/booked-in\.co\.uk\/sitemap\.xml$/m.test(robots))
    bad("robots.txt does not point at the sitemap");
  else ok("robots.txt points at the sitemap, and disallows nothing the sitemap lists");

  /* A noindex page in the sitemap is a contradiction a crawler resolves by
     trusting neither. */
  for (const loc of locs) {
    const f = served(new URL(loc).pathname);
    if (f && f.endsWith(".html")) {
      const h = fs.readFileSync(path.join(DIST, f), "utf8");
      if (/name=["']robots["'][^>]*noindex/i.test(h))
        bad(`${f} is in the sitemap and is also marked noindex`);
    }
  }
  ok("nothing in the sitemap is marked noindex");
}

console.log("\n-- the vendored client --");
{
  /* Three pages name this file. If one is updated and the others are not, two
     different versions of supabase-js are shipped and only one of them is in
     vendor/, so a page 404s its own client and goes blank. */
  const want = fs.readdirSync(path.join(DIST, "vendor"))
                 .filter((f) => /^supabase-js-.*\.js$/.test(f));
  want.length === 1
    ? ok(`one copy of supabase-js is shipped (${want[0]})`)
    : bad(`${want.length} copies of supabase-js in vendor/: ${want.join(", ")}`);
  for (const f of ["book/index.html", "book/manage.html", "app/index.html"]) {
    const h = fs.readFileSync(path.join(DIST, f), "utf8");
    const m = h.match(/src="(\/vendor\/supabase-js-[^"]+)"/);
    if (!m) { bad(`${f} does not load supabase-js from /vendor`); continue; }
    onDisk.has(m[1].slice(1))
      ? ok(`${f} loads ${m[1].split("/").pop()}, which is in the build`)
      : bad(`${f} loads ${m[1]}, which is not in the build`);
  }
  for (const f of ["book/index.html", "book/manage.html", "app/index.html"]) {
    const h = fs.readFileSync(path.join(DIST, f), "utf8");
    /cdn\.jsdelivr|unpkg\.com|cdnjs\.|fonts\.googleapis|fonts\.gstatic/.test(h)
      ? bad(`${f} still reaches a CDN, which the privacy notice says it does not`)
      : ok(`${f} reaches no CDN`);
  }
}

console.log("\n-- an address that belongs to nobody --");
{
  /* The catch-all rewrite means Render never reaches 404.html, so the message
     a lost visitor actually sees is the booking page's own. Both have to say
     something useful, and both have to offer the way back. */
  const gone = fs.readFileSync(path.join(DIST, "book/index.html"), "utf8");
  const block = (gone.match(/<div id="gone"[\s\S]*?<\/div>/) || [""])[0];
  /nothing at this address/i.test(block)
    ? ok("the booking page says plainly that nothing is there")
    : bad("the booking page's gone state does not say what is wrong");
  /href="\/"/.test(block)
    ? ok("and offers the way back to the marketing site")
    : bad("the gone state offers no way out");

  const four = fs.readFileSync(path.join(DIST, "404.html"), "utf8");
  /href="\/"/.test(four) && /href="\/app\/"/.test(four)
    ? ok("404.html offers the way back too, for when that rule changes")
    : bad("404.html offers no way out");
}

console.log("\n-- pages that must stay out of search results --");
for (const f of ["book/manage.html", "app/index.html", "404.html"]) {
  const h = fs.readFileSync(path.join(DIST, f), "utf8");
  /name=["']robots["'][^>]*noindex/i.test(h)
    ? ok(`${f} is noindex`)
    : bad(`${f} is not marked noindex`);
}

if (external.size) {
  console.log("\n-- links off this site, for a human to check --");
  [...external].sort().forEach((u) => console.log("       " + u));
}

console.log("");
console.log(fail ? "FAILURES" : "all passed");
process.exit(fail);
