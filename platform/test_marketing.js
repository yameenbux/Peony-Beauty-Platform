/* The marketing site, the legal pages and the 404, on every screen that
 * matters, plus the contrast of every text style on the page.
 *
 * Two things are checked that an eye does not reliably catch. The first is
 * horizontal overflow: a single element three pixels too wide gives a phone a
 * sideways scroll and makes the whole page feel broken, and it is invisible on
 * a desktop. The second is contrast, computed the way the WCAG formula does,
 * including compositing a translucent colour onto whatever is actually behind
 * it - which is how a dark panel with pale text on it gets wrongly reported as
 * a failure by every naive checker.
 *
 *   node test_marketing.js
 */
const { chromium, devices } = require('playwright');
const { start, ROOT } = require('./serve');
const path = require('node:path');
const fs = require('node:fs');
const OUT = path.join(__dirname, '..', '.shots');
fs.mkdirSync(OUT, { recursive: true });
let PAGE = null, ORIGIN = null;

const TARGETS = [
  { n:'iphone-se', d:devices['iPhone SE'] },
  { n:'iphone-12', d:devices['iPhone 12'] },
  { n:'galaxy-s9', d:devices['Galaxy S9+'] },
  { n:'pixel-7',   d:devices['Pixel 7'] },
  { n:'ipad-land', d:devices['iPad Pro 11 landscape'] },
  { n:'desk-1024', d:{ viewport:{width:1024,height:760} } },
  { n:'desk-1280', d:{ viewport:{width:1280,height:860} } },
  { n:'desk-1440', d:{ viewport:{width:1440,height:900} } },
];
const lum = c => { const f=v=>{v/=255;return v<=0.03928?v/12.92:Math.pow((v+0.055)/1.055,2.4);};
                   return 0.2126*f(c[0])+0.7152*f(c[1])+0.0722*f(c[2]); };

(async () => {
  const srv = await start();
  ORIGIN = srv.origin;
  PAGE = srv.origin + '/';
  const browser = await chromium.launch();
  let fails = 0;

  for (const t of TARGETS) {
    const ctx = await browser.newContext({ ...t.d });
    const page = await ctx.newPage();
    const errs = [];
    page.on('console', m => { if (m.type()==='error') errs.push(m.text()); });
    page.on('pageerror', e => errs.push('PAGEERROR ' + e.message));
    await page.goto(PAGE, { waitUntil:'load' });
    await page.waitForTimeout(800);

    const head = await page.evaluate(() => {
      const de = document.documentElement;
      // an element clipped by an ancestor cannot widen the document, so the
      // honest signal is scrollWidth; the list below is only a diagnostic
      const clipped = el => {
        for (let n = el.parentElement; n; n = n.parentElement) {
          const o = getComputedStyle(n);
          if (o.overflowX !== 'visible' || o.overflowY !== 'visible') return true;
        }
        return false;
      };
      const over = [];
      document.querySelectorAll('body *').forEach(el => {
        const b = el.getBoundingClientRect();
        if (!b.width && !b.height) return;
        if ((b.right > de.clientWidth + 1.5 || b.left < -1.5) && !clipped(el))
          over.push(el.tagName.toLowerCase()+'.'+(el.className||'').toString().split(' ')[0]
                    +' ['+Math.round(b.left)+'→'+Math.round(b.right)+']');
      });
      return { mode:document.compatMode, scrollW:de.scrollWidth, clientW:de.clientWidth,
               over:over.slice(0,5), overN:over.length };
    });

    // scroll the whole page: this is what arms the reveals and, on a phone
    // where the devices start below the fold, what starts the booking loop
    await page.evaluate(async () => {
      const h = document.documentElement.scrollHeight;
      for (let y = 0; y < h; y += 400) { window.scrollTo(0, y); await new Promise(r => setTimeout(r, 55)); }
    });
    await page.waitForTimeout(500);
    const revealed = await page.evaluate(() => ({
      in: document.querySelectorAll('.rv.in').length, all: document.querySelectorAll('.rv').length }));

    // on a short phone the devices start below the fold, so the loop is
    // correctly paused at scroll 0; bring the stage into view to test it
    await page.evaluate(() => document.getElementById('stage')
      .scrollIntoView({block:'center'}));
    await page.waitForTimeout(6000);
    const loop = await page.evaluate(() => ({
      rows: document.querySelectorAll('#rows .row').length,
      taken: (document.querySelectorAll('.dash-stats b')[2]||{}).textContent }));

    await page.screenshot({ path:`${OUT}/${t.n}.png` });
    const bad = head.overN>0 || errs.length>0 || head.scrollW>head.clientW+1
             || head.mode!=='CSS1Compat' || revealed.in!==revealed.all || loop.rows!==4;
    if (bad) fails++;
    console.log(`${bad?'FAIL':'ok  '} ${t.n.padEnd(10)} ${String(head.clientW).padStart(4)}px  `
      +`${head.mode==='CSS1Compat'?'std':'QUIRKS'}  scrollW=${head.scrollW}  over=${head.overN}  `
      +`err=${errs.length}  reveal=${revealed.in}/${revealed.all}  rows=${loop.rows} taken=${loop.taken}`);
    if (head.overN) console.log('       '+head.over.join('\n       '));
    if (errs.length) console.log('       '+errs.slice(0,3).join('\n       '));
    await ctx.close();
  }

  /* The pages nobody looks at twice, which is exactly why they break. */
  console.log('');
  /* /no-such-thing is served the booking page by the catch-all rewrite, which
     is where the real "nothing here" message lives; 404.html is checked at its
     own path because that is the only way to reach it while that rule exists. */
  for (const [name, url] of [['privacy','/privacy.html'], ['terms','/terms.html'],
                             ['nothing-here','/no-such-thing-at-all'],
                             ['404-file','/404.html']]) {
    for (const [dn, dev] of [['se', devices['iPhone SE']],
                             ['desk', { viewport:{width:1280,height:900} }]]) {
      const c = await browser.newContext({ ...dev });
      const p = await c.newPage();
      const errs = [];
      p.on('console', m => { if (m.type()==='error') errs.push(m.text()); });
      p.on('pageerror', e => errs.push('PAGEERROR ' + e.message));
      await p.goto(ORIGIN + url, { waitUntil:'load' });
      await p.waitForTimeout(250);
      const r = await p.evaluate(() => ({ sw:document.documentElement.scrollWidth,
        cw:document.documentElement.clientWidth, mode:document.compatMode,
        title:document.title }));
      const bad = r.sw > r.cw + 1 || errs.length > 0 || r.mode !== 'CSS1Compat';
      if (bad) fails++;
      console.log(`${bad?'FAIL':'ok  '} ${(name+'/'+dn).padEnd(14)} ${String(r.cw).padStart(4)}px  `
        + `scrollW=${r.sw}  err=${errs.length}  "${r.title}"`);
      await p.screenshot({ path:`${OUT}/${name}-${dn}.png` });
      await c.close();
    }
  }

  const ctx = await browser.newContext({ viewport:{width:1280,height:900} });
  const page = await ctx.newPage();
  await page.goto(PAGE, { waitUntil:'load' });
  await page.waitForTimeout(500);
  const pairs = await page.evaluate(() => {
    const parse = s => { const m=(s||'').match(/[\d.]+/g); return m?m.map(Number):null; };
    const over = (fg,bg) => { const a = fg[3]===undefined?1:fg[3];
      return [0,1,2].map(i => fg[i]*a + bg[i]*(1-a)); };
    // a gradient sets background-IMAGE, not background-color: walking past it
    // and landing on the body is how a dark panel reads as a contrast failure
    function bgOf(el){
      let stack = [], grad = null;
      for (let n = el; n && n !== document.documentElement; n = n.parentElement) {
        const cs = getComputedStyle(n);
        if (cs.backgroundImage && cs.backgroundImage !== 'none' && !grad) {
          const stops = cs.backgroundImage.match(/rgba?\([^)]+\)/g);
          if (stops) { const c = stops.map(parse);
            grad = [0,1,2].map(i => c.reduce((s,x)=>s+x[i],0)/c.length); }
        }
        const c = parse(cs.backgroundColor);
        if (c && (c[3]===undefined || c[3] > 0)) {
          stack.push(c); if ((c[3]===undefined?1:c[3]) >= 1) break;
        }
        if (grad) break;
      }
      let base = grad || [255,255,255];
      for (let i = stack.length-1; i >= 0; i--) base = over(stack[i], base);
      return base;
    }
    const out = [];
    document.querySelectorAll('p,span,li,td,th,h1,h2,h3,h4,h5,b,time,summary,a,div').forEach(el => {
      const direct = [...el.childNodes].some(n => n.nodeType===3 && n.textContent.trim());
      if (!direct) return;
      const cs = getComputedStyle(el);
      if (cs.visibility==='hidden' || cs.display==='none') return;
      out.push({ k:(el.className||'').toString().split(' ')[0]||el.tagName,
                 size:parseFloat(cs.fontSize), w:cs.fontWeight,
                 fg:over(parse(cs.color), bgOf(el)), bg:bgOf(el) });
    });
    return out;
  });
  const seen = new Map();
  for (const p of pairs) {
    const ratio = (() => { const a=lum(p.fg), b=lum(p.bg);
      return (Math.max(a,b)+0.05)/(Math.min(a,b)+0.05); })();
    const large = p.size>=24 || (p.size>=18.66 && +p.w>=700);
    const need = large ? 3 : 4.5;
    const key = `${p.k}@${p.size.toFixed(1)}`;
    if (!seen.has(key) || seen.get(key).ratio > ratio) seen.set(key, {ratio,need});
  }
  let cfail = 0;
  const worst = [...seen.entries()].sort((a,b)=>a[1].ratio-b[1].ratio);
  console.log('\ncontrast — ten lowest of ' + worst.length + ' text styles:');
  worst.forEach(([k,v],i) => { const pass = v.ratio>=v.need; if(!pass) cfail++;
    if (i<10 || !pass) console.log(`  ${pass?'ok  ':'FAIL'} ${k.padEnd(24)} ${v.ratio.toFixed(2)}:1 (needs ${v.need})`); });
  /* -------------------------------------------------------- monthly/yearly --
     The one control on the page that changes what somebody is about to be
     charged, so what it claims has to be arithmetic rather than copy. */
  let bfail = 0;
  {
    const bok = (c, m) => { console.log((c ? '  ok   ' : '  FAIL ') + m); if (!c) bfail++; };
    console.log('\nthe billing switch:');
    await page.goto(PAGE, { waitUntil:'load' });
    await page.waitForTimeout(400);

    const read = () => page.$$eval('#pricing .tier', ts => ts.map(t => ({
      name: t.querySelector('.tier-nm').textContent.trim(),
      price: t.querySelector('.tier-pr b').textContent.trim(),
      unit: t.querySelector('.tier-pr span').textContent.trim(),
      sub:  (t.querySelector('.tier-sub') || {}).textContent || '',
    })));

    const monthly = await read();
    bok(monthly.length === 3, 'three tiers');
    bok(monthly.every(t => t.unit === 'a month' || t.unit === 'forever'),
        'it opens on monthly, which is what the page said before the switch existed');

    /* Nothing claimed that is not on the card. */
    await page.click('#billsw [data-cycle="year"]');
    await page.waitForTimeout(450);
    const yearly = await read();
    const by = Object.fromEntries(yearly.map(t => [t.name, t]));
    const bm = Object.fromEntries(monthly.map(t => [t.name, t]));

    bok(by['Pro'].price === '\u00a396' && by['Pro'].unit === 'a year',
        `Pro yearly is ${by['Pro'].price} ${by['Pro'].unit}`);
    bok(by['Pro+'].price === '\u00a3230' && by['Pro+'].unit === 'a year',
        `Pro+ yearly is ${by['Pro+'].price} ${by['Pro+'].unit}`);
    bok(by['Free'].price === '\u00a30', 'Free is still free, whichever way you pay');

    /* The sums. A saving the card states and the prices contradict is the one
       bug on this page that would cost somebody money. */
    const money = s => Number(String(s).replace(/[^0-9.]/g, ''));
    for (const name of ['Pro', 'Pro+']) {
      const m = money(bm[name].price), y = money(by[name].price);
      const saved = m * 12 - y;
      const pcm = y / 12;
      const claimedSave = money((by[name].sub.match(/£([\d.]+) a year saved/) || [])[1] || 0);
      const claimedPcm  = money((by[name].sub.match(/£([\d.]+) a month/) || [])[1] || 0);
      bok(Math.abs(claimedSave - saved) < 0.01,
          `${name} says it saves £${claimedSave}, and 12 × £${m} − £${y} = £${saved}`);
      bok(Math.abs(claimedPcm - pcm) < 0.01,
          `${name} says £${claimedPcm} a month, and £${y} ÷ 12 = £${pcm.toFixed(2)}`);
      bok(saved / (m * 12) >= 0.20 - 0.001,
          `${name} really is the 20% the switch advertises (${(saved / (m * 12) * 100).toFixed(1)}%)`);
    }

    /* And back, because a toggle that only goes one way strands her on the
       bigger number. */
    await page.click('#billsw [data-cycle="month"]');
    await page.waitForTimeout(450);
    const again = await read();
    bok(JSON.stringify(again) === JSON.stringify(monthly), 'switching back restores every card exactly');
    bok(await page.getAttribute('#billsw [data-cycle="month"]', 'aria-checked') === 'true',
        'and the control says which side it is on, for a screen reader too');
  }

  /* -------------------------------------------------------- structured data --
     Google reads the prices in the markup, not the ones on the cards. If the
     two drift apart it shows a price we are not charging - which is both a
     trust problem and the sort of thing that gets price markup ignored or
     penalised. So the prices are checked against the cards rather than against
     a list written here. */
  let sfail = 0;
  {
    const sok = (c, m) => { console.log((c ? '  ok   ' : '  FAIL ') + m); if (!c) sfail++; };
    console.log('\nstructured data:');
    await page.goto(PAGE, { waitUntil:'load' });
    await page.waitForTimeout(300);
    const blocks = await page.$$eval('script[type="application/ld+json"]', ns => ns.map(n => n.textContent));
    sok(blocks.length > 0, 'the page carries structured data');
    let graph = [];
    try { const d = JSON.parse(blocks[0]); graph = d['@graph'] || [d]; sok(true, 'and it is valid JSON'); }
    catch (e) { sok(false, 'and it is valid JSON — ' + e.message); }

    const byType = Object.fromEntries(graph.map(n => [n['@type'], n]));
    sok(!!byType.Organization, 'an Organization');
    sok(!!byType.SoftwareApplication, 'and the product itself');

    /* Nothing invented. Review markup with no reviews behind it is the one
       kind of structured data that is actively punished. */
    const raw = blocks.join(' ');
    sok(!/aggregateRating|"@type"\s*:\s*"Review"/.test(raw),
        'and claims no rating or review it does not have');

    const cards = await page.$$eval('#pricing .tier', ts => ts.map(t => ({
      name: t.querySelector('.tier-nm').textContent.trim(),
      price: t.querySelector('.tier-pr b').textContent.replace(/[^0-9.]/g, ''),
    })));
    const offers = (byType.SoftwareApplication || {}).offers || [];
    sok(offers.length === cards.length,
        `one offer per tier on the page (${offers.length} offers, ${cards.length} cards)`);
    for (const c of cards) {
      const o = offers.filter(x => x.name === c.name)[0];
      sok(!!o, `${c.name} is in the markup`);
      if (o) sok(o.price === c.price,
                 `${c.name} is marked up at £${o.price} and the card says £${c.price}`);
      if (o) sok(o.priceCurrency === 'GBP', `${c.name} is priced in pounds`);
    }
  }

  /* ---------------------------------------------------------------- the nav --
     The island is a fixed-height pill, so anything inside it that wraps hangs
     out of the bottom. Nothing looking for a SIDEWAYS scroll can see that: the
     wordmark broke across two lines at 320px and every overflow check on this
     page stayed green. Checked at every width, because it is the narrow ones
     that break and the wide ones that get looked at. */
  let nfail = 0;
  {
    const nok = (c, m) => { console.log((c ? '  ok   ' : '  FAIL ') + m); if (!c) nfail++; };
    console.log('\nthe nav island:');
    for (const t of TARGETS) {
      const c = await browser.newContext({ ...t.d });
      const pg = await c.newPage();
      await pg.goto(PAGE, { waitUntil:'load' });
      await pg.waitForTimeout(500);
      const r = await pg.evaluate(() => {
        const island = document.querySelector('.nav-in');
        const b = island.getBoundingClientRect();
        let worst = 0, who = '';
        island.querySelectorAll('*').forEach(el => {
          if (!el.offsetWidth && !el.offsetHeight) return;
          const q = el.getBoundingClientRect();
          const out = Math.max(b.top - q.top, q.bottom - b.bottom);
          if (out > worst) { worst = out; who = el.className || el.tagName; }
        });
        return { out: Math.round(worst), who, h: Math.round(b.height) };
      });
      nok(r.out <= 1, `${t.n.padEnd(10)} nothing hangs out of the island` +
          (r.out > 1 ? ` — ${r.who} escapes by ${r.out}px` : ''));
      await c.close();
    }
  }

  /* ------------------------------------------------------------ the buttons --
     The fill opens from where the pointer crossed the edge. Both halves are
     worth a check: that it ANIMATES rather than snapping, which is the whole
     effect, and that the origin really follows the pointer rather than always
     opening from the middle - a screenshot cannot tell those two apart. */
  let btfail = 0;
  {
    const bok = (c, m) => { console.log((c ? '  ok   ' : '  FAIL ') + m); if (!c) btfail++; };
    console.log('\nthe button fill:');
    await page.goto(PAGE, { waitUntil:'load' });
    await page.waitForTimeout(500);
    const el = await page.$('.btn-ghost');
    const box = await el.boundingBox();
    const scale = () => page.evaluate(() => {
      const m = new DOMMatrix(getComputedStyle(document.querySelector('.btn-ghost'), '::before').transform);
      return +m.a.toFixed(3);
    });
    bok(await scale() === 0, 'at rest there is no fill at all');

    /* In at the left edge, not the middle. */
    await page.mouse.move(box.x + 3, box.y + box.height / 2);
    const seen = [];
    for (let i = 0; i < 5; i++) { seen.push(await scale()); await page.waitForTimeout(80); }
    const mid = seen.filter(v => v > 0 && v < 0.999);
    bok(mid.length > 0, `it animates rather than snapping (${seen.join(' → ')})`);
    bok(seen.every((v, i) => i === 0 || v >= seen[i - 1]), 'and only ever grows');
    await page.waitForTimeout(600);
    bok(await scale() === 1, 'and ends up covering the button');

    const ox = await page.evaluate(() =>
      parseFloat(document.querySelector('.btn-ghost').style.getPropertyValue('--ox')));
    bok(ox < 15, `it opens from where the pointer came in, not the middle (${ox.toFixed(1)}%)`);

    /* Off the button, back to nothing, or the next hover starts filled. */
    await page.mouse.move(box.x - 60, box.y - 60);
    await page.waitForTimeout(700);
    bok(await scale() === 0, 'and empties again when the pointer leaves');

    /* A quiet button is a word, not a shape. */
    const quiet = await page.evaluate(() => {
      const b = document.createElement('button');
      b.className = 'btn btn-quiet'; b.textContent = 'x';
      document.body.appendChild(b);
      return getComputedStyle(b, '::before').display;
    });
    bok(quiet === 'none', 'a quiet button is not given a shape it does not have');
  }

  /* ----------------------------------------------------------- the anchors --
     Every section the nav points at sets padding-top:0, and the bar is sticky,
     so a jump landed the heading underneath it. The eye does not catch this in
     a screenshot of the top of the page; it only shows up after a click. */
  let afail = 0;
  {
    console.log('\nnav anchors — where the heading lands after a jump:');
    const links = await page.$$eval('.nav-links a[href^="#"]', as =>
      [...new Set(as.map(a => a.getAttribute('href')))]);
    for (const href of links) {
      const r = await page.evaluate(async (h) => {
        const el = document.querySelector(h);
        if (!el) return null;
        window.location.hash = '';
        window.scrollTo(0, 0);
        window.location.hash = h;
        await new Promise(r => setTimeout(r, 400));
        const bar = document.querySelector('.nav').getBoundingClientRect().height;
        const head = el.querySelector('h1,h2,h3') || el;
        return { top: head.getBoundingClientRect().top, bar,
                 vh: window.innerHeight };
      }, href);
      if (!r) continue;
      /* Clear of the bar, and still in the top half of the screen - a section
         whose own padding pushes its heading below the fold has not been
         jumped to in any sense the reader would recognise. */
      const ok = r.top >= r.bar && r.top <= r.vh / 2;
      if (!ok) afail++;
      console.log(`  ${ok?'ok  ':'FAIL'} ${href.padEnd(10)} heading at ${Math.round(r.top)}px, ` +
                  `bar is ${Math.round(r.bar)}px`);
    }
  }

  /* ------------------------------------------------------------- the mark --
     The ring says "six slots, one of them taken". Five of the six were drawn
     in a pink so close to the backdrop that they did not survive it, on every
     background the mark is used against, so the logo rendered as a single
     carmine comma. Nothing that reads text or markup can see that: the SVG is
     correct and complete either way. So this paints the mark on each real
     backdrop and counts how much of it is actually there. */
  let mfail = 0;
  {
    /* From dist/, because that is the file that ships. */
    const fs = require('fs');
    const icon = fs.readFileSync(require('path').join(ROOT, 'site', 'icon.svg'), 'utf8');
    const page = await (await browser.newContext({ viewport:{width:120,height:120} })).newPage();
    const backdrops = { 'petal (app rail)':'#FAEFF0',
                        'porcelain (booking page)':'#FDFAFA', 'white':'#FFFFFF' };
    console.log('\nthe mark — how much of it survives its backdrop:');
    for (const [name, bg] of Object.entries(backdrops)) {
      await page.setContent(`<body style="margin:0;background:${bg}">${
        icon.replace(/width="32" height="32"/, 'width="34" height="34"')}</body>`);
      const lit = await page.evaluate(async (bgc) => {
        const svg = new XMLSerializer().serializeToString(document.querySelector('svg'));
        const img = new Image();
        img.src = 'data:image/svg+xml;base64,' + btoa(unescape(encodeURIComponent(svg)));
        await img.decode();
        const c = document.createElement('canvas'); c.width = 34; c.height = 34;
        const x = c.getContext('2d');
        x.fillStyle = bgc; x.fillRect(0, 0, 34, 34);
        x.drawImage(img, 0, 0, 34, 34);
        const d = x.getImageData(0, 0, 34, 34).data;
        const b = [parseInt(bgc.slice(1,3),16), parseInt(bgc.slice(3,5),16), parseInt(bgc.slice(5,7),16)];
        let n = 0;
        for (let i = 0; i < d.length; i += 4)
          if (Math.abs(d[i]-b[0]) + Math.abs(d[i+1]-b[1]) + Math.abs(d[i+2]-b[2]) > 120) n++;
        return n;
      }, bg);
      /* One slot alone paints about 45px. Six need to be well clear of that,
         or the count the mark exists to show cannot be counted. */
      const ok = lit >= 120;
      if (!ok) mfail++;
      console.log(`  ${ok?'ok  ':'FAIL'} ${name.padEnd(26)} ${String(lit).padStart(3)}px visible (needs 120+)`);
    }
  }

  await ctx.close(); await browser.close(); await srv.close();
  console.log(`\n${fails} layout failure(s), ${cfail} contrast failure(s), ` +
              `${afail} anchor failure(s), ${bfail} billing failure(s), ` +
              `${btfail} button failure(s), ${nfail} nav failure(s), ` +
              `${sfail} structured-data failure(s), ${mfail} logo failure(s)`);
  const bad = fails + cfail + afail + bfail + btfail + nfail + sfail + mfail;
  console.log(bad ? 'FAILURES' : 'all passed');
  process.exit(bad ? 1 : 0);
})();
