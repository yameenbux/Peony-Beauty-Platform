const { chromium } = require('playwright');
const B = 'http://127.0.0.1:8099';
const STUB = `
window.supabase={createClient:function(){var S=window.__S;
 function res(d,e){return Promise.resolve({data:d===undefined?null:d,error:e||null});}
 return {storage:{from:function(){return{getPublicUrl:function(p){return{data:{publicUrl:'https://stub.test/'+p}};}};}},
  rpc:function(n,a){S.ops.push({n:n,a:a});
   if(n==='get_studio')return res(a.p_slug===S.slug?S.studio:null);
   if(n==='free_slots')return res([]);
   if(n==='get_booking')return res(S.booking);
   return res(null);},
  auth:{getSession:function(){return res({session:null});},
   onAuthStateChange:function(){return {data:{subscription:{unsubscribe:function(){}}}};},
   signInWithOtp:function(){return res({});},signOut:function(){return res({});}}};}};`;
const S = { slug:'studio-mila', ops:[], studio:{ slug:'studio-mila', name:'Studio Mila',
  tagline:'Mobile lashes', trade:'lashes', timezone:'Europe/London', plan:'free',
  notice_hours:24, services:[{id:'s1',name:'Hybrid full set',price_pence:5000,duration_min:120}],
  openings:[] }, booking:{ ref:'AB12CD34', starts_at:new Date(Date.now()+864e5*9).toISOString(),
  ends_at:new Date(Date.now()+864e5*9).toISOString(), status:'confirmed', client_name:'Ruby',
  service:'Hybrid full set', price_pence:5000, studio:'Studio Mila', slug:'studio-mila',
  timezone:'Europe/London', cancel_hours:24, can_cancel:true } };

(async () => {
  // The host tests below need booked-in.test to resolve. Chromium can be told to
// map it itself, which keeps this runnable without editing /etc/hosts as root.
const b = await chromium.launch({ args: [
  "--host-resolver-rules=MAP booked-in.test 127.0.0.1," +
  "MAP studio-mila.booked-in.test 127.0.0.1,MAP www.booked-in.test 127.0.0.1",
]});
let fail = 0;
  const ok = (c,m)=>{console.log((c?'ok   ':'FAIL ')+m); if(!c) fail++;};
  async function go(path, tweak) {
    const ctx = await b.newContext({viewport:{width:1100,height:800}});
    const p = await ctx.newPage(); const errs=[];
    p.on('pageerror', e=>errs.push(e.message));
    p.on('console', m=>{if(m.type()==='error') errs.push(m.text());});
    await p.route('**/supabase-js*/**', r=>r.fulfill({contentType:'application/javascript',body:STUB}));
    // stand in for the config Render writes from its environment variables
    await p.route('**/platform/config.js', r=>r.fulfill({contentType:'application/javascript',
      body:'window.BOOKEDIN={SUPABASE_URL:"https://stub.supabase.co",SUPABASE_ANON_KEY:"stub",'
          +'PAGE_HOST:"booked-in.test:8099",FUNCTIONS_URL:"https://fn.stub.test"};'}));
    await p.addInitScript(`window.__S=${JSON.stringify(S)};`);
    const resp = await p.goto(B+path, {waitUntil:'load'});
    await p.waitForTimeout(500);
    const out = await (tweak||(async x=>({})))(p);
    return {ctx,p,errs,status:resp.status(),out};
  }
  { const {ctx,p,errs,status} = await go('/');
    ok(status===200 && /Booked In/.test(await p.title()), `/ serves the marketing site (${status}, "${await p.title()}")`);
    ok(await p.isVisible('.hero'), '/ renders the hero');
    ok(errs.length===0, `/ has no console errors (${errs.length})`); await ctx.close(); }

  { const {ctx,p,errs,status} = await go('/studio-mila');
    ok(status===200, `/studio-mila is a 200, not a 404 (${status})`);
    ok((await p.textContent('#who'))==='Studio Mila', 'the rewrite reads the slug off the displayed path');
    ok(await p.isVisible('#main'), 'her booking page renders');
    const credit = await p.getAttribute('#credit a','href');
    ok(credit==='/', `the footer credit points at the marketing site (${credit})`);
    ok(errs.length===0, `no console errors on her page (${errs.length})`); await ctx.close(); }

  { const {ctx,p,status} = await go('/not-a-real-studio');
    ok(status===200 && await p.isVisible('#gone'),
       'an unknown name gets the booking page’s own "No page here", not a server 404'); await ctx.close(); }

  { const {ctx,p,errs,status} = await go('/app/');
    ok(status===200, `/app/ is served as a real file, the rewrite does not shadow it (${status})`);
    ok(await p.isVisible('#signin'), '/app/ shows the sign-in screen');
    ok(errs.length===0, `/app/ has no console errors (${errs.length})`); await ctx.close(); }

  { const {ctx,p,status} = await go('/book/manage.html?r=AB12CD34&t=11111111-2222-3333-4444-555555555555');
    ok(status===200 && (await p.textContent('#d-ref'))==='AB12CD34', 'the manage page resolves at its absolute path');
    const rebook = await p.getAttribute('#rebook','href');
    ok(rebook==='/studio-mila', `and links back to her page absolutely (${rebook})`); await ctx.close(); }

  // the assets the pages ask for
  for (const [path, type] of [['/site/logo.svg','image/svg'],['/platform/config.js','javascript'],
                              ['/app/app.css','css'],['/share.png','image/png'],
                              ['/privacy.html','html'],['/terms.html','html'],
                              ['/site/doc.css','css']]) {
    const ctx = await b.newContext(); const p = await ctx.newPage();
    const r = await p.goto(B+path);
    ok(r.status()===200 && (r.headers()['content-type']||'').includes(type.split('/').pop()),
       `${path} serves as ${type} (${r.status()}, ${r.headers()['content-type']})`);
    await ctx.close();
  }
  // The slug can arrive two ways and both have to work. PAGE_HOST is
  // booked-in.test here, so a label in front of it is hers and the bare host
  // is not — which is the distinction the dot-counting version got wrong.
  const HOSTS = [
    ['http://booked-in.test:8099/studio-mila',            'studio-mila', 'apex, slug in the path'],
    ['http://studio-mila.booked-in.test:8099/book/',      'studio-mila', 'a subdomain in front of the host (not deployed, but the code path works)'],
    ['http://www.booked-in.test:8099/studio-mila',        'studio-mila', 'www is ignored as a slug'],
    ['http://booked-in.test:8099/book/?s=studio-mila',    'studio-mila', 'the ?s= fallback'],
  ];
  for (const [url, want, label] of HOSTS) {
    const ctx = await b.newContext({viewport:{width:1000,height:800}});
    const p = await ctx.newPage();
    await p.route('**/supabase-js*/**', r=>r.fulfill({contentType:'application/javascript',body:STUB}));
    await p.route('**/platform/config.js', r=>r.fulfill({contentType:'application/javascript',
      body:'window.BOOKEDIN={SUPABASE_URL:"https://stub.supabase.co",SUPABASE_ANON_KEY:"stub",'
          +'PAGE_HOST:"booked-in.test:8099",FUNCTIONS_URL:""};'}));
    await p.addInitScript(`window.__S=${JSON.stringify(S)};`);
    await p.goto(url, {waitUntil:'load'});
    await p.waitForTimeout(450);
    const asked = await p.evaluate(()=>{
      const c = window.__S.ops.filter(o=>o.n==='get_studio')[0];
      return c ? c.a.p_slug : null; });
    ok(asked === want, `${label}: looked up "${asked}" (wanted "${want}")`);
    await ctx.close();
  }

  { const ctx = await b.newContext(); const p = await ctx.newPage();
    await p.route('**/supabase-js*/**', r=>r.fulfill({contentType:'application/javascript',body:STUB}));
    await p.route('**/platform/config.js', r=>r.fulfill({contentType:'application/javascript',
      body:'window.BOOKEDIN={SUPABASE_URL:"https://stub.supabase.co",SUPABASE_ANON_KEY:"stub",'
          +'PAGE_HOST:"booked-in.test:8099",FUNCTIONS_URL:""};'}));
    await p.addInitScript(`window.__S=${JSON.stringify(S)};`);
    await p.goto('http://booked-in.test:8099/', {waitUntil:'load'});
    await p.waitForTimeout(400);
    const asked = await p.evaluate(()=>{
      const c = window.__S.ops.filter(o=>o.n==='get_studio')[0];
      return c ? c.a.p_slug : '(none)'; });
    ok(asked === '(none)', `the bare host is not mistaken for a studio (asked for "${asked}")`);
    await ctx.close(); }

  // the footer links to these, and a legal page that 404s is worse than none
  for (const path of ['/privacy.html','/terms.html']) {
    const ctx = await b.newContext({viewport:{width:900,height:800}});
    const p = await ctx.newPage();
    await p.goto(B+path, {waitUntil:'load'});
    await p.waitForTimeout(400);
    const r = await p.evaluate(() => ({
      styled: getComputedStyle(document.body).fontFamily.includes('Jakarta'),
      h: document.querySelectorAll('h2').length,
      back: !!document.querySelector('.doc-back'),
      over: document.documentElement.scrollWidth - document.documentElement.clientWidth }));
    ok(r.styled && r.h > 4 && r.back && r.over <= 1,
       `${path} renders styled with ${r.h} sections and a way back (overflow ${r.over}px)`);
    await ctx.close();
  }

  await b.close();
  console.log(fail ? `\n${fail} failure(s)` : '\nall passed');
  process.exit(fail?1:0);
})();
