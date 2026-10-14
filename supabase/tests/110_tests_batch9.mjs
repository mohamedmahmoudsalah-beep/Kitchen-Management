// اختبارات 018 (Dashboard + Low Stock) على Postgres تجريبي (PGlite). التشغيل: npm i --no-save @electric-sql/pglite && node supabase/tests/110_tests_batch9.mjs
import { PGlite } from '@electric-sql/pglite';
import { btree_gist } from '@electric-sql/pglite/contrib/btree_gist';
import { pg_trgm } from '@electric-sql/pglite/contrib/pg_trgm';
import fs from 'fs';
import path from 'path'; import { fileURLToPath } from 'url';
const base=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..')+'/';
const db = new PGlite({ extensions: { btree_gist, pg_trgm } });
await db.exec(fs.readFileSync(base+'tests/00_supabase_stub.sql','utf8'));
for (const f of fs.readdirSync(base+'migrations').sort()) await db.exec(fs.readFileSync(base+'migrations/'+f,'utf8'));
let fails=0; const ok=(n,c,extra='')=>{ console.log((c?'ok  - ':'FAIL - ')+n, c?'':extra); if(!c) fails++; };
const q=async(s,p)=> (await db.query(s,p)).rows;
const err=async(s,p)=>{ try{ await db.query(s,p); return null;}catch(e){return e.message;} };

await db.exec(`insert into auth.users (id,email) values ('00000000-0000-0000-0000-000000000001','mohamed.mahmoudsalah@breadfast.com'),('00000000-0000-0000-0000-000000000002','viewer@breadfast.com')`);
await db.exec(`select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false)`);
const kid = async(c)=> (await q(`select id from kitchens where code=$1`,[c]))[0].id;
const maadi=await kid('MAADI'), nc7=await kid('NC7');
const prod=async(o)=> (await q(`select public.save_product(null,$1::jsonb) as id`,[JSON.stringify(o)]))[0].id;
const A=await prod({syt_code:'RM0500-A',generic_code:'RM0500',name:'olives A',factor:'1',cost_per_uom:'100'});
const B=await prod({syt_code:'RM0500-B',generic_code:'RM0500',name:'olives B',factor:'0.36',cost_per_uom:'400'});
const X=await prod({syt_code:'X1',name:'solo',factor:'1',cost_per_uom:'10'});
const post=async(type,k,d,lines)=>{ const id=(await q(`select public.save_document(null,$1,$2,$3,null,$4::jsonb) as id`,[type,k,d,JSON.stringify(lines)]))[0].id; await q(`select public.post_document($1)`,[id]); };
const L=(p,qty)=>({product_id:p,mode:'BASE',qty:String(qty)});
await post('PURCHASE',maadi,'2026-10-01',[L(A,5),L(X,100)]);
await post('PURCHASE',maadi,'2026-10-03',[L(B,17.28),L(X,20)]);
await post('WH_TXN',maadi,'2026-10-05',[L(X,10)]);
await post('PURCHASE',nc7,'2026-10-04',[L(X,50)]);

// ---- Low stock import
const rows=(a)=>JSON.stringify(a);
let r=(await q(`select public.stock_levels_import($1,$2::jsonb,'upsert',false) as r`,[maadi,rows([{row:2,code:'RM0500-B',low:'10',high:'50'},{row:3,code:'X1',low:'20',high:'200'}])]))[0].r;
ok('validate passes and counts', r.ok===true && r.created===2 && r.committed===false, JSON.stringify(r));
ok('validate does not save', (await q(`select count(*)::int n from stock_levels`))[0].n===0);
r=(await q(`select public.stock_levels_import($1,$2::jsonb,'upsert',false) as r`,[maadi,rows([{row:2,code:'NOPE',low:'1',high:'5'},{row:3,code:'X1',low:'30',high:'20'},{row:4,code:'RM0500-A',low:'1',high:'5'},{row:5,code:'RM0500-B',low:'1',high:'5'},{row:6,code:'X1',low:'abc',high:'5'},{row:7,code:'',low:'1',high:'5'}])]))[0].r;
ok('errors by row, nothing saved', r.ok===false && r.error_count===5, JSON.stringify(r));
ok('error rows right', JSON.stringify(r.errors.map(e=>e.row))==='[2,3,5,6,7]', JSON.stringify(r.errors));
ok('duplicate generic message names first row', /صف 4/.test(r.errors.find(e=>e.row===5).reason));
r=(await q(`select public.stock_levels_import($1,$2::jsonb,'upsert',true) as r`,[maadi,rows([{row:2,code:'RM0500-B',low:'10',high:'50'},{row:3,code:'X1',low:'20',high:'200'}])]))[0].r;
ok('commit saves 2', r.ok && (await q(`select count(*)::int n from stock_levels`))[0].n===2);
ok('syt code stored under Generic key', (await q(`select count(*)::int n from stock_levels where item_key='RM0500'`))[0].n===1);
let rep=await q(`select * from report_low_stock($1)`,[maadi]);
const by=Object.fromEntries(rep.map(x=>[x.item_key,x]));
ok('generic group qty = A+B', Number(by['RM0500'].qty)===22.28, JSON.stringify(by['RM0500']));
ok('RM0500 status HIGH? (22.28 between 10 and 50 = AVG)', by['RM0500'].status==='AVG');
ok('X1 = 100+20-10 = 110 AVG', Number(by['X1'].qty)===110 && by['X1'].status==='AVG');
ok('value uses each size cost', Number(by['RM0500'].value)===5*100+17.28*400, String(by['RM0500'].value));
ok('name from last purchased size (B)', by['RM0500'].product_name==='olives B', by['RM0500'].product_name);
// thresholds -> statuses
await q(`select public.stock_levels_import($1,$2::jsonb,'upsert',true)`,[maadi,rows([{row:2,code:'X1',low:'110',high:'200'},{row:3,code:'RM0500',low:'1',high:'22.28'}])]);
rep=await q(`select * from report_low_stock($1)`,[maadi]); const b2=Object.fromEntries(rep.map(x=>[x.item_key,x]));
ok('qty == low → LOW', b2['X1'].status==='LOW'); ok('qty == high → HIGH', b2['RM0500'].status==='HIGH');
ok('LOW sorted first', rep[0].status==='LOW');
// replace removes others, unchanged rows detected
r=(await q(`select public.stock_levels_import($1,$2::jsonb,'replace',false) as r`,[maadi,rows([{row:2,code:'X1',low:'110',high:'200'}])]))[0].r;
ok('replace preview: removed 1, unchanged 1', r.removed===1 && r.unchanged===1, JSON.stringify(r));
await q(`select public.stock_levels_import($1,$2::jsonb,'replace',true)`,[maadi,rows([{row:2,code:'X1',low:'110',high:'200'}])]);
ok('replace removed the other', (await q(`select count(*)::int n from stock_levels where kitchen_id=$1`,[maadi]))[0].n===1);
// item with stock but no level → NOT_SET; level but zero stock → shows with 0
rep=await q(`select * from report_low_stock($1)`,[maadi]); ok('NOT_SET shown for stocked item without levels', rep.some(x=>x.item_key==='RM0500'&&x.status==='NOT_SET'));
// kitchens are independent
rep=await q(`select * from report_low_stock($1)`,[nc7]); ok('nc7 only its own stock, no levels', rep.length===1 && rep[0].status==='NOT_SET' && Number(rep[0].qty)===50);
await q(`select public.stock_levels_import($1,$2::jsonb,'upsert',true)`,[nc7,rows([{row:2,code:'X1',low:'60',high:'90'}])]);
ok('nc7 X1 LOW (50<=60)', (await q(`select status from report_low_stock($1)`,[nc7]))[0].status==='LOW');
ok('maadi unaffected', (await q(`select low_qty from stock_levels where kitchen_id=$1`,[maadi]))[0].low_qty==='110.0000'||Number((await q(`select low_qty from stock_levels where kitchen_id=$1`,[maadi]))[0].low_qty)===110);
// audit
ok('audit log has stock_levels rows', (await q(`select count(*)::int n from audit_log where table_name='stock_levels'`))[0].n>=3);

// ---- permissions (viewer has no write; normal user w/o page)
await db.exec(`update profiles set role='viewer', is_active=true where email='viewer@breadfast.com'`);
await db.exec(`select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false); set role authenticated;`);
ok('viewer cannot import', /مش مسموحلك/.test(await err(`select public.stock_levels_import($1,$2::jsonb,'upsert',true)`,[maadi,rows([{row:2,code:'X1',low:'1',high:'2'}])])||''));
ok('viewer w/o kitchen cannot read report', /مش مسموحلك/.test(await err(`select * from report_low_stock($1)`,[maadi])||''));
ok('helper not callable by users', /permission denied/.test(await err(`select * from _low_stock_rows(array[$1::uuid])`,[maadi])||''));
await db.exec(`reset role; select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);`);

// ---- dashboard
let s=(await q(`select dashboard_summary($1) as s`,[maadi]))[0].s;
ok('summary maadi stock value', Number(s.stock_value)===5*100+17.28*400+110*10, String(s.stock_value));
ok('summary has low_stock counts', s.low_stock && s.low_stock.low===1, JSON.stringify(s.low_stock));
ok('summary by_category present', Array.isArray(s.by_category));
s=(await q(`select dashboard_summary(null) as s`))[0].s;
ok('ALL: 4 kitchens, stock = maadi + nc7', s.kitchens_count===4 && Number(s.stock_value)===5*100+17.28*400+110*10+50*10, JSON.stringify([s.kitchens_count,s.stock_value]));
ok('ALL: by_kitchen lists all kitchens', s.by_kitchen.length===4);
ok('ALL: top product X1 aggregated across kitchens', s.top_products.some(p=>p.syt_code==='X1' && Number(p.qty)===160));
let t=await q(`select * from dashboard_trend($1,'2026-09-28','2026-10-07')`,[maadi]);
ok('trend has 10 days', t.length===10);
const d=(x)=>t.find(r=>String(r.day).startsWith(x)||new Date(r.day).toISOString().slice(0,10)===x);
ok('before opening = 0', Number(d('2026-09-30').stock_value)===0);
ok('oct 1 = opening 5*100+100*10', Number(d('2026-10-01').stock_value)===1500, String(d('2026-10-01').stock_value));
ok('oct 3 purchases value', Number(d('2026-10-03').purchases_value)===17.28*400+200, String(d('2026-10-03').purchases_value));
ok('oct 5 usage 10*10', Number(d('2026-10-05').usage_value)===100);
ok('last day equals current stock value', Number(d('2026-10-07').stock_value)===5*100+17.28*400+110*10);
t=await q(`select * from dashboard_trend(null,'2026-10-04','2026-10-04')`);
ok('ALL trend includes nc7 purchase', Number(t[0].purchases_value)===500, String(t[0].purchases_value));
ok('trend > 180 days rejected', /180/.test(await err(`select * from dashboard_trend($1,'2026-01-01','2026-10-01')`,[maadi])||''));

// ---- reset wipes stock_levels
r=(await q(`select public.reset_all_data('2003') as r`))[0].r;
ok('reset reports stock_levels', r.stock_levels>=2);
ok('stock_levels empty after reset', (await q(`select count(*)::int n from stock_levels`))[0].n===0);
console.log(fails? `\n${fails} FAILED`:'\nALL 018 SQL TESTS PASSED'); process.exit(fails?1:0);
