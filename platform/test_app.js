const { chromium, devices } = require('playwright');
const PAGE = 'file:///home/user/test/app/index.html';
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

const CONFIG = `window.PEONY = { SUPABASE_URL:"https://stub.supabase.co",
  SUPABASE_ANON_KEY:"stub", PAGE_HOST:"peony.uk",
  FUNCTIONS_URL:"https://fn.stub.test" };`;
const NOFN = CONFIG.replace('FUNCTIONS_URL:"https://fn.stub.test"', 'FUNCTIONS_URL:""');

async function mk(browser, state, dev, cfg) {
  const ctx = await browser.newContext(dev || { viewport:{width:1280,height:900} });
  const page = await ctx.newPage();
  const errs = [];
  page.on('console', m => { if (m.type()==='error') errs.push(m.text()); });
  page.on('pageerror', e => errs.push('PAGEERROR ' + e.message));
  await page.route('**/supabase-js*/**', r => r.fulfill({ contentType:'application/javascript', body: STUB }));
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
    closures:[{on_date:'2026-12-24', reason:'Christmas'}],
    services:[
      {id:'s1',name:'Hybrid full set',price_pence:5000,duration_min:120,active:true,sort:1},
      {id:'s2',name:'Russian infills',price_pence:4000,duration_min:90,active:true,sort:2}],
    openings:[{id:'o1',weekday:2,starts:'09:00:00',ends:'18:00:00',area:''},
              {id:'o2',weekday:5,starts:'10:00:00',ends:'16:00:00',area:''}],
    bookings: bookings }};
}

(async () => {
  const browser = await chromium.launch();
  let fail = 0;
  const ok = (c, m) => { console.log((c?'ok   ':'FAIL ') + m); if(!c) fail++; };

  // a genuinely oversized photograph, the sort that comes off a phone
  const fs = require('fs');
  const BIGPNG = '/tmp/peony-big-photo.png';
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
    await page.fill('#email','ellie@example.com');
    await page.click('#otp-go');
    await page.waitForTimeout(150);
    const said = await page.textContent('#otp-said');
    ok(/Sent/.test(said), 'asking for a link says it was sent');
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
    ok(errs.length===0, 'no console errors through the wizard ('+errs.length+')');
    await ctx.close(); }

  // --- dashboard, empty diary ---
  { const {ctx,page,errs} = await mk(browser, withStudio([]));
    await page.waitForTimeout(250);
    ok(await page.isVisible('#app'), 'an existing studio opens the dashboard');
    ok(/Nothing booked yet/.test(await page.textContent('#diary-list')), 'an empty diary invites her to share the link');
    ok(await page.textContent('#s-today') === '0', 'today counts zero');
    await page.click('.tab[data-panel="page"]');
    ok((await page.textContent('#live-url')) === 'peony.uk/studio-mila', 'her link is shown');
    ok(/Booked with Peony/.test(await page.textContent('#plan-line')), 'the free plan explains the footer credit');
    ok(await page.isVisible('#plan-buy'), 'a free studio is offered Pro');
    ok(await page.isHidden('#plan-manage'), 'and has no billing to manage yet');
    ok(/Reminders sent/.test(await page.textContent('#pro-list')), 'it says what Pro buys');
    // text assertions cannot see a missing sprite; a 300x150 fallback box can
    const icon = await page.locator('#pro-list .mk').first().boundingBox();
    ok(icon && icon.width <= 24 && icon.height <= 24,
       `the tick icons render at their intended size (${icon?Math.round(icon.width)+'x'+Math.round(icon.height):'missing'})`);
    const listH = (await page.locator('#pro-list').boundingBox()).height;
    ok(listH < 120, `the Pro list stays compact (${Math.round(listH)}px)`);
    ok(errs.length===0, 'no console errors on an empty dashboard ('+errs.length+')');
    await ctx.close(); }

  // --- dashboard with bookings ---
  const soon = new Date(Date.now() + 3*36e5).toISOString();
  const later = new Date(Date.now() + 2*864e5).toISOString();
  { const {ctx,page,errs} = await mk(browser, withStudio([
      {id:'b1',ref:'AB12',starts_at:soon,ends_at:soon,client_name:'Ruby H.',
       client_email:'r@x.com',status:'confirmed',service:'Hybrid full set',price_pence:5000},
      {id:'b2',ref:'CD34',starts_at:later,ends_at:later,client_name:'Sian T.',
       client_email:'s@x.com',status:'confirmed',service:'Russian infills',price_pence:4000},
      {id:'b3',ref:'EF56',starts_at:later,ends_at:later,client_name:'Mia K.',
       client_email:'m@x.com',status:'cancelled',service:'Russian infills',price_pence:4000}]));
    await page.waitForTimeout(250);
    ok(await page.textContent('#s-today') === '1', 'today counts only today');
    ok(await page.textContent('#s-week') === '2', 'the week counts confirmed only');
    ok(await page.textContent('#s-taken') === '£90', 'the week total excludes the cancelled one');
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
    for (const panel of ['diary','treats','days','page']) {
      await page.click(`.tab[data-panel="${panel}"]`);
      await page.waitForTimeout(120);
      const r = await page.evaluate(() => ({
        sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth }));
      if (r.sw - r.cw > worst) { worst = r.sw - r.cw; where = panel; }
    }
    await page.screenshot({ path:`${OUT}/app-${n}.png` });
    ok(worst <= 1 && errs.length === 0,
       `${n} (${await page.evaluate(()=>document.documentElement.clientWidth)}px) no overflow across all four panels` +
       (worst>1?` — ${worst}px on ${where}`:'') + (errs.length?` errs=${errs.length}`:''));
    await ctx.close();
  }

  await browser.close();
  console.log(fail ? `\n${fail} failure(s)` : '\nall passed');
  process.exit(fail ? 1 : 0);
})();
