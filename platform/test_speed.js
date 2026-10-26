/* What each page actually costs to open, measured rather than guessed.
 *
 * The numbers that matter on a phone on mobile data are the count of requests
 * before anything is painted, the bytes that have to arrive first, and whether
 * anything in the critical path belongs to somebody else - a third-party
 * stylesheet is a DNS lookup, a TLS handshake and a round trip before the
 * browser even learns which font file it needs.
 *
 * The budgets below are deliberately loose. They are not there to chase a
 * score; they are there to fail loudly if someone drops a 2 MB hero image or
 * puts a CDN back in front of the fonts.
 *
 *   node test_speed.js
 */
const { chromium, devices } = require("playwright");
const { start } = require("./serve");

/* What actually holds up the first paint is the stylesheets, and only those.
   The fonts are declared font-display:swap, so text is painted immediately in
   a fallback face and swapped when the real one lands - which is why they get
   a budget of their own rather than being counted as blocking. That the swap
   is really set is asserted further down, because without it every one of
   these pages would start blank. */
const BUDGET = {
  "/":            { requests: 14, cssKB: 12, fontKB: 130, totalKB: 400 },
  "/studio-mila": { requests: 14, cssKB: 24, fontKB: 80,  totalKB: 400 },
  "/app/":        { requests: 14, cssKB: 24, fontKB: 80,  totalKB: 400 },
  "/privacy.html":{ requests: 12, cssKB: 24, fontKB: 80,  totalKB: 300 },
};

(async () => {
  const srv = await start();
  const browser = await chromium.launch();
  let fail = 0;
  const ok = (c, m) => { console.log((c ? "ok   " : "FAIL ") + m); if (!c) fail++; };

  console.log("-- what a first visit costs, on a cold cache --");
/* The one host allowed on a page, and only because the privacy notice
   describes it by name: Cloudflare Web Analytics sets no cookie and writes
   nothing to the visitor's device. build.sh injects it only when
   CF_ANALYTICS_TOKEN is set, so without this the suite would pass on a local
   build that is not what production serves - which is the same way a test
   passes for the wrong reason every other time it happens. Anything else is
   still a failure. */
const ALLOWED = new Set(["static.cloudflareinsights.com", "cloudflareinsights.com"]);

for (const [p, budget] of Object.entries(BUDGET)) {
    const ctx = await browser.newContext({ ...devices["iPhone 12"] });
    const page = await ctx.newPage();
    const seen = [];
    const thirdParty = new Set();
    page.on("response", async (r) => {
      const u = new URL(r.url());
      if (u.hostname !== "127.0.0.1" && !ALLOWED.has(u.hostname)) thirdParty.add(u.hostname);
      let size = 0;
      try { size = (await r.body()).length; } catch { /* redirect, or no body */ }
      seen.push({ url: u.pathname, host: u.hostname, size, type: r.request().resourceType() });
    });
    /* The booking page and the dashboard need a config to boot; without one
       they render an error, which is not the page being measured. */
    await page.route("**/config.js", (r) => r.fulfill({ contentType: "application/javascript",
      body: 'window.BOOKEDIN={SUPABASE_URL:"https://stub.supabase.co",SUPABASE_ANON_KEY:"stub",PAGE_HOST:"booked-in.co.uk"};' }));
    await page.goto(srv.origin + p, { waitUntil: "load" });
    await page.waitForTimeout(400);

    const total = seen.reduce((a, b) => a + b.size, 0);
    const sum = (t) => seen.filter((r) => r.type === t).reduce((a, b) => a + b.size, 0);
    const css = sum("stylesheet"), font = sum("font");
    const kb = (n) => Math.round(n / 1024);

    ok(seen.length <= budget.requests,
       `${p.padEnd(14)} ${String(seen.length).padStart(2)} requests (budget ${budget.requests})`);
    ok(css <= budget.cssKB * 1024,
       `${p.padEnd(14)} ${String(kb(css)).padStart(3)} KB of CSS, which is all that holds up the first paint (budget ${budget.cssKB})`);
    ok(font <= budget.fontKB * 1024,
       `${p.padEnd(14)} ${String(kb(font)).padStart(3)} KB of fonts, swapped in after (budget ${budget.fontKB})`);
    ok(total <= budget.totalKB * 1024,
       `${p.padEnd(14)} ${String(kb(total)).padStart(3)} KB in total (budget ${budget.totalKB})`);
    const beacon = seen.some((r) => ALLOWED.has(r.host));
    ok(thirdParty.size === 0,
       `${p.padEnd(14)} nothing is fetched from anybody else` +
       (beacon ? " (bar the analytics beacon, which the notice names)" : "") +
       (thirdParty.size ? ` — ${[...thirdParty].join(", ")}` : ""));

    const heavy = seen.filter((r) => r.size > 80 * 1024)
                      .map((r) => `${r.url} ${kb(r.size)}KB`);
    if (heavy.length) console.log("       heaviest: " + heavy.join(", "));
    await ctx.close();
  }

  console.log("\n-- the font files --");
  {
    const ctx = await browser.newContext({ ...devices["iPhone 12"] });
    const page = await ctx.newPage();
    const fonts = [];
    page.on("response", async (r) => {
      if (r.request().resourceType() !== "font") return;
      let n = 0; try { n = (await r.body()).length; } catch {}
      fonts.push([new URL(r.url()).pathname, n]);
    });
    await page.goto(srv.origin + "/privacy.html", { waitUntil: "load" });
    await page.waitForTimeout(600);
    /* Only the latin subsets should come down for English text. Pulling
       latin-ext as well would be 45 KB nobody on this page can see. */
    ok(fonts.every(([u]) => !/latin-ext/.test(u)),
       `only the subsets the page needs are fetched (${fonts.map(([u]) => u.split("/").pop()).join(", ") || "none"})`);
    /* Without this every page would hold its text back behind a font download,
       which is the single worst thing self-hosting could have introduced. */
    const css = await (await fetch(srv.origin + "/site/fonts.css")).text();
    const faces = (css.match(/@font-face/g) || []).length;
    const swaps = (css.match(/font-display:\s*swap/g) || []).length;
    ok(faces > 0 && faces === swaps,
       `every one of the ${faces} faces is font-display:swap, so no text waits on a download`);
    await ctx.close();
  }

  await browser.close();
  await srv.close();
  console.log("");
  console.log(fail ? "FAILURES" : "all passed");
  process.exit(fail ? 1 : 0);
})();
