/* Booked In — pictures of the thing, for people who do not read diffs.
 *
 *   ./build.sh && node shots.js [outdir]
 *
 * Drives the real built pages over HTTP against the same kind of stubbed
 * Supabase the test suites use, then photographs each screen. Nothing here
 * asserts anything: if a screenshot looks wrong, the suites are where that gets
 * caught. This exists so the product can be looked at.
 *
 * The studio it invents does both - a room at home and a car - because that is
 * the shape that shows the most of the software at once.
 */
const { chromium, devices } = require('playwright');
const { start } = require('./serve');
const fs = require('fs');
const path = require('path');

/* Into .shots/ at the repo root, which .gitignore already covers: these are
   regenerated on demand and must never end up committed. Pass a path to put
   them somewhere else. */
const OUT = process.argv[2] || path.join(__dirname, '..', '.shots', 'tour');

/* A soft blush card standing in for her own photography. Deliberately not a
   stock photograph of somebody else's work: these are screenshots of the
   software, and the one thing on the page that should be hers is hers. */
const PHOTO = `<svg xmlns="http://www.w3.org/2000/svg" width="400" height="400">
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#F3DDE2"/><stop offset=".55" stop-color="#E7C3CC"/>
    <stop offset="1" stop-color="#C98D9C"/></linearGradient></defs>
  <rect width="400" height="400" fill="url(#g)"/>
  <g fill="none" stroke="#8E5E6B" stroke-opacity=".45" stroke-width="7" stroke-linecap="round">
    <path d="M70 250 q60-70 130-70 t130 70"/>
    <path d="M118 196 l-14-34"/><path d="M160 178 l-8-38"/><path d="M200 172 l0-40"/>
    <path d="M240 178 l8-38"/><path d="M282 196 l14-34"/>
  </g></svg>`;

/* --------------------------------------------------------------- her studio */
const DAY = 864e5;
const iso = (d, h, m) => {
  const t = new Date(Date.now() + d * DAY);
  t.setHours(h, m || 0, 0, 0);
  return t.toISOString();
};
const STUDIO = {
  id: 't1', slug: 'studio-mila', name: 'Studio Mila',
  tagline: 'Lashes & brows · Nuneaton and Coventry',
  /* Pro+, because it is the plan that shows the most of the software at once -
     the insurance pack included. */
  trade: 'lashes', plan: 'pro_plus', timezone: 'Europe/London',
  notice_hours: 24, slot_step_min: 15, cancel_hours: 24, remind_hours: 24,
  rebook_on: true, rebook_lead_days: 3,
  brand_hex: '#B8465C', logo_path: null, card_theme: 'light', card_align: 'left',
  patch_valid_months: 6,
  venue_kind: 'both',
  deposit_pence: 1000, deposit_how: 'bank',
  deposit_name: 'E Mila', deposit_sort: '04-00-04', deposit_account: '12345678',
  deposit_note: 'Within 24 hours please, or the time goes back up.',
  address: 'Flat 2, 14 Mill Road, Nuneaton CV11 4QX',
  address_note: 'The white door beside the chippy. Park on the road, free after 6.',
  closures: [{ on_date: '2026-12-24', reason: 'Christmas Eve' }],
  trade_profile: { label:'Lashes', client:'client', lead:'rebook', gaps:false,
    patch:'Adhesive, tint and lifting solution all need a test first.' },
  services: [
    { id:'s1', name:'Hybrid full set', price_pence:5000, duration_min:120, active:true,
      sort:1, photo_path:'t1/hybrid.jpg', rebook_weeks:3, patch_test_hours:48,
      records_patch_test:false },
    { id:'s2', name:'Russian infills', price_pence:4000, duration_min:90, active:true,
      sort:2, photo_path:'t1/russian.jpg', rebook_weeks:3, patch_test_hours:48,
      records_patch_test:false },
    { id:'s3', name:'Brow lamination', price_pence:3500, duration_min:60, active:true,
      sort:3, photo_path:'t1/brows.jpg', rebook_weeks:6, patch_test_hours:24,
      records_patch_test:false },
    { id:'s4', name:'Patch test', price_pence:0, duration_min:15, active:true,
      sort:4, photo_path:null, rebook_weeks:null, patch_test_hours:null,
      records_patch_test:true }
  ],
  openings: [2, 3, 4, 5, 6].map((w, i) =>
    ({ id:'o'+i, weekday:w, starts:'09:00:00', ends:'18:00:00', area:'' })),
  bookings: [
    { id:'b1', ref:'AB12CD34', starts_at:iso(0, 14), ends_at:iso(0, 16),
      client_name:'Ruby Hall', client_email:'ruby@example.com', client_phone:'07700 900111',
      client_id:'c1', client_address:'8 Oaston Road, Nuneaton CV11 6JZ',
      status:'confirmed', service:'Hybrid full set', price_pence:5000,
      deposit_pence:1000, deposit_paid_at: iso(-2, 9) },
    { id:'b2', ref:'EF56GH78', starts_at:iso(1, 10), ends_at:iso(1, 11, 30),
      client_name:'Sian Price', client_email:'sian@example.com', client_phone:'07700 900222',
      client_id:'c2', client_address:null,
      status:'confirmed', service:'Russian infills', price_pence:4000,
      deposit_pence:1000, deposit_paid_at:null },
    { id:'b3', ref:'IJ90KL12', starts_at:iso(1, 13), ends_at:iso(1, 14),
      client_name:'Nina Okafor', client_email:'nina@example.com', client_phone:null,
      client_id:'c3', client_address:'3 Elm Close, Coventry CV10 7AA',
      status:'confirmed', service:'Brow lamination', price_pence:3500 },
    { id:'b4', ref:'MN34OP56', starts_at:iso(3, 11), ends_at:iso(3, 13),
      client_name:'Amy Shaw', client_email:'amy@example.com', client_phone:'07700 900444',
      client_id:'c4', client_address:null,
      status:'confirmed', service:'Hybrid full set', price_pence:5000 }
  ]
};

const CLIENTS = [
  { id:'c1', name:'Ruby Hall', email:'ruby@example.com', phone:'07700 900111',
    address:'8 Oaston Road, Nuneaton CV11 6JZ',
    notes:'Prefers 11mm. Reacted to the adhesive she had elsewhere in 2024.',
    visits:9, spent_pence:43500, cancelled:1,
    first_visit:iso(-420, 10), last_visit:iso(-21, 10), next_visit:iso(0, 14) },
  { id:'c2', name:'Sian Price', email:'sian@example.com', phone:'07700 900222',
    address:null, notes:null, visits:4, spent_pence:16000, cancelled:0,
    first_visit:iso(-150, 10), last_visit:iso(-28, 10), next_visit:iso(1, 10) },
  { id:'c3', name:'Nina Okafor', email:'nina@example.com', phone:null,
    address:'3 Elm Close, Coventry CV10 7AA', notes:null,
    visits:2, spent_pence:7000, cancelled:0,
    first_visit:iso(-90, 10), last_visit:iso(-45, 10), next_visit:iso(1, 13) },
  { id:'c4', name:'Amy Shaw', email:'amy@example.com', phone:'07700 900444',
    address:null, notes:null, visits:1, spent_pence:5000, cancelled:0,
    first_visit:iso(-14, 10), last_visit:iso(-14, 10), next_visit:iso(3, 11) },
  { id:'c5', name:'Leah Byrne', email:'leah@example.com', phone:'07700 900555',
    address:null, notes:null, visits:6, spent_pence:27000, cancelled:2,
    first_visit:iso(-300, 10), last_visit:iso(-70, 10), next_visit:null }
];

/* covered, lapsing this month, lapsed, never - so one screenshot shows all
   four states the Clients tab can be in. */
const PATCHES = {
  c1: { tested_at: iso(-21, 10), valid_until: iso(160, 10) },
  c2: { tested_at: iso(-155, 10), valid_until: iso(27, 10) },
  c3: { tested_at: iso(-220, 10), valid_until: iso(-38, 10) }
};

const REBOOK = [
  { booking_id:'r1', client_name:'Leah Byrne', client_email:'leah@example.com',
    service:'Hybrid full set', last_visit:iso(-70, 10), due_on:iso(-49, 10).slice(0,10),
    sent_at:null, opted_out:false },
  { booking_id:'r2', client_name:'Ruby Hall', client_email:'ruby@example.com',
    service:'Brow lamination', last_visit:iso(-45, 10), due_on:iso(-3, 10).slice(0,10),
    sent_at:iso(-3, 10), opted_out:false }
];

const APP_STUB = `
window.supabase = { createClient: function(){
  var S = window.__S;
  function res(d,e){ return Promise.resolve({ data:d===undefined?null:d, error:e||null }); }
  function builder(){ var b = { eq:function(){return b;}, in:function(){return b;},
    select:function(){return b;}, then:function(f,r){ return res({}).then(f,r); } }; return b; }
  return {
    storage:{ from:function(){ return {
      getPublicUrl:function(p){ return { data:{ publicUrl:'https://stub.test/'+p } }; },
      upload:function(p){ return res({ path:p }); } }; } },
    auth:{
      getSession:function(){ return res({ session:{ access_token:'tok', user:{ id:'u1' } } }); },
      onAuthStateChange:function(){ return { data:{ subscription:{ unsubscribe:function(){} } } }; },
      signInWithOtp:function(){ return res({}); }, signOut:function(){ return res({}); } },
    rpc:function(name, args){
      if(name === 'my_studio')      return res(S.studio);
      if(name === 'my_clients')     return res(S.clients);
      if(name === 'my_patch_tests') return res(S.patches);
      if(name === 'my_rebooks')     return res(S.rebook);
      if(name === 'client_record')  return res(S.pack);
      if(name === 'my_billing')     return res({ until: S.until });
      if(name === 'my_waitlist')    return res(S.waitlist || []);
      if(name === 'my_earnings')    return res(S.earnings);
      if(name === 'photo_prefix')   return res('t1');
      if(name === 'free_slots')     return res(window.__freeSlots(args.p_from, args.p_to));
      return res(null);
    },
    from:function(){ return { update:builder, insert:builder, upsert:builder,
                              delete:builder, select:builder }; }
  };
}};`;

const BOOK_STUB = `
window.supabase = { createClient: function(){
  var S = window.__S;
  function res(d,e){ return Promise.resolve({ data:d===undefined?null:d, error:e||null }); }
  return {
    storage:{ from:function(){ return {
      getPublicUrl:function(p){ return { data:{ publicUrl:'https://stub.test/'+p } }; } }; } },
    rpc:function(name, args){
      if(name === 'get_studio') return res(S.studio);
      if(name === 'free_slots') return res(S.slotsFor(args.p_from));
      if(name === 'book') return res([{ ref:'AB12CD34',
        token:'11111111-2222-3333-4444-555555555555',
        starts_at:args.p_starts, ends_at:args.p_starts }]);
      if(name === 'get_booking') return res({ ref:'AB12CD34',
        deposit: S.studio.deposit_pence ? { pence:S.studio.deposit_pence, how:'bank',
          name:S.studio.deposit_name, sort:S.studio.deposit_sort,
          account:S.studio.deposit_account, note:S.studio.deposit_note } : null });
      return res(null);
    }
  };
}};`;

const CONFIG = `window.BOOKEDIN = { SUPABASE_URL:"https://stub.supabase.co",
  SUPABASE_ANON_KEY:"stub", PAGE_HOST:"booked-in.co.uk",
  FUNCTIONS_URL:"https://fn.stub.test" };`;

/* Free times both pages can show: a few a day, inside her opening hours, far
   enough out that the notice period does not swallow them. */
const SLOTGEN = `
window.__freeSlots = function(from, to){
  var out = [], a = new Date(from + 'T00:00:00'), b = new Date(to + 'T23:59:59');
  for(var d = new Date(a); d <= b; d.setDate(d.getDate() + 1)){
    if([0,1].indexOf(d.getDay()) !== -1) continue;
    if(d < new Date(Date.now() + 2 * 864e5)) continue;
    /* A different first free hour each day, so a card made from this diary
       looks like a diary rather than a repeating row. */
    [[10,15],[12,16],[9,14],[13,17],[11,16]][d.getDay() % 5].forEach(function(h){
      out.push(new Date(d.getFullYear(), d.getMonth(), d.getDate(), h, 0, 0).toISOString());
    });
  }
  return out;
};

window.__S.slotsFor = function(from){
  var out = [], f = new Date(from);
  for(var i = 3; i < 26; i++){
    var d = new Date(); d.setDate(d.getDate() + i);
    if(d.getMonth() !== f.getMonth() || d.getFullYear() !== f.getFullYear()) continue;
    if([0,1].indexOf(d.getDay()) !== -1) continue;
    [9,11,14,16].forEach(function(h){
      out.push(new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate(), h, 0, 0)).toISOString());
    });
  }
  return out;
};`;

async function ctxFor(browser, dev) {
  /* en-GB, because a native date field is drawn by the BROWSER in the viewer's
     locale and no attribute on the page can change it. Shooting this tour in
     Chromium's en-US default put mm/dd/yyyy in a picture of a product for
     British beauty therapists, which is a thing none of them will ever see. */
  const ctx = await browser.newContext(Object.assign(
    { locale:'en-GB', timezoneId:'Europe/London' },
    dev || { viewport:{ width:1400, height:1000 }, deviceScaleFactor:2 }));
  return ctx;
}

async function wire(page, stub, state) {
  await page.route('**/supabase-js*', r =>
    r.fulfill({ contentType:'application/javascript', body: stub }));
  await page.route('**/config.js', r =>
    r.fulfill({ contentType:'application/javascript', body: CONFIG }));
  await page.route('**/stub.test/**', r =>
    r.fulfill({ contentType:'image/svg+xml', body: PHOTO }));
  await page.addInitScript(`window.__S = ${JSON.stringify(state)}; ${SLOTGEN}`);
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const srv = await start();
  /* LANG, not the context's locale option and not --lang: Chromium draws a
     native date or time field from the PROCESS locale, which navigator.language
     does not touch. Left at the container's default this tour photographed
     10/25/2026 and 10:30 AM in a product sold to British beauty therapists -
     a screen none of them will ever see. */
  const browser = await chromium.launch({ args: ['--lang=en-GB'],
    env: Object.assign({}, process.env,
      { LANG:'en_GB.UTF-8', LANGUAGE:'en_GB', LC_ALL:'en_GB.UTF-8' }) });
  const shot = async (page, name, opts) => {
    /* The toast is position:fixed, so a full-page screenshot paints it floating
       in the middle of the picture. It is not on screen; hide it rather than
       photograph a thing that is not there. */
    await page.addStyleTag({ content: '.toast{display:none !important}' }).catch(() => {});
    await page.screenshot(Object.assign({ path: path.join(OUT, name + '.png') }, opts || {}));
    console.log('  ' + name + '.png');
  };

  const appState = { studio: STUDIO, clients: CLIENTS, patches: PATCHES,
                     rebook: REBOOK, until: iso(24, 10), slots: [],
    /* Three people who tried to book and could not, which is the only list in
       the app that is worth money the moment somebody cancels. */
    waitlist: [
      { id:'w1', name:'Dani Okafor', email:'dani@example.com', note:'any evening',
        service:'Hybrid full set', created_at: iso(-9, 9), notified_at: null },
      { id:'w2', name:'Leah Byrne', email:'leah@example.com', note:'Saturdays only',
        service:'Brow lamination', created_at: iso(-16, 9), notified_at: iso(-2, 9) },
      { id:'w3', name:'Nina Patel', email:'nina@example.com', note:null,
        service: null, created_at: iso(-23, 9), notified_at: null }],
    /* Her price list read as an hourly rate, which is the number she has never
       been shown: brows pay £35 an hour, a hybrid full set pays £25. */
    earnings: { since_days: 180, treatments: [
      { id:'s3', name:'Brow lamination', visits: 11, price_pence:3500,
        duration_min:60, taken_pence:38500, per_hour_pence:3500 },
      { id:'s2', name:'Russian infills', visits: 18, price_pence:4000,
        duration_min:90, taken_pence:72000, per_hour_pence:2667 },
      { id:'s1', name:'Hybrid full set', visits: 24, price_pence:5000,
        duration_min:120, taken_pence:120000, per_hour_pence:2500 }] },
    pack: {
      studio: { name: STUDIO.name, slug: STUDIO.slug, address: STUDIO.address },
      client: { name:'Ruby Hall', email:'ruby@example.com', phone:'07700 900111',
                address:'8 Oaston Road, Nuneaton CV11 6JZ', since: iso(-420, 10) },
      valid_months: 6, produced_at: new Date().toISOString(),
      patch_tests: [
        { tested_at: iso(-21, 11), valid_until: iso(162, 11), from_booking: true,
          note: 'No reaction at 48 hours.' },
        { tested_at: iso(-210, 11), valid_until: iso(-28, 11), from_booking: false,
          note: 'Recorded from her card.' }],
      appointments: [
        { ref:'AB12CD34', starts_at: iso(0, 14), service:'Hybrid full set',
          status:'confirmed', price_pence:5000, needed_patch_hours:48,
          address:'8 Oaston Road, Nuneaton CV11 6JZ' },
        { ref:'ZZ88YY11', starts_at: iso(-21, 11), service:'Hybrid full set',
          status:'confirmed', price_pence:5000, needed_patch_hours:48, address:null },
        { ref:'QQ44RR77', starts_at: iso(-49, 10), service:'Brow lamination',
          status:'cancelled', price_pence:3500, needed_patch_hours:24, address:null }] } };

  /* ------------------------------------------------------------ dashboard -- */
  console.log('her dashboard');
  {
    const ctx = await ctxFor(browser);
    const page = await ctx.newPage();
    await wire(page, APP_STUB, appState);
    await page.goto(srv.origin + '/app/', { waitUntil:'load' });
    await page.waitForTimeout(600);
    await shot(page, '01-diary');
    /* The first four, which a studio sees until she has done them. */
    await page.evaluate(() => { try{
      ['trade','days','share'].forEach(k =>
        localStorage.removeItem('bi.setup.studio-mila.' + k)); }catch(e){} });
    await page.reload({ waitUntil:'load' });
    await page.waitForTimeout(700);
    await shot(page, '34-first-four');

    /* The phone booking, open, because closed it is one line of text. */
    await page.click('#add-sum');
    await page.waitForTimeout(250);
    await page.fill('#ab-date', iso(11, 10).slice(0, 10));
    await page.fill('#ab-time', '10:30');
    await page.fill('#ab-name', 'Carla Mendes');
    await page.fill('#ab-mail', 'carla@example.com');
    await page.fill('#ab-tel', '07700 900333');
    await page.fill('#ab-addr', '8 Barras Lane, Coventry');
    await page.check('#ab-again');
    await page.waitForTimeout(200);
    await shot(page, '21-add-booking', { fullPage: true });
    await page.click('#add-sum');
    await page.waitForTimeout(200);

    for (const [tab, name] of [['clients','02-clients'], ['rebook','03-rebooking'],
                               ['treats','04-treatments'], ['days','05-days'],
                               ['share','06-share'], ['page','07-your-page']]) {
      await page.click(`.tab[data-panel="${tab}"]`);
      await page.waitForTimeout(tab === 'share' ? 900 : 350);
      if (tab === 'clients') {               // one card open, so the detail shows
        await page.locator('.cline').first().locator('summary').click();
        await page.waitForTimeout(200);
      }
      await shot(page, name,
        { fullPage: ['treats','page','share','days','rebook'].indexOf(tab) !== -1 });
    }
    await ctx.close();
  }

  /* ------------------------------------------------------ picking a trade --
     Twelve now, not four, and 'Something else' is no longer an empty list and
     a shrug. This is the first screen anybody sees. */
  {
    const fresh = JSON.parse(JSON.stringify(appState));
    fresh.studio = null;
    fresh.takenSlugs = [];
    const ctx = await ctxFor(browser);
    const page = await ctx.newPage();
    await wire(page, APP_STUB, fresh);
    await page.goto(srv.origin + '/app/', { waitUntil:'load' });
    await page.waitForTimeout(800);
    await shot(page, '26-trades');
    await ctx.close();
  }

  /* ------------------------------------------------------------- a salon --
     The same dashboard for a trade that is not lashes, because that is the
     whole point of 019: the product used to be identical for everybody after
     the first five minutes. */
  {
    const salon = JSON.parse(JSON.stringify(appState));
    salon.studio.name = 'Ivy & Fern';
    salon.studio.slug = 'ivy-and-fern';
    salon.studio.trade = 'hair';
    salon.studio.trade_profile = { label:'Hair', client:'client', lead:'gaps', gaps:true,
      patch:'Colour needs an allergy alert test 48 hours before. That is the one your insurer will ask about.' };
    salon.studio.services = [
      { id:'h1', name:'Cut & blow dry', price_pence:3500, duration_min:60, active:true,
        sort:1, photo_path:null, rebook_weeks:6, patch_test_hours:null,
        records_patch_test:false, gap_after_min:null, gap_min:null },
      { id:'h2', name:'Root tint', price_pence:4500, duration_min:90, active:true,
        sort:2, photo_path:null, rebook_weeks:6, patch_test_hours:48,
        records_patch_test:false, gap_after_min:20, gap_min:35 },
      { id:'h3', name:'Full head highlights', price_pence:9000, duration_min:180, active:true,
        sort:3, photo_path:null, rebook_weeks:10, patch_test_hours:48,
        records_patch_test:false, gap_after_min:60, gap_min:45 },
      { id:'h4', name:'Balayage', price_pence:9500, duration_min:180, active:true,
        sort:4, photo_path:null, rebook_weeks:12, patch_test_hours:48,
        records_patch_test:false, gap_after_min:60, gap_min:45 },
      { id:'h5', name:'Fringe trim', price_pence:1000, duration_min:15, active:true,
        sort:5, photo_path:null, rebook_weeks:null, patch_test_hours:null,
        records_patch_test:false, gap_after_min:null, gap_min:null }];
    salon.earnings = { since_days: 180, treatments: [
      { id:'h5', name:'Fringe trim', visits: 22, price_pence:1000,
        duration_min:15, taken_pence:22000, per_hour_pence:4000 },
      { id:'h1', name:'Cut & blow dry', visits: 61, price_pence:3500,
        duration_min:60, taken_pence:213500, per_hour_pence:3500 },
      { id:'h2', name:'Root tint', visits: 34, price_pence:4500,
        duration_min:90, taken_pence:153000, per_hour_pence:3000 },
      { id:'h4', name:'Balayage', visits: 12, price_pence:9500,
        duration_min:180, taken_pence:114000, per_hour_pence:3167 },
      { id:'h3', name:'Full head highlights', visits: 18, price_pence:9000,
        duration_min:180, taken_pence:162000, per_hour_pence:3000 }] };
    salon.patches = {};
    /* A colour at ten, and the fringe trim sold into the middle of it. */
    const t10 = iso(0, 10, 0), t1030 = iso(0, 10, 30);
    salon.studio.bookings = [
      { id:'hb1', ref:'RT44KK21', starts_at: t10,
        ends_at: new Date(new Date(t10).getTime() + 90 * 60000).toISOString(),
        client_name:'Nadia Shah', client_email:'nadia@example.com',
        client_phone:'07700 900444', client_id:'c1', status:'confirmed',
        service:'Root tint', price_pence:4500, gap_after_min:20, gap_min:35 },
      { id:'hb2', ref:'FT11MM02', starts_at: t1030,
        ends_at: new Date(new Date(t1030).getTime() + 15 * 60000).toISOString(),
        client_name:'Erin Boyle', client_email:'erin@example.com',
        client_phone:null, client_id:'c2', status:'confirmed',
        service:'Fringe trim', price_pence:1000, gap_after_min:null, gap_min:null }];

    const ctx = await ctxFor(browser);
    const page = await ctx.newPage();
    await wire(page, APP_STUB, salon);
    await page.goto(srv.origin + '/app/', { waitUntil:'load' });
    await page.waitForTimeout(700);
    await shot(page, '24-salon-diary');
    await page.click('.tab[data-panel="treats"]');
    await page.waitForTimeout(400);
    await shot(page, '25-salon-processing-time', { fullPage: true });
    await ctx.close();
  }

  /* on a phone, which is where she actually uses it */
  {
    const ctx = await ctxFor(browser, Object.assign({}, devices['iPhone 12'],
      { deviceScaleFactor: 3 }));
    const page = await ctx.newPage();
    await wire(page, APP_STUB, appState);
    await page.goto(srv.origin + '/app/', { waitUntil:'load' });
    await page.waitForTimeout(600);
    await shot(page, '08-diary-phone');
    await ctx.close();
  }

  /* The insurance pack opens in a window of its own, so it has to be caught. */
  {
    const ctx = await ctxFor(browser, { viewport:{ width:900, height:1180 }, deviceScaleFactor:2 });
    const page = await ctx.newPage();
    await wire(page, APP_STUB, appState);
    await page.goto(srv.origin + '/app/', { waitUntil:'load' });
    await page.waitForTimeout(600);
    await page.click('.tab[data-panel="clients"]');
    await page.locator('.cline').first().waitFor({ timeout:5000 }).catch(() => {});
    await page.locator('.cline').first().locator('summary').click();
    await page.waitForTimeout(250);
    const popping = page.waitForEvent('popup');
    await page.locator('.cline').first().locator('.packgo').click();
    const pack = await popping;
    await pack.waitForLoadState('domcontentloaded');
    await pack.waitForTimeout(400);
    await pack.screenshot({ path: path.join(OUT, '20-insurance-pack.png'), fullPage: true });
    console.log('  20-insurance-pack.png');
    await ctx.close();
  }

  /* -------------------------------------------------------- booking page -- */
  console.log('her clients’ page');
  const bookState = kind => ({ studio: Object.assign({}, STUDIO, { venue_kind: kind }) });

  for (const [kind, name] of [['both','09-book-both'], ['mobile','10-book-mobile'],
                              ['salon','11-book-salon']]) {
    const ctx = await ctxFor(browser, Object.assign({}, devices['iPhone 12'],
      { deviceScaleFactor: 3 }));
    const page = await ctx.newPage();
    await wire(page, BOOK_STUB, bookState(kind));
    await page.goto(srv.origin + '/studio-mila', { waitUntil:'load' });
    await page.waitForTimeout(500);
    await shot(page, name, { fullPage: true });
    await ctx.close();
  }

  /* the whole way through, on a phone: treatment, day, time, details */
  {
    const ctx = await ctxFor(browser, Object.assign({}, devices['iPhone 12'],
      { deviceScaleFactor: 3 }));
    const page = await ctx.newPage();
    await wire(page, BOOK_STUB, bookState('mobile'));
    await page.goto(srv.origin + '/studio-mila', { waitUntil:'load' });
    await page.waitForTimeout(400);
    await page.locator('.svc').first().click();
    await page.waitForTimeout(700);
    await shot(page, '12-book-calendar');
    await page.locator('.grid button.open').first().click();
    await page.waitForTimeout(400);
    await page.locator('#time-list button').first().click();
    await page.waitForTimeout(400);
    await shot(page, '13-book-form', { fullPage: true });
    await page.fill('#cname', 'Ruby Hall');
    await page.fill('#cmail', 'ruby@example.com');
    await page.fill('#caddr', '8 Oaston Road, Nuneaton CV11 6JZ');
    await page.waitForTimeout(2200);
    await page.click('#go');
    await page.waitForTimeout(700);
    await shot(page, '14-book-done', { fullPage: true });
    await ctx.close();
  }

  /* ------------------------------------------------------ marketing site -- */
  console.log('the site that sells it');
  {
    const ctx = await ctxFor(browser);
    const page = await ctx.newPage();
    await page.goto(srv.origin + '/', { waitUntil:'load' });
    await page.waitForTimeout(700);
    await page.evaluate(() => window.scrollTo(0, 0));
    await shot(page, '15-site-hero');
    for (const [sel, name] of [['#how','16-site-how'], ['#safe','17-site-patch'],
                               ['#compare','18-site-compare'], ['#plus','22-site-plus'],
                               ['#pricing','19-site-pricing']]) {
      const el = await page.$(sel);
      if (!el) continue;
      await el.scrollIntoViewIfNeeded();
      await page.waitForTimeout(700);
      await shot(page, name);
      /* Both sides of the billing switch, because the yearly side is the whole
         reason the switch is there. */
      if (sel === '#pricing') {
        /* the section is taller than the screen, so framing on its heading
           leaves the three cards - the point of it - below the fold */
        await (await page.$('#billsw')).scrollIntoViewIfNeeded();
        await page.evaluate(() => window.scrollBy(0, -110));
        await page.waitForTimeout(500);
        await shot(page, name);
        await page.click('#billsw [data-cycle="year"]');
        await page.waitForTimeout(700);
        await shot(page, '23-site-pricing-yearly');
        await page.click('#billsw [data-cycle="month"]');
      }
    }
    await ctx.close();
  }

  await browser.close();
  await srv.close();
  console.log('\n' + OUT);
})();
