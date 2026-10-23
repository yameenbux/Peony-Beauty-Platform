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
      /* The account details live here and nowhere public, so the stub puts
         them here too - a test that read them off get_studio would pass on a
         page that leaks them. */
      /* What take_deposit() would have worked out, so the kind and the amount
         on the booking agree the way they do in the database. */
      var mode  = S.studio.pay_mode || 'deposit';
      var price = S.booking.price_pence || 0;
      var due   = mode === 'none' ? 0
                : mode === 'full' ? price
                : Math.min(S.studio.deposit_pence || 0, price);
      return res(Object.assign({}, S.booking, due ? { deposit:{
        pence: due, kind: due >= price ? 'full' : 'deposit',
        paid_at: S.depositPaid || null, how:'bank',
        name:'E Mila', sort:'04-00-04', account:'12345678',
        note:'Within 24 hours please.' } } : {}));
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
      if(S.needsPatch){ S.needsPatch = false;
        return res(null, { code:'P0005',
          message:'Hybrid full set needs a patch test at least 48 hours beforehand, and we do not have one on record for you. Book a patch test first and then come back for this.' }); }
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
    needsPatch: !!opts.needsPatch,
    emptyFirstMonth: !!opts.emptyFirstMonth,
    studio: {
      slug:'studio-mila', name:'Studio Mila', tagline:'Mobile lashes · Manchester',
      trade:'lashes', timezone:'Europe/London', plan: opts.plan || 'free', notice_hours:24,
      services:[{id:'s1',name:'Hybrid full set',price_pence:5000,duration_min:120,
                 photo_path:'t1/s1.jpg',patch_test_hours:48,records_patch_test:false},
                {id:'s2',name:'Russian infills',price_pence:4000,duration_min:90,
                 photo_path:null,patch_test_hours:null,records_patch_test:true},
                {id:'s3',name:'Patch test',price_pence:0,duration_min:15,
                 photo_path:null,patch_test_hours:null,records_patch_test:true}],
      venue_kind: opts.venue || 'salon',
      deposit_pence: opts.deposit === undefined ? 0 : opts.deposit,
      /* The database defaults this to 'deposit', so that an amount on its own
         still means what it has always meant. A stub that defaulted it to
         'none' would hide exactly the regression that matters. */
      pay_mode: opts.payMode || 'deposit',
      address: opts.address === undefined ? null : opts.address,
      address_note: opts.note === undefined ? null : opts.note,
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
/* Two bookable days, counted back from the end of the month the page ASKED
 * for, rather than forward from today.
 *
 * This used to be today+10 and today+11, emitted only if they fell inside the
 * displayed month - so from about the 20th onwards both landed in the NEXT
 * month, the grid came back empty, and "only days with free times are
 * clickable" failed. On 21 October it reported 1; by the 23rd there were none
 * left and the suite crashed reading [0] of an empty list. Neither had
 * anything to do with the booking page.
 *
 * Anchoring to the requested month makes it the same test on every date. When
 * a month has fewer than two days left the stub returns nothing, and the page
 * does what it does in production: moves to the next month, which has two.
 * That path is covered on its own by the emptyFirstMonth case below.
 *
 * The clock is deliberately NOT frozen. book/index.html refuses a form filled
 * in under two seconds as a bot, so a fixed Date.now() makes every booking
 * look like one and most of this file fails - which is the anti-spam working,
 * not a reason to switch it off in the one suite that exercises it.
 */
const SLOTGEN = `
window.__S.slotsFor = function(from){
  var f0 = new Date(from);
  var last = new Date(f0.getFullYear(), f0.getMonth() + 1, 0);
  var d1 = last;
  var d0 = new Date(last); d0.setDate(d0.getDate() - 1);
  var soon = new Date(); soon.setHours(0,0,0,0); soon.setDate(soon.getDate() + 2);
  if(d0 < soon) return [];
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
    ok((await page.locator('.svc').count()) === 3, 'every treatment is offered');
    /* £0 is a price list being clumsy about the one thing on this page we most
       want booked. */
    ok((await page.textContent('.svc:nth-child(3) .pr')) === 'Free',
       'a treatment that costs nothing says Free, not £0');
    ok(/£50/.test(await page.textContent('.svc')), 'prices show in pounds');
    ok(/120 minutes/.test(await page.textContent('.svc')), 'each treatment shows how long it takes');
    ok((await page.locator('.svc:first-child .shot img').count()) === 1,
       'a treatment with a photo shows it');
    ok((await page.getAttribute('.svc:first-child .shot img','src')) === 'https://stub.test/t1/s1.jpg',
       'the photo comes from her own storage folder');
    /* The slot stays so the list keeps one straight left edge, but it draws
       nothing: a tinted square reads as a photo that failed to load, and a
       ragged edge reads as a bug. Both are checked, because textContent cannot
       see either of them. */
    ok((await page.locator('.svc:nth-child(2) .shot.none').count()) === 1,
       'a treatment without a photo still holds its place in the row');
    ok((await page.locator('.svc:nth-child(2) .shot img').count()) === 0,
       'with no image in it');
    const slot = await page.evaluate(() => {
      const a = document.querySelector('.svc:first-child .shot').getBoundingClientRect();
      const b = document.querySelector('.svc:nth-child(2) .shot').getBoundingClientRect();
      const c = getComputedStyle(document.querySelector('.svc:nth-child(2) .shot'));
      return { same: Math.abs(a.width - b.width) < 1 && Math.abs(a.left - b.left) < 1,
               bg: c.backgroundColor, border: c.borderStyle };
    });
    ok(slot.same, 'the same width, in the same place, so the names line up');
    ok(/rgba\(0, 0, 0, 0\)|transparent/.test(slot.bg) && slot.border === 'none',
       `and nothing drawn in it (${slot.bg}, ${slot.border})`);
    ok(await page.isVisible('.powered'), 'the page carries "Powered by Booked In"');
    ok(/Powered by Booked In/.test(await page.textContent('.powered')),
       'in those words, with the mark beside it');
    ok((await page.locator('.powered svg').count()) === 1, 'and the mark is there');
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
      // the month the PAGE asked for, which is not necessarily this one: late
      // in a month it will have moved on to the next
      const asked = window.__S.ops.filter(o => o.name === 'free_slots').pop().args.p_from;
      const iso = window.__S.slotsFor(asked)[0];
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
  /* The address field lives inside the form, and the form is hidden until a
     time is picked - so isVisible() on it answers a question about the form,
     not about the field. Ask the element's own flag. */
  const asksAddress = page => page.evaluate(() => !document.getElementById('f-addr').hidden);

  { const {ctx,page,errs} = await toForm();
    await page.waitForTimeout(2100);
    await page.click('#go');
    await page.waitForTimeout(200);
    ok(/need a name/i.test(await page.textContent('#e-cname')), 'an empty name is named, under the field');
    ok(await bookCalls(page) === 0, 'and nothing is sent to the database');
    ok(await page.getAttribute('#cname','aria-invalid') === 'true', 'the field is marked invalid for a screen reader');
    /* Not textContent: the message was correct and SHIPPED looking like a grey
       uppercase field label, because the label rule also matched it and no
       test had ever looked at how it was painted. */
    const errStyle = await page.evaluate(() => {
      const cs = getComputedStyle(document.getElementById('e-cname'));
      return { t: cs.textTransform, c: cs.color, w: cs.fontWeight };
    });
    ok(errStyle.t === 'none', `the message is not uppercased like a label (${errStyle.t})`);
    ok(errStyle.c === 'rgb(163, 24, 43)', `and is painted in the error colour (${errStyle.c})`);
    ok(+errStyle.w >= 600, `and is weighted to be noticed (${errStyle.w})`);

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

  /* --------------------------------------------------------- patch test -- */
  /* The one refusal in here that is not a convenience. A reaction with no
     dated record can leave her uninsured, so the database will not take the
     booking - and the page has to say so before she has spent four taps
     getting to a form that is going to refuse her. */
  { const {ctx,page} = await mk(browser, state());
    const tiles = await page.locator('.svc').allTextContents();
    ok(/Patch test 48h before/.test(tiles[0]),
       'the treatment that needs one says so on the tile');
    ok(!/Patch test \d+h/.test(tiles[1]),
       'and the one that does not, does not');
    ok(/Book this first/.test(tiles[1]),
       'the patch test appointment itself is marked as the thing to book first');
    await ctx.close(); }

  { const {ctx,page,errs} = await toForm(state({needsPatch:true}));
    await page.fill('#cname','Ruby Hall'); await page.fill('#cmail','ruby@example.com');
    await page.waitForTimeout(2100);
    await page.click('#go');
    await page.waitForTimeout(350);
    const said = await page.textContent('#e-form');
    ok(/needs a patch test at least 48 hours/.test(said),
       'a refused booking says exactly what is missing');
    ok(/Book a patch test first/.test(said), 'and what to do about it');
    ok(await page.isHidden('#s-done'), 'with no confirmation');
    ok(await page.isVisible('#s-you'),
       'and the time she picked still there, because her typing was not the problem');
    ok(errs.length === 0, `no console errors on a patch refusal (${errs.length})`);
    await ctx.close(); }

  /* ---------------------------------------------------------- deposits --
     The money goes from her client to HER. The page's whole job is to say the
     amount early, say the account accurately, and never put her bank details
     anywhere they do not belong. */
  { const {ctx,page} = await toForm(state({ deposit: 1000 }));
    const said = await page.textContent('#dep-say');
    ok(/£10/.test(said), `the deposit is named before she types anything (${said.slice(0,40)}…)`);
    ok(/straight to her, not to us/.test(said), 'and said to go straight to the studio');

    /* The account must not be on the page until there is a booking to attach
       it to. textContent of the whole body, because a leak anywhere counts. */
    /* The sort code and the name on the account, not the bare account number:
       a month grid renders "1 2 3 ... 10 11 12" and textContent runs it all
       together, so "12345678" matches any calendar. The hyphenated sort code
       and her name cannot appear by accident. */
    const bodyTxt = await page.textContent('body');
    ok(!/04-00-04/.test(bodyTxt) && !/E Mila/.test(bodyTxt),
       'her account details are nowhere on the public page');
    ok((await page.textContent('#done-pay')) === '',
       'and nothing has been written into the block that will hold them');

    await page.fill('#cname','Ruby Hall'); await page.fill('#cmail','ruby@example.com');
    await page.waitForTimeout(2100);
    await page.click('#go');
    await page.waitForTimeout(500);
    const pay = await page.textContent('#done-pay');
    ok(/£10/.test(pay), 'the confirmation says what to pay');
    ok(/04-00-04/.test(pay) && /12345678/.test(pay), 'and the account to pay it into');
    ok(/AB12CD34/.test(pay), 'with the reference that lets her match it up');
    ok(/Within 24 hours/.test(pay), 'and whatever she asked to add');
    ok(/confirm once it reaches her/.test(pay),
       'and says plainly that nothing here can see her bank');
    await ctx.close(); }

  /* Full price, which is the barber's case: he does not want £10 of £18, he
     wants the £18. Same block of account details, different sentence - and
     the sentence is the whole point, because "a deposit of £50 holds this
     appointment" about a £50 treatment is a lie about what happens next. */
  { const {ctx,page} = await toForm(state({ payMode:'full', deposit: 1000 }));
    const said = await page.textContent('#dep-say');
    ok(/£50 is due for this appointment/.test(said),
       `the whole price is named, not the deposit figure (${said.slice(0,50)}…)`);
    ok(!/deposit/i.test(said), 'and it is not called a deposit');
    await page.fill('#cname','Ruby Hall'); await page.fill('#cmail','ruby@example.com');
    await page.waitForTimeout(2100);
    await page.click('#go');
    await page.waitForTimeout(500);
    const pay = await page.textContent('#done-pay');
    ok(/Paying for this/.test(pay), 'the confirmation heads it as paying, not as a deposit');
    ok(/£50/.test(pay) && /04-00-04/.test(pay), 'with the amount and the account');
    await ctx.close(); }

  { /* A deposit that happens to equal the price is a payment in full, whatever
       the setting is called - the database decides it that way and the page
       has to say it the same way. */
    const {ctx,page} = await toForm(state({ deposit: 5000 }));
    const said = await page.textContent('#dep-say');
    ok(/is due for this appointment/.test(said) && !/deposit/i.test(said),
       `a deposit as big as the price is not called a deposit (${said.slice(0,50)}…)`);
    await ctx.close(); }

  { /* Switched off, with her amount and her account still on file. Nothing
       about paying may appear anywhere. */
    const {ctx,page} = await toForm(state({ payMode:'none', deposit: 1000 }));
    ok(await page.isHidden('#dep-say'), 'switched off, nothing is asked for');
    await page.fill('#cname','Ruby Hall'); await page.fill('#cmail','ruby@example.com');
    await page.waitForTimeout(2100);
    await page.click('#go');
    await page.waitForTimeout(500);
    ok(await page.isHidden('#done-pay'), 'and no account details on the confirmation');
    await ctx.close(); }

  { /* A studio taking no deposit must not mention one anywhere. */
    const {ctx,page} = await toForm();
    ok(await page.isHidden('#dep-say'), 'no deposit, nothing said');
    await page.fill('#cname','Ruby Hall'); await page.fill('#cmail','ruby@example.com');
    await page.waitForTimeout(2100);
    await page.click('#go');
    await page.waitForTimeout(500);
    ok(await page.isHidden('#done-pay'), 'and nothing on the confirmation either');
    await ctx.close(); }

  { /* Capped at the price, the same way the database caps it: a £0 patch test
       must never announce a £10 deposit. */
    const {ctx,page} = await mk(browser, state({ deposit: 1000 }));
    await page.locator('.svc').nth(2).click();     // the £0 patch test
    await page.waitForTimeout(500);
    await firstOpenDay(page).click(); await page.waitForTimeout(250);
    await page.locator('#time-list button').first().click(); await page.waitForTimeout(250);
    ok(await page.isHidden('#dep-say'), 'a free treatment is never asked for a deposit');
    await ctx.close(); }

  /* ------------------------------------------------------------- venue --
     Two trades, and the page has to ask the opposite question of each. Getting
     this the wrong way round means either a client driving to a town instead of
     a door, or a technician's home address published on a page. */
  { /* premises, with an address */
    const {ctx,page,errs} = await mk(browser, state({ venue:'salon',
      address:'14 Mill Road, Coventry CV1 2AB', note:'Buzzer 2, park on the street.' }));
    ok(await page.isVisible('#s-where'), 'a studio with a room shows where it is');
    ok(/14 Mill Road/.test(await page.textContent('#where-addr')), 'with the address itself');
    ok(/Buzzer 2/.test(await page.textContent('#where-note')), 'and the part no address field holds');
    const map = await page.getAttribute('#where-map','href');
    ok(/^https:\/\/www\.google\.com\/maps\/search\/\?api=1&query=/.test(map) &&
       /Mill%20Road/.test(map), `with a maps link a phone can open (${map.slice(0,54)}…)`);
    ok(await asksAddress(page) === false, 'and never asks her client for an address');
    ok(await page.isHidden('#where-pick'), 'with nothing to choose between');
    ok(errs.length === 0, `no console errors (${errs.length})`);
    await ctx.close(); }

  { /* mobile: her own address must not be on the page at all */
    const {ctx,page} = await mk(browser, state({ venue:'mobile',
      address:'14 Mill Road, Coventry CV1 2AB', note:'I can park anywhere nearby.' }));
    const body = await page.textContent('body');
    ok(!/14 Mill Road/.test(body),
       'a mobile studio\'s own address never appears on her page, even when she has one');
    ok(await asksAddress(page) === true, 'her client is asked for hers instead');
    ok(/park anywhere/.test(await page.textContent('#where-travel')),
       'and what she needs on arrival is said up front');
    await ctx.close(); }

  { /* mobile: the address is required, and checked the way the database checks it */
    const {ctx,page} = await toForm(state({ venue:'mobile' }));
    ok(await page.isVisible('#f-addr'), 'and once the form is on screen, so is the box');
    await page.fill('#cname','Ruby Hall'); await page.fill('#cmail','ruby@example.com');
    await page.waitForTimeout(2100);
    await page.click('#go');
    await page.waitForTimeout(250);
    ok(await bookCalls(page) === 0, 'no address, no request');
    ok(/address she should come to/i.test(await page.textContent('#e-caddr')),
       'and it says what is missing');
    await page.fill('#caddr','Coventry');
    await page.click('#go');
    await page.waitForTimeout(250);
    ok(await bookCalls(page) === 0, '"Coventry" is a town, not a door, and does not go either');
    ok(/number and the postcode/i.test(await page.textContent('#e-caddr')), 'and says why');
    /* The error has to be an error. A specificity bug once rendered every one
       of these as a grey uppercase field label, and textContent cannot see it. */
    const red = await page.evaluate(() => {
      const c = getComputedStyle(document.getElementById('e-caddr'));
      return { t: c.textTransform, s: c.fontSize };
    });
    ok(red.t === 'none', `the message is not painted as a field label (${red.t})`);
    await page.fill('#caddr','14 Mill Road, Coventry CV1 2AB');
    await page.click('#go');
    await page.waitForTimeout(400);
    ok(await page.isVisible('#s-done'), 'a real address books');
    const call = await page.evaluate(() => window.__S.ops.filter(o=>o.name==='book')[0]);
    ok(call.args.p_address === '14 Mill Road, Coventry CV1 2AB', 'and reaches book() as given');
    ok(/coming to 14 Mill Road/.test(await page.textContent('#done-where')),
       'the confirmation says it back, while she can still check it');
    ok(await page.isHidden('#s-where'),
       'and the section above it is put away rather than saying it twice');
    const ics = await page.getAttribute('#ics','href');
    const text = await page.evaluate(h => fetch(h).then(r => r.text()), ics);
    ok(/\r\nLOCATION:14 Mill Road\\, Coventry CV1 2AB\r\n/.test(text),
       'and the calendar entry carries it, with the comma escaped as the format demands');
    await ctx.close(); }

  { /* both: the client chooses, and the page changes under her */
    const {ctx,page} = await mk(browser, state({ venue:'both',
      address:'14 Mill Road, Coventry CV1 2AB' }));
    ok(await page.isVisible('#where-pick'), 'a studio who does both lets her client choose');
    ok(await page.isVisible('#where-addr'), 'coming to her is the first offer');
    ok(await asksAddress(page) === false, 'and asks for no address');
    await page.click('#where-pick [data-venue="mobile"], #where-pick [data-at="mobile"]');
    await page.waitForTimeout(150);
    ok(await asksAddress(page) === true, 'choosing the other way asks for hers');
    ok(await page.isHidden('#where-at'), 'and puts the studio address away');
    await page.click('#where-pick [data-at="salon"]');
    await page.waitForTimeout(150);
    ok(await page.isVisible('#where-at') && await asksAddress(page) === false,
       'and changing her mind back works');
    await ctx.close(); }

  { /* a premises studio who has not filled hers in yet */
    const {ctx,page} = await mk(browser, state({ venue:'salon' }));
    ok(await page.isHidden('#s-where'), 'no address yet means no empty box');
    ok(await asksAddress(page) === false, 'and still no question for her client');
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
    ok(!/LOCATION:/.test(text),
       'with no empty LOCATION line when there is nowhere to name');
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

  { /* It used to come off at Pro and was sold that way. It does not any more,
       and the pricing copy was changed in the same commit - this is the test
       that stops it quietly going back. */
    const {ctx,page} = await mk(browser, state({plan:'pro'}));
    ok(await page.isVisible('.powered'),
       'a Pro page carries "Powered by Booked In" too, on every plan');
    ok((await page.locator('.powered svg').count()) === 1, 'mark and all');
    await ctx.close(); }

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

  /* --------------------------------------------------- paying, looked up --
     The manage page is where somebody goes back for the bank details she
     closed the tab on. Four states, and the wording has to match which one it
     is: a deposit to pay, a whole price to pay, or either of those already
     received - because "£50 received, the rest is due on the day" about a £50
     treatment is a sentence that gets her a phone call. */
  { const {ctx,page} = await manage(state({ deposit: 1000 }), GOOD);
    const pay = await page.textContent('#m-pay');
    ok(/Your deposit/.test(pay), 'manage: a deposit is headed as a deposit');
    ok(/£10/.test(pay) && /04-00-04/.test(pay), 'manage: with the amount and the account');
    ok(/AB12CD34/.test(pay), 'manage: and the reference to quote');
    await ctx.close(); }

  { const {ctx,page} = await manage(state({ payMode:'full', deposit: 1000 }), GOOD);
    const pay = await page.textContent('#m-pay');
    ok(/Paying for this/.test(pay), 'manage: full payment is not headed as a deposit');
    ok(/£50/.test(pay), 'manage: and names the whole price, not the deposit figure');
    await ctx.close(); }

  { const st = state({ deposit: 1000 }); st.depositPaid = '2026-10-01T09:00:00Z';
    const {ctx,page} = await manage(st, GOOD);
    const pay = await page.textContent('#m-pay');
    ok(/£10 received/.test(pay), 'manage: a deposit she has marked off reads as received');
    ok(/1 October 2026/.test(pay), 'manage: on the day she marked it');
    ok(/rest is due on the day/.test(pay), 'manage: and says what is still owing');
    await ctx.close(); }

  { const st = state({ payMode:'full', deposit: 1000 }); st.depositPaid = '2026-10-01T09:00:00Z';
    const {ctx,page} = await manage(st, GOOD);
    ok(/Nothing else to pay/.test(await page.textContent('#m-pay')),
       'manage: and a full payment leaves nothing owing');
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
