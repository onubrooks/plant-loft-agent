-- Run in SQL Editor. All test writes are rolled back.
begin;
do $$
declare q jsonb; first_request jsonb; replay jsonb; bad boolean;
 base jsonb := '{"session_id":"test-session-001","kind":"RENTAL","transport":"SELF_PICKUP","start_at":"2026-11-10T10:00:00+01:00","end_at":"2026-11-11T10:00:00+01:00","transport_confirmed":true,"event_logistics":{"venue_access_at":"2026-11-10T08:00:00+01:00","setup_ready_at":"2026-11-10T09:30:00+01:00","onsite_contact":"Demo contact 08000000000"}}';
begin
 q:=plant_loft_tool('prepare_quote',base||'{"items":[{"category":"GOLDEN_PALM","quantity":9}]}');
 assert (q#>>'{summary,goods_or_rental_kobo}')::bigint=4050000,'9-palm price';
 q:=plant_loft_tool('prepare_quote',base||'{"items":[{"category":"GOLDEN_PALM","quantity":6},{"category":"LADY_PALM","quantity":4},{"category":"SMALL_PLANT","quantity":2}],"setup":true,"end_at":"2026-11-12T10:00:00+01:00"}');
 assert (q#>>'{summary,known_subtotal_kobo}')::bigint=9800000,'Mixed palms, small plants, two periods, setup';
 q:=plant_loft_tool('prepare_quote',base||'{"items":[{"category":"GOLDEN_PALM","quantity":9},{"category":"SMALL_PLANT","quantity":1}]}');
 assert (q#>>'{summary,goods_or_rental_kobo}')::bigint=4250000,'Small plants excluded from tier';
 q:=plant_loft_tool('prepare_quote',base||'{"items":[{"category":"GOLDEN_PALM","quantity":10}],"transport":"BUSINESS_DELIVERY","transport_confirmed":true}');
 assert (q#>>'{summary,goods_or_rental_kobo}')::bigint=3500000,'10-palm rate';
 assert q#>'{summary,final_total_kobo}'='null'::jsonb,'Unknown transport blocks final total';
 bad:=false;
 begin perform plant_loft_tool('confirm_request',jsonb_build_object('session_id','test-session-001','quote_id',q->>'quote_id','confirmed',false)); exception when raise_exception then bad:=true; end;
 assert bad,'Confirmation required';
 first_request:=plant_loft_tool('confirm_request',jsonb_build_object('session_id','test-session-001','quote_id',q->>'quote_id','confirmed',true));
 update plant_loft_quotes set expires_at=now()-interval '1 hour' where id=(q->>'quote_id')::uuid;
 replay:=plant_loft_tool('confirm_request',jsonb_build_object('session_id','test-session-001','quote_id',q->>'quote_id','confirmed',true));
 assert first_request->>'id'=replay->>'id','Replay returns same result even after quote expiry';
 assert (select count(*) from plant_loft_requests where quote_id=(q->>'quote_id')::uuid)=1,'Exactly one request';
 replay:=plant_loft_tool('get_request',jsonb_build_object('session_id','different-session','quote_id',q->>'quote_id'));
 assert replay->>'found'='false','Cross-session lookup';
 q:=plant_loft_tool('prepare_quote',base||'{"items":[{"category":"GOLDEN_PALM","quantity":2}],"end_at":"2026-11-11T11:00:00+01:00"}');
 assert q#>>'{summary,rental_periods}'='2','Twenty-five hours bills two started days';
 assert (q#>>'{summary,end_at}')::timestamptz='2026-11-11T11:00:00+01:00'::timestamptz,'Actual collection time remains unchanged';
 q:=plant_loft_tool('prepare_quote','{"session_id":"test-session-001","kind":"SALE","transport":"SELF_PICKUP","items":[{"product_id":"plant-01","pot_id":"pot-19","quantity":2}],"transport_confirmed":true}');
 assert (q#>>'{summary,known_subtotal_kobo}')::bigint=2300000,'Sale uses stored plant and pot prices';
 assert not has_function_privilege('anon','public.plant_loft_tool(text,jsonb)','EXECUTE'),'Anonymous RPC forbidden';
 assert not has_table_privilege('anon','public.plant_loft_requests','SELECT'),'Anonymous record access forbidden';
end $$;
select 'PASS: rental boundaries, mixed tiers, duration, transport, confirmation, replay, session scope, sale pricing, permissions' as result;
rollback;
