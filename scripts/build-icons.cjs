/* Rasterises the brand SVGs into the PNG and ICO files that browsers and
 * phones still insist on.
 *
 * Chromium does the rendering because it is the same engine that will draw the
 * SVG favicon, so the raster and vector versions cannot drift. ImageMagick is
 * only used to pack the three PNGs into a single .ico, which it does without
 * re-rasterising anything.
 *
 * The output is committed, so a normal build never shells out to a browser.
 * Re-run it only when a mark changes:
 *   NODE_PATH=$(npm root -g) node scripts/build-icons.cjs
 */
/* CommonJS, and playwright is resolved the way the rest of the suite in
 * platform/ resolves it: from the global install, via NODE_PATH. */
const { chromium } = require("playwright");
const { execFileSync } = require("node:child_process");
const { mkdtempSync, readFileSync, rmSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join } = require("node:path");

const root = join(__dirname, "..");
const tmp = mkdtempSync(join(tmpdir(), "icons-"));

/* [source svg, output png, pixel size] */
const PNGS = [
  ["site/favicon.svg",  join(tmp, "ico-16.png"),            16],
  ["site/favicon.svg",  join(tmp, "ico-32.png"),            32],
  ["site/favicon.svg",  join(tmp, "ico-48.png"),            48],
  ["site/app-icon.svg", "site/apple-touch-icon.png",       180],
  ["site/app-icon.svg", "site/icon-192.png",               192],
  ["site/app-icon.svg", "site/icon-512.png",               512],
];

(async function main(){
const browser = await chromium.launch();
try {
  for (const [src, out, size] of PNGS) {
    const svg = readFileSync(join(root, src), "utf8");
    const page = await browser.newPage({
      viewport: { width: size, height: size },
      deviceScaleFactor: 1,
    });
    /* A bare SVG document would get the browser's default 8px body margin and
       its own intrinsic 32px size, so it is placed in a page sized to the
       output instead and told to fill it. */
    await page.setContent(
      `<!doctype html><meta charset="utf-8">` +
      `<style>html,body{margin:0;padding:0;width:${size}px;height:${size}px}` +
      `svg{display:block;width:${size}px;height:${size}px}</style>` + svg,
      { waitUntil: "load" }
    );
    const path = out.startsWith("/") ? out : join(root, out);
    await page.screenshot({ path, omitBackground: true });
    await page.close();
    console.log(`  ${size.toString().padStart(3)}px  ${out}`);
  }
} finally {
  await browser.close();
}

/* Old browsers, some crawlers and Windows shortcuts still ask for /favicon.ico
   by filename whatever the <link> tags say, so it has to exist. Three sizes in
   one file: 16 for the tab, 32 for the bookmark bar, 48 for the desktop. */
execFileSync("convert", [
  join(tmp, "ico-16.png"), join(tmp, "ico-32.png"), join(tmp, "ico-48.png"),
  join(root, "site/favicon.ico"),
]);
console.log("  16+32+48  site/favicon.ico");
rmSync(tmp, { recursive: true, force: true });
})();
