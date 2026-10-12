/* Renders the Open Graph preview images that Instagram, WhatsApp, Facebook,
 * iMessage and the rest show when somebody pastes one of our links.
 *
 * There are two, because the two kinds of link are shown to two different
 * people. share.png sells the product to a beauty professional. share-book.png
 * is what her client sees when the studio's booking link lands in a DM, and it
 * has to say "book an appointment", not "£10 a month".
 *
 * A studio's booking page is one static file served under every studio's path,
 * so this image cannot carry a studio's own name. Generic Booked In branding is
 * the honest option, and it still beats the blank card the page had before.
 *
 * Chromium renders them from the real typefaces in site/fonts, so the cards
 * cannot drift from the site. The output is committed; re-run only on a change:
 *   NODE_PATH=$(npm root -g) node scripts/build-share.cjs
 */
const { chromium } = require("playwright");
const { execFileSync } = require("node:child_process");
const { readFileSync, statSync } = require("node:fs");
const { join } = require("node:path");

const root = join(__dirname, "..");
const b64 = (p) => readFileSync(join(root, p)).toString("base64");

/* The fonts are inlined as data URIs because the page is rendered from a
   string with no origin to resolve a relative URL against. */
const FACE = (fam, style, file) => `@font-face{font-family:'${fam}';
  font-style:${style};font-weight:400 700;font-display:block;
  src:url(data:font/woff2;base64,${b64("site/fonts/" + file)}) format('woff2')}`;

const CSS = `
${FACE("Bodoni Moda", "normal", "bodoni-moda-normal-latin.woff2")}
${FACE("Bodoni Moda", "italic", "bodoni-moda-italic-latin.woff2")}
${FACE("Plus Jakarta Sans", "normal", "plus-jakarta-sans-normal-latin.woff2")}
*{margin:0;padding:0;box-sizing:border-box}
body{width:1200px;height:630px;background:#FDFAFA;position:relative;overflow:hidden;
     font-family:'Plus Jakarta Sans',system-ui,sans-serif;color:#2A1119}
/* the blush bloom, top right */
.bloom{position:absolute;right:-170px;top:-210px;width:720px;height:720px;
  border-radius:50%;background:radial-gradient(circle,#F2D7DB 0%,#FAEFF0 46%,rgba(253,250,250,0) 72%)}
/* the mark again, oversized and cropped by the corner */
.ring{position:absolute;right:-96px;bottom:-150px;width:470px;height:470px}
.wrap{position:relative;height:630px;padding:74px 80px;display:flex;flex-direction:column}
.lockup{display:flex;align-items:center;gap:20px;margin-bottom:58px}
.lockup svg{width:40px;height:40px;display:block}
.lockup span{font-family:'Bodoni Moda',Georgia,serif;font-size:29px;font-weight:500;
  letter-spacing:.2em;color:#43192A}
h1{font-family:'Bodoni Moda',Georgia,serif;font-weight:400;font-size:78px;
  line-height:1.04;letter-spacing:-.022em;color:#43192A;max-width:19ch}
h1 em{font-style:italic;color:#B8465C}
p{margin-top:30px;font-size:25px;line-height:1.45;color:#6B4753;max-width:27ch}
.row{margin-top:auto;display:flex;align-items:center;gap:26px;
  font-size:19px;font-weight:600;color:#43192A}
.row i{width:5px;height:5px;border-radius:50%;background:#E5B9C0;display:block}
`;

/* The ring, enlarged: 6 slots on a 200-unit circle, one of them taken. Same
   construction as site/icon.svg - dash = period - (visual gap + stroke) - just
   scaled up, so the proportions match the favicon a reader just saw. */
const RING = (() => {
  const r = 86, sw = 20, vg = 15;
  const period = (2 * Math.PI * r) / 6;
  const dash = period - (vg + sw);
  const circ = 2 * Math.PI * r;
  const f = (n) => n.toFixed(3);
  return `<svg class="ring" viewBox="0 0 200 200" xmlns="http://www.w3.org/2000/svg">
    <g transform="rotate(-90 100 100)" fill="none" stroke-linecap="round">
      <circle cx="100" cy="100" r="${r}" stroke="#F2D7DB" stroke-width="${sw}"
              stroke-dasharray="${f(dash)} ${f(period - dash)}"/>
      <circle cx="100" cy="100" r="${r}" stroke="#E5B9C0" stroke-width="${sw}"
              stroke-dasharray="${f(dash)} ${f(circ - dash)}" stroke-dashoffset="${f(-2 * period)}"/>
    </g></svg>`;
})();

const MONOGRAM = readFileSync(join(root, "site/monogram.svg"), "utf8")
  .replace(/<!--[\s\S]*?-->/g, "");

const page = (body) =>
  `<!doctype html><html lang="en-GB"><meta charset="utf-8"><style>${CSS}</style>` +
  `<body><div class="bloom"></div>${RING}<div class="wrap">` +
  `<div class="lockup">${MONOGRAM}<span>BOOKED IN</span></div>${body}</div></body></html>`;

const CARDS = [
  ["site/share.png", page(
    `<h1>Your clients book themselves.<br>You just <em>show up</em>.</h1>
     <p>A booking page as beautiful as your work, on a link that is yours alone.</p>
     <div class="row"><span>No commission, ever</span><i></i><span>&pound;10 a month</span>
     <i></i><span>Free to start</span></div>`)],
  ["site/share-book.png", page(
    `<h1>Book an <em>appointment</em>.</h1>
     <p>Pick the time that suits you and it is yours. No phone call, no waiting
        on a reply &mdash; it takes about a minute.</p>
     <div class="row"><span>Instant confirmation</span><i></i>
     <span>Change or cancel any time</span></div>`)],
];

(async function main() {
  const browser = await chromium.launch();
  try {
    for (const [out, html] of CARDS) {
      const p = await browser.newPage({
        viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1,
      });
      await p.setContent(html, { waitUntil: "load" });
      await p.evaluate(() => document.fonts.ready);
      const path = join(root, out);
      await p.screenshot({ path });
      await p.close();
      /* Flat brand colour and one soft gradient quantise to a 200-colour
         palette with no visible loss (RMSE 0.5%) and roughly half the bytes.
         Worth doing: WhatsApp and some other clients quietly drop a preview
         image that is too heavy, and nothing here needs 24-bit colour. */
      execFileSync("convert", [path, "-strip", "-dither", "FloydSteinberg",
                               "-colors", "200", "PNG8:" + path]);
      console.log(`  1200x630  ${out}  ${Math.round(statSync(path).size / 1024)} KB`);
    }
  } finally {
    await browser.close();
  }
})();
