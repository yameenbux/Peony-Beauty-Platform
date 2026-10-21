/* The Stories card, checked by looking at the pixels.
 *
 * A canvas has no DOM to assert against: the only honest question is "what
 * ended up on the picture", so these count ink. The two failures that matter
 * are invisible to any other kind of test - a long studio name running off the
 * right-hand edge, and anything readable drifting into the top or bottom strip
 * that Instagram covers with its own buttons. Both produce a card that looks
 * fine in the preview and is ruined once posted.
 *
 *   node test_story.js
 */
const { chromium } = require("playwright");
const { start } = require("./serve");

const DATA = {
  studio: "Studio Mila",
  tagline: "Mobile lashes · Nuneaton & Coventry",
  link: "booked-in.co.uk/studio-mila",
  credit: true,
  service: "Russian infills",
  price: "£40",
  slots: [
    { day: "Thursday 22 October", time: "2pm" },
    { day: "Friday 23 October",   time: "10:30am" },
    { day: "Saturday 24 October", time: "1pm" },
  ],
  treatments: [
    { name: "Classic full set", price: "£45" },
    { name: "Hybrid full set",  price: "£50" },
    { name: "Russian infills",  price: "£40" },
  ],
};

/* Everything the eye reads is dark - plum, ink, carmine, or white on carmine.
   The bloom and the big ring are pale by design and deliberately allowed into
   the covered strips, so "is there ink here" has to mean "is there DARK ink
   here" or it would flag the decoration. */
const INK_PROBE = `
  window.__ink = function (canvas, x, y, w, h) {
    const d = canvas.getContext("2d").getImageData(x, y, w, h).data;
    let n = 0;
    for (let i = 0; i < d.length; i += 4) {
      const L = (0.2126 * d[i] + 0.7152 * d[i+1] + 0.0722 * d[i+2]) / 255;
      if (d[i+3] > 8 && L < 0.55) n++;
    }
    return n;
  };`;

(async () => {
  const srv = await start();
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
  const errs = [];
  page.on("pageerror", (e) => errs.push(e.message));
  page.on("console", (m) => { if (m.type() === "error") errs.push(m.text()); });
  await page.goto(srv.origin + "/app/", { waitUntil: "load" });
  await page.addScriptTag({ content: INK_PROBE });

  let fail = 0;
  const ok = (c, m) => { console.log((c ? "ok   " : "FAIL ") + m); if (!c) fail++; };

  const draw = (kind, over) => page.evaluate(async ([k, d]) => {
    const c = await window.BookedInStory.render(k, d);
    const S = window.BookedInStory;
    return {
      w: c.width, h: c.height,
      /* Above and below what the apps leave visible. */
      above: window.__ink(c, 0, 0, c.width, S.SAFE.top - 10),
      below: window.__ink(c, 0, S.SAFE.bottom + 10, c.width, c.height - S.SAFE.bottom - 10),
      /* The margins. Ink here is a line that did not fit. */
      left:  window.__ink(c, 0, 0, 80, c.height),
      right: window.__ink(c, c.width - 80, 0, 80, c.height),
      /* Where the Booked In mark goes on a free card: above the link pill,
         which is itself the last thing inside the visible area. */
      credit: window.__ink(c, 90, S.SAFE.bottom - 185, 420, 70),
      /* The body, so an empty card cannot pass every other check. */
      body: window.__ink(c, 80, S.SAFE.top, 920, S.SAFE.bottom - S.SAFE.top),
    };
  }, [kind, Object.assign({}, DATA, over || {})]);

  console.log("-- every card is the Stories frame, and has something on it --");
  for (const kind of ["spaces", "gap", "book"]) {
    const r = await draw(kind);
    ok(r.w === 1080 && r.h === 1920, `${kind}: 1080x1920 (${r.w}x${r.h})`);
    ok(r.body > 20000, `${kind}: there is a card here, not a blank (${r.body} ink)`);
  }

  console.log("\n-- nothing readable where the app puts its own buttons --");
  for (const kind of ["spaces", "gap", "book"]) {
    const r = await draw(kind);
    ok(r.above === 0, `${kind}: the top strip is clear (${r.above})`);
    ok(r.below === 0, `${kind}: the bottom strip is clear (${r.below})`);
  }

  console.log("\n-- nothing runs off the edge --");
  /* The names and dates most likely to break it: a long studio name, a long
     treatment, and the longest day-and-date English produces. */
  const LONG = {
    studio: "The Lash & Brow Studio by Antoinette, Nuneaton",
    service: "Russian volume infills with a lash lift",
    slots: [{ day: "Wednesday 28 September", time: "10:30am" }],
    treatments: [{ name: "Russian volume infills with a lash lift", price: "£125" }],
    tagline: "Mobile lashes, brows and facials across Nuneaton, Coventry and Hinckley",
  };
  for (const kind of ["spaces", "gap", "book"]) {
    const r = await draw(kind, LONG);
    ok(r.right === 0, `${kind}: nothing in the right margin with a long name (${r.right})`);
    ok(r.left === 0,  `${kind}: nor the left (${r.left})`);
    ok(r.above === 0 && r.below === 0,
       `${kind}: and it still does not grow into the covered strips`);
  }

  console.log("\n-- a single space reads as a single space --");
  {
    const r = await page.evaluate(async (d) => {
      const c = await window.BookedInStory.render("spaces", d);
      return c.toDataURL().length;
    }, Object.assign({}, DATA, { slots: [DATA.slots[0]] }));
    ok(r > 1000, "one slot still draws a card");
  }

  console.log("\n-- the mark is off every card now --");
  {
    // It used to come off at Pro and sit on free cards. 028 took it off
    // altogether: this is a post she makes to her own followers under her own
    // name, and 013 already observed that a card looking like us rather than
    // like her is a card she does not post. `credit` is no longer a thing the
    // renderer reads, so passing it must change nothing.
    const free = await draw("spaces", { credit: true });
    const pro  = await draw("spaces", { credit: false });
    ok(free.credit === 0, `no mark on what used to be a free card (${free.credit})`);
    ok(pro.credit === 0,  `and none on a Pro card (${pro.credit})`);
    ok(pro.body > 20000,  "and it is otherwise the same card");
    ok(free.body === pro.body,
       "the flag is dead: passing it draws an identical card");
  }

  console.log("\n-- her colours, not ours --");
  {
    const sample = (over) => page.evaluate(async ([d]) => {
      const c = await window.BookedInStory.render("spaces", d);
      const g = c.getContext("2d");
      const px = (x, y) => { const p = g.getImageData(x, y, 1, 1).data;
        return { rgb: [p[0], p[1], p[2]],
                 L: (0.2126*p[0] + 0.7152*p[1] + 0.0722*p[2]) / 255 }; };
      /* Background well clear of anything drawn on it, and the left padding of
         the link pill - inside the pill, but before the text starts at x=144,
         so this reads her accent rather than a letter's antialiasing. */
      return { bg: px(30, 1200), pill: px(115, 1575) };
    }, [Object.assign({}, DATA, over)]);

    const sage = await sample({ brand_hex: "#5F7A5C" });
    ok(sage.pill.rgb[1] > sage.pill.rgb[0] && sage.pill.rgb[1] > sage.pill.rgb[2],
       `a green brand gives a green link pill (${sage.pill.rgb})`);
    ok(sage.bg.L > 0.9, `and a light card stays light (${sage.bg.L.toFixed(2)})`);

    const dark = await sample({ brand_hex: "#C9A227", card_theme: "dark" });
    ok(dark.bg.L < 0.25, `a dark card is dark (${dark.bg.L.toFixed(2)})`);
    ok(dark.pill.L > dark.bg.L + 0.3,
       `with a pill that lifts off it (${dark.pill.L.toFixed(2)} on ${dark.bg.L.toFixed(2)})`);

    /* A near-black brand is the one that breaks a naive derivation: the accent
       comes out the same as the background and the card goes blank. */
    const noir = await sample({ brand_hex: "#111111", card_theme: "dark" });
    ok(noir.pill.L > noir.bg.L + 0.25,
       `even a near-black brand keeps a readable pill (${noir.pill.L.toFixed(2)} on ${noir.bg.L.toFixed(2)})`);
  }

  console.log("\n-- left or centred --");
  {
    const weight = (align) => page.evaluate(async ([d]) => {
      const c = await window.BookedInStory.render("book", d);
      /* Ink in the left third against the right third. Centred text spreads;
         left-aligned text piles up on the left. */
      return { l: window.__ink(c, 60, 300, 300, 900),
               r: window.__ink(c, 720, 300, 300, 900) };
    }, [Object.assign({}, DATA, { card_align: align })]);
    const left = await weight("left");
    const mid  = await weight("centre");
    ok(left.l > left.r, `left-aligned piles the ink on the left (${left.l} vs ${left.r})`);
    ok(mid.r > left.r, `and centring moves some of it across (${mid.r} vs ${left.r})`);
  }

  console.log("\n-- a logo that will not load --");
  {
    /* The browser raises a console error for a failed image load whatever we
       do about it, so anything added while this one test runs is dropped
       rather than filtered by message - the message does not carry the URL,
       and a filter loose enough to catch it would hide a real missing asset. */
    const before = errs.length;
    const r = await page.evaluate(async ([d]) => {
      const c = await window.BookedInStory.render("spaces", d);
      return window.__ink(c, 80, 270, 920, 1100);
    }, [Object.assign({}, DATA, { logo_url: "https://logo-does-not-exist.invalid/x.png" })]);
    ok(r > 20000, `a broken logo still gives her a card (${r} ink)`);
    errs.length = before;
  }

  console.log("\n-- it refuses what it cannot draw --");
  {
    const msg = await page.evaluate(() =>
      window.BookedInStory.render("nonsense", {}).then(() => "", (e) => e.message));
    ok(/unknown card/.test(msg), `an unknown card is an error, not a blank (${msg})`);
  }

  ok(errs.length === 0, `no console errors while drawing (${errs.length})` +
     (errs.length ? ": " + errs[0].slice(0, 120) : ""));
  await browser.close();
  await srv.close();
  console.log("");
  console.log(fail ? "FAILURES" : "all passed");
  process.exit(fail ? 1 : 0);
})();
