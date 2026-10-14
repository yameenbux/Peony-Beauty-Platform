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
    await page.waitForTimeout(500);
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
    await page.fill('#off-date','2026-12-31');
    await page.click('#off-add');
    await page.waitForTimeout(400);
    ok((await page.locator('#off-list .off').count()) === 2, 'she can close another day');
    const clo = await page.evaluate(() => window.__S.ops.filter(o=>o.name==='set_closure').pop());
    ok(clo && clo.args.p_date === '2026-12-31' && clo.args.p_on === true,
       'set_closure is called with the date she picked');
    await page.locator('#off-list .off button').first().click();
    await page.waitForTimeout(400);
    ok((await page.locator('#off-list .off').count()) === 1, 'she can open a day back up');
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
    ok(errs.length === 0, `no console errors on a Pro dashboard (${errs.length})`);
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
    ok(await page.isHidden('#sh-credit'), 'a Pro studio is not told about the mark');

    await page.click('.seg .sg[data-card="spaces"]');
    await page.waitForTimeout(700);
    ok(await page.isVisible('#sh-svc-f'), 'and it comes back for the others');
    ok(errs.length === 0, `no console errors on the share tab (${errs.length})`);
    await ctx.close(); }

  { /* A free studio is told why the mark is there and how it comes off. */
    const {ctx,page} = await mk(browser, withStudio([]));
    await page.click('.tab[data-panel="share"]');
    await page.waitForTimeout(900);
    ok(await page.isVisible('#sh-credit'), 'a free studio is told about the mark');
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
