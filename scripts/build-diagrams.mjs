/* Builds the diagrams in README.md from assets/diagrams/*.mmd.
 *
 * GitHub renders mermaid in a fenced block but cannot animate it, and cannot
 * theme it to match anything. So these are built: the sources stay in the repo
 * as text, which keeps a diagram something you can edit and diff, and the
 * script below owns the palette and the animation in one place.
 *
 *   node scripts/build-diagrams.mjs
 *
 * Needs a Chromium. It will find Playwright's if one is installed, otherwise
 * set PUPPETEER_EXECUTABLE_PATH or CHROME_PATH.
 */
import { readdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createRequire } from "node:module";

/* Playwright may be installed globally rather than in this repo, so resolve it
 * rather than assuming a local node_modules. */
const require_ = createRequire(import.meta.url);
let chromium;
try {
  ({ chromium } = require_("playwright"));
} catch {
  console.error("This needs Playwright. Either `npm i -D playwright`, or run with\n" +
                "  NODE_PATH=$(npm root -g) node scripts/build-diagrams.mjs");
  process.exit(1);
}

const HERE = dirname(fileURLToPath(import.meta.url));
const DIR = join(HERE, "..", "assets", "diagrams");
/* Loaded from node_modules rather than a CDN: the build then works offline
 * and cannot be changed under us by a third party. */
const MERMAID_PKG = "mermaid/dist/mermaid.min.js";

/* Light first, then redefined under prefers-color-scheme, so a diagram follows
 * GitHub's theme rather than glowing white in a dark one.
 *
 * Do NOT add a font-family override here. Mermaid sizes every box for the font
 * it measured with BEFORE this stylesheet is applied, so changing the face
 * afterwards clips the last line of a label. */
const STYLE = `
:root{
  --ink:#2A1119; --soft:#6B4753; --paper:#FDFAFA;
  --core-fill:#43192A; --core-line:#B8465C; --core-ink:#FAEFF0;
  --live-fill:#E6F4EC; --live-line:#2E7D5B;
  --todo-fill:#FBEFDD; --todo-line:#C08A4E;
  --ext-fill:#F5ECEE;  --ext-line:#A5808D;
}
@media (prefers-color-scheme: dark){
  :root{
    --ink:#F6EEE9; --soft:#CBB7AE; --paper:#171214;
    --core-fill:#5A2437; --core-line:#E08098; --core-ink:#FFF3F5;
    --live-fill:#17352A; --live-line:#4FBF8B;
    --todo-fill:#3A2E1E; --todo-line:#D9A867;
    --ext-fill:#2C2126;  --ext-line:#8A6B77;
  }
}
.bicore>rect,.bicore>path,.bicore>polygon{fill:var(--core-fill)!important;stroke:var(--core-line)!important;stroke-width:3px!important}
.bicore .nodeLabel,.bicore foreignObject div,.bicore span{color:var(--core-ink)!important;fill:var(--core-ink)!important}
.bilive>rect,.bilive>path,.bilive>polygon{fill:var(--live-fill)!important;stroke:var(--live-line)!important;stroke-width:2px!important}
.bitodo>rect,.bitodo>path,.bitodo>polygon{fill:var(--todo-fill)!important;stroke:var(--todo-line)!important;stroke-width:2px!important;stroke-dasharray:6 4!important}
.biext>rect,.biext>path,.biext>polygon{fill:var(--ext-fill)!important;stroke:var(--ext-line)!important;stroke-width:1.5px!important}
.bilive .nodeLabel,.bitodo .nodeLabel,.biext .nodeLabel,
.bilive foreignObject div,.bitodo foreignObject div,.biext foreignObject div{color:var(--ink)!important;fill:var(--ink)!important}
.cluster>rect{fill:none!important;stroke:var(--ext-line)!important;stroke-width:1.5px!important;rx:10}
.cluster .nodeLabel,.cluster-label foreignObject div{color:var(--soft)!important;font-weight:700!important}
.edgeLabel,.edgeLabel foreignObject div,.edgeLabel span{color:var(--soft)!important;background:var(--paper)!important;fill:var(--soft)!important}
/* mermaid puts a rect behind each edge label and fills it its own grey */
.edgeLabel rect,rect.edgeLabel{fill:var(--paper)!important;opacity:1!important}
.flowchart-link,path.flowchart-link{stroke:var(--core-line)!important;stroke-width:2px!important}
marker path,defs marker path{fill:var(--core-line)!important;stroke:var(--core-line)!important}

/* the connectors animate, so you can see which way the information travels */
.flowchart-link{stroke-dasharray:9 5;animation:bi-flow 1.1s linear infinite}
@keyframes bi-flow{to{stroke-dashoffset:-14}}
@media (prefers-reduced-motion: reduce){
  .flowchart-link{animation:none;stroke-dasharray:none}
}
`;

const browser = await chromium.launch({
  executablePath: process.env.PUPPETEER_EXECUTABLE_PATH || process.env.CHROME_PATH || undefined,
});
const page = await browser.newPage({ viewport: { width: 1600, height: 1200 } });
let mermaidPath;
try {
  mermaidPath = require_.resolve(MERMAID_PKG);
} catch {
  console.error("This needs mermaid. Run `npm i -D mermaid@11.4.1`, or set NODE_PATH\n" +
                "to a directory that has it.");
  process.exit(1);
}
await page.goto("about:blank");
await page.addScriptTag({ path: mermaidPath });
await page.evaluate(() =>
  window.mermaid.initialize({ startOnLoad: false, securityLevel: "loose",
    flowchart: { htmlLabels: true, curve: "basis", padding: 14 } }));

const files = (await readdir(DIR)).filter((f) => f.endsWith(".mmd")).sort();
let made = 0;
for (const f of files) {
  const src = await readFile(join(DIR, f), "utf8");
  const svg = await page.evaluate(async ([code, css]) => {
    const { svg } = await window.mermaid.render("d" + Math.random().toString(36).slice(2), code);
    const doc = new DOMParser().parseFromString(svg, "image/svg+xml");
    const root = doc.documentElement;
    // a fixed max-width from mermaid stops the SVG scaling to the column
    root.removeAttribute("style");
    root.setAttribute("width", "100%");
    const style = doc.createElementNS("http://www.w3.org/2000/svg", "style");
    style.textContent = css;
    root.insertBefore(style, root.firstChild);
    return new XMLSerializer().serializeToString(root);
  }, [src, STYLE]);
  const out = f.replace(/\.mmd$/, ".svg");
  await writeFile(join(DIR, out), svg + "\n");
  console.log(`  ${out}  (${(svg.length / 1024).toFixed(1)}KB)`);
  made++;
}
await browser.close();
console.log(`${made} diagram(s) built`);
