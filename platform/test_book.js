const { chromium, devices } = require('playwright');
const { start } = require('./serve');
/* Over HTTP, from the built site, because that is the only way the absolute
   paths and the catch-all rewrite are exercised at all. Filled in by main(). */
let ORIGIN = null;
const OUT  = '/tmp/claude-0/-home-user-test/24071892-c542-5742-989c-e77eb82ac33e/scratchpad/shots';

const STUB = `
window.supabase = { createClient: function(){
  var S = window.__S;
  function res(d,e){ return Promise.resolve({ data:d===undefined?null:d, error:e||null }); }
  return {
    storage: { from: function(){ return {
      getPublicUrl: function(path){ return { data:{ publicUrl:'https://stub.test/' + path } }; }
    }; } },
    rpc: function(name, args){
    S.ops.push({ name: name, args: args });
    if(name === 'get_studio')  return res(S.slug === (args.p_slug) ? S.studio : null);
    if(name === 'free_slots')  return res(S.slotsFor(args.p_from));
    if(name === 'get_booking'){
      if(args.p_token !== '11111111-2222-3333-4444-555555555555') return res(null);
      return res(S.booking);
    }
    if(name === 'set_rebook_opt_out'){
      if(args.p_token !== 'ab12cd34-ef56-7890-abcd-ef1234567890') return res(null, { message:'That link is not valid.' });
      S.optedOut = (args.p_off === undefined ? true : args.p_off);
      return res({ studio:'Studio Mila', opted_out:S.optedOut });
    }
    if(name === 'cancel_booking'){
      if(S.cancelFails) return res(null, { message:'It is too close to your appointment to cancel here.' });
      S.booking = Object.assign({}, S.booking, { status:'cancelled', can_cancel:false });
      return res({ ref:args.p_ref, cancelled:true });
    }
    if(name === 'book'){
      if(S.collide){ S.collide = false;
        /* PostgREST passes the SQLSTATE through, and the page uses it to tell
           a lost race apart from a mistyped address. */
        return res(null, { code:'P0003', message:'Someone just took that time.' }); }
      if(S.limited){ S.limited = false;
        return res(null, { code:'P0004',
          message:'You already have 3 appointments booked here. Cancel one before booking another.' }); }
      return res([{ ref:'AB12CD34', token:'11111111-2222-3333-4444-555555555555',
                    starts_at:args.p_starts, ends_at:args.p_starts }]);
    }
    return res(null,{message:'unknown rpc '+name});
  }};
}};`;
const CONFIG = `window.BOOKEDIN={SUPABASE_URL:"https://stub.supabase.co",SUPABASE_ANON_KEY:"stub",PAGE_HOST:"booked-in.co.uk"};`;

// slots ten and eleven days out, so they are always in a real future month
function state(opts) {
  opts = opts || {};
  return {
    slug: 'studio-mila', ops: [], collide: !!opts.collide, limited: !!opts.limited,
    emptyFirstMonth: !!opts.emptyFirstMonth,
    studio: {
      slug:'studio-mila', name:'Studio Mila', tagline:'Mobile lashes · Manchester',
      trade:'lashes', timezone:'Europe/London', plan: opts.plan || 'free', notice_hours:24,
      services:[{id:'s1',name:'Hybrid full set',price_pence:5000,duration_min:120,photo_path:'t1/s1.jpg'},
                {id:'s2',name:'Russian infills',price_pence:4000,duration_min:90,photo_path:null}],
      openings:[] },
    booking: {
      ref:'AB12CD34', starts_at: opts.when || new Date(Date.now()+10*864e5).toISOString(),
      ends_at: opts.when || new Date(Date.now()+10*864e5).toISOString(),
      status: opts.status || 'confirmed', client_name:'Ruby Hall',
      service:'Hybrid full set', price_pence:5000, studio:'Studio Mila',
      slug:'studio-mila', timezone:'Europe/London', cancel_hours:24,
      can_cancel: opts.status !== 'cancelled' },
    cancelFails: !!opts.cancelFails
  };
}
const SLOTGEN = `
window.__S.slotsFor = function(from){
  var d0 = new Date(); d0.setDate(d0.getDate() + 10);
  var d1 = new Date(); d1.setDate(d1.getDate() + 11);
  var inMonth = function(d){
    var f = new Date(from);
    return d.getFullYear() === f.getFullYear() && d.getMonth() === f.getMonth();
  };
  var out = [];
  var push = function(d, hrs){ hrs.forEach(function(h){
    out.push(new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate(), h, 0, 0)).toISOString()); }); };
  if(window.__S.emptyFirstMonth){
    var f = new Date(from);
    if(f.getMonth() === new Date().getMonth()) return [];
    var n = new Date(); n.setMonth(n.getMonth()+1); n.setDate(12);
    push(n,[9,11,14]); return out;
  }
  if(inMonth(d0)) push(d0,[9,11,14]);
  if(inMonth(d1)) push(d1,[10,13]);
  return out;
};`;

async function mk(browser, st, dev, path) {
  const ctx = await browser.newContext(dev || { viewport:{width:1280,height:900} });
  const page = await ctx.newPage();
  const errs = [];
  page.on('console', m => { if (m.type()==='error') errs.push(m.text()); });
  page.on('pageerror', e => errs.push('PAGEERROR ' + e.message));
  await page.route('**/supabase-js*', r => r.fulfill({ contentType:'application/javascript', body: STUB }));
  await page.route('**/config.js', r => r.fulfill({ contentType:'application/javascript', body: CONFIG }));
  await page.route('**/stub.test/**', r => r.fulfill({ contentType:'image/png',
    body: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==','base64') }));
  await page.addInitScript(`window.__S = ${JSON.stringify(st)}; ${SLOTGEN}`);
  /* A studio's real address, which is a path under the rewrite rather than a
     query string. ORIGIN + path, so a test can ask for any address it likes. */
  await page.goto(ORIGIN + (path === undefined ? '/studio-mila' : path), { waitUntil:'load' });
  await page.waitForTimeout(260);
  return { ctx, page, errs };
}
const firstOpenDay = page => page.locator('.grid button.open').first();

(async () => {
  /* The booking page is reached at a studio's own path, not at the file it is
     served from, so that is where the tests open it. */
  const srv = await start();
  ORIGIN = srv.origin;
  const browser = await chromium.launch();
  let fail = 0;
  const ok = (c,m) => { console.log((c?'ok   ':'FAIL ')+m); if(!c) fail++; };

  { const {ctx,page} = await mk(browser, state(), null, '/book/index.html');
    ok(await page.isVisible('#gone'), 'the bare template, with no studio in the path, says so');
    await ctx.close(); }
  { const {ctx,page} = await mk(browser, state(), null, '/nobody');
    ok(await page.isVisible('#gone'), 'an unknown studio says so'); await ctx.close(); }

  { const {ctx,page,errs} = await mk(browser, state());
    ok(await page.textContent('#who') === 'Studio Mila', 'her name is the heading');
    ok(await page.textContent('#tag') === 'Mobile lashes · Manchester', 'her tagline shows');
    ok((await page.locator('.svc').count()) === 2, 'both treatments are offered');
    ok(/£50/.test(await page.textContent('.svc')), 'prices show in pounds');
    ok(/120 minutes/.test(await page.textContent('.svc')), 'each treatment shows how long it takes');
    ok((await page.locator('.svc:first-child .shot img').count()) === 1,
       'a treatment with a photo shows it');
    ok((await page.getAttribute('.svc:first-child .shot img','src')) === 'https://stub.test/t1/s1.jpg',
       'the photo comes from her own storage folder');
    ok((await page.locator('.svc:nth-child(2) .shot').count()) === 0,
       'a treatment without a photo leaves no empty box');
    ok(await page.isVisible('#credit'), 'the free plan carries the Booked In credit');
    ok(await page.isHidden('#s-when'), 'the calendar waits until a treatment is picked');

    await page.locator('.svc').first().click();
    await page.waitForTimeout(400);
    ok(await page.isVisible('#s-when'), 'picking a treatment reveals the calendar');
    const open = await page.locator('.grid button.open').count();
    ok(open === 2, `only days with free times are clickable (${open})`);
    ok((await page.locator('.grid button:disabled').count()) > 20, 'the rest of the month is not clickable');

    await firstOpenDay(page).click();
    await page.waitForTimeout(300);
    ok(await page.isVisible('#s-time'), 'picking a day reveals the times');
    ok((await page.locator('#time-list button').count()) === 3, 'that day offers its three times');
    // the stub emits 09:00 UTC; what the page must show is that instant in
    // Europe/London, which is 10:00 while British Summer Time is running
    const want = await page.evaluate(() => {
      const iso = window.__S.slotsFor(new Date().toISOString().slice(0,10))[0];
      return new Intl.DateTimeFormat('en-GB',{timeZone:'Europe/London',hour:'2-digit',
        minute:'2-digit',hour12:false}).format(new Date(iso));
    });
    const got = await page.textContent('#time-list button');
    ok(got === want, `times read in her timezone, not the viewer's (shows ${got}, UTC slot is 09:00)`);
    ok(/What time on/.test(await page.textContent('#time-head')), 'the time heading names the day');

    await page.locator('#time-list button').first().click();
    await page.waitForTimeout(300);
    ok(await page.isVisible('#s-you'), 'picking a time reveals the form');
    const sum = await page.textContent('#summary');
    ok(/Hybrid full set/.test(sum) && /£50/.test(sum) && sum.indexOf(want) !== -1,
       'the summary repeats what she chose');
    ok((await page.locator('#summary img').count()) === 1, 'the summary carries the photo too');

    await page.fill('#cname','Ruby Hall');
    await page.fill('#cmail','ruby@example.com');
    /* The form refuses a submit within two seconds of appearing, so a real
       booking has to wait as a real person would. The guard itself is tested
       on its own further down. */
    await page.waitForTimeout(2100);
    await page.click('#go');
    await page.waitForTimeout(400);
    ok(await page.isVisible('#s-done'), 'confirming shows the confirmation');
    ok(/AB12CD34/.test(await page.textContent('#done-ref')), 'the reference is shown');
    const mhref = await page.getAttribute('#manage','href');
    ok(/r=AB12CD34/.test(mhref) && /t=11111111/.test(mhref),
       'the confirmation links to a manage page carrying the token');
    ok(await page.isHidden('#s-svc'), 'the booking form is put away afterwards');
    const call = await page.evaluate(() => window.__S.ops.filter(o=>o.name==='book')[0]);
    ok(call.args.p_name === 'Ruby Hall' && call.args.p_phone === null,
       'book() gets her details, with no phone sent as null');
    ok(errs.length === 0, `no console errors through a whole booking (${errs.length})`);
    await ctx.close(); }

  // the race, from the client's side
  { const {ctx,page,errs} = await mk(browser, state({collide:true}));
    await page.locator('.svc').first().click(); await page.waitForTimeout(400);
    await firstOpenDay(page).click(); await page.waitForTimeout(250);
    await page.locator('#time-list button').first().click(); await page.waitForTimeout(250);
    await page.fill('#cname','Late Lucy'); await page.fill('#cmail','lucy@example.com');
    await page.waitForTimeout(2100);
    await page.click('#go');
    await page.waitForTimeout(500);
    ok(/just took that time/.test(await page.textContent('#toast')), 'a lost race is explained plainly');
    ok(await page.isHidden('#s-done'), 'a lost race does not show a confirmation');
    ok(await page.isHidden('#s-you'), 'a lost race clears the form');
    ok(await page.isVisible('#s-when'), 'a lost race leaves her on the calendar to pick again');
    ok(errs.length === 0, `no console errors on a lost race (${errs.length})`);
    await ctx.close(); }

  /* ------------------------------------------------- the form's defences --
     A booking page is a public RPC with a text box in front of it. These are
     the checks that stand between a bored stranger and somebody's week. */
  async function toForm(st) {
    const r = await mk(browser, st || state());
    await r.page.locator('.svc').first().click(); await r.page.waitForTimeout(400);
    await firstOpenDay(r.page).click(); await r.page.waitForTimeout(250);
    await r.page.locator('#time-list button').first().click(); await r.page.waitForTimeout(250);
    return r;
  }
  const bookCalls = page => page.evaluate(() => window.__S.ops.filter(o => o.name === 'book').length);

  { const {ctx,page,errs} = await toForm();
    await page.waitForTimeout(2100);
    await page.click('#go');
    await page.waitForTimeout(200);
    ok(/need a name/i.test(await page.textContent('#e-cname')), 'an empty name is named, under the field');
    ok(await bookCalls(page) === 0, 'and nothing is sent to the database');
    ok(await page.getAttribute('#cname','aria-invalid') === 'true', 'the field is marked invalid for a screen reader');

    await page.fill('#cname','Ruby Hall');
    await page.fill('#cmail','ruby@example');          // no dot: the browser accepts this, we do not
    await page.click('#go');
    await page.waitForTimeout(200);
    ok(/email address/i.test(await page.textContent('#e-cmail')), 'an address the browser would accept is still caught');
    ok(await bookCalls(page) === 0, 'and that is not sent either');

    await page.fill('#cmail','ruby@example.com');
    await page.waitForTimeout(100);
    ok(await page.getAttribute('#cmail','aria-invalid') === 'false', 'correcting it clears the message as she types');
    ok(errs.length === 0, `no console errors while being refused (${errs.length})`);
    await ctx.close(); }

  { const {ctx,page} = await toForm();
    await page.fill('#cname','Bot'); await page.fill('#cmail','bot@example.com');
    await page.evaluate(() => { document.getElementById('ctrap').value = 'http://spam.example'; });
    await page.waitForTimeout(2100);
    await page.click('#go');
    await page.waitForTimeout(250);
    ok(await bookCalls(page) === 0, 'a filled honeypot never reaches the database');
    ok(await page.isHidden('#s-done'), 'and shows no confirmation');
    await ctx.close(); }

  { const {ctx,page} = await toForm();
    await page.fill('#cname','Fast Bot'); await page.fill('#cmail','fast@example.com');
    await page.click('#go');                            // no wait at all
    await page.waitForTimeout(250);
    ok(await bookCalls(page) === 0, 'a submit within two seconds of the form appearing is held back');
    ok(/give it a second/i.test(await page.textContent('#e-form')), 'and says so without accusing her of anything');
    await page.waitForTimeout(2000);
    await page.click('#go');
    await page.waitForTimeout(400);
    ok(await page.isVisible('#s-done'), 'waiting a moment and trying again works');
    await ctx.close(); }

  { const {ctx,page} = await toForm(state({limited:true}));
    await page.fill('#cname','Sara Khan'); await page.fill('#cmail','sara@example.com');
    await page.waitForTimeout(2100);
    await page.click('#go');
    await page.waitForTimeout(350);
    ok(/already have 3 appointments/.test(await page.textContent('#e-form')),
       'a limit from the database is shown as it was written');
    ok(await page.isVisible('#s-you'), 'and the time she picked is still there, because her typing was not the problem');
    ok(await page.isHidden('#s-done'), 'with no confirmation');
    await ctx.close(); }

  /* ------------------------------------------------- the confirmation -- */
  { const {ctx,page} = await toForm();
    await page.fill('#cname','Ruby Hall'); await page.fill('#cmail','ruby@example.com');
    await page.waitForTimeout(2100);
    await page.click('#go');
    await page.waitForTimeout(400);
    ok(/#booked$/.test(page.url()), `the confirmation has an address of its own (${page.url().split('/').pop()})`);
    ok(!/AB12CD34|11111111/.test(page.url()), 'and the reference and token stay out of it');

    const ics = await page.getAttribute('#ics','href');
    ok(/^blob:/.test(ics), 'the calendar file is built in the browser, not fetched from anywhere');
    const text = await page.evaluate(h => fetch(h).then(r => r.text()), ics);
    ok(/^BEGIN:VCALENDAR/.test(text) && /END:VCALENDAR\r\n$/.test(text),
       'it is a whole VCALENDAR, ending with the CRLF the format requires');
    ok(/\r\nUID:AB12CD34@booked-in\.co\.uk\r\n/.test(text), 'carrying the booking reference');
    ok(/\r\nDTSTART:\d{8}T\d{6}Z\r\n/.test(text), 'with times in UTC, as the format requires');
    ok(/SUMMARY:Hybrid full set/.test(text), 'and the treatment in the title');
    ok(!/\n(?!\r)/.test(text.replace(/\r\n/g, '')), 'and no bare newline anywhere in it');
    await ctx.close(); }

  // a month with nothing in it must not be where the calendar opens
  { const {ctx,page} = await mk(browser, state({emptyFirstMonth:true}));
    await page.locator('.svc').first().click();
    await page.waitForTimeout(700);
    const open = await page.locator('.grid button.open').count();
    const shown = await page.textContent('#month');
    const thisMonth = new Date().toLocaleDateString('en-GB',{month:'long',year:'numeric'});
    ok(open > 0 && shown !== thisMonth, `the calendar skips to a month with free days (${shown})`);
    await ctx.close(); }

  { const {ctx,page} = await mk(browser, state({plan:'pro'}));
    ok(await page.isHidden('#credit'), 'a Pro page carries no Booked In credit'); await ctx.close(); }

  // ---- the manage page ----
  const MANAGE = ORIGIN + '/book/manage.html';
  async function manage(st, q) {
    const ctx = await browser.newContext({ viewport:{width:1280,height:900} });
    const page = await ctx.newPage();
    const errs = [];
    page.on('pageerror', e => errs.push(e.message));
    page.on('console', m => { if(m.type()==='error') errs.push(m.text()); });
    await page.route('**/supabase-js*', r => r.fulfill({ contentType:'application/javascript', body: STUB }));
    await page.route('**/config.js', r => r.fulfill({ contentType:'application/javascript', body: CONFIG }));
  await page.route('**/stub.test/**', r => r.fulfill({ contentType:'image/png',
    body: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==','base64') }));
    await page.addInitScript(`window.__S = ${JSON.stringify(st)}; ${SLOTGEN}`);
    page.on('dialog', d => d.accept());
    await page.goto(MANAGE + q, { waitUntil:'load' });
    await page.waitForTimeout(260);
    return { ctx, page, errs };
  }
  const GOOD = '?r=AB12CD34&t=11111111-2222-3333-4444-555555555555';

  { const {ctx,page} = await manage(state(), '');
    ok(await page.isVisible('#gone'), 'manage: a link with no reference says so'); await ctx.close(); }
  { const {ctx,page} = await manage(state(), '?r=AB12CD34&t=00000000-0000-0000-0000-000000000000');
    ok(await page.isVisible('#gone'), 'manage: a guessed reference with the wrong token shows nothing');
    await ctx.close(); }

  { const {ctx,page,errs} = await manage(state(), GOOD);
    ok(await page.textContent('#d-ref') === 'AB12CD34', 'manage: shows the reference');
    ok(await page.textContent('#d-what') === 'Hybrid full set', 'manage: shows the treatment');
    ok(await page.textContent('#d-cost') === '£50', 'manage: shows the price');
    ok(await page.textContent('#d-state') === 'Booked', 'manage: shows it as booked');
    ok(await page.isVisible('#cancel'), 'manage: a cancellable booking offers the button');
    ok(/studio-mila/.test(await page.getAttribute('#rebook','href')), 'manage: links back to her page');
    await page.click('#cancel');
    await page.waitForTimeout(400);
    ok(await page.textContent('#d-state') === 'Cancelled', 'manage: cancelling updates the status');
    ok(await page.isHidden('#act'), 'manage: the button goes once it is cancelled');
    ok(/nothing more to do/i.test(await page.textContent('#why')), 'manage: explains there is nothing left to do');
    ok(errs.length === 0, `manage: no console errors (${errs.length})`);
    await ctx.close(); }

  { const {ctx,page} = await manage(state({status:'confirmed', cancelFails:true}), GOOD);
    await page.click('#cancel'); await page.waitForTimeout(400);
    ok(/too close/.test(await page.textContent('#toast')), 'manage: a refused cancellation is explained');
    ok(await page.textContent('#d-state') === 'Booked', 'manage: a refused cancellation leaves it booked');
    await ctx.close(); }

  { const {ctx,page} = await manage(state({status:'cancelled'}), GOOD);
    ok(await page.isHidden('#act'), 'manage: an already-cancelled booking offers no button');
    ok(await page.textContent('#d-state') === 'Cancelled', 'manage: shows it as cancelled');
    await ctx.close(); }

  /* --------------------------------------------------- turning them off -- */
  /* Somebody who followed "turn these off" has already said what she wants.
     Making her press a second button to mean it is how an unsubscribe quietly
     fails to happen, and how a studio ends up reported for spam. */
  { const st = state();
    const {ctx,page,errs} = await manage(st,
      '?u=ab12cd34-ef56-7890-abcd-ef1234567890');
    ok(await page.isVisible('#unsub'), 'unsubscribe: the link opens an unsubscribe, not a booking');
    ok(await page.isHidden('#main'), 'unsubscribe: and no appointment is shown');
    ok(/are off/.test(await page.textContent('#u-head')),
       'unsubscribe: it is already done by the time she reads it');
    const said = await page.textContent('#u-said');
    ok(/Studio Mila/.test(said), `unsubscribe: it names the studio (${said})`);
    const call = await page.evaluate(() =>
      window.__S.ops.filter(o => o.name === 'set_rebook_opt_out').pop());
    ok(call && call.args.p_off === true, 'unsubscribe: and the server was told');
    ok(/confirmation and a\s+reminder/.test(await page.textContent('#u-note')),
       'unsubscribe: it explains what she will still get');

    await page.click('#u-undo');
    await page.waitForTimeout(300);
    ok(/back on/.test(await page.textContent('#u-head')),
       'unsubscribe: she can change her mind in the other direction too');
    ok(await page.isHidden('#u-note'),
       'unsubscribe: and the note about what survives goes away when it no longer applies');
    ok(errs.length === 0, `unsubscribe: no console errors (${errs.length})`);
    await ctx.close(); }

  { const {ctx,page} = await manage(state(), '?u=00000000-0000-0000-0000-000000000000');
    ok(await page.isVisible('#gone'), 'unsubscribe: a made-up token says it cannot find that');
    ok(await page.isHidden('#unsub'), 'unsubscribe: and claims nothing was turned off');
    await ctx.close(); }

  for (const [n,d] of [['iphone-se',devices['iPhone SE']],['iphone-12',devices['iPhone 12']],
                       ['galaxy-s9',devices['Galaxy S9+']],['ipad-land',devices['iPad Pro 11 landscape']],
                       ['desk-1280',{viewport:{width:1280,height:900}}]]) {
    const {ctx,page,errs} = await mk(browser, state(), d);
    await page.locator('.svc').first().click(); await page.waitForTimeout(450);
    await firstOpenDay(page).click(); await page.waitForTimeout(250);
    await page.locator('#time-list button').first().click(); await page.waitForTimeout(250);
    const r = await page.evaluate(() => ({ sw:document.documentElement.scrollWidth,
      cw:document.documentElement.clientWidth, mode:document.compatMode }));
    await page.screenshot({ path:`${OUT}/book-${n}.png` });
    ok(r.sw - r.cw <= 1 && errs.length === 0 && r.mode === 'CSS1Compat',
      `${n} (${r.cw}px) no overflow mid-booking` +
      (r.sw-r.cw>1?` — ${r.sw-r.cw}px`:'') + (errs.length?` errs=${errs.length}`:''));
    await ctx.close();
  }

  await browser.close();
  await srv.close();
  console.log(fail ? `\n${fail} failure(s)` : '\nall passed');
  process.exit(fail?1:0);
})();
