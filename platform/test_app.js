const { chromium, devices } = require('playwright');
const { start } = require('./serve');
/* Over HTTP, from the built site: see serve.js. Filled in by main(). */
let PAGE = null;
const OUT  = '/tmp/claude-0/-home-user-test/24071892-c542-5742-989c-e77eb82ac33e/scratchpad/shots';

// A stand-in for supabase-js backed by an in-memory studio. It exercises this
// app's own logic; it makes no claim about the real client.
const STUB = `
window.supabase = { createClient: function(){
  var S = window.__S;
  function res(data, error){ return Promise.resolve({ data: data===undefined?null:data, error: error||null }); }
  function builder(table, op, payload){
    var b = {
      eq: function(){ return b; }, in: function(){ return b; }, select: function(){ return b; },
      then: function(f, r){
        S.ops.push({ table: table, op: op, payload: payload });
        if(op === 'upsert' && table === 'service'){
          S.studio.services = payload.map(function(p,i){
            return { id: p.id || 'new-'+i, name: p.name, price_pence: p.price_pence,
                     duration_min: p.duration_min, active: true, sort: p.sort };
          });
        }
        if(op === 'delete' && table === 'opening') S.studio.openings = [];
        if(op === 'insert' && table === 'opening') S.studio.openings = payload.slice();
        if(op === 'update' && table === 'tenant') Object.assign(S.studio, payload);
        return res({}).then(f, r);
      }
    };
    return b;
  }
  return {
    storage: { from: function(){ return {
      getPublicUrl: function(path){ return { data:{ publicUrl:'https://stub.test/' + path } }; },
      upload: function(path, blob, opts){ S.ops.push({ op:'upload', path:path, size:blob.size,
        type:blob.type, upsert:opts && opts.upsert }); return res({ path:path }); }
    }; } },
    auth: {
      getSession: function(){ return res({ session: S.session &&
        Object.assign({ access_token:'tok_123' }, S.session) }); },
      onAuthStateChange: function(cb){ S.authCb = cb; return { data:{ subscription:{ unsubscribe:function(){} } } }; },
      signInWithOtp: function(a){ S.ops.push({ op:'otp', email:a.email }); return res({}); },
      signOut: function(){ S.session = null; return res({}); }
    },
    rpc: function(name, args){
      S.ops.push({ op:'rpc', name: name, args: args });
      if(name === 'my_studio')      return res(S.studio);
      if(name === 'my_billing')     return res(S.billing || null);
      if(name === 'my_waitlist')    return res(S.waitlist || []);
      if(name === 'my_patch_tests') return res(S.patchTests || {});
      if(name === 'studio_book'){
        if(S.bookFails) return res(null, { message: S.bookFails });
        return res([{ ref:'AB12CD34', starts_at: args.p_starts, ends_at: args.p_starts }]);
      }
      if(name === 'book_series'){
        var made = [], miss = [];
        for(var i = 0; i < args.p_times; i++){
          var at = new Date(new Date(args.p_first).getTime() +
                            i * args.p_every_weeks * 7 * 864e5).toISOString();
          /* the third one always clashes, so the skip path is exercised */
          if(i === 2) miss.push({ starts_at: at, why:'You already have something at that time.' });
          else made.push({ ref:'AB' + i, starts_at: at });
        }
        return res({ booked: made, skipped: miss });
      }
      if(name === 'studio_cancel'){
        S.studio.bookings = S.studio.bookings.map(function(b){
          return b.id === args.p_id
            ? Object.assign({}, b, { status:'cancelled', cancelled_by:'studio' }) : b; });
        return res({ cancelled:true });
      }
      if(name === 'set_closure'){
        S.studio.closures = args.p_on
          ? S.studio.closures.concat([{ on_date:args.p_date, reason:null }])
          : S.studio.closures.filter(function(c){ return c.on_date !== args.p_date; });
        return res({ date:args.p_date, closed:args.p_on });
      }
      if(name === 'slug_available') return res(S.takenSlugs.indexOf(args.p_slug) === -1);
      if(name === 'create_studio'){
        if(S.takenSlugs.indexOf(args.p_slug) !== -1) return res(null, { message:'That link is taken.' });
        S.studio = { id:'t1', slug:args.p_slug, name:args.p_name, trade:args.p_trade,
          plan:'free', timezone:args.p_tz, notice_hours:24, slot_step_min:15,
          services:[{id:'s1',name:'Hybrid full set',price_pence:5000,duration_min:120,active:true,sort:1}],
          openings:[{id:'o1',weekday:2,starts:'09:00:00',ends:'18:00:00',area:''}],
          bookings:[] };
        return res(args.p_slug);
      }
      if(name === 'free_slots')     return res(S.slots || []);
      if(name === 'my_clients')     return res(S.clients || []);
      if(name === 'client_record'){
        /* The database decides the tier, not the browser - so the stub has to
           refuse it too, or the test would pass on a page that leaks it. */
        if(S.studio.plan !== 'pro_plus')
          return res(null, { code:'P0006', message:'The insurance pack is part of Pro+.' });
        return res({ studio:{ name:S.studio.name, slug:S.studio.slug, address:S.studio.address },
          client:{ name:'Ruby Hall', email:'ruby@example.com' },
          valid_months:6, produced_at:new Date().toISOString(),
          patch_tests:[{ tested_at:'2026-09-20T10:00:00Z', valid_until:'2027-03-20T10:00:00Z',
                         from_booking:true, note:'No reaction at 48h.' }],
          appointments:[{ ref:'AB12', starts_at:'2026-09-20T10:00:00Z', service:'Hybrid full set',
                          status:'confirmed', price_pence:5000, needed_patch_hours:48 }] });
      }
      if(name === 'set_client_notes'){
        var c = (S.clients || []).filter(function(x){ return x.id === args.p_client; })[0];
        if(!c) return res(null, { message:'That client is not yours.' });
        c.notes = (args.p_notes || '').trim() || null;
        return res(null);
      }
      return res(null, { message:'unknown rpc ' + name });
    },
    from: function(table){ return {
      update: function(p){ return builder(table,'update',p); },
      insert: function(p){ return builder(table,'insert',p); },
      upsert: function(p){ return builder(table,'upsert',p); },
      delete: function(){  return builder(table,'delete',null); }
    }; }
  };
}};`;

const CONFIG = `window.BOOKEDIN = { SUPABASE_URL:"https://stub.supabase.co",
  SUPABASE_ANON_KEY:"stub", PAGE_HOST:"booked-in.co.uk",
  FUNCTIONS_URL:"https://fn.stub.test" };`;
const NOFN = CONFIG.replace('FUNCTIONS_URL:"https://fn.stub.test"', 'FUNCTIONS_URL:""');

async function mk(browser, state, dev, cfg, at) {
  const ctx = await browser.newContext(dev || { viewport:{width:1280,height:900} });
  const page = await ctx.newPage();
  /* Pin the page's clock when a test needs "today" to mean a known day. The
     fixed time stops Date moving; timers still run, so the page still boots. */
  if (at) await page.clock.setFixedTime(at);
  const errs = [];
  page.on('console', m => { if (m.type()==='error') errs.push(m.text()); });
  page.on('pageerror', e => errs.push('PAGEERROR ' + e.message));
  await page.route('**/supabase-js*', r => r.fulfill({ contentType:'application/javascript', body: STUB }));
  await page.route('**/config.js', r => r.fulfill({ contentType:'application/javascript', body: cfg || CONFIG }));
  await page.route('https://fn.stub.test/**', (r, req) => {
    const name = req.url().split('/').pop();
    const body = JSON.parse(req.postData() || '{}');
    return r.fulfill({ contentType:'application/json', status: 200,
      body: JSON.stringify({ url: 'https://pay.stub.test/' + name +
        (body.yearly ? '?yearly=1' : body.portal ? '?portal=1' : '') }) });
  });
  await page.route('https://pay.stub.test/**', r =>
    r.fulfill({ contentType:'text/html', body:'<!doctype html><title>stripe</title>paid' }));
  await page.route('**/stub.test/**', r => r.fulfill({ contentType:'image/png',
    body: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==','base64') }));
  await page.addInitScript(`window.__S = ${JSON.stringify(state)};`);
  page.on('dialog', d => d.accept());
  await page.goto(PAGE, { waitUntil:'load' });
  return { ctx, page, errs };
}
const NOSTUDIO = { session:{user:{id:'u1'}}, studio:null, takenSlugs:['taken'], ops:[] };
const SIGNEDOUT = { session:null, studio:null, takenSlugs:[], ops:[] };
function withStudio(bookings){
  return { session:{user:{id:'u1'}}, takenSlugs:[], ops:[], studio:{
    id:'t1', slug:'studio-mila', name:'Studio Mila', trade:'lashes', plan:'free',
    trade_profile:{ label:'Lashes', client:'client', lead:'rebook', gaps:false,
                    patch:'Adhesive, tint and lifting solution all need a test first.' },
    timezone:'Europe/London', notice_hours:24, slot_step_min:15, cancel_hours:24, remind_hours:24,
    rebook_on:false, rebook_lead_days:3,
    brand_hex:null, logo_path:null, card_theme:'light', card_align:'left',
    venue_kind:'mobile', address:null, address_note:null,
    closures:[{on_date:'2026-12-24', reason:'Christmas'}],
    services:[
      {id:'s1',name:'Hybrid full set',price_pence:5000,duration_min:120,active:true,sort:1,rebook_weeks:3},
      {id:'s2',name:'Russian infills',price_pence:4000,duration_min:90,active:true,sort:2,rebook_weeks:null}],
    openings:[{id:'o1',weekday:2,starts:'09:00:00',ends:'18:00:00',area:''},
              {id:'o2',weekday:5,starts:'10:00:00',ends:'16:00:00',area:''}],
    bookings: bookings },
    /* Three free times, spread over three days, far enough out that no notice
       period reaches them. */
    slots: [0, 1, 2].map(function(i){
      var d = new Date(Date.now() + (i + 3) * 864e5);
      d.setUTCHours(10 + i, 0, 0, 0);
      return d.toISOString();
    }),
    clients:[
      { id:'c1', name:'Ruby Hall', email:'ruby@example.com', phone:'07700 900111',
        notes:null, visits:6, spent_pence:27000, cancelled:1,
        address:'14 Mill Road, Coventry CV1 2AB',
        first_visit:'2026-02-03T10:00:00Z', last_visit:'2026-09-08T10:00:00Z',
        next_visit:null, since:'2026-02-03T10:00:00Z' },
      { id:'c2', name:'Sian Price', email:'sian@example.com', phone:null,
        notes:'Allergic to the old adhesive.', visits:1, spent_pence:4000, cancelled:0,
        first_visit:'2026-10-01T10:00:00Z', last_visit:'2026-10-01T10:00:00Z',
        next_visit:'2099-01-05T10:00:00Z', since:'2026-10-01T10:00:00Z' }
    ] };
}

(async () => {
  const srv = await start();
  PAGE = srv.origin + '/app/';
  const browser = await chromium.launch();
  let fail = 0;
  const ok = (c, m) => { console.log((c?'ok   ':'FAIL ') + m); if(!c) fail++; };

  // a genuinely oversized photograph, the sort that comes off a phone
  const fs = require('fs');
  const BIGPNG = '/tmp/bookedin-big-photo.png';
  { const ctx = await browser.newContext();
    const p = await ctx.newPage();
    const dataUrl = await p.evaluate(() => {
      const c = document.createElement('canvas');
      c.width = 2400; c.height = 1800;
      const g = c.getContext('2d');
      const grd = g.createLinearGradient(0,0,2400,1800);
      grd.addColorStop(0,'#B8465C'); grd.addColorStop(1,'#43192A');
      g.fillStyle = grd; g.fillRect(0,0,2400,1800);
      for(let i=0;i<400;i++){ g.fillStyle = `hsl(${i%360},60%,${40+i%40}%)`;
        g.fillRect(Math.random()*2400, Math.random()*1800, 40, 40); }
      return c.toDataURL('image/png');
    });
    fs.writeFileSync(BIGPNG, Buffer.from(dataUrl.split(',')[1], 'base64'));
    await ctx.close(); }
  ok(fs.statSync(BIGPNG).size > 200000,
     `test fixture is a large photo (${Math.round(fs.statSync(BIGPNG).size/1024)}KB, 2400x1800)`);

  // --- signed out ---
  { const {ctx,page,errs} = await mk(browser, SIGNEDOUT);
    await page.waitForTimeout(250);
    ok(await page.isVisible('#signin'), 'signed out shows the sign-in screen');
    /* What she does next is in another application, so the whole screen hands
       over rather than a line of text appearing under the button. */
    await page.fill('#email','not-an-email');
    await page.click('#otp-go');
    await page.waitForTimeout(150);
    ok(/does not look like an email/i.test(await page.textContent('#e-email')),
       'a mistyped address is caught before anything is sent');
    ok(await page.isVisible('#signin'), 'and she stays on the sign-in screen');

    await page.fill('#email','ellie@example.com');
    await page.waitForTimeout(100);
    ok(await page.getAttribute('#email','aria-invalid') === 'false',
       'correcting it clears the message as she types');
    await page.click('#otp-go');
    await page.waitForTimeout(250);
    ok(await page.isVisible('#sent'), 'asking for a link moves her to a screen that says to go and look');
    ok(await page.textContent('#sent-to') === 'ellie@example.com',
       'which repeats the address back, so a typo is obvious before she waits for nothing');
    await page.click('#sent-back');
    await page.waitForTimeout(150);
    ok(await page.isVisible('#signin'), 'and she can get back to change it');
    ok(errs.length===0, 'no console errors on sign-in ('+errs.length+')');
    await ctx.close(); }

  // --- signed in, no studio yet: the wizard ---
  { const {ctx,page,errs} = await mk(browser, NOSTUDIO);
    await page.waitForTimeout(250);
    ok(await page.isVisible('#wizard'), 'a new account goes straight to the wizard');
    ok(await page.isDisabled('#w1-next'), 'cannot continue before picking a trade');
    await page.click('.trade[data-trade="lashes"]');
    ok(!await page.isDisabled('#w1-next'), 'picking a trade unlocks the step');
    await page.click('#w1-next');
    await page.fill('#sname','Studio Mila');
    await page.fill('#stag','Mobile lashes · Manchester');
    /* Asked here rather than as a fourth step. Left unasked it would have to be
       guessed, and the guess is wrong for half the trade. */
    ok(await page.isVisible('#w-venue'), 'the wizard asks where she works');
    ok(await page.isVisible('#w-f-addr'), 'and offers an address box, since it opens on premises');
    await page.click('#w-venue [data-venue="mobile"]');
    await page.waitForTimeout(120);
    ok(await page.isHidden('#w-f-addr'),
       'saying she travels puts the address box away rather than asking for her home');
    ok(await page.isVisible('#w-mob'), 'and says what her page will do instead');
    await page.click('#w2-next');
    await page.waitForTimeout(450);
    ok(await page.inputValue('#slug') === 'studio-mila', 'the link is suggested from the name');
    ok(/is yours/.test(await page.textContent('#slug-said')), 'a free link reports as available');

    await page.fill('#slug','taken');
    await page.waitForTimeout(450);
    ok(/already has that one/.test(await page.textContent('#slug-said')), 'a taken link is refused');
    ok(await page.isDisabled('#w3-go'), 'cannot submit a taken link');

    await page.fill('#slug','Studio Mila!!');
    await page.waitForTimeout(450);
    ok(/Letters, numbers/.test(await page.textContent('#slug-said')), 'a malformed link is explained');

    await page.fill('#slug','studio-mila');
    await page.waitForTimeout(450);
    await page.click('#w3-go');
    /* There is a deliberate beat here: the preview phone confirms the page
       is live before the dashboard replaces it. Worth waiting for, and worth
       asserting, because a silent cut would be the thing to notice. */
    await page.waitForTimeout(250);
    ok(await page.evaluate(() => document.getElementById('pv-phone')
         .classList.contains('made')),
       'the preview confirms the page before the screen changes');
    await page.waitForSelector('#app:not([hidden])', { timeout: 4000 });
    ok(await page.isVisible('#app'), 'making the page lands on the dashboard');
    const s = await page.evaluate(() => window.__S.ops.filter(o=>o.op==='rpc'&&o.name==='create_studio')[0]);
    ok(s && s.args.p_trade==='lashes' && s.args.p_slug==='studio-mila', 'create_studio got the right arguments');
    const tag = await page.evaluate(() => window.__S.ops.filter(o=>o.table==='tenant')[0]);
    ok(tag && tag.payload.tagline === 'Mobile lashes · Manchester', 'the tagline is saved after creation');
    ok(tag && tag.payload.venue_kind === 'mobile', 'and so is the answer about where she works');
    ok(tag && !('address' in tag.payload),
       'with no address sent for a studio who has not got one');
    ok(errs.length===0, 'no console errors through the wizard ('+errs.length+')');
    await ctx.close(); }

  // --- dashboard, empty diary ---
  { const {ctx,page,errs} = await mk(browser, withStudio([]));
    await page.waitForTimeout(250);
    ok(await page.isVisible('#app'), 'an existing studio opens the dashboard');
    ok(/Nothing booked yet/.test(await page.textContent('#diary-list')), 'an empty diary invites her to share the link');
    ok(await page.textContent('#s-today') === '0', 'today counts zero');
    await page.click('.tab[data-panel="page"]');
    ok((await page.textContent('#live-url')) === 'booked-in.co.uk/studio-mila', 'her link is shown');
    ok(/rebooking, reminders and unbranded story cards/.test(await page.textContent('#plan-line')),
       'the free plan says what Pro adds, not what the footer costs');
    ok(await page.isVisible('#plan-buy'), 'a free studio is offered Pro');
    ok(await page.isHidden('#plan-manage'), 'and has no billing to manage yet');
    ok(/Reminders sent/.test(await page.textContent('#pro-list')), 'it says what Pro buys');
    // text assertions cannot see a missing sprite; a 300x150 fallback box can
    const icon = await page.locator('#pro-list .mk').first().boundingBox();
    ok(icon && icon.width <= 24 && icon.height <= 24,
       `the tick icons render at their intended size (${icon?Math.round(icon.width)+'x'+Math.round(icon.height):'missing'})`);
    const listH = (await page.locator('#pro-list').boundingBox()).height;
    ok(listH < 120, `the Pro list stays compact (${Math.round(listH)}px)`);
    /* ----------------------------------------------------------- venue -- */
    ok(await page.isVisible('#venue-pick'), 'the page panel lets her say where she works');
    ok(await page.getAttribute('#venue-pick [data-venue="mobile"]','aria-checked') === 'true',
       'and shows the shape she is actually set to');
    ok(await page.isHidden('#venue-at'),
       'a studio who travels is not asked to publish her own address');
    ok(await page.isVisible('#v-mob'), 'and is told what her page does instead');
    /* The refusal matters more than the save: "clients come to me" with an
       empty address produces a page that announces a venue and will not say
       where it is. */
    await page.click('#venue-pick [data-venue="salon"]');
    await page.waitForTimeout(120);
    ok(await page.isVisible('#venue-at'), 'switching to premises asks for the address');
    await page.click('#venue-save');
    await page.waitForTimeout(200);
    let wrote = await page.evaluate(() =>
      window.__S.ops.filter(o => o.table === 'tenant' && o.payload && 'venue_kind' in o.payload).length);
    ok(wrote === 0, 'and premises with no address is not saved');
    ok(/number and postcode/i.test(await page.textContent('#toast')), 'it says why');
    /* The same rule her own clients are held to: a street and a town is not
       an address. Nothing downstream checks hers, so this is the only guard. */
    await page.fill('#v-addr','Mill Road, Nuneaton');
    await page.click('#venue-save');
    await page.waitForTimeout(200);
    wrote = await page.evaluate(() =>
      window.__S.ops.filter(o => o.table === 'tenant' && o.payload && 'venue_kind' in o.payload).length);
    ok(wrote === 0, 'and neither is a street with no number or postcode');
    await page.fill('#v-addr','14 Mill Road, Coventry CV1 2AB');
    await page.fill('#v-note','Buzzer 2, park on the street.');
    await page.click('#venue-save');
    await page.waitForTimeout(250);
    const v = await page.evaluate(() =>
      window.__S.ops.filter(o => o.table === 'tenant' && o.payload && 'venue_kind' in o.payload)[0]);
    ok(v && v.payload.venue_kind === 'salon' &&
       v.payload.address === '14 Mill Road, Coventry CV1 2AB' &&
       v.payload.address_note === 'Buzzer 2, park on the street.',
       'a complete answer is saved as given');
    ok(errs.length===0, 'no console errors on an empty dashboard ('+errs.length+')');
    await ctx.close(); }

  // --- dashboard with bookings ---
  /* Pinned, because "three hours from now" is tomorrow if this runs after
     21:00 in London, and a test that passes depending on the hour it is run is
     worse than no test. A Monday morning, well clear of either midnight. */
  const NOW = Date.parse('2026-06-15T09:00:00Z');
  const soon = new Date(NOW + 3*36e5).toISOString();
  const later = new Date(NOW + 2*864e5).toISOString();
  { const {ctx,page,errs} = await mk(browser, withStudio([
      {id:'b1',ref:'AB12',starts_at:soon,ends_at:soon,client_name:'Ruby H.',
       client_email:'r@x.com',status:'confirmed',service:'Hybrid full set',price_pence:5000,
       client_address:'14 Mill Road, Coventry CV1 2AB'},
      {id:'b2',ref:'CD34',starts_at:later,ends_at:later,client_name:'Sian T.',
       client_email:'s@x.com',status:'confirmed',service:'Russian infills',price_pence:4000},
      {id:'b3',ref:'EF56',starts_at:later,ends_at:later,client_name:'Mia K.',
       client_email:'m@x.com',status:'cancelled',service:'Russian infills',price_pence:4000}]),
      null, null, NOW);
    await page.waitForTimeout(250);
    ok(await page.textContent('#s-today') === '1', 'today counts only today');
    ok(await page.textContent('#s-week') === '2', 'the week counts confirmed only');
    ok(await page.textContent('#s-taken') === '£90', 'the week total excludes the cancelled one');
    /* A diary that says she has a 10am and declines to say where is the one
       thing a mobile technician cannot use at 9:40. */
    ok(/14 Mill Road/.test(await page.textContent('#nx-at')),
       'the next appointment says where she is going');
    const nxMap = await page.getAttribute('#nx-at a','href');
    ok(/maps\/search/.test(nxMap) && /Mill%20Road/.test(nxMap), 'as a link to maps, not text to retype');
    ok(/14 Mill Road/.test(await page.textContent('#diary-list .row .at')),
       'and so does its row in the diary');
    const rows = await page.locator('#diary-list .row').count();
    const ats  = await page.locator('#diary-list .row .at').count();
    ok(ats === 1 && rows > 1, `with no empty line on the ones she is not travelling to (${ats} of ${rows})`);
    ok((await page.locator('#diary-list .row').count()) === 3, 'all three show, cancelled included');
    ok((await page.locator('#diary-list .row.gone').count()) === 1, 'the cancelled one is struck through');
    ok((await page.locator('.daygroup').count()) === 2, 'bookings group by day');

    ok((await page.locator('#diary-list .row .x').count()) === 2,
       'only the two future confirmed bookings offer a cancel control');
    await page.locator('#diary-list .row .x').first().click();
    await page.waitForTimeout(400);
    ok((await page.locator('#diary-list .row.gone').count()) === 2, 'cancelling strikes the row through');
    ok(/you cancelled/.test(await page.textContent('#diary-list')),
       'the diary says who cancelled it');
    ok(await page.textContent('#s-week') === '1', 'the week count drops after a cancellation');
    ok((await page.locator('#diary-list .row .x').count()) === 1,
       'a cancelled booking no longer offers the control');

    await page.click('.tab[data-panel="treats"]');
    ok((await page.locator('#treat-list .tline').count()) === 2, 'her treatments load for editing');
    ok((await page.inputValue('#treat-list .tline:first-child .pr')) === '50.00', 'price shows in pounds');
    await page.click('#treat-add');
    ok((await page.locator('#treat-list .tline').count()) === 3, 'she can add a row');
    await page.fill('#treat-list .tline:last-child .nm','Brow tint');
    await page.fill('#treat-list .tline:last-child .pr','12.50');
    await page.fill('#treat-list .tline:last-child .mins','30');
    await page.click('#treat-save');
    await page.waitForTimeout(300);
    const up = await page.evaluate(() => window.__S.ops.filter(o=>o.op==='upsert')[0]);
    ok(up && up.payload.length===3 && up.payload[2].price_pence===1250,
       'saving converts pounds to pence (' + (up?up.payload[2].price_pence:'-') + ')');

    // ---- the patch-test rules ----
    /* "Patch test - needs one - [ ] hours before" is a row asking itself a
       question. The field is dimmed rather than removed, because a treatment
       IS allowed to both need a prior test and record one, and it has to come
       straight back when she unticks. */
    /* One row per active treatment - three by now, because a treatment was
       added and saved a few assertions ago. */
    const ptN = await page.locator('#pt-list .ptline').count();
    const active = await page.evaluate(() =>
      window.__S.studio.services.filter(s => s.active).length);
    ok(ptN === active, `one patch-test row per active treatment (${ptN} of ${active})`);
    const ptRow = page.locator('#pt-list .ptline').first();
    ok((await ptRow.getAttribute('class')).indexOf('is-test') === -1,
       'an ordinary treatment is asked how many hours before');
    await ptRow.locator('.rec').check();
    await page.waitForTimeout(120);
    ok((await ptRow.getAttribute('class')).indexOf('is-test') !== -1,
       'ticking "this is the patch test" quiets the hours beside it');
    const dimmed = await page.evaluate(() => {
      const r = document.querySelector('#pt-list .ptline');
      return { hrs: +getComputedStyle(r.querySelector('.hrs')).opacity,
               lab: +getComputedStyle(r.querySelector('.every')).opacity,
               disabled: r.querySelector('.hrs').disabled };
    });
    ok(dimmed.hrs < 0.8 && dimmed.lab < 0.8,
       `visibly quieter, not just class-swapped (${dimmed.hrs}, ${dimmed.lab})`);
    ok(dimmed.disabled === false,
       'but still typeable, because a treatment may need a test and record one');
    await ptRow.locator('.rec').uncheck();
    await page.waitForTimeout(120);
    ok((await ptRow.getAttribute('class')).indexOf('is-test') === -1,
       'and unticking brings it straight back');

    // ---- photographs ----
    ok((await page.locator('#treat-list .tline:first-child .shot').count()) === 1,
       'every treatment row has a photo slot');
    ok(/Add/.test(await page.textContent('#treat-list .tline:first-child .shot')),
       'a treatment without a photo invites one');
    // a row that has never been saved has no id yet, so there is nothing to
    // name a photo after. Add one here rather than reusing an earlier row,
    // which the save above has since given an id.
    await page.click('#treat-add');
    const unsaved = page.locator('#treat-list .tline:last-child .shot');
    ok((await unsaved.getAttribute('class')).indexOf('off') !== -1,
       'a treatment that has never been saved cannot take a photo yet');
    ok(/Save first/.test(await unsaved.textContent()), 'and it says why');
    await page.click('#treat-list .tline:last-child .del');

    await page.setInputFiles('#treat-list .tline:first-child .shot input', BIGPNG);
    await page.waitForTimeout(900);
    const shot = await page.evaluate(() => window.__S.ops.filter(o=>o.op==='upload')[0]);
    ok(!!shot, 'choosing a photo uploads it');
    ok(shot && shot.path === 't1/s1.jpg',
       `it lands in her own folder, named for the treatment (${shot?shot.path:'-'})`);
    ok(shot && shot.type === 'image/jpeg', 'it is converted to JPEG');
    ok(shot && shot.size < 400000,
       `a 2400x1800 photo is shrunk before upload (${shot?Math.round(shot.size/1024):'-'}KB)`);
    ok(shot && shot.upsert === true, 'replacing a photo overwrites rather than piling up files');
    const saved = await page.evaluate(() => window.__S.ops.filter(o=>o.table==='service'&&o.op==='update').pop());
    ok(saved && saved.payload.photo_path === 't1/s1.jpg', 'the path is written to the treatment');
    ok((await page.locator('#treat-list .tline:first-child .shot img').count()) === 1,
       'the thumbnail appears straight away');

    await page.click('#treat-save');
    await page.waitForTimeout(300);
    const keep = await page.evaluate(() => window.__S.ops.filter(o=>o.op==='upsert').pop());
    ok(keep && keep.payload[0].photo_path === 't1/s1.jpg',
       'saving prices does not drop the photo');

    await page.click('.tab[data-panel="days"]');
    ok((await page.locator('#day-list .dline').count()) === 7, 'every weekday is listed');
    ok((await page.locator('#day-list .dline .on:checked').count()) === 2, 'only her two open days are ticked');
    ok(await page.isDisabled('#day-list .dline:nth-child(1) .from'), 'a closed day has its times disabled');
    await page.check('#day-list .dline:nth-child(1) .on');
    ok(!await page.isDisabled('#day-list .dline:nth-child(1) .from'), 'ticking a day enables its times');
    await page.fill('#day-list .dline:nth-child(1) .to','08:00');
    await page.click('#day-save');
    await page.waitForTimeout(200);
    ok(/after its start/.test(await page.textContent('#toast')), 'a finish before the start is refused');
    await page.fill('#day-list .dline:nth-child(1) .to','17:00');
    await page.click('#day-save');
    await page.waitForTimeout(400);
    const ins = await page.evaluate(() => window.__S.ops.filter(o=>o.op==='insert'&&o.table==='opening')[0]);
    ok(ins && ins.payload.length===3, 'saving writes the three open days');
    const upd = await page.evaluate(() => window.__S.ops.filter(o=>o.table==='tenant').pop());
    ok(upd && upd.payload.cancel_hours === 24, 'the cancellation window is saved with the days');
    ok(upd && upd.payload.remind_hours === 24, 'the reminder window is saved too');
    ok(await page.isDisabled('#remindh'), 'on Free the reminder control is not usable');
    ok(/part of Pro/.test(await page.textContent('#remind-hint')),
       'and it says plainly that reminders are a Pro thing');

    ok((await page.locator('#off-list .off').count()) === 1, 'her existing day off is listed');
    ok(/24 Dec/.test(await page.textContent('#off-list')), 'the day off reads as a date');
    /* A native date input prints itself in the BROWSER's locale, which is not
       something the page can set - so a UK studio on a US-configured machine
       is shown 12/31/2026 and has no way to tell. The date is said back in
       full underneath, where it cannot be read two ways. */
    await page.fill('#off-date','2026-12-31');
    await page.waitForTimeout(150);
    const said = await page.textContent('#off-said');
    ok(/Thursday 31 December 2026/.test(said),
       `the date is said back in words, whatever the box prints (${said})`);
    await page.click('#off-add');
    await page.waitForTimeout(400);
    ok((await page.locator('#off-list .off').count()) === 2, 'she can close another day');
    const clo = await page.evaluate(() => window.__S.ops.filter(o=>o.name==='set_closure').pop());
    ok(clo && clo.args.p_date === '2026-12-31' && clo.args.p_on === true,
       'set_closure is called with the date she picked');
    await page.locator('#off-list .off button').first().click();
    await page.waitForTimeout(400);
    ok((await page.locator('#off-list .off').count()) === 1, 'she can open a day back up');
    ok((await page.textContent('#off-said')) === '',
       'and the line clears once the day is closed, so it never says a stale date');
    await page.click('#off-add');
    await page.waitForTimeout(200);
    ok(/Pick a date/.test(await page.textContent('#toast')), 'closing with no date picked is refused');
    ok(errs.length===0, 'no console errors on the dashboard ('+errs.length+')');
    await ctx.close(); }

  // --- billing ---
  { const st = withStudio([]); st.studio.plan = 'pro';
    st.billing = { plan:'pro', until:'2027-01-14T00:00:00Z', subscribed:true, customer:'cus_1' };
    const {ctx,page,errs} = await mk(browser, st);
    await page.click('.tab[data-panel="page"]');
    await page.waitForTimeout(300);
    ok(await page.isHidden('#plan-buy'), 'a Pro studio is not sold Pro again');
    ok(await page.isVisible('#plan-manage'), 'and can manage its billing');
    ok(/paid up to 14 January 2027/.test(await page.textContent('#plan-line')),
       `the plan line shows when it is paid to (${await page.textContent('#plan-line')})`);
    ok(await page.isHidden('#pro-list'), 'the Pro sales list is put away');
    ok(await page.isVisible('#plus-offer'), 'and Pro+ is offered on top');
    ok(errs.length === 0, `no console errors on a Pro dashboard (${errs.length})`);
    await ctx.close(); }

  /* ------------------------------------------------------------- Pro+ --
     Three plans means every "is she Pro?" is now a floor, not an equality, and
     every one of those is somewhere a studio who pays MORE could silently lose
     what she already had. That is the bug this block exists to catch. */
  { const st = withStudio([]); st.studio.plan = 'pro_plus';
    st.billing = { plan:'pro_plus', until:'2027-01-14T00:00:00Z', subscribed:true, customer:'cus_1' };
    const {ctx,page,errs} = await mk(browser, st);
    await page.click('.tab[data-panel="page"]');
    await page.waitForTimeout(300);
    ok(/Pro\+/.test(await page.textContent('#plan-line')), 'a Pro+ studio is told she is on Pro+');
    ok(await page.isHidden('#plan-buy'), 'and is not sold Pro');
    ok(await page.isHidden('#plus-offer'), 'nor Pro+ again');
    ok(await page.isVisible('#plan-manage'), 'and can manage her billing');

    /* Everything Pro buys, still bought. */
    await page.click('.tab[data-panel="rebook"]');
    await page.waitForTimeout(200);
    ok(await page.isVisible('#rb-live'), 'rebooking did not disappear when she upgraded');
    ok(await page.isHidden('#rb-locked'), 'and is not shown locked');
    await page.click('.tab[data-panel="days"]');
    await page.waitForTimeout(200);
    ok(!(await page.isDisabled('#remindh')), 'nor did reminders');
    await page.click('.tab[data-panel="share"]');
    await page.waitForTimeout(500);
    ok(await page.isHidden('#sh-credit'), 'nor an unbranded story card');

    /* The pack, which is what she is actually paying the extra for. */
    await page.click('.tab[data-panel="clients"]');
    await page.locator('.cline').first().waitFor({ timeout:4000 }).catch(()=>{});
    await page.locator('.cline').first().locator('summary').click();
    await page.waitForTimeout(200);
    const pop = page.waitForEvent('popup');
    await page.locator('.cline').first().locator('.packgo').click();
    const doc = await pop;
    await doc.waitForLoadState('domcontentloaded');
    const txt = await doc.textContent('body');
    ok(/Ruby Hall/.test(txt), 'the pack names the client');
    ok(/Patch tests/.test(txt) && /No reaction at 48h/.test(txt),
       'and carries her dated patch tests');
    ok(/Appointments/.test(txt) && /Hybrid full set/.test(txt), 'and her appointments');
    ok(/Produced/.test(txt), 'and says when it was produced');
    ok(/Booked and attended/.test(txt),
       'and distinguishes a test she booked from one typed in afterwards');
    await doc.close();
    ok(errs.length === 0, `no console errors on a Pro+ dashboard (${errs.length})`);
    await ctx.close(); }

  /* ---------------------------------------------------------- the trial --
     Every studio starts on Pro+ for fourteen days. In the database that is a
     real pro_plus plan with an end date, which is what makes it cheap - and
     exactly why the dashboard has to tell a trial from a subscription. The
     bug this block exists to catch is a trialling studio shown a billing
     portal for a subscription she does not have, and never shown a price. */
  { const st = withStudio([]);
    st.studio.plan = 'pro_plus';
    st.studio.plan_state = 'trialing';
    st.studio.trial_until = new Date(Date.now() + 9 * 864e5).toISOString();
    const {ctx,page,errs} = await mk(browser, st);
    await page.waitForTimeout(400);
    ok(await page.isVisible('#trial-bar'), 'the trial is said at the top of the diary');
    const eye = await page.textContent('#tb-eye');
    ok(/fourteen days/i.test(eye), `and says what it is (${eye})`);
    const say = await page.textContent('#tb-say');
    ok(/9 days left/.test(say), `with the days counted (${say})`);
    ok(/reminders/i.test(say) && /insurance pack/i.test(say),
       'and names what she has, not what she is missing');
    ok(await page.isVisible('#tb-track'), 'and shows how far through she is');
    /* Everything Pro+ buys has to really be on during the trial, or the
       fourteen days sell nothing. */
    await page.click('.tab[data-panel="rebook"]');
    await page.waitForTimeout(200);
    ok(await page.isVisible('#rb-live'), 'rebooking is on during the trial');
    await page.click('.tab[data-panel="page"]');
    await page.waitForTimeout(300);
    ok(await page.isVisible('#plan-buy'), 'a trialling studio is still shown the prices');
    ok(await page.isHidden('#plan-manage'),
       'and not a billing portal for a subscription she has not got');
    const line = await page.textContent('#plan-line');
    ok(/free until/i.test(line), `the plan line says it is free for now (${line})`);
    ok(!/paid up to/.test(line), 'and never claims she has paid');
    /* The one button, and where it goes. */
    await page.click('.tab[data-panel="diary"]');
    await page.waitForTimeout(200);
    await page.click('#tb-go');
    await page.waitForTimeout(400);
    ok(await page.isVisible('#plan-buy'), 'keeping Pro+ takes her to the prices');
    ok(errs.length === 0, `no console errors while trialling (${errs.length})`);
    await ctx.close(); }

  /* Day fifteen, which is the half that has to work: she has used all of it
     and now cannot. What she must not be told is that anything is gone. */
  { const st = withStudio([]);
    st.studio.plan = 'free';
    st.studio.plan_state = 'trial_over';
    st.studio.trial_until = new Date(Date.now() - 864e5).toISOString();
    const {ctx,page,errs} = await mk(browser, st);
    await page.waitForTimeout(400);
    ok(await page.isVisible('#trial-bar'), 'the end of the trial is said too');
    ok(/ended/i.test(await page.textContent('#tb-eye')), 'and says it has ended');
    const say = await page.textContent('#tb-say');
    ok(/still (where you left them|here)|exactly where/.test(say),
       `the first thing she is told is what she keeps (${say})`);
    ok(/reminders/i.test(say) && /stopped/.test(say), 'then what stopped');
    ok(await page.isHidden('#tb-track'), 'with no countdown left to run');
    await page.click('.tab[data-panel="page"]');
    await page.waitForTimeout(300);
    ok(await page.isVisible('#plan-buy'), 'and she is shown the way back');
    ok(await page.isVisible('#pro-list'), 'with what it buys spelled out again');
    ok(errs.length === 0, `no console errors after the trial (${errs.length})`);
    await ctx.close(); }

  /* ------------------------------------------------- what they pay up front --
     Three modes, and the thing worth testing is which boxes each one needs.
     Full price asks for her bank details regardless of the deposit figure,
     which is the case 017's constraint did not cover. */
  { const st = withStudio([]);
    st.studio.plan = 'pro_plus';
    st.studio.pay_mode = 'deposit';
    st.studio.deposit_pence = 1000;
    st.studio.deposit_how = 'bank';
    st.studio.deposit_name = 'J Patel';
    st.studio.deposit_sort = '04-00-04';
    st.studio.deposit_account = '12345678';
    const {ctx,page,errs} = await mk(browser, st);
    await page.click('.tab[data-panel="page"]');
    await page.waitForTimeout(300);
    ok(await page.isVisible('#dep-amt-wrap'), 'a deposit has an amount');
    ok(await page.isVisible('#dep-bank'), 'and somewhere to send it');

    /* Full price: no amount box, because the treatment's price IS the amount. */
    await page.click('#dep-mode [data-mode="full"]');
    await page.waitForTimeout(200);
    ok(await page.isHidden('#dep-amt-wrap'),
       'full price asks for no amount - the treatment already has one');
    ok(await page.isVisible('#dep-bank'), 'but still needs her bank details');
    ok(/whole price/i.test(await page.textContent('#h-dep-mode')),
       'and says what it means');
    await page.click('#dep-save');
    await page.waitForTimeout(300);
    const up = await page.evaluate(() =>
      window.__S.ops.filter(o => o.table === 'tenant' && o.op === 'update').pop());
    ok(up && up.payload.pay_mode === 'full', `the mode is saved (${up && up.payload.pay_mode})`);
    ok(up && !('deposit_pence' in up.payload),
       'and her deposit figure is left alone, to go back to');
    ok(up && up.payload.deposit_name === 'J Patel', 'with the account it goes to');
    ok(/full price/i.test(await page.textContent('#toast')),
       `and she is told what will happen (${await page.textContent('#toast')})`);

    /* Off: not a reset. Her sort code survives being switched off, or turning
       it back on next month means typing it again. */
    await page.click('#dep-mode [data-mode="none"]');
    await page.waitForTimeout(200);
    ok(await page.isHidden('#dep-rest'), 'switching it off puts the details away');
    await page.click('#dep-save');
    await page.waitForTimeout(300);
    const off = await page.evaluate(() =>
      window.__S.ops.filter(o => o.table === 'tenant' && o.op === 'update').pop());
    ok(off && off.payload.pay_mode === 'none', 'off is saved as a mode');
    ok(off && Object.keys(off.payload).length === 1,
       `and touches nothing else, so her bank details survive (${off && Object.keys(off.payload).join(',')})`);
    ok(errs.length === 0, `no console errors on the deposits card (${errs.length})`);
    await ctx.close(); }

  /* ------------------------------------------------- the first four --
     The curated half: the wizard gets her a page, this gets her ready, and
     the first item is different for every trade. */
  { const st = withStudio([]);
    const {ctx,page,errs} = await mk(browser, st);
    await page.waitForTimeout(400);
    ok(await page.isVisible('#setup'), 'a new studio is shown what to do next');
    ok(/Check your patch test hours/.test(await page.textContent('#setup-list')),
       'and a lash studio is told to check her patch test hours');
    const n = await page.$$eval('#setup .srow', ns => ns.length);
    ok(n === 4, `four things, not a page of them (${n})`);
    ok(/0\/4|1\/4/.test(await page.textContent('#setup-frac')),
       'with a count she can see');

    /* Tapping one takes her there and ticks it. */
    await page.click('#setup .srow[data-k="days"]');
    await page.waitForTimeout(350);
    ok(await page.isVisible('#p-days'), 'tapping an item takes her to it');
    await page.click('.tab[data-panel="diary"]');
    await page.waitForTimeout(300);
    ok(await page.$eval('#setup .srow[data-k="days"]',
         n2 => n2.classList.contains('done')), 'and it is ticked when she comes back');
    ok(errs.length === 0, `no console errors (${errs.length})`);
    await ctx.close(); }

  { /* A salon is told something else entirely. */
    const st = withStudio([]); st.studio.trade = 'hair';
    const {ctx,page} = await mk(browser, st);
    await page.waitForTimeout(400);
    const txt = await page.textContent('#setup-list');
    ok(/processing time/.test(txt), 'a salon is told to set her processing time');
    ok(!/patch test hours/.test(txt), 'and is not told to do the lash one');
    await ctx.close(); }

  { /* And a PMU artist a third thing. */
    const st = withStudio([]); st.studio.trade = 'pmu';
    const {ctx,page} = await mk(browser, st);
    await page.waitForTimeout(400);
    ok(/deposits/.test(await page.textContent('#setup-list')),
       'a PMU artist is told to turn on deposits first');
    await ctx.close(); }

  { /* Done is gone: it does not sit there ticked forever. */
    const st = withStudio([]);
    st.studio.services = st.studio.services.map(x =>
      Object.assign({}, x, { photo_path: 't1/x.jpg' }));
    const ctx = await browser.newContext({ viewport:{width:1280,height:900} });
    const page = await ctx.newPage();
    await page.route('**/supabase-js*', r => r.fulfill({ contentType:'application/javascript', body: STUB }));
    await page.route('**/config.js', r => r.fulfill({ contentType:'application/javascript', body: CONFIG }));
    await page.addInitScript(`window.__S = ${JSON.stringify(st)};`);
    await page.addInitScript(`try{
      localStorage.setItem('bi.setup.studio-mila.trade','1');
      localStorage.setItem('bi.setup.studio-mila.days','1');
      localStorage.setItem('bi.setup.studio-mila.share','1');
    }catch(e){}`);
    await page.goto(PAGE, { waitUntil:'load' });
    await page.waitForTimeout(600);
    ok(await page.isHidden('#setup'),
       'once all four are done the card is gone, not sitting there ticked');
    await ctx.close(); }

  /* ------------------------------------------------- the signup journey --
     Motion is the point of this screen, and a screenshot cannot tell a
     transition from a cut. So these sample the live values instead: that the
     preview really fills in from the answers, that the rail really fills,
     and that somebody who asked for no motion gets none of it. */
  { const {ctx,page,errs} = await mk(browser, NOSTUDIO);
    await page.waitForTimeout(400);
    console.log('');

    /* The toast is the aria-live region and lives at the bottom of every
       screen. Parked, it must be entirely off it. */
    const park = await page.evaluate(() => {
      const t = document.getElementById('toast');
      return Math.round(t.getBoundingClientRect().top - window.innerHeight);
    });
    ok(park >= 0, `the empty toast is fully off screen (${park}px past the bottom)`);

    ok(await page.isVisible('#pv-phone'), 'the page she is making is on screen from the start');
    ok(/booked-in\.co\.uk/.test(await page.textContent('#pv-url')),
       'showing the address it will live at');
    const ghosts = await page.$$eval('.pv-ghost', ns => ns.filter(n => !n.hidden).length);
    ok(ghosts > 0, 'with the parts she has not answered drawn as blanks, not left empty');

    /* Picking a trade fills the treatment list from that trade's seeds. */
    await page.click('.trade[data-trade="hair"]');
    await page.waitForTimeout(450);
    const rows = await page.textContent('#pv-list');
    ok(/Root tint/.test(rows) && /Full head highlights/.test(rows),
       'picking hair puts a salon price list in the preview');
    ok(await page.$eval('.trades', n => n.classList.contains('chosen')),
       'and the tiles she did not pick step back');

    await page.click('#w1-next');
    await page.waitForTimeout(500);
    const filled = await page.$$eval('.steps i', ns =>
      ns.map(n => getComputedStyle(n, '::after').transform));
    ok(filled[0] !== 'none' && filled[0] !== filled[2],
       'the rail fills behind her rather than switching colour');

    await page.fill('#sname', 'Ivy & Fern');
    await page.waitForTimeout(250);
    ok((await page.textContent('#pv-name')).trim() === 'Ivy & Fern',
       'her name lands on the preview as she types it');
    await page.fill('#stag', 'Colour specialist · Leeds');
    await page.waitForTimeout(250);
    ok(/Colour specialist/.test(await page.textContent('#pv-tag')),
       'and so does the line under it');

    /* Going back should feel like going back. */
    await page.click('[data-back="w1"]');
    await page.waitForTimeout(150);
    ok(await page.$eval('#w1', n => n.classList.contains('back')),
       'going back arrives from the other side');
    await page.click('#w1-next');
    await page.waitForTimeout(500);
    ok(!(await page.$eval('#w2', n => n.classList.contains('back'))),
       'and going on does not');
    ok(errs.length === 0, `no console errors through the wizard (${errs.length})`);
    await ctx.close(); }

  { /* Asked for no motion: the states still change, they just arrive. */
    const ctx = await browser.newContext({ viewport:{width:1280,height:900},
      reducedMotion:'reduce' });
    const page = await ctx.newPage();
    const errs = [];
    page.on('pageerror', e => errs.push('PAGEERROR ' + e.message));
    await page.route('**/supabase-js*', r => r.fulfill({ contentType:'application/javascript', body: STUB }));
    await page.route('**/config.js', r => r.fulfill({ contentType:'application/javascript', body: CONFIG }));
    await page.addInitScript(`window.__S = ${JSON.stringify(NOSTUDIO)};`);
    await page.goto(PAGE, { waitUntil:'load' });
    await page.waitForTimeout(400);
    const anim = await page.$eval('.card.wiz-step', n => getComputedStyle(n).animationName);
    ok(anim === 'none', `the entrance does not run for her (${anim})`);
    await page.click('.trade[data-trade="nails"]');
    await page.waitForTimeout(200);
    ok(/BIAB/.test(await page.textContent('#pv-list')),
       'but the preview still fills in, because that is information');
    ok(errs.length === 0, `no console errors with motion off (${errs.length})`);
    await ctx.close(); }

  /* ------------------------------------------------------- by trade --
     `trade` used to be written at signup and never read again. These check it
     now changes what she is shown - and, more importantly, that it changes it
     the RIGHT way round: the sector with processing time gets the card, and
     the sector without is never asked about it. */
  { const st = withStudio([]);
    const {ctx,page,errs} = await mk(browser, st);
    await page.click('.tab[data-panel="treats"]');
    await page.waitForTimeout(350);
    ok(await page.isHidden('#gap-card'),
       'a lash studio is not asked about processing time');
    ok(/Adhesive, tint and lifting/.test(await page.textContent('#pt-trade')),
       'and the patch card speaks about her work, not about hair');
    ok(errs.length === 0, `no console errors on a lash dashboard (${errs.length})`);
    await ctx.close(); }

  { /* The same dashboard, for a salon. */
    const st = withStudio([]);
    st.studio.trade = 'hair';
    st.studio.trade_profile = { label:'Hair', client:'client', lead:'gaps', gaps:true,
      patch:'Colour needs an allergy alert test 48 hours before. That is the one your insurer will ask about.' };
    st.studio.services = [
      { id:'s1', name:'Root tint', price_pence:4500, duration_min:90, active:true,
        sort:1, rebook_weeks:6, gap_after_min:20, gap_min:35 },
      { id:'s2', name:'Cut & blow dry', price_pence:3500, duration_min:60, active:true,
        sort:2, rebook_weeks:6, gap_after_min:null, gap_min:null },
      { id:'s3', name:'Fringe trim', price_pence:1000, duration_min:10, active:true,
        sort:3, rebook_weeks:null, gap_after_min:null, gap_min:null }];
    const {ctx,page,errs} = await mk(browser, st);
    await page.click('.tab[data-panel="treats"]');
    await page.waitForTimeout(350);
    ok(await page.isVisible('#gap-card'), 'a salon IS asked about processing time');
    ok(/allergy alert test/.test(await page.textContent('#pt-trade')),
       'and is told what a patch test means for colour');
    const rows = await page.$$eval('#gap-list .gline', ns => ns.map(n => ({
      name: n.querySelector('.nm').textContent,
      after: n.querySelector('.ga').value,
      mins: n.querySelector('.gm').value,
      off: n.querySelector('.ga').disabled })));
    ok(rows.length === 3, 'every treatment is listed');
    const tint = rows.filter(r => r.name === 'Root tint')[0];
    ok(tint && tint.after === '20' && tint.mins === '35', 'the colour carries its gap');
    const cut = rows.filter(r => r.name === 'Cut & blow dry')[0];
    ok(cut && cut.after === '' && cut.mins === '', 'a dry cut carries none');
    const trim = rows.filter(r => r.name === 'Fringe trim')[0];
    ok(trim && trim.off, 'and a ten-minute treatment cannot hold one, so it is not offered');

    await page.fill('#gap-list .gline:first-child .gm', '');
    await page.click('#gap-save');
    await page.waitForTimeout(250);
    ok(/both numbers, or neither/.test(await page.textContent('#gap-said')),
       'half a gap is refused in words, not in constraint language');

    await page.fill('#gap-list .gline:first-child .ga', '70');
    await page.fill('#gap-list .gline:first-child .gm', '40');
    await page.click('#gap-save');
    await page.waitForTimeout(250);
    ok(/finish before it does/.test(await page.textContent('#gap-said')),
       'and so is one that outlasts the treatment');

    await page.fill('#gap-list .gline:first-child .ga', '25');
    await page.fill('#gap-list .gline:first-child .gm', '30');
    await page.click('#gap-save');
    await page.waitForTimeout(400);
    /* One update per row, so the last one is the fringe trim's nulls - the
       one that matters is the row that changed. */
    const sent = await page.evaluate(() =>
      window.__S.ops.filter(o => o.table === 'service' && o.op === 'update'
        && o.payload && 'gap_min' in o.payload).map(o => o.payload));
    ok(sent.length === 3, `every row is saved, not just the edited one (${sent.length})`);
    ok(sent.some(x => x.gap_after_min === 25 && x.gap_min === 30), 'a good one saves');
    ok(sent.some(x => x.gap_after_min === null && x.gap_min === null),
       'and clearing one sends null rather than nothing');
    ok(errs.length === 0, `no console errors on a salon dashboard (${errs.length})`);
    await ctx.close(); }

  { /* And the diary says when the chair is free, in her clock. */
    const when = new Date(Date.now() + 3 * 3600e3);
    const st = withStudio([{ id:'b1', ref:'AB12CD34', starts_at: when.toISOString(),
      ends_at: new Date(when.getTime() + 90 * 60000).toISOString(),
      client_name:'Nadia Shah', client_email:'nadia@example.com', client_phone:null,
      client_id:'c1', status:'confirmed', service:'Root tint', price_pence:4500,
      gap_after_min:20, gap_min:35 }]);
    st.studio.trade = 'hair';
    const {ctx,page,errs} = await mk(browser, st);
    await page.waitForTimeout(400);
    const row = await page.textContent('#diary-list');
    ok(/Chair free/.test(row), 'the diary says the chair is free mid-appointment');
    const a = new Date(when.getTime() + 20 * 60000)
      .toLocaleTimeString('en-GB', { hour:'2-digit', minute:'2-digit' });
    const b = new Date(when.getTime() + 55 * 60000)
      .toLocaleTimeString('en-GB', { hour:'2-digit', minute:'2-digit' });
    ok(row.indexOf(a) !== -1 && row.indexOf(b) !== -1,
       `and says between which two times (${a} to ${b})`);
    ok(errs.length === 0, `no console errors on a salon diary (${errs.length})`);
    await ctx.close(); }

  /* --------------------------------------------- a booking by hand --
     Half her week arrives by text and on the phone. Until this existed there
     was nowhere to type it, which made her diary a partial diary and the
     overlap guard a partial guard. */
  { const st = withStudio([]);
    const {ctx,page,errs} = await mk(browser, st);
    await page.waitForTimeout(300);
    ok(await page.isVisible('#add-card'), 'she can put a booking in herself');
    ok(await page.isHidden('#ab-svc'), 'closed until she asks, so the diary stays the first thing');
    await page.click('#add-sum');
    ok(await page.isVisible('#ab-svc'), 'and opens when she does');
    ok(/Hybrid full set/.test(await page.textContent('#ab-svc')), 'listing her own treatments');
    ok(await page.isVisible('#ab-addr-wrap'), 'and asking where she is going, because she travels');
    ok(await page.isHidden('#ab-rep'), 'a standing appointment is not offered on Free');
    ok(await page.isVisible('#ab-rep-locked'), 'it is signposted instead');

    /* Refusals first. It is her diary: nothing half-typed goes in it. */
    await page.click('#ab-go');
    ok(/Pick a day/.test(await page.textContent('#ab-out')), 'a booking with no day is refused');
    await page.fill('#ab-date', '2026-11-17');
    ok(/Tuesday 17 November 2026/.test(await page.textContent('#ab-said')),
       'the day is said back in words, so a mm/dd picker cannot mislead her');
    await page.fill('#ab-time', '10:30');
    await page.click('#ab-go');
    ok(/name/.test(await page.textContent('#ab-out')), 'and one with no name');
    await page.fill('#ab-name', 'Ruby Hall');
    await page.fill('#ab-mail', 'ruby@');
    await page.click('#ab-go');
    ok(/not reach her/.test(await page.textContent('#ab-out')),
       'and one with an email that will never reach her');
    ok(await page.getAttribute('#ab-mail', 'aria-invalid') === 'true',
       'with the field itself marked, not just a line of text');

    await page.fill('#ab-mail', 'ruby@example.com');
    await page.fill('#ab-tel', '07700 900111');
    await page.fill('#ab-addr', '14 Mill Road, Coventry');
    await page.click('#ab-go');
    await page.waitForTimeout(400);
    const bk = await page.evaluate(() =>
      window.__S.ops.filter(o => o.op === 'rpc' && o.name === 'studio_book')[0]);
    ok(!!bk, 'and a complete one goes in');
    ok(bk && bk.args.p_starts === '2026-11-17T10:30:00.000Z',
       'at the time she typed, read on her clock (' + (bk && bk.args.p_starts) + ')');
    ok(bk && bk.args.p_name === 'Ruby Hall' && bk.args.p_email === 'ruby@example.com',
       'with the client it is for');
    ok(bk && bk.args.p_address === '14 Mill Road, Coventry',
       'and the address she is travelling to');
    ok(/Ruby is in for/.test(await page.textContent('#ab-out')),
       'and she is told who is in, and when');
    ok(await page.inputValue('#ab-name') === '',
       'the form clears, so the next phone call does not land on the last one');
    ok(errs.length === 0, `no console errors adding a booking (${errs.length})`);
    await ctx.close(); }

  { /* Her clock, not the laptop's. Typed from a hotel in New York, a July
       appointment at 10:30 is 10:30 in Coventry - 09:30 UTC, because London is
       an hour ahead of UTC in summer. Getting this wrong is an hour-late
       appointment, which is the worst kind of bug this app could ship. */
    const st = withStudio([]);
    const {ctx,page,errs} = await mk(browser, st,
      { viewport:{width:1280,height:900}, timezoneId:'America/New_York' });
    await page.waitForTimeout(300);
    await page.click('#add-sum');
    await page.fill('#ab-date', '2026-07-14');
    await page.fill('#ab-time', '10:30');
    await page.fill('#ab-name', 'Ruby Hall');
    await page.fill('#ab-mail', 'ruby@example.com');
    await page.click('#ab-go');
    await page.waitForTimeout(400);
    const bk = await page.evaluate(() =>
      window.__S.ops.filter(o => o.op === 'rpc' && o.name === 'studio_book')[0]);
    ok(bk && bk.args.p_starts === '2026-07-14T09:30:00.000Z',
       'a summer appointment typed abroad is still her 10:30 (' + (bk && bk.args.p_starts) + ')');
    ok(/14 July/.test(await page.textContent('#ab-out')) &&
       /09:30|10:30/.test(await page.textContent('#ab-out')),
       'and is read back to her on her own clock');
    ok(errs.length === 0, `no console errors across timezones (${errs.length})`);
    await ctx.close(); }

  { /* The standing appointment: Pro+. Every six weeks is how this trade works,
       and typing it out six times is why it ends up in nobody's diary. */
    const st = withStudio([]); st.studio.plan = 'pro_plus';
    const {ctx,page,errs} = await mk(browser, st);
    await page.waitForTimeout(300);
    await page.click('#add-sum');
    ok(await page.isVisible('#ab-rep'), 'a Pro+ studio is offered the standing appointment');
    ok(await page.isHidden('#ab-rep-locked'), 'and not sold what she already has');
    ok(await page.isHidden('#ab-every'), 'the how-often is out of the way until she wants it');
    await page.check('#ab-again');
    ok(await page.isVisible('#ab-every'), 'and appears when she ticks it');
    await page.selectOption('#ab-weeks', '6');
    await page.selectOption('#ab-times', '4');
    await page.fill('#ab-date', '2026-11-17');
    await page.fill('#ab-time', '10:30');
    await page.fill('#ab-name', 'Ruby Hall');
    await page.fill('#ab-mail', 'ruby@example.com');
    await page.click('#ab-go');
    await page.waitForTimeout(400);
    const sr = await page.evaluate(() =>
      window.__S.ops.filter(o => o.op === 'rpc' && o.name === 'book_series')[0]);
    ok(!!sr, 'the series goes in as a series, not four bookings typed out');
    ok(sr && sr.args.p_every_weeks === 6 && sr.args.p_times === 4,
       'at the interval and count she chose');
    const out = await page.textContent('#ab-out');
    ok(/3 appointments in/.test(out), 'she is told how many went in (' + out + ')');
    ok(/1 skipped/.test(out) && /already have something/.test(out),
       'and which one did not, with the reason, rather than quietly being three');
    ok(errs.length === 0, `no console errors on a series (${errs.length})`);
    await ctx.close(); }

  /* ------------------------------------------------- the waiting list --
     The people who tried to book and could not. Pro+, because what makes it
     worth anything is that it fills the cancellation by itself. */
  { const st = withStudio([]); st.studio.plan = 'pro_plus';
    st.waitlist = [
      { id:'w1', name:'Dani Okafor', email:'dani@example.com', note:'any evening',
        service:'Hybrid full set', created_at:'2026-10-02T09:00:00Z', notified_at:null },
      { id:'w2', name:'Leah Byrne', email:'leah@example.com', note:null, service:null,
        created_at:'2026-09-20T09:00:00Z', notified_at:'2026-10-13T09:00:00Z' }
    ];
    const {ctx,page,errs} = await mk(browser, st);
    await page.click('.tab[data-panel="clients"]');
    await page.waitForTimeout(400);
    ok(await page.isVisible('#wl-card'), 'a Pro+ studio sees who is waiting for a space');
    const txt = await page.textContent('#wl-list');
    ok(/Dani Okafor/.test(txt) && /Leah Byrne/.test(txt), 'both of them');
    ok(/any evening/.test(txt), 'with what they asked for');
    ok(/Hybrid full set/.test(txt), 'and the treatment they are waiting on');
    ok(/told/.test(txt), 'somebody already offered a slot says so');
    ok(/joined/.test(txt), 'and somebody still waiting says how long');
    ok(/automatically/.test(await page.textContent('#wl-card')),
       'and she is told she does not have to do anything, because she does not');
    ok(errs.length === 0, `no console errors on the waiting list (${errs.length})`);
    await ctx.close(); }

  { /* The patch bar on Pro+ is not a to-do list. The nudge went out at 10:38
       this morning, so the sentence has to say so, or she does the work the
       extra fiver already bought. */
    const lapsed = new Date(Date.now() - 400 * 864e5).toISOString();
    const st = withStudio([]); st.studio.plan = 'pro_plus';
    st.patchTests = { c1: { tested_at: lapsed, valid_until: lapsed } };
    const {ctx,page} = await mk(browser, st);
    await page.click('.tab[data-panel="clients"]');
    await page.waitForTimeout(400);
    ok(await page.isVisible('#cl-due'), 'a lapsed patch test still raises the bar');
    ok(/asked to book one/.test(await page.textContent('#cl-due')),
       'and on Pro+ it says she has already been chased');
    await ctx.close(); }

  { /* On Pro the same bar is a to-do list, and must not claim otherwise. */
    const lapsed = new Date(Date.now() - 400 * 864e5).toISOString();
    const st = withStudio([]); st.studio.plan = 'pro';
    st.patchTests = { c1: { tested_at: lapsed, valid_until: lapsed } };
    const {ctx,page} = await mk(browser, st);
    await page.click('.tab[data-panel="clients"]');
    await page.waitForTimeout(400);
    ok(!/asked to book/.test(await page.textContent('#cl-due')),
       'on Pro nobody has been chased, and the bar does not pretend otherwise');
    await ctx.close(); }

  { /* Below Pro+ it is not a locked card, it is nothing: there is nobody on the
       list, because the public page never offered one. */
    const st = withStudio([]); st.studio.plan = 'pro';
    const {ctx,page} = await mk(browser, st);
    await page.click('.tab[data-panel="clients"]');
    await page.waitForTimeout(400);
    ok(await page.isHidden('#wl-card'), 'a Pro studio is not shown an empty waiting list');
    await ctx.close(); }

  { /* On anything below Pro+ the button is a signpost, and the refusal is the
       database's rather than a hidden button's. */
    const {ctx,page} = await mk(browser, withStudio([]));
    await page.click('.tab[data-panel="clients"]');
    await page.locator('.cline').first().waitFor({ timeout:4000 }).catch(()=>{});
    await page.locator('.cline').first().locator('summary').click();
    await page.waitForTimeout(200);
    ok(/Pro\+/.test(await page.locator('.cline').first().locator('.packgo').textContent()),
       'a Free studio sees the pack, marked as Pro+');
    await page.locator('.cline').first().locator('.packgo').click();
    await page.waitForTimeout(300);
    ok(await page.isVisible('#p-page'), 'tapping it takes her to the plan rather than failing silently');
    await ctx.close(); }

  /* ------------------------------------------------------------ clients -- */
  { const {ctx,page,errs} = await mk(browser, withStudio([]));
    await page.click('.tab[data-panel="clients"]');
    await page.waitForTimeout(350);
    ok(await page.isVisible('#p-clients'), 'the clients tab opens');
    ok((await page.locator('.cline').count()) === 2, 'both clients are listed');
    const sum = await page.textContent('#cl-sum');
    ok(/2 clients/.test(sum) && /£310/.test(sum),
       `the summary adds up what they have spent between them (${sum})`);

    const first = page.locator('.cline').first();
    ok(/Ruby Hall/.test(await first.textContent()), 'the one seen most recently is first');
    ok(/6 visits/.test(await first.textContent()), 'with how many times she has been');
    ok(/£270/.test(await first.textContent()), 'and what she has spent');
    ok(/last seen/.test(await first.textContent()),
       'and how long it has been, in weeks rather than a date');
    ok(/booked/.test(await page.locator('.cline').nth(1).textContent()),
       'somebody with an appointment ahead shows that instead');

    /* The address and the notes are behind the summary: four facts wide is
       what she scans, everything else is about one client at a time. */
    ok(!(await first.locator('.cbody').isVisible()), 'the detail starts closed');
    await first.locator('summary').click();
    await page.waitForTimeout(150);
    ok(await first.locator('.cbody').isVisible(), 'and opens when she asks');
    ok(/ruby@example\.com/.test(await first.textContent()), 'showing her email');
    ok(/1 cancelled/.test(await first.textContent()), 'and that she cancelled once');
    /* Kept from the booking so a regular never retypes it, and shown only
       here, to the one person entitled to see it. */
    ok(/14 Mill Road/.test(await first.locator('.cbody').textContent()),
       'and where she went last time');
    ok(/maps\/search/.test(await first.locator('.cbody .at a').getAttribute('href')),
       'as a link to maps');
    const noAddr = page.locator('.cline').nth(1);
    await noAddr.locator('summary').click();
    await page.waitForTimeout(150);
    ok((await noAddr.locator('.at').count()) === 0,
       'a client who has never given one shows no empty line');

    await first.locator('.note').fill('Patch tested 2 Oct. Prefers 11mm.');
    await first.locator('.nsave').click();
    await page.waitForTimeout(250);
    ok(/Saved/.test(await first.locator('.nsaid').textContent()), 'a note saves');
    const call = await page.evaluate(() =>
      window.__S.ops.filter(o => o.name === 'set_client_notes').pop());
    ok(call && call.args.p_client === 'c1' &&
       /Patch tested/.test(call.args.p_notes), 'and goes to the right client');

    await page.fill('#cl-find', 'sian');
    await page.waitForTimeout(150);
    ok((await page.locator('.cline').count()) === 1, 'search narrows the list');
    await page.fill('#cl-find', 'ruby@exa');
    await page.waitForTimeout(150);
    ok((await page.locator('.cline').count()) === 1, 'by address as well as name');
    ok(errs.length === 0, `no console errors on the clients tab (${errs.length})`);
    await ctx.close(); }

  /* -------------------------------------------------------------- share -- */
  { const st = withStudio([]);
    st.studio.plan = 'pro';
    const {ctx,page,errs} = await mk(browser, st);
    await page.click('.tab[data-panel="share"]');
    await page.waitForTimeout(900);
    ok(await page.isVisible('#p-share'), 'the share tab opens');
    ok(await page.isHidden('#sh-none'), 'and a card is drawn, not an excuse');
    const dims = await page.evaluate(() => {
      const c = document.getElementById('sh-canvas');
      return { w:c.width, h:c.height, shown:Math.round(c.getBoundingClientRect().width) };
    });
    ok(dims.w === 1080 && dims.h === 1920,
       `the picture is the Stories size (${dims.w}x${dims.h})`);
    ok(dims.shown < 400, `however small it is shown (${dims.shown}px)`);

    /* The free times on the card have to be the ones long enough for the
       treatment she picked, or the card is advertising appointments she
       cannot actually take. */
    const call = await page.evaluate(() =>
      window.__S.ops.filter(o => o.name === 'free_slots').pop());
    ok(call && call.args.p_service === 's1' && call.args.p_slug === 'studio-mila',
       'and they are looked up for the treatment she chose');

    await page.selectOption('#sh-svc', 's2');
    await page.waitForTimeout(700);
    const call2 = await page.evaluate(() =>
      window.__S.ops.filter(o => o.name === 'free_slots').pop());
    ok(call2 && call2.args.p_service === 's2', 'changing the treatment asks again');

    await page.click('.seg .sg[data-card="book"]');
    await page.waitForTimeout(700);
    ok(await page.isHidden('#sh-svc-f'),
       '"Book with me" lists every treatment, so there is nothing to pick');
    ok(await page.$('#sh-credit') === null,
       'the mark hint is gone from the page entirely');

    await page.click('.seg .sg[data-card="spaces"]');
    await page.waitForTimeout(700);
    ok(await page.isVisible('#sh-svc-f'), 'and it comes back for the others');
    ok(errs.length === 0, `no console errors on the share tab (${errs.length})`);
    await ctx.close(); }

  { /* There is no mark on any card now, so there is nothing to explain to a
       free studio either. 028 took it off: the Stories card is a post she
       makes under her own name, and the booking page keeps "Powered by
       Booked In" on every plan. */
    const {ctx,page} = await mk(browser, withStudio([]));
    await page.click('.tab[data-panel="share"]');
    await page.waitForTimeout(900);
    ok(await page.$('#sh-credit') === null,
       'a free studio is not told about a mark that no longer exists');
    await ctx.close(); }

  { /* A week with nothing free must say so rather than drawing an empty card
       that she posts without noticing. */
    const st = withStudio([]);
    st.slots = [];
    const {ctx,page,errs} = await mk(browser, st);
    await page.click('.tab[data-panel="share"]');
    await page.waitForTimeout(900);
    ok(await page.isVisible('#sh-none'), 'nothing free says so');
    ok(/Nothing free in the next week/.test(await page.textContent('#sh-none')),
       'and says which week it looked at');
    await page.click('.seg .sg[data-card="gap"]');
    await page.waitForTimeout(700);
    ok(/the good kind of problem/.test(await page.textContent('#sh-none')),
       'and a full two days is phrased as the good news it is');
    ok(errs.length === 0, `no console errors with nothing free (${errs.length})`);
    await ctx.close(); }
  /* --------------------------------------------------------- her brand -- */
  { const st = withStudio([]);
    st.studio.plan = 'pro';
    const {ctx,page,errs} = await mk(browser, st);
    await page.click('.tab[data-panel="share"]');
    await page.waitForTimeout(900);

    ok(await page.inputValue('#sh-hex') === '#b8465c',
       'with no colour set it starts on ours');
    /* The picker and the box are two views of one value, and she will reach
       for whichever is nearer. */
    await page.fill('#sh-hex-t', '#5F7A5C');
    await page.waitForTimeout(600);
    ok((await page.inputValue('#sh-hex')).toLowerCase() === '#5f7a5c',
       'typing a hex moves the picker');

    await page.fill('#sh-hex-t', 'green');
    await page.locator('#sh-hex-t').blur();
    await page.waitForTimeout(200);
    ok(/looks like #B8465C/.test(await page.textContent('#e-sh-hex-t')),
       'a colour that is not a hex is refused, with an example');
    const style = await page.evaluate(() => {
      const cs = getComputedStyle(document.getElementById('e-sh-hex-t'));
      return { t: cs.textTransform, c: cs.color };
    });
    ok(style.t === 'none' && style.c === 'rgb(163, 24, 43)',
       'and the refusal is painted as an error, not as a field label');

    await page.fill('#sh-hex-t', '#5F7A5C');
    await page.waitForTimeout(600);
    await page.click('.seg [data-theme="dark"]');
    await page.waitForTimeout(700);
    await page.click('.seg [data-align="centre"]');
    await page.waitForTimeout(700);

    /* The preview has to move with the controls, not with the last save: a
       card she has to save before she can see it is a card she will not
       bother to customise. */
    const bg = await page.evaluate(() => {
      const c = document.getElementById('sh-canvas');
      const d = c.getContext('2d').getImageData(20, 960, 1, 1).data;
      return (0.2126*d[0] + 0.7152*d[1] + 0.0722*d[2]) / 255;
    });
    ok(bg < 0.3, `a dark card is actually dark without saving first (${bg.toFixed(2)})`);

    /* Three segmented controls share a class on this panel, and a selector
       broad enough to catch all of them had one group clearing another. */
    const segs = await page.evaluate(() =>
      [].map.call(document.querySelectorAll('.seg [data-theme],.seg [data-align]'),
        b => (b.dataset.theme || b.dataset.align) + '=' + b.getAttribute('aria-checked')));
    ok(segs.join(' ') === 'light=false dark=true left=false centre=true',
       `each control keeps its own choice (${segs.join(' ')})`);
    await page.click('#sh-brand-save');
    await page.waitForTimeout(400);
    const saved = await page.evaluate(() =>
      window.__S.ops.filter(o => o.table === 'tenant' && o.op === 'update').pop());
    ok(saved && saved.payload.brand_hex === '#5F7A5C' &&
       saved.payload.card_theme === 'dark' && saved.payload.card_align === 'centre',
       'and all three are saved together');
    ok(/Every card you make now uses it/.test(await page.textContent('#sh-said')),
       'with a line that says what saving did');
    ok(errs.length === 0, `no console errors setting a brand (${errs.length})`);
    await ctx.close(); }

  { /* The frame Instagram puts around it, so the covered strips are visible
       here rather than discovered after posting. */
    const {ctx,page} = await mk(browser, withStudio([]));
    await page.click('.tab[data-panel="share"]');
    await page.waitForTimeout(900);
    ok(await page.isVisible('.igchrome'), 'the card is previewed inside Instagram\'s own frame');
    ok(await page.textContent('#ig-name') === 'studio-mila',
       'carrying her handle, so it reads as her Story');
    ok(await page.isVisible('.igsend') && await page.isVisible('.igbar'),
       'with the bar and the button that cover the top and bottom of it');
    await ctx.close(); }
  /* ---------------------------------------------------------- rebooking -- */
  { const {ctx,page,errs} = await mk(browser, withStudio([]));
    await page.click('.tab[data-panel="rebook"]');
    await page.waitForTimeout(250);
    ok(await page.isVisible('#rb-locked'), 'on Free, rebooking is shown as a Pro thing');
    ok(await page.isHidden('#rb-live'), 'and none of the controls are there to fiddle with');
    await page.click('#rb-upgrade');
    await page.waitForTimeout(250);
    ok(await page.isVisible('#p-page') && await page.isVisible('#plan-line'),
       'and "See Pro" actually lands on the plan rather than nowhere');
    ok(errs.length === 0, `no console errors on a locked rebooking tab (${errs.length})`);
    await ctx.close(); }

  { const st = withStudio([]);
    st.studio.plan = 'pro';
    const {ctx,page,errs} = await mk(browser, st);
    await page.click('.tab[data-panel="rebook"]');
    await page.waitForTimeout(250);
    ok(await page.isVisible('#rb-live'), 'on Pro, the controls are there');
    ok(await page.isHidden('#rb-locked'), 'and the sales card is not');
    ok((await page.locator('#rb-list .rline').count()) === 2, 'every treatment is listed');
    ok(await page.inputValue('#rb-list .rline:first-child .wk') === '3',
       'the interval it was given is filled in');
    ok(await page.inputValue('#rb-list .rline:nth-child(2) .wk') === '',
       'and a treatment with none set is blank, not zero');
    ok(await page.isChecked('#rb-on') === false,
       'the switch is off, so nothing has been sent on her behalf without asking');

    await page.check('#rb-on');
    await page.selectOption('#rb-lead', '5');
    await page.fill('#rb-list .rline:nth-child(2) .wk', '4');
    await page.click('#rb-save');
    await page.waitForTimeout(400);
    const ops = await page.evaluate(() => window.__S.ops);
    const ten = ops.filter(o => o.table === 'tenant' && o.op === 'update').pop();
    ok(ten && ten.payload.rebook_on === true && ten.payload.rebook_lead_days === 5,
       'the switch and the lead time are saved');
    const svc = ops.filter(o => o.table === 'service' && o.op === 'update');
    ok(svc.length === 2 && svc.some(o => o.payload.rebook_weeks === 4),
       'and so is every interval');
    ok(/Clients who are due will hear from you/.test(await page.textContent('#rb-said')),
       'and it says what will now happen');

    await page.uncheck('#rb-on');
    await page.click('#rb-save');
    await page.waitForTimeout(400);
    ok(/Nothing will be sent/.test(await page.textContent('#rb-said')),
       'turning it off says that too, rather than just "saved"');

    await page.fill('#rb-list .rline:first-child .wk', '99');
    await page.click('#rb-save');
    await page.waitForTimeout(250);
    ok(/does not look right/.test(await page.textContent('#toast')),
       'a nonsense interval is refused before it is sent anywhere');
    ok(errs.length === 0, `no console errors on the rebooking tab (${errs.length})`);
    await ctx.close(); }

  { const {ctx,page} = await mk(browser, withStudio([]));
    await page.click('.tab[data-panel="page"]');
    await page.click('#go-pro');
    await page.waitForURL('**/pay.stub.test/**', { timeout: 4000 }).catch(()=>{});
    ok(/pay\.stub\.test\/checkout$/.test(page.url()),
       `going Pro sends her to checkout (${page.url()})`);
    await ctx.close(); }

  { const {ctx,page} = await mk(browser, withStudio([]));
    await page.click('.tab[data-panel="page"]');
    await page.click('#go-pro-year');
    await page.waitForURL('**/pay.stub.test/**', { timeout: 4000 }).catch(()=>{});
    ok(/yearly=1/.test(page.url()), 'the yearly button asks for the yearly price');
    await ctx.close(); }

  { const st = withStudio([]); st.studio.plan = 'pro';
    st.billing = { plan:'pro', until:null, subscribed:true, customer:'cus_1' };
    const {ctx,page} = await mk(browser, st);
    await page.click('.tab[data-panel="page"]');
    await page.click('#billing');
    await page.waitForURL('**/pay.stub.test/**', { timeout: 4000 }).catch(()=>{});
    ok(/portal=1/.test(page.url()), 'manage billing opens the portal');
    await ctx.close(); }

  { const {ctx,page} = await mk(browser, withStudio([]), null, NOFN);
    await page.click('.tab[data-panel="page"]');
    await page.click('#go-pro');
    await page.waitForTimeout(250);
    ok(/not switched on/.test(await page.textContent('#toast')),
       'with no functions deployed it says so instead of failing silently');
    ok(page.url().indexOf('pay.stub.test') === -1, 'and does not navigate anywhere');
    await ctx.close(); }

  // --- layout across real devices ---
  for (const [n,d] of [['iphone-se',devices['iPhone SE']],['iphone-12',devices['iPhone 12']],
                       ['ipad-land',devices['iPad Pro 11 landscape']],
                       ['desk-1280',{viewport:{width:1280,height:900}}]]) {
    const {ctx,page,errs} = await mk(browser, withStudio([
      {id:'b1',ref:'AB12',starts_at:soon,ends_at:soon,client_name:'Ruby H.',
       client_email:'r@x.com',status:'confirmed',service:'Hybrid full set',price_pence:5000}]), d);
    await page.waitForTimeout(250);
    let worst = 0, where = '';
    for (const panel of ['diary','clients','rebook','treats','days','page']) {
      await page.click(`.tab[data-panel="${panel}"]`);
      /* The clients list is fetched the first time its tab is opened, and a
         list that has not arrived cannot overflow. Wait for a row. */
      if (panel === 'clients') await page.locator('.cline').first()
        .waitFor({ timeout: 4000 }).catch(() => {});
      await page.waitForTimeout(120);
      const r = await page.evaluate(() => ({
        sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth }));
      if (r.sw - r.cw > worst) { worst = r.sw - r.cw; where = panel; }
    }
    await page.screenshot({ path:`${OUT}/app-${n}.png` });
    ok(worst <= 1 && errs.length === 0,
       `${n} (${await page.evaluate(()=>document.documentElement.clientWidth)}px) no overflow across all six panels` +
       (worst>1?` — ${worst}px on ${where}`:'') + (errs.length?` errs=${errs.length}`:''));
    await ctx.close();
  }

  await browser.close();
  await srv.close();
  console.log(fail ? `\n${fail} failure(s)` : '\nall passed');
  process.exit(fail ? 1 : 0);
})();
